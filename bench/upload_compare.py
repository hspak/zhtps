"""Compare buffered and streaming upload servers with the same large-body work."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import statistics
import subprocess
import time
import zlib

from architecture import host_sample, remote_source
from compare import admin_json, free_port, wait_ready
from overload import proc_sample, stop
from remote_load import RemoteLoad, identity
from summarize_architecture import host_delta


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path)
    parser.add_argument('--go-binary', type=Path)
    parser.add_argument('--before-label', default='buffered')
    parser.add_argument('--go-procs', type=int, default=32)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--body-bytes', type=int, nargs='+', default=[65536, 8388608])
    parser.add_argument('--connections', type=int, default=32)
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--worker-cpus', default='9-12')
    parser.add_argument('--capacity', type=int, default=256)
    parser.add_argument('--zig-cpus', default='', help='Affinity for the entire ZHTPS process, including application threads')
    parser.add_argument('--app-cpu', type=int, help='Diagnostic placement of non-main threads in a single-worker ZHTPS process')
    parser.add_argument('--duration', type=float, default=12)
    parser.add_argument('--rate', type=float, default=0)
    parser.add_argument('--trace-client', action='store_true')
    parser.add_argument('--queue-mode', choices=('hash', 'distinct', 'pair'), default='hash')
    parser.add_argument('--profile', action='store_true')
    parser.add_argument('--probe-queues', action='store_true')
    parser.add_argument('--unique-queues', action='store_true')
    parser.add_argument('--freeze-hash', action='store_true')
    parser.add_argument('--calibrate-body', action='store_true')
    args = parser.parse_args()
    if not args.before and not args.go_binary:
        parser.error('at least one of --before or --go-binary is required')
    if args.app_cpu is not None and args.workers != 1:
        parser.error('--app-cpu requires one network worker')
    args.output.mkdir(parents=True, exist_ok=False)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, 65536), hard))
    if args.before and args.before_label in ('go', 'streaming'):
        parser.error('--before-label must differ from go and streaming')
    binaries = {}
    if args.before:
        binaries[args.before_label] = args.before.resolve()
    if args.go_binary:
        binaries['go'] = args.go_binary.resolve()
    binaries['streaming'] = args.candidate.resolve()
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()}
    assert len(set(hashes.values())) == len(binaries)
    client_source = (ROOT / 'bench/upload_client.py').read_text()
    agent_source = remote_source()
    for name in ('upload_client.py', 'upload_compare.py', 'architecture.py', 'remote_load.py', 'compare.py', 'overload.py'):
        (args.output / name).write_bytes((ROOT / 'bench' / name).read_bytes())
    (args.output / 'variants.json').write_text(json.dumps(dict(
        binaries={name: str(path) for name, path in binaries.items()}, sha256=hashes,
        client_source_sha256=hashlib.sha256(client_source.encode()).hexdigest(),
        agent_source_sha256=hashlib.sha256(agent_source.encode()).hexdigest()), indent=2) + '\n')
    for size in args.body_bytes:
        body = bytes(range(256)) * (size // 256) + bytes(range(size % 256))
        body_path = args.output / f'body-{size}.bin'
        expected_path = args.output / f'expected-{size}.bin'
        body_path.write_bytes(body)
        expected_path.write_bytes(f'{size}:{zlib.crc32(body):08x}\n'.encode())
        for repeat in range(args.repeats):
            order = list(binaries)
            order = order[repeat % len(order):] + order[:repeat % len(order)]
            for name in order:
                folder = args.output / f'n{size}-{name}-{repeat + 1}'
                folder.mkdir()
                port, admin = free_port('192.0.2.10'), free_port()
                command = ([str(binaries[name]), '-listen', f'192.0.2.10:{port}'] if name == 'go' else
                           [str(binaries[name]), '--address', '192.0.2.10', '--port', str(port),
                           '--admin-port', str(admin), '--workers', str(args.workers), '--worker-cpus', args.worker_cpus,
                           '--max-connections', str(args.capacity), '--max-active', str(args.capacity),
                           '--max-requests', '4294967295', '--no-access-log'])
                if name != 'go' and args.zig_cpus:
                    command = ['taskset', '-c', args.zig_cpus, *command]
                record = dict(variant=name, repeat=repeat + 1, body_bytes=size, connections=args.connections,
                               command=command, binary_sha256=hashes[name],
                               server_identity=identity(), samples=[])
                server = remote = profile = None
                print('START', folder.name, flush=True)
                with (folder / 'server.log').open('w') as log, (folder / 'ssh.log').open('w') as sshlog:
                    try:
                        env = dict(os.environ)
                        for setting in ('GOMAXPROCS', 'GOGC', 'GOMEMLIMIT', 'GODEBUG'):
                            env.pop(setting, None)
                        if name == 'go':
                            env['GOMAXPROCS'] = str(args.go_procs)
                        server = subprocess.Popen(command, stdout=subprocess.PIPE if name == 'go' else subprocess.DEVNULL,
                                                  stderr=log, env=env, text=True)
                        if name == 'go':
                            record['go_runtime'] = json.loads(server.stdout.readline())
                            assert record['go_runtime']['gomaxprocs'] == args.go_procs
                        wait_ready(server, port, '192.0.2.10')
                        if name != 'go' and args.app_cpu is not None:
                            record['application_affinity'] = []
                            for task in Path(f'/proc/{server.pid}/task').iterdir():
                                tid = int(task.name)
                                if tid == server.pid:
                                    continue
                                previous = sorted(os.sched_getaffinity(tid))
                                task_name = (task / 'comm').read_text().strip()
                                if args.app_cpu not in previous:
                                    record['application_affinity'].append(dict(tid=tid, name=task_name, before=previous,
                                                                               skipped='inherits network-worker affinity'))
                                    continue
                                os.sched_setaffinity(tid, {args.app_cpu})
                                record['application_affinity'].append(dict(tid=tid, name=task_name, before=previous,
                                                                           after=sorted(os.sched_getaffinity(tid))))
                        if args.profile:
                            profile_command = ['perf', 'record', '-F', '997', '-e', 'cycles:u',
                                               '--call-graph', 'dwarf,8192', '-o', str(folder / 'user.perf.data'),
                                               '-p', str(server.pid)]
                            profile = subprocess.Popen(profile_command, stdout=log, stderr=log)
                            record['profile_command'] = profile_command
                        record['running_binary_sha256'] = hashlib.sha256(
                            Path(f'/proc/{server.pid}/exe').read_bytes()).hexdigest()
                        assert record['running_binary_sha256'] == hashes[name]
                        record['server_affinity'] = sorted(os.sched_getaffinity(server.pid))
                        transport = ['ssh', '-F', '/path/to/benchmark-ssh.conf', '-T', 'client.example',
                                     shlex.join(['python3', '-u', '-c', agent_source])]
                        remote = RemoteLoad('client.example', sshlog, transport=transport)
                        record['remote_identity'] = remote.identity
                        assert remote.identity['boot_id'] != record['server_identity']['boot_id']
                        record['clock_offset_ns'] = remote.clock_offset_ns
                        record['clock_uncertainty_ns'] = remote.clock_uncertainty_ns
                        if name != 'go':
                            record['metrics_before'] = admin_json(admin, '/debug/metrics')
                        arguments = ['-c', client_source, '-address', f'192.0.2.10:{port}',
                                     '-connections', str(args.connections), '-warmup', '5',
                                     '-duration', str(args.duration), '-rate', str(args.rate)]
                        if args.trace_client:
                            arguments.append('-trace')
                        arguments += ['-queue-mode', args.queue_mode]
                        if args.probe_queues:
                            arguments.append('-probe-queues')
                        if args.unique_queues:
                            arguments.append('-unique-queues')
                        if args.freeze_hash:
                            arguments.append('-freeze-hash')
                        if args.calibrate_body:
                            arguments.append('-calibrate-body')
                        remote.start('/usr/bin/python3', arguments, list(range(8)), args.connections, 120,
                                     {'-request-body': body_path, '-expect-body': expected_path})
                        record['remote_started'] = remote.started
                        next_sample = 0
                        while not remote.completed():
                            if server.poll() is not None:
                                raise RuntimeError('server exited during upload load')
                            if time.monotonic() >= next_sample:
                                record['samples'].append(dict(unix_ns=time.time_ns(), server=proc_sample(server.pid),
                                                              host=host_sample(), metrics=admin_json(admin, '/debug/metrics')
                                                              if name != 'go' else None))
                                next_sample = time.monotonic() + .25
                            time.sleep(.02)
                        record['load'] = remote.result['client']
                        record['remote_samples'] = remote.samples
                        if name != 'go':
                            record['metrics_after'] = admin_json(admin, '/debug/metrics')
                        load = record['load']
                        assert not load['failures'] and load['window_successes'] > 0
                        assert load['request_body_sha256'] == hashlib.sha256(body).hexdigest()
                        assert load['expected_body_sha256'] == hashlib.sha256(expected_path.read_bytes()).hexdigest()
                        assert all(row['attempts'] == row['successes'] for row in load['workers'])
                        begin = load['measure_start_unix_ns'] + remote.clock_offset_ns
                        end = load['measure_end_unix_ns'] + remote.clock_offset_ns
                        samples = [s for s in record['samples'] if begin + 250_000_000 <= s['unix_ns'] < end - 250_000_000]
                        assert len(samples) >= 4
                        first, last = samples[0], samples[-1]
                        seconds = (last['unix_ns'] - first['unix_ns']) / 1e9
                        cpu_cores = (last['server']['cpu_seconds'] - first['server']['cpu_seconds']) / seconds
                        goodput = load['goodput_bytes_per_second'] / 2**20
                        summary = dict(variant=name, body_bytes=size, connections=args.connections, rate_cap=args.rate,
                                       goodput_mib_per_second=goodput, service_p99_ms=load['service_p99_ms'],
                                       rss_median_mib=statistics.median(s['server']['VmRSS'] / 2**20 for s in samples),
                                       rss_peak_mib=max(s['server']['VmRSS'] / 2**20 for s in samples),
                                       cpu_cores=cpu_cores, cpu_us_per_mib=cpu_cores / goodput * 1e6,
                                       cpu_interval_seconds=seconds, server_host=host_delta(first['host'], last['host']))
                        (folder / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
                        record['outcome'] = 'measured'
                        print('DONE', folder.name, {k: v for k, v in summary.items() if k != 'server_host'}, flush=True)
                    except BaseException as error:
                        record['outcome'] = 'failed'
                        record['error'] = repr(error)
                        record['remote_failure'] = getattr(remote, 'failure', None)
                        raise
                    finally:
                        if remote is not None:
                            remote.stop()
                        stop(profile)
                        if profile is not None:
                            record['profile_exit'] = profile.returncode
                        stop(server)
                        if server is not None and server.stdout is not None:
                            server.stdout.close()
                        record['server_exit'] = None if server is None else server.returncode
                        (folder / 'run.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
