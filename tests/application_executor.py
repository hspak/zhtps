"""Exercise cross-worker scheduling and borrowed lifetimes through real sockets."""

import contextlib
import json
import signal
import time
import unittest

from wire import Client, Running


def get(client, path):
    client.send(f'GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode())
    status, _, body = client.response()
    assert status == 200, (status, body)
    return body


def connections(server):
    captured = set()
    start = 0
    with Client(server.admin_port) as admin:
        while start is not None:
            page = json.loads(get(admin, f'/debug/connections?start={start}'))
            captured.update((c['worker'], c['id']) for c in page['connections'] if not c['admin'])
            start = page['next']
    return captured


def clients_by_worker(server, stack):
    groups = {}
    previous = connections(server)
    for _ in range(32):
        client = stack.enter_context(Client(server.port))
        deadline = time.monotonic() + 2
        while True:
            current = connections(server)
            added = current - previous
            if added:
                break
            assert time.monotonic() < deadline, current
            time.sleep(.005)
        assert len(added) == 1, added
        worker, _ = added.pop()
        groups.setdefault(worker, []).append(client)
        previous = current
        if len(groups) == 2 and max(map(len, groups.values())) >= 2:
            shared = next(worker for worker, clients in groups.items() if len(clients) >= 2)
            return groups[shared][0], groups[shared][1], groups[1 - shared][0]
    raise AssertionError('did not obtain two owners and a pair of sockets on one owner')


def wait_inspection(client, predicate):
    deadline = time.monotonic() + 2
    while True:
        captured = json.loads(get(client, '/inspect'))
        if predicate(captured):
            return captured
        assert time.monotonic() < deadline, captured
        time.sleep(.005)


class ApplicationExecutorTests(unittest.TestCase):
    def test_inline_head_keeps_the_application_deadline_during_body_ingestion(self):
        with Running('--workers', '2', '--no-access-log', '--body-timeout-ms', '10000') as server:
            with Client(server.port) as slow:
                slow.send(b'POST /body HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n'
                          b'Expect: 100-continue\r\n\r\n')
                self.assertEqual(slow.response()[0], 100)
                slow.socket.settimeout(2)
                self.assertEqual(slow.socket.recv(1), b'')
            with Client(server.admin_port) as admin:
                captured = json.loads(get(admin, '/debug/metrics'))
            self.assertEqual(captured['counters']['application_timeouts_total'], 1)
            self.assertEqual(captured['counters']['body_timeouts_total'], 0)
            with Client(server.port) as recovered:
                self.assertEqual(get(recovered, '/'), b'ZHTPS\n')

    def test_idle_lane_serves_a_socket_whose_owners_lane_is_blocked(self):
        with Running('--workers', '2', '--max-connections', '32', '--no-access-log') as server:
            with contextlib.ExitStack() as stack:
                held, fast, other = clients_by_worker(server, stack)
                try:
                    held.send(b'GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n')
                    wait_inspection(other, lambda c: c['holding'] == 1)
                    fast.socket.settimeout(.3)
                    self.assertEqual(get(fast, '/'), b'ZHTPS\n')
                    self.assertEqual(json.loads(get(other, '/inspect'))['released'], 0)
                finally:
                    server.process.send_signal(signal.SIGUSR1)
                self.assertEqual(held.response()[::2], (200, b'ZHTPS\n'))
                captured = wait_inspection(other, lambda c: c['released'] == 1)
                self.assertEqual(captured, {'holding': 1, 'released': 1})

    def test_disconnect_does_not_release_storage_until_the_shared_hook_returns(self):
        with Running('--workers', '2', '--max-connections', '32', '--no-access-log') as server:
            with contextlib.ExitStack() as stack:
                held, fast, other = clients_by_worker(server, stack)
                try:
                    held.send(b'GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n')
                    wait_inspection(other, lambda c: c['holding'] == 1)
                    held.socket.close()
                    self.assertEqual(get(fast, '/'), b'ZHTPS\n')
                    self.assertEqual(json.loads(get(other, '/inspect'))['released'], 0)
                finally:
                    server.process.send_signal(signal.SIGUSR1)
                wait_inspection(other, lambda c: c['released'] == 1)
                self.assertEqual(get(fast, '/'), b'ZHTPS\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
