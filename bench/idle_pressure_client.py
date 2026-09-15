"""Bounded remote workload: fill keepalive slots, then offer new connections."""

from concurrent.futures import ThreadPoolExecutor
import collections
import http.client
import json
import os
from pathlib import Path
import platform
import resource
import socket
import sys
import time


def emit(value):
    print(json.dumps(value), flush=True)


def main():
    options = json.loads(sys.stdin.readline())
    count = options['connections']
    assert 1 <= count <= 8192 and 1 <= options['requests'] <= 1024
    os.sched_setaffinity(0, set(range(8)))
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, count + 256), hard))
    emit({'kind': 'hello', 'hostname': platform.node(),
          'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip()})
    idle = []
    try:
        for _ in range(count):
            connection = http.client.HTTPConnection(options['address'], options['port'], timeout=3)
            idle.append(connection)
            connection.request('GET', '/')
            response = connection.getresponse()
            assert response.status == 200 and response.read() == b'ZHTPS\n'
        emit({'kind': 'ready', 'validated_initial_responses': count})
        assert json.loads(sys.stdin.readline())['kind'] == 'go'

        def request_new(_):
            begin = time.monotonic_ns()
            connection = http.client.HTTPConnection(options['address'], options['port'], timeout=.5)
            try:
                connection.request('GET', '/')
                response = connection.getresponse()
                if response.status != 200 or response.read() != b'ZHTPS\n':
                    return {'error': 'invalid_response', 'elapsed_ns': time.monotonic_ns() - begin}
                return {'error': None, 'elapsed_ns': time.monotonic_ns() - begin}
            except (OSError, http.client.HTTPException) as error:
                return {'error': type(error).__name__, 'elapsed_ns': time.monotonic_ns() - begin}
            finally:
                connection.close()

        cpu_begin = time.process_time()
        begin = time.monotonic()
        with ThreadPoolExecutor(max_workers=32) as executor:
            results = list(executor.map(request_new, range(options['requests'])))
        elapsed = time.monotonic() - begin
        successes = sorted(row['elapsed_ns'] for row in results if row['error'] is None)
        closed_idle = 0
        for connection in idle:
            connection.sock.setblocking(False)
            try:
                if connection.sock.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b'':
                    closed_idle += 1
            except BlockingIOError:
                pass
            except ConnectionResetError:
                closed_idle += 1
        emit({'kind': 'result', 'elapsed_seconds': elapsed,
              'client_cpu_seconds': time.process_time() - cpu_begin,
              'offered_new_connections': len(results), 'successes': len(successes),
              'failures': dict(collections.Counter(row['error'] for row in results if row['error'])),
              'new_connection_goodput': len(successes) / elapsed,
              'success_p99_ms': successes[min(len(successes) - 1, int(len(successes) * .99))] / 1e6
              if successes else None,
              'idle_connections_closed': closed_idle, 'outcomes': results})
        assert json.loads(sys.stdin.readline())['kind'] == 'finish'
    finally:
        for connection in idle:
            connection.close()


if __name__ == '__main__':
    main()
