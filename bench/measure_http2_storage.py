"""Measure charged HTTP/2 storage for fixed live uploads, independent of request rate."""

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', action='append', required=True, help='label=path/to/zhtps')
    parser.add_argument('--workers', default='1,2,4,8')
    parser.add_argument('--connections', type=int, default=64)
    parser.add_argument('--streams', type=int, default=4)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    variants = {label: str(Path(path).resolve()) for label, path in
                (item.split('=', 1) for item in args.variant)}
    assert len(variants) == len(args.variant) >= 2
    assert 0 < args.connections <= 256 and 0 < args.streams <= 100
    workers = list(map(int, args.workers.split(',')))
    assert all(0 < count <= 8 for count in workers)
    args.output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(ROOT / 'tests'))
    sys.argv = [sys.argv[0], next(iter(variants.values()))]
    import http2
    import wire
    from buffer_pools import metrics

    def digest(path):
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()

    def snapshot(server, active):
        deadline = time.monotonic() + 5
        while True:
            captured = metrics(server)
            if captured['gauges']['http2_streams_active'] == active:
                break
            assert time.monotonic() < deadline, captured
            time.sleep(.01)
        status = Path(f'/proc/{server.process.pid}/status').read_text().splitlines()
        return {'metrics': captured, 'status': [line for line in status if
                line.startswith(('VmRSS:', 'VmHWM:', 'VmSize:', 'VmData:', 'Threads:'))]}

    report = {'started_utc': datetime.now(timezone.utc).isoformat(),
              'workload': {'connections': args.connections, 'streams': args.streams,
                           'method': 'POST /echo', 'body': 'one verified byte per stream',
                           'description': 'Sample connected, pending heads, consumed partial bodies and completed streams; no throughput claim.'},
              'binary_sha256': {label: digest(path) for label, path in variants.items()},
              'source_sha256': {str(path.relative_to(ROOT)): digest(path) for path in
                                [Path(__file__), ROOT / 'tests/http2.py', ROOT / 'tests/wire.py',
                                 ROOT / 'tests/buffer_pools.py']},
              'runs': [], 'complete': False}

    def save():
        (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')

    save()
    http2.Http2Tests.setUpClass()
    try:
        for count in workers:
            for repeat in range(args.repeats):
                labels = list(variants)
                offset = repeat % len(labels)
                for label in labels[offset:] + labels[:offset]:
                    wire.BINARY = variants[label]
                    run = {'variant': label, 'workers': count, 'repeat': repeat + 1,
                           'successful_uploads': 0, 'errors': [], 'snapshots': {}}
                    report['runs'].append(run)
                    try:
                        with wire.Running(*http2.Http2Tests.options, '--workers', str(count),
                                          '--worker-cpus', ','.join(map(str, range(count))),
                                          '--no-access-log', '--max-active', '1024',
                                          '--max-connections', '1024', '--http2-worker-streams', '65535',
                                          '--http2-memory-bytes', '4294967295',
                                          '--header-timeout-ms', '60000', '--body-timeout-ms', '60000') as server:
                            run['command'] = server.process.args
                            with ExitStack() as stack:
                                clients = [stack.enter_context(http2.Client(server.port, http2.Http2Tests.context))
                                           for _ in range(args.connections)]
                                for client in clients:
                                    client.synchronize()
                                run['snapshots']['connected'] = snapshot(server, 0)
                                streams = []
                                for client in clients:
                                    streams.append([client.request('/echo', 'POST', end=False)
                                                    for _ in range(args.streams)])
                                    client.synchronize()
                                active = args.connections * args.streams
                                run['snapshots']['pending_heads'] = snapshot(server, active)
                                for client, ids in zip(clients, streams):
                                    for stream in ids:
                                        client.upload(stream, b'x', end=False)
                                    client.synchronize()
                                run['snapshots']['pending_bodies'] = snapshot(server, active)
                                for client, ids in zip(clients, streams):
                                    for stream in ids:
                                        client.h2.end_stream(stream)
                                    client.flush()
                                    for stream in ids:
                                        response = client.wait(stream)
                                        assert response['reset'] is None and response['ended'], response
                                        assert response['headers'][':status'] == '200' and response['body'] == b'x', response
                                        run['successful_uploads'] += 1
                                    client.synchronize()
                                run['snapshots']['completed'] = snapshot(server, 0)
                            run['server_events'] = server.events
                        assert run['successful_uploads'] == args.connections * args.streams
                        run['server_exit'] = server.process.returncode
                    except BaseException as error:
                        run['errors'].append(repr(error))
                        save()
                        raise
                    save()
                    charged = {phase: item['metrics']['gauges']['http2_bytes_allocated'] for phase, item in run['snapshots'].items()}
                    print(f'{label} w{count} r{repeat + 1}: {charged}; {run["successful_uploads"]} verified uploads', flush=True)
        assert {label: digest(path) for label, path in variants.items()} == report['binary_sha256']
        assert all(digest(ROOT / path) == expected for path, expected in report['source_sha256'].items())
        report['complete'] = True
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        save()
    finally:
        http2.Http2Tests.doClassCleanups()


if __name__ == '__main__':
    main()
