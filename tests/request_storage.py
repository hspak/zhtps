"""Request storage follows active parsing and cleanup rather than idle sockets."""

from contextlib import ExitStack
import time
import unittest

from buffer_pools import REQUEST, metrics
from wire import Client, Running


def wait_active(server, expected):
    deadline = time.monotonic() + 3
    while True:
        captured = metrics(server)
        if captured['gauges']['request_storage_active'] == expected:
            return captured
        if time.monotonic() >= deadline:
            raise AssertionError(captured)
        time.sleep(.01)


class RequestStorageTests(unittest.TestCase):
    def test_idle_sockets_release_request_storage_after_each_response(self):
        with Running('--no-access-log', '--max-connections', '80') as server:
            with ExitStack() as stack:
                clients = [stack.enter_context(Client(server.port)) for _ in range(70)]
                wait_active(server, 0)
                for _ in range(2):
                    for client in clients:
                        client.send(REQUEST)
                        self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
                    wait_active(server, 0)
                for client in clients:
                    client.send(REQUEST * 17)
                    for _ in range(17):
                        self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
                wait_active(server, 0)

    def test_fragmented_requests_grow_the_pool_then_return_to_its_cache_bound(self):
        with Running('--no-access-log', '--max-connections', '80',
                     '--max-active', '80') as server:
            with ExitStack() as stack:
                clients = [stack.enter_context(Client(server.port)) for _ in range(70)]
                for client in clients:
                    client.send(b'GET / HTTP/1.1\r\nHost: localhost\r\nX-Hold: ')
                captured = wait_active(server, 70)
                self.assertEqual(captured['gauges']['request_storage_cached'], 0)
                self.assertEqual(captured['counters']['request_storage_allocations_total'], 6)
                for client in clients:
                    client.send(b'done\r\n\r\n')
                    self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
                captured = wait_active(server, 0)
                self.assertEqual(captured['gauges']['request_storage_cached'], 64)

    def test_disconnect_and_deadline_return_partial_request_leases(self):
        with Running('--no-access-log', '--body-timeout-ms', '150') as server:
            with Client(server.port) as client:
                client.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                            b'Content-Length: 10\r\nExpect: 100-continue\r\n\r\n')
                self.assertEqual(client.response()[0], 100)
                wait_active(server, 1)
                self.assertEqual(client.response()[0], 408)
            wait_active(server, 0)
            with Client(server.port) as client:
                client.send(b'GET / HTTP/1.1\r\nHost: ')
                wait_active(server, 1)
            captured = wait_active(server, 0)
            self.assertEqual(captured['counters']['request_storage_exhaustions_total'], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
