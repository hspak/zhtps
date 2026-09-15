"""Measure the actual server with validated pipeline and fragmented-write loads."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import subprocess
import time

from overload import get_json, kernel_sample, proc_sample, stop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--depth', type=int, default=1)
    parser.add_argument('--fragment', type=int, default=0)
    args = parser.parse_args()
    os.sched_setaffinity(0, {0})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = ['taskset', '-c', '2', str(args.binary), '--port', '0', '--admin-port', '0',
               '--no-access-log', '--max-connections', '256', '--max-requests', '4294967295']
    admin = None
    with args.output.with_suffix('.log').open('w+') as log:
        server = subprocess.Popen(command, stderr=log, stdout=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10; ports = {}
            while len(ports) < 2:
                log.seek(0)
                for line in log:
                    event = json.loads(line)
                    if event.get('event') in ('listening', 'admin_listening'): ports[event['event']] = event['port']
                if server.poll() is not None or time.monotonic() > deadline: raise RuntimeError('startup')
                time.sleep(.01)
            client = ['taskset', '-c', '4-7', '/tmp/zhtps-pipeline', '-address', f"127.0.0.1:{ports['listening']}",
                      '-connections', '64', '-depth', str(args.depth), '-fragment', str(args.fragment)]
            env = dict(os.environ, GOMAXPROCS='4')
            subprocess.run([*client, '-duration', '1s'], env=env, check=True, capture_output=True, timeout=10)
            admin = http.client.HTTPConnection('127.0.0.1', ports['admin_listening'], timeout=2)
            metrics_before = get_json(admin, '/debug/metrics'); before = proc_sample(server.pid); kernel_before = kernel_sample()
            run = subprocess.run([*client, '-duration', '5s'], env=env, check=True, capture_output=True, text=True, timeout=15)
            after = proc_sample(server.pid); kernel_after = kernel_sample(); metrics_after = get_json(admin, '/debug/metrics')
            workload = json.loads(run.stdout)
            result = {'server_command': command, 'client_command': client, 'workload': workload,
                      'before': before, 'after': after, 'kernel_before': kernel_before, 'kernel_after': kernel_after,
                      'metrics_before': metrics_before, 'metrics_after': metrics_after,
                      'server_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                      'client_sha256': hashlib.sha256(Path('/tmp/zhtps-pipeline').read_bytes()).hexdigest(),
                      'cpu_ns_per_response': (after['cpu_seconds'] - before['cpu_seconds']) * 1e9 / workload['validated_responses']}
        finally:
            if admin is not None: admin.close()
            stop(server)
    result['server_exit'] = server.returncode
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'output': str(args.output), 'cpu_ns_per_response': result['cpu_ns_per_response'], **workload}), flush=True)


if __name__ == '__main__': main()
