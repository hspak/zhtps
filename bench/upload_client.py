"""Closed-loop checksum uploads with a warmup and explicit completion window."""

import argparse
import collections
import hashlib
import http.client
import json
from pathlib import Path
import queue
import socket
import struct
import subprocess
import threading
import time
import zlib


def tcp_info(connection):
    # Linux's append-only tcp_info layout, through tcpi_sndbuf_limited.
    raw = connection.sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_INFO, 232)
    fields = {
        'rto_us': ('I', 8), 'unacked': ('I', 24), 'lost': ('I', 32),
        'rtt_us': ('I', 68), 'snd_cwnd': ('I', 80), 'total_retrans': ('I', 100),
        'bytes_acked': ('Q', 120), 'notsent_bytes': ('I', 144),
        'delivery_rate': ('Q', 160), 'busy_us': ('Q', 168),
        'rwnd_limited_us': ('Q', 176), 'sndbuf_limited_us': ('Q', 184),
    }
    return {name: struct.unpack_from('=' + fmt, raw, offset)[0]
            for name, (fmt, offset) in fields.items()}


def probe_queue(connection, interface, body, expected):
    """Observe this socket's FQ-CoDel bucket while other benchmark sockets idle."""
    stopped = threading.Event()
    observed = collections.Counter()
    samples = []
    errors = []

    def observe():
        try:
            while not stopped.is_set():
                result = subprocess.run(['tc', '-j', '-s', 'class', 'show', 'dev', interface],
                                        capture_output=True, text=True, check=True, timeout=2)
                classes = json.loads(result.stdout)
                sample = {row['handle']: row['stats']['backlog'] for row in classes
                          if row.get('class') == 'fq_codel' and row['stats']['backlog'] >= 16384}
                observed.update(sample)
                samples.append(sample)
        except BaseException as error:
            errors.append(error)

    observer = threading.Thread(target=observe)
    observer.start()
    requests = 0
    try:
        deadline = time.monotonic() + .1
        while True:
            connection.request('POST', '/upload', body=body,
                               headers={'Content-Type': 'application/octet-stream'})
            response = connection.getresponse()
            if response.status != 200 or response.read() != expected:
                raise ValueError('queue-probe response differs')
            requests += 1
            if observed or time.monotonic() >= deadline:
                break
    finally:
        stopped.set()
        observer.join()
    if errors:
        raise errors[0]
    ranked = observed.most_common()
    bucket = ranked[0][0] if ranked and ranked[0][1] >= sum(observed.values()) * .9 else None
    return dict(bucket=bucket, weights=dict(observed), samples=samples, requests=requests,
                body_bytes=len(body),
                local_address=connection.sock.getsockname())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('-address', required=True)
    parser.add_argument('-connections', type=int, default=32)
    parser.add_argument('-request-body', type=Path, required=True)
    parser.add_argument('-expect-body', type=Path, required=True)
    parser.add_argument('-warmup', type=float, default=5)
    parser.add_argument('-duration', type=float, default=12)
    parser.add_argument('-rate', type=float, default=0,
                        help='Aggregate start-rate cap; zero runs continuously')
    parser.add_argument('-trace', action='store_true', help='Record send/response timing and TCP_INFO')
    parser.add_argument('-queue-mode', choices=('hash', 'distinct', 'pair'), default='hash',
                        help='Diagnostic SO_PRIORITY assignment for a default-handle FQ-CoDel queue')
    parser.add_argument('-probe-queues', action='store_true', help='Map each socket to its client FQ-CoDel bucket before warmup')
    parser.add_argument('-unique-queues', action='store_true', help='Prepare sockets in distinct client FQ-CoDel buckets')
    parser.add_argument('-freeze-hash', action='store_true', help='Disable transmit rehashing without queue probing')
    parser.add_argument('-calibrate-body', action='store_true', help='Send an 8 MiB setup body before warmup, without probing')
    args = parser.parse_args()
    host, _, port = args.address.rpartition(':')
    body, expected = args.request_body.read_bytes(), args.expect_body.read_bytes()
    assert 0 < len(body) <= 8 * 1024 * 1024 and 1 <= args.connections <= 256
    assert args.rate >= 0
    assert args.queue_mode == 'hash' or args.connections <= 6
    probing = args.probe_queues or args.unique_queues
    assert not probing or args.queue_mode == 'hash'
    queue_configuration = None
    if probing or args.calibrate_body:
        probe_body = bytes(range(256)) * 32768
        probe_expected = f'{len(probe_body)}:{zlib.crc32(probe_body):08x}\n'.encode()
    if probing:
        route = json.loads(subprocess.check_output(['ip', '-j', 'route', 'get', host], text=True))[0]
        interface = route['dev']
        queue_configuration = json.loads(subprocess.check_output(['tc', '-j', '-s', 'qdisc', 'show',
                                                                 'dev', interface], text=True))
        assert len(queue_configuration) == 1 and queue_configuration[0]['kind'] == 'fq_codel'
        # Use an 8 MiB probe: a small upload can drain before netlink observes it.
    preparation_lock = threading.Lock()
    used_buckets = set()
    ready = queue.Queue()
    begin = threading.Event()
    timing = {}
    outcomes = [dict(attempts=0, successes=0, failures=[], latencies_ns=[]) for _ in range(args.connections)]

    def work(index):
        connection = http.client.HTTPConnection(host, int(port), timeout=20)
        row = outcomes[index]
        try:
            connection.connect()
            if probing:
                row['queue_probes'] = []
                with preparation_lock:
                    for attempt in range(32):
                        # Keep the observed hash stable for the measured connection.
                        connection.sock.setsockopt(socket.SOL_SOCKET, 74, 0)  # SO_TXREHASH
                        assert connection.sock.getsockopt(socket.SOL_SOCKET, 74) == 0
                        probe = probe_queue(connection, interface, probe_body, probe_expected)
                        row['queue_probes'].append(probe)
                        if probe['bucket'] is None:
                            continue
                        if args.unique_queues and probe['bucket'] in used_buckets:
                            connection.close()
                            connection.connect()
                            continue
                        row['queue_bucket'] = probe['bucket']
                        used_buckets.add(probe['bucket'])
                        break
                    else:
                        raise RuntimeError('could not prepare a confirmed client queue bucket')
            if args.freeze_hash:
                connection.sock.setsockopt(socket.SOL_SOCKET, 74, 0)
            row['tx_rehash'] = connection.sock.getsockopt(socket.SOL_SOCKET, 74)
            if args.freeze_hash or probing:
                assert row['tx_rehash'] == 0
            if args.calibrate_body:
                with preparation_lock:
                    connection.request('POST', '/upload', body=probe_body,
                                       headers={'Content-Type': 'application/octet-stream'})
                    response = connection.getresponse()
                    if response.status != 200 or response.read() != probe_expected:
                        raise ValueError('calibration response differs')
                    row['calibration_bytes'] = len(probe_body)
            priority = 0 if args.queue_mode == 'hash' else index + 1
            if args.queue_mode == 'pair' and index == 1:
                priority = 1
            if priority:
                connection.sock.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, priority)
            row['queue_priority'] = connection.sock.getsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY)
            if args.trace:
                row['local_address'] = connection.sock.getsockname()
                row['trace'] = []
            ready.put(None)
            if not begin.wait(30):
                raise TimeoutError('start barrier')
            next_start = timing['begin_mono']
            if args.rate:
                next_start += int(index / args.rate * 1e9)
            while time.monotonic_ns() < timing['end_mono']:
                if args.rate:
                    if next_start >= timing['end_mono']:
                        break
                    time.sleep(max(0, (next_start - time.monotonic_ns()) / 1e9))
                    if time.monotonic_ns() >= timing['end_mono']:
                        break
                started = time.monotonic_ns()
                if args.trace:
                    before = tcp_info(connection)
                row['attempts'] += 1
                connection.request('POST', '/upload', body=body,
                                   headers={'Content-Type': 'application/octet-stream'})
                if args.trace:
                    sent = time.monotonic_ns()
                    after_send = tcp_info(connection)
                response = connection.getresponse()
                if response.status != 200 or response.read() != expected:
                    raise ValueError('response status, body length, or checksum differs')
                finished = time.monotonic_ns()
                if args.trace:
                    row['trace'].append(dict(started_ns=started, sent_ns=sent, finished_ns=finished,
                                             before=before, after_send=after_send,
                                             after_response=tcp_info(connection)))
                row['successes'] += 1
                if timing['start_mono'] <= finished < timing['end_mono']:
                    row['latencies_ns'].append(finished - started)
                if args.rate:
                    # A late client resumes at its capped rate without catch-up bursts.
                    next_start = max(next_start + int(args.connections / args.rate * 1e9), finished)
        except BaseException as error:
            row['failures'].append(repr(error))
            ready.put(repr(error))
        finally:
            connection.close()

    threads = [threading.Thread(target=work, args=(index,)) for index in range(args.connections)]
    for thread in threads:
        thread.start()
    try:
        for _ in threads:
            failure = ready.get(timeout=25)
            if failure is not None:
                raise RuntimeError(failure)
        now_mono, now_wall = time.monotonic_ns(), time.time_ns()
        timing.update(begin_mono=now_mono, start_mono=now_mono + int(args.warmup * 1e9),
                      end_mono=now_mono + int((args.warmup + args.duration) * 1e9))
        start_wall = now_wall + int(args.warmup * 1e9)
        end_wall = start_wall + int(args.duration * 1e9)
    finally:
        begin.set()
    for thread in threads:
        thread.join()
    latencies = sorted(value for row in outcomes for value in row['latencies_ns'])
    failures = collections.Counter(error for row in outcomes for error in row['failures'])
    result = dict(connections=args.connections, rate_cap=args.rate, request_body_bytes=len(body),
                   queue_mode=args.queue_mode, freeze_hash=args.freeze_hash,
                   calibrate_body=args.calibrate_body,
                   queue_configuration=queue_configuration, unique_queues=args.unique_queues,
                   request_body_sha256=hashlib.sha256(body).hexdigest(),
                   expected_body_sha256=hashlib.sha256(expected).hexdigest(),
                   measure_start_unix_ns=start_wall, measure_end_unix_ns=end_wall,
                   duration_seconds=args.duration, window_successes=len(latencies),
                   validated_body_bytes=len(latencies) * len(body),
                   goodput_bytes_per_second=len(latencies) * len(body) / args.duration,
                   service_p99_ms=latencies[min(len(latencies) - 1, int(.99 * len(latencies)))] / 1e6
                   if latencies else None,
                   failures=dict(failures), workers=outcomes)
    print(json.dumps(result), flush=True)
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
