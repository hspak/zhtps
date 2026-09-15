"""Count upload server syscalls in a diagnostic run, excluded from timing decisions."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import zlib

from compare import free_port


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve()
    port, admin = free_port(), free_port()
    server_command = [str(binary), '--address', '127.0.0.1', '--port', str(port),
                      '--admin-port', str(admin), '--workers', '1', '--worker-cpus', '9',
                      '--max-connections', '256', '--max-active', '256', '--no-access-log']
    command = ['strace', '-f', '-c', '-o', str(args.output / 'syscalls.txt'), *server_command]
    body = bytes(range(256)) * 256
    expected = f'{len(body)}:{zlib.crc32(body):08x}\n'.encode()
    record = dict(command=command, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  requests=0, body_bytes=len(body), diagnostic_only=True)
    with (args.output / 'server.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while True:
                client = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                try:
                    client.request('GET', '/')
                    response = client.getresponse()
                    assert response.status == 200 and response.read() == b'ZHTPS\n'
                    break
                except OSError:
                    client.close()
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise
                    time.sleep(.02)
            for _ in range(1000):
                client.request('POST', '/upload', body=body)
                response = client.getresponse()
                assert response.status == 200 and response.read() == expected
                record['requests'] += 1
            client.close()
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                record['trace_exit'] = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise
            (args.output / 'run.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
