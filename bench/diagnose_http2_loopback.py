"""Remove the physical network in a separate high-connection ZHTPS diagnostic control."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import resource
import socket
import subprocess
import sys
import tempfile
import time

from compare_http2_lan import ROOT, aggregate, digest
from compare_http2 import stop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(hard, max(soft, 131072)), hard))
    binary = ROOT / 'zig-out/http2-benchmark/bin/zhtps'
    client = ROOT / 'zig-out/http2-benchmark/lan-client'
    report = {'scope': 'Loopback diagnostic; both processes share a host with disjoint physical CPU cores.',
              'binary_sha256': {'zhtps': digest(binary), 'client': digest(client)}, 'runs': []}
    with tempfile.TemporaryDirectory(prefix='zhtps-h2-local-cert-') as temporary:
        cert, key = Path(temporary) / 'cert.pem', Path(temporary) / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                        '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost',
                        '-addext', 'subjectAltName=IP:127.0.0.1'], check=True, capture_output=True)
        for repeat in range(args.repeats):
            folder = args.output / f'r{repeat + 1}'
            folder.mkdir()
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            command = ['taskset', '-c', '0-7', str(binary), '--address', '127.0.0.1', '--port', str(port),
                       '--admin-connections', '0', '--workers', '8', '--worker-cpus', '0-7',
                       '--no-access-log', '--max-connections', '8176', '--max-active', '8176',
                       '--http2-worker-streams', '65535', '--http2-memory-bytes', '4294967295',
                       '--max-requests', '4294967295', '--tls-certificate', str(cert), '--tls-key', str(key)]
            server = supervisor = None
            with (folder / 'server.log').open('w') as logs, (folder / 'supervisor.log').open('w') as errors:
                try:
                    server = subprocess.Popen(command, stdout=logs, stderr=logs)
                    deadline = time.monotonic() + 10
                    while True:
                        if server.poll() is not None:
                            raise RuntimeError('server exited during setup')
                        try:
                            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                raise
                            time.sleep(.02)
                    supervisor = subprocess.Popen([sys.executable, '-u', str(ROOT / 'bench/http2_remote.py')],
                                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
                    def send(message):
                        supervisor.stdin.write((json.dumps(message) + '\n').encode())
                        supervisor.stdin.flush()
                    hello = json.loads(supervisor.stdout.readline())
                    assert hello['kind'] == 'hello'
                    config = {'kind': 'run', 'folder': str((folder / 'client').resolve()), 'binary': str(client),
                              'binary_sha256': digest(client), 'certificate': str(cert),
                              'client_cpus': [*range(8, 16), *range(24, 32)], 'client_processes': 8,
                              'connections': 16384, 'streams': 4, 'url': f'https://127.0.0.1:{port}/',
                              'duration': 8, 'warmup': 2, 'timeout': 2, 'setup_deadline': 180,
                              'setup_concurrency': 32, 'max_seconds': 240}
                    send(config)
                    with (folder / 'events.jsonl').open('w') as events:
                        for line in supervisor.stdout:
                            events.write(line.decode())
                            event = json.loads(line)
                            if event['kind'] == 'prepared':
                                send({'kind': 'warmup'})
                            elif event['kind'] == 'ready':
                                send({'kind': 'measure'})
                            elif event['kind'] == 'result':
                                result = event
                                break
                            elif event['kind'] in ('error', 'eof'):
                                raise RuntimeError(event)
                            send({'kind': 'heartbeat'})
                        else:
                            raise RuntimeError('supervisor exited without a result')
                    supervisor.stdin.close()
                    assert supervisor.wait(timeout=10) == 0
                    summary = aggregate(result['shards'], 8)
                    for item in result['failure_logs']:
                        raw = gzip.decompress((folder / 'client' / item['path']).read_bytes())
                        assert hashlib.sha256(raw).hexdigest() == item['sha256_uncompressed']
                        assert len(raw.splitlines()) == item['entries']
                    run = {'server_command': command, 'client_config': config, 'identity': hello,
                           'result': result, 'summary': summary, 'server_exit_before_shutdown': server.poll()}
                    (folder / 'run.json').write_text(json.dumps(run, indent=2) + '\n')
                    report['runs'].append(run)
                    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
                    print(f"r{repeat + 1}: {summary['requests_per_second']:,.0f}/s, "
                          f"p99 {summary['p99_ms']} ms, {summary['failure_log_entries']} total failures", flush=True)
                finally:
                    if supervisor and supervisor.poll() is None:
                        stop(supervisor)
                    if server:
                        stop(server)
    assert digest(binary) == report['binary_sha256']['zhtps']
    assert digest(client) == report['binary_sha256']['client']


if __name__ == '__main__':
    main()
