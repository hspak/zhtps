"""Regression: a prepared load process must keep connections alive at the barrier.

Run against a client executable with --client. A 17-second barrier exceeds the
server's default 15-second idle timeout without changing the server's settings.
"""

import argparse
import json
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parent.parent


def check(client):
    with tempfile.TemporaryDirectory(prefix='zhtps-http2-idle-') as temporary:
        folder = Path(temporary)
        cert, key = folder / 'cert.pem', folder / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt',
                        'ec_paramgen_curve:P-256', '-nodes', '-keyout', str(key),
                        '-out', str(cert), '-days', '1', '-subj', '/CN=localhost',
                        '-addext', 'subjectAltName=IP:127.0.0.1'], check=True, capture_output=True)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        with (folder / 'server.log').open('w') as server_log, (folder / 'client.log').open('w') as client_log:
            server = subprocess.Popen([str(ROOT / 'zig-out/http2-benchmark/bin/zhtps'),
                                       '--port', str(port), '--admin-connections', '0',
                                       '--tls-certificate', str(cert), '--tls-key', str(key),
                                       '--no-access-log', '--max-requests', '4294967295'],
                                      stdout=server_log, stderr=server_log)
            process = None
            try:
                deadline = time.monotonic() + 5
                while True:
                    assert server.poll() is None, 'server exited'
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise
                        time.sleep(.02)
                process = subprocess.Popen([str(Path(client).resolve()), '-url', f'https://127.0.0.1:{port}/',
                                            '-ca', str(cert), '-connections', '2', '-streams', '4',
                                            '-duration', '.2s', '-warmup', '.1s', '-timeout', '2s',
                                            '-failures', str(folder / 'failures.jsonl'), '-synchronize'],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=client_log)
                events = queue.Queue()
                def collect():
                    for line in process.stdout:
                        events.put(json.loads(line))
                    events.put({'phase': 'eof'})
                threading.Thread(target=collect, daemon=True).start()
                event = events.get(timeout=10)
                assert event['phase'] in ('prepared', 'ready'), event
                assert event['established'] == 2
                time.sleep(17)
                def start():
                    process.stdin.write(f'{time.time_ns() + 100_000_000}\n'.encode())
                    process.stdin.flush()
                # Accept both protocols so the same behavioral assertion can be
                # run against the client from before the shared setup barrier.
                if event['phase'] == 'prepared':
                    start()
                    event = events.get(timeout=10)
                    assert event['phase'] == 'ready', event
                start()
                event = events.get(timeout=10)
                assert event['phase'] == 'measured', event
                result = events.get(timeout=10)
                assert result['phase'] == 'result', result
                assert process.wait(timeout=5) == 0
                assert result['measurement']['failed'] == 0, result['measurement']
                assert result['successful_connections'] == result['alive_connections'] == 2
                assert result['failure_log_entries'] == 0
                print(json.dumps({'passed': True, 'barrier_seconds': 17,
                                  'successful_connections': result['successful_connections'],
                                  'measured_successes': result['measurement']['succeeded'],
                                  'failures': result['failure_log_entries']}))
            finally:
                for child in (process, server):
                    if child and child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', default=ROOT / 'zig-out/http2-benchmark/lan-client')
    check(parser.parse_args().client)
