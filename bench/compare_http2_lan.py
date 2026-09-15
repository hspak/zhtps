"""HTTP/2 comparison over a separate wired load host, retaining all request failures."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import resource
import shlex
import shutil
import socket
import statistics
import subprocess
import tarfile
import tempfile
import threading
import time

from compare_http2 import cpu_list, cpu_seconds, process_snapshot, stop
from http2_remote import identity, host_sample

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def quantile(histogram, percentile):
    rank = (sum(histogram.values()) - 1) * percentile // 100
    if rank < 0:
        return None
    for micros, count in sorted(histogram.items()):
        if rank < count:
            return micros / 1000
        rank -= count
    raise AssertionError('percentile missing')


def aggregate(shards, duration):
    result = {}
    for phase in ('setup', 'holding', 'warmup', 'measurement'):
        counts = Counter()
        for shard in shards:
            item = shard[phase]
            assert item['attempted'] == item['succeeded'] + item['failed']
            assert sum((item['failure_kinds'] or {}).values()) == item['failed']
            counts.update(item['failure_kinds'] or {})
        result[phase] = {key: sum(shard[phase][key] for shard in shards)
                         for key in ('attempted', 'succeeded', 'failed')}
        result[phase]['failure_kinds'] = dict(counts)
    for key in ('requested_connections', 'established_connections', 'ready_connections',
                'participating_connections', 'successful_connections', 'alive_connections',
                'setup_unattempted', 'reconnections', 'failure_log_entries'):
        result[key] = sum(shard[key] for shard in shards)
    latency, failure_latency = Counter(), Counter()
    for shard in shards:
        assert sum(shard['latency_us'].values()) == shard['measurement']['succeeded']
        assert sum(shard['failure_latency_us'].values()) == shard['measurement']['failed']
        latency.update({int(key): value for key, value in shard['latency_us'].items()})
        failure_latency.update({int(key): value for key, value in shard['failure_latency_us'].items()})
    assert result['failure_log_entries'] == sum(result[phase]['failed'] for phase in
                                                ('setup', 'holding', 'warmup', 'measurement'))
    elapsed = max(duration, (max(shard['end_ns'] for shard in shards) -
                             min(shard['start_ns'] for shard in shards)) / 1e9)
    result.update(seconds=elapsed, requests_per_second=result['measurement']['succeeded'] / elapsed,
                  p50_ms=quantile(latency, 50), p99_ms=quantile(latency, 99),
                  failure_p99_ms=quantile(failure_latency, 99),
                  client_cpu_cores=sum(shard['client_cpu_seconds'] for shard in shards) / elapsed,
                  start_skew_ms=(max(shard['start_ns'] for shard in shards) -
                                 min(shard['start_ns'] for shard in shards)) / 1e6)
    result['full_population'] = (result['ready_connections'] == result['requested_connections'] and
                                 result['participating_connections'] == result['requested_connections'])
    return result


class Remote:
    def __init__(self, ssh, directory, logs):
        command = ['python3', '-u', directory + '/http2_remote.py']
        self.process = subprocess.Popen([*ssh, shlex.join(command)] if ssh else command,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=logs)
        self.events = queue.Queue()
        def read():
            try:
                for line in self.process.stdout:
                    self.events.put(json.loads(line))
                self.events.put({'kind': 'eof'})
            except BaseException as error:
                self.events.put({'kind': 'invalid', 'error': repr(error)})
        threading.Thread(target=read, daemon=True).start()
    def send(self, message):
        self.process.stdin.write((json.dumps(message) + '\n').encode())
        self.process.stdin.flush()
    def receive(self):
        return self.events.get(timeout=10)
    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            stop(self.process)


def trial(args, ssh, remote_dir, name, workers, connections, repeat, port, cert, key, folder):
    folder.mkdir()
    cpus = cpu_list(args.server_cpus)[:workers]
    if name == 'zhtps':
        command = [args.zhtps, '--address', args.address, '--port', str(port),
                   '--admin-connections', '0', '--workers', str(workers), '--worker-cpus', ','.join(map(str, cpus)),
                   '--no-access-log', '--max-connections', '8176', '--max-active', '8176',
                   '--http2-worker-streams', '65535', '--http2-memory-bytes', '4294967295',
                   '--max-requests', '4294967295', '--tls-certificate', str(cert), '--tls-key', str(key)]
    elif name == 'go':
        command = [args.go_server, '-listen', f'{args.address}:{port}', '-http2',
                   '-tls-certificate', str(cert), '-tls-key', str(key)]
    else:
        command = [shutil.which(name), str(ROOT / 'bench/http2_lan_server.cjs'),
                   str(port), str(cert), str(key), args.address]
    command = ['taskset', '-c', ','.join(map(str, cpus)), *command]
    env = dict(os.environ)
    for variable in ('GOMAXPROCS', 'GOGC', 'GOMEMLIMIT', 'GODEBUG'):
        env.pop(variable, None)
    env['GOMAXPROCS'] = str(workers)
    run = {'server': name, 'workers': workers, 'connections': connections, 'streams': args.streams,
           'repeat': repeat, 'server_cpus': cpus, 'server_command': command,
           'server_identity': identity(), 'server_host_before': host_sample(), 'valid': False}
    run['client_location'] = 'remote' if ssh else 'loopback'
    remote = server = None
    remote_folder = remote_dir + '/' + folder.name
    with (folder / 'server.log').open('w') as logs, (folder / 'ssh.log').open('w') as sshlogs, \
         (folder / 'events.jsonl').open('w') as events:
        try:
            server = subprocess.Popen(command, stdout=logs, stderr=logs, env=env)
            deadline = time.monotonic() + 20
            while True:
                if server.poll() is not None:
                    raise RuntimeError('server exited during startup')
                try:
                    with socket.create_connection((args.address, port), timeout=.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('server startup')
                    time.sleep(.02)
            remote = Remote(ssh, remote_dir, sshlogs)
            hello = remote.receive()
            assert hello['kind'] == 'hello', hello
            run['client_identity'] = hello['identity']
            same_host = hello['identity']['boot_id'] == run['server_identity']['boot_id']
            assert same_host == (not ssh), 'client location does not match the selected transport'
            clocks = []
            for _ in range(5):
                before = time.time_ns()
                remote.send({'kind': 'clock'})
                clock = remote.receive()
                after = time.time_ns()
                assert clock['kind'] == 'clock', clock
                clocks.append({'offset_ns': clock['unix_ns'] - (before + after) // 2,
                               'uncertainty_ns': (after - before) // 2})
            clock = min(clocks, key=lambda item: item['uncertainty_ns'])
            run['clock'] = clock
            config = {'kind': 'run', 'folder': remote_folder, 'binary': remote_dir + '/client',
                      'binary_sha256': digest(args.client), 'certificate': remote_dir + '/cert.pem',
                      'url': f'https://{args.address}:{port}/', 'connections': connections,
                      'streams': args.streams, 'duration': args.duration, 'warmup': args.warmup,
                      'timeout': args.timeout, 'setup_deadline': args.setup_deadline,
                      'setup_concurrency': args.setup_concurrency, 'client_cpus': cpu_list(args.client_cpus),
                      'client_processes': args.client_processes, 'max_seconds': args.setup_deadline + args.duration + 45}
            run['client_config'] = config
            remote.send(config)
            deadline = time.monotonic() + config['max_seconds'] + 30
            before_cpu = before_time = None
            while True:
                if time.monotonic() > deadline:
                    raise TimeoutError('controller trial deadline')
                remote.send({'kind': 'heartbeat'})
                event = remote.receive()
                event['controller_received_ns'] = time.time_ns()
                events.write(json.dumps(event, separators=(',', ':')) + '\n')
                events.flush()
                kind = event['kind']
                if kind == 'launched':
                    run['client_launch'] = event
                elif kind == 'prepared':
                    run['prepared'] = event
                    run['server_prepared'] = process_snapshot(server.pid) if server.poll() is None else None
                    remote.send({'kind': 'warmup'})
                elif kind == 'ready':
                    run['ready'] = event
                    run['server_before'] = process_snapshot(server.pid) if server.poll() is None else None
                    remote.send({'kind': 'measure'})
                elif kind == 'scheduled':
                    local_start = event['start_ns'] - clock['offset_ns']
                    time.sleep(max(0, (local_start - time.time_ns()) / 1e9))
                    before_time = time.monotonic()
                    before_cpu = cpu_seconds(server.pid) if server.poll() is None else None
                    run['server_network_before'] = host_sample()
                elif kind == 'measured':
                    after_cpu = cpu_seconds(server.pid) if server.poll() is None else None
                    run['server_cpu_window_seconds'] = time.monotonic() - before_time
                    run['server_cpu_seconds'] = after_cpu - before_cpu if after_cpu is not None and before_cpu is not None else None
                    run['server_after'] = process_snapshot(server.pid) if server.poll() is None else None
                    run['server_network_after'] = host_sample()
                elif kind == 'result':
                    run['client_result'] = event
                    run.update(aggregate(event['shards'], args.duration))
                    run['valid'] = True
                    break
                elif kind in ('error', 'eof', 'invalid'):
                    raise RuntimeError(event)
            cpu = run['server_cpu_seconds']
            run['server_cpu_cores'] = cpu / run['server_cpu_window_seconds'] if cpu is not None else None
            successes = run['measurement']['succeeded']
            run['server_cpu_us_per_request'] = cpu * 1e6 / successes if cpu is not None and successes else None
        except BaseException as error:
            run['error'] = repr(error)
            print(f'{folder.name}: {error!r}', flush=True)
        finally:
            if remote is not None:
                remote.close()
            if server is not None:
                run['server_exit_before_shutdown'] = server.poll()
                stop(server)
                run['server_exit_code'] = server.returncode
            run['server_host_after'] = host_sample()
            (folder / 'run.json').write_text(json.dumps(run, indent=2) + '\n')
    # Retain stderr and every failure even when the supervisor could not finish.
    command = ['tar', '-C', remote_folder, '-czf', '-', '.']
    archive = subprocess.run([*ssh, shlex.join(command)] if ssh else command,
                             capture_output=True, timeout=60)
    if archive.returncode:
        run['artifact_error'] = archive.stderr.decode(errors='replace')
        run['valid'] = False
    else:
        target = folder / 'client'
        target.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive.stdout), mode='r:gz') as files:
            files.extractall(target, filter='data')
        if run.get('valid'):
            for item in run['client_result']['failure_logs']:
                content = gzip.decompress((target / item['path']).read_bytes())
                assert hashlib.sha256(content).hexdigest() == item['sha256_uncompressed']
                assert len(content.splitlines()) == item['entries']
    (folder / 'run.json').write_text(json.dumps(run, indent=2) + '\n')
    return run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client-host', default='client.example')
    parser.add_argument('--ssh-key', default='/path/to/benchmark-key')
    parser.add_argument('--address', default='192.0.2.10')
    parser.add_argument('--zhtps', default='zig-out/http2-benchmark/bin/zhtps')
    parser.add_argument('--go-server', default='zig-out/http2-benchmark/go-server')
    parser.add_argument('--client', default='zig-out/http2-benchmark/lan-client')
    parser.add_argument('--server-cpus', default='0-7')
    parser.add_argument('--client-cpus', default='0-15')
    parser.add_argument('--client-processes', type=int, default=8)
    parser.add_argument('--workers', default='1,2,4,8')
    parser.add_argument('--servers', default='zhtps,go,node,bun')
    parser.add_argument('--connections', default='64,1024,8192,16384')
    parser.add_argument('--streams', type=int, default=4)
    parser.add_argument('--duration', type=float, default=8)
    parser.add_argument('--warmup', type=float, default=2)
    parser.add_argument('--timeout', type=float, default=2)
    parser.add_argument('--setup-deadline', type=float, default=180)
    parser.add_argument('--setup-concurrency', type=int, default=32)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    workers = list(map(int, args.workers.split(',')))
    connections = list(map(int, args.connections.split(',')))
    servers = args.servers.split(',')
    if not set(servers) <= {'zhtps', 'go', 'node', 'bun'} or min(workers) < 1 or max(workers) > len(cpu_list(args.server_cpus)):
        parser.error('invalid servers or workers')
    if min(connections) < args.client_processes or not 1 <= args.streams <= 100 or args.repeats < 1 or args.duration <= 0:
        parser.error('invalid connection counts or measurement parameters')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(hard, max(soft, 131072)), hard))
    ssh_options = ['-i', str(Path(args.ssh_key).expanduser()), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10']
    ssh = ['ssh', *ssh_options, args.client_host]
    remote_dir = subprocess.check_output([*ssh, 'mktemp -d /tmp/zhtps-http2-lan.XXXXXXXX'], text=True).strip()
    sources = [ROOT / 'build.zig', ROOT / 'build.zig.zon', *sorted(path for path in (ROOT / 'src').rglob('*') if path.is_file()),
               ROOT / 'bench/compare_http2_lan.py', ROOT / 'bench/compare_http2.py', ROOT / 'bench/http2_remote.py',
               ROOT / 'bench/http2_lan_server.cjs', ROOT / 'bench/go_server/main.go',
               *sorted((ROOT / 'bench/http2_lan_client').glob('*'))]
    sources = [path for path in sources if path.is_file()]
    binaries = {'zhtps': args.zhtps, 'go': args.go_server, 'client': args.client,
                **{name: shutil.which(name) for name in ('node', 'bun') if name in servers}}
    report = {'arguments': vars(args), 'started_utc': datetime.now(timezone.utc).isoformat(),
              'server_identity': identity(), 'remote_directory': remote_dir, 'complete': False,
              'binary_sha256': {name: digest(path) for name, path in binaries.items()},
              'source_sha256': {str(path.relative_to(ROOT)): digest(path) for path in sources},
              'versions': {'go': subprocess.check_output(['go', 'version'], text=True).strip(),
                           'zig': subprocess.check_output(['zig', 'version'], text=True).strip(),
                           **{name: subprocess.check_output([shutil.which(name), '--version'], text=True).strip()
                              for name in ('node', 'bun') if name in servers}}, 'runs': []}
    with tarfile.open(output / 'source.tar.gz', 'w:gz') as archive:
        for path in sources:
            archive.add(path, arcname=str(path.relative_to(ROOT)))
    def save():
        temporary = output / 'results.tmp'
        temporary.write_text(json.dumps(report, indent=2) + '\n')
        temporary.replace(output / 'results.json')
    save()
    with tempfile.TemporaryDirectory(prefix='zhtps-http2-lan-cert-') as temporary:
        cert, key = Path(temporary) / 'cert.pem', Path(temporary) / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                        '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=zhtps-benchmark',
                        '-addext', f'subjectAltName=IP:{args.address}'], check=True, capture_output=True)
        for source, name in ((args.client, 'client'), (ROOT / 'bench/http2_remote.py', 'http2_remote.py'), (cert, 'cert.pem')):
            subprocess.run(['scp', *ssh_options, str(source), f'{args.client_host}:{remote_dir}/{name}'], check=True)
        used_ports = set()
        for count in workers:
            names = [name for name in servers if count == 1 or name in ('zhtps', 'go')]
            for population in connections:
                for repeat in range(args.repeats):
                    offset = repeat % len(names) if names else 0
                    for name in names[offset:] + names[:offset]:
                        while True:
                            with socket.socket() as listener:
                                listener.bind((args.address, 0))
                                port = listener.getsockname()[1]
                            if port not in used_ports:
                                used_ports.add(port)
                                break
                        label = f'w{count}-c{population}-{name}-r{repeat + 1}'
                        run = trial(args, ssh, remote_dir, name, count, population, repeat, port, cert, key, output / label)
                        report['runs'].append(run)
                        save()
                        if run['valid']:
                            print(f"{label}: {run['requests_per_second']:,.0f} req/s, p99={run['p99_ms']} ms, "
                                  f"setup failures={run['setup']['failed']} + unattempted={run['setup_unattempted']}, "
                                  f"warmup failures={run['warmup']['failed']}, measured failures={run['measurement']['failed']}, "
                                  f"ready={run['ready_connections']}/{population}", flush=True)
        for name, path in binaries.items():
            assert digest(path) == report['binary_sha256'][name]
        for path in sources:
            assert digest(path) == report['source_sha256'][str(path.relative_to(ROOT))]
    report['finished_utc'] = datetime.now(timezone.utc).isoformat()
    report['complete'] = all(run['valid'] for run in report['runs'])
    save()
    # Only this newly created staging directory is removed, after local evidence is saved.
    if report['complete']:
        subprocess.run([*ssh, shlex.join(['rm', '-rf', '--', remote_dir])], check=True)
    else:
        raise SystemExit('Incomplete trials were retained; remote staging was kept for diagnosis')


if __name__ == '__main__':
    main()
