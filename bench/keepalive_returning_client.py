"""Fill slots, introduce newcomers, then reuse every original connection repeatedly.

Only idempotent GETs are retried, once, after a stale keepalive fails. Logical
latency includes both attempts. Failed newcomers and resident attempts remain
in the output; successful-response latency is never substituted for failures.
"""

from concurrent.futures import ThreadPoolExecutor
import collections
import http.client
import json
import os
from pathlib import Path
import platform
import resource
import sys
import time


def emit(result):
    print(json.dumps(result), flush=True)


def main():
    options = json.loads(sys.stdin.readline())
    os.sched_setaffinity(0, set(range(8)))
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, 4096), hard))
    residents = [http.client.HTTPConnection(options['address'], options['port'], timeout=.5)
                 for _ in range(1024)]

    def request(connection, resident):
        begin = time.monotonic_ns()
        attempts = []
        opened = 0
        for _ in range(2 if resident else 1):
            try:
                if connection.sock is None:
                    opened += 1
                connection.request('GET', '/')
                response = connection.getresponse()
                if response.status != 200 or response.read() != b'ZHTPS\n':
                    raise ValueError('invalid response')
                return dict(success=True, elapsed_us=(time.monotonic_ns() - begin) / 1000,
                            attempts=attempts, connections_opened=opened)
            except (OSError, http.client.HTTPException) as error:
                attempts.append(type(error).__name__)
                connection.close()
        return dict(success=False, elapsed_us=(time.monotonic_ns() - begin) / 1000,
                    attempts=attempts, connections_opened=opened)

    def newcomer(_):
        connection = http.client.HTTPConnection(options['address'], options['port'], timeout=.5)
        try:
            return request(connection, False)
        finally:
            connection.close()

    def summarize(rows):
        successes = sorted(r['elapsed_us'] for r in rows if r['success'])
        return dict(offered=len(rows), successes=len(successes), failures=len(rows) - len(successes),
                    connections_opened=sum(r['connections_opened'] for r in rows),
                    attempt_errors=dict(collections.Counter(e for r in rows for e in r['attempts'])),
                    p50_us=successes[len(successes) // 2] if successes else None,
                    p99_us=successes[min(len(successes) - 1, int(len(successes) * .99))] if successes else None)

    rounds = []
    try:
        # Sequential setup guarantees every slot contains a validated keepalive.
        for connection in residents:
            assert request(connection, False)['success']
        emit(dict(validated=len(residents), identity=dict(hostname=platform.node(),
                  boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip())))
        assert json.loads(sys.stdin.readline())['go']
        begin = time.monotonic()
        with ThreadPoolExecutor(max_workers=32) as executor:
            for number in range(options['rounds']):
                time.sleep(options['idle_ms'] / 1000)
                arrivals = list(executor.map(newcomer, range(128)))
                returning = list(executor.map(lambda c: request(c, True), residents))
                rounds.append(dict(round=number + 1, newcomers=arrivals, residents=returning))
        emit(dict(elapsed_seconds=time.monotonic() - begin, rounds=rounds,
                  newcomers=summarize([r for trial in rounds for r in trial['newcomers']]),
                  residents=summarize([r for trial in rounds for r in trial['residents']])))
        assert json.loads(sys.stdin.readline())['finish']
    finally:
        for connection in residents:
            connection.close()


if __name__ == '__main__':
    main()
