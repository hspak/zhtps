"""Measure idle timer cost with an explicitly selected server build."""
import argparse
import hashlib
import json
import os
import resource
from pathlib import Path
import socket
import subprocess
import time

from overload import proc_sample, stop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--connections', type=int, default=0)
    parser.add_argument('--seconds', type=int, default=10)
    args = parser.parse_args()
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    needed = max(args.connections + 64, 8256)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(max(soft, needed), hard), hard))
    os.sched_setaffinity(0, {0})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = ['taskset', '-c', '2', str(args.binary), '--port', '0', '--admin-port', '0',
               '--no-access-log', '--max-connections', '8168', '--idle-timeout-ms', '60000']
    sockets = []
    with args.output.with_suffix('.log').open('w+') as log:
        server = subprocess.Popen(command, stderr=log, stdout=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            port = None
            while port is None:
                log.seek(0)
                for line in log:
                    event = json.loads(line)
                    if event.get('event') == 'listening': port = event['port']
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('server did not start')
                time.sleep(.01)
            for _ in range(args.connections):
                sockets.append(socket.create_connection(('127.0.0.1', port), timeout=5))
            time.sleep(1)
            before = proc_sample(server.pid)
            before['task_runtime_ns'] = int(Path(f'/proc/{server.pid}/schedstat').read_text().split()[0])
            start = time.monotonic_ns()
            time.sleep(args.seconds)
            after = proc_sample(server.pid)
            after['task_runtime_ns'] = int(Path(f'/proc/{server.pid}/schedstat').read_text().split()[0])
            elapsed = time.monotonic_ns() - start
            result = {'command': command, 'connections': args.connections, 'elapsed_ns': elapsed,
                      'before': before, 'after': after,
                      'cpu_seconds': after['cpu_seconds'] - before['cpu_seconds'],
                      'task_runtime_ns': after['task_runtime_ns'] - before['task_runtime_ns'],
                      'sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest()}
        finally:
            for client in sockets: client.close()
            stop(server)
    result['server_exit'] = server.returncode
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__': main()
