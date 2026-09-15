"""Exercise buffer promotion, bounded overload and reuse through the HTTP server."""

import json
from contextlib import ExitStack
from pathlib import Path
import time
import unittest

from wire import Client, Running


REQUEST = b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'


def metrics(server):
    with Client(server.admin_port) as client:
        client.send(b'GET /debug/metrics HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
        status, _, body = client.response()
        assert status == 200
        return json.loads(body)


def wait_released(server):
    deadline = time.monotonic() + 2
    while True:
        captured = metrics(server)
        if captured['gauges']['buffer_bytes_active'] == 0:
            return captured
        if time.monotonic() >= deadline:
            raise AssertionError(captured['gauges'])
        time.sleep(.01)


class BufferPoolTests(unittest.TestCase):
    def test_admission_rejection_does_not_borrow_body_buffers(self):
        for budget in (0, 65536):
            with self.subTest(budget=budget), Running(
                    '--no-access-log', '--max-active', '1',
                    '--large-buffer-bytes', str(budget)) as server, Client(server.port) as slow:
                slow.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                          b'Content-Length: 1\r\nExpect: 100-continue\r\n\r\n')
                self.assertEqual(slow.response()[0], 100)
                with Client(server.port) as rejected:
                    rejected.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                                  b'Transfer-Encoding: chunked\r\n'
                                  b'Expect: 100-continue\r\n\r\n')
                    self.assertEqual(rejected.response()[0], 503)
                    captured = metrics(server)
                    self.assertEqual(captured['counters']['buffer_allocations_total'], 0)
                    self.assertEqual(captured['counters']['buffer_exhaustions_total'], 0)
                    self.assertEqual(captured['counters']['requests_rejected_total'], 1)
                    self.assertEqual(captured['gauges']['buffer_bytes_active'], 0)
                slow.send(b'x')
                self.assertEqual(slow.response()[::2], (200, b'x'))

    def test_unused_slots_do_not_reserve_full_connection_buffer_sets(self):
        footprints = []
        for capacity in (64, 4096):
            with Running('--no-access-log', '--max-connections', str(capacity),
                         '--max-active', '64') as server:
                with Client(server.port) as client:
                    client.send(REQUEST)
                    self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
                status = Path(f'/proc/{server.process.pid}/status').read_text()
                footprints.append(int(next(line.split()[1] for line in status.splitlines()
                                           if line.startswith('VmRSS:'))) * 1024)
        # Slot records and ring metadata may grow; unused 20 KiB buffer sets must not.
        self.assertLess(footprints[1] - footprints[0], 16 * 1024 * 1024, footprints)

    def test_closed_connections_reuse_buffers_after_partial_reads_are_canceled(self):
        with Running('--no-access-log', '--max-connections', '64') as server:
            for repeat in range(2):
                with ExitStack() as stack:
                    clients = [stack.enter_context(Client(server.port)) for _ in range(32)]
                    for index, client in enumerate(clients):
                        body = bytes([index + 1]) * 317
                        client.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                                    b'Content-Length: 317\r\n\r\n' + body)
                    for index, client in enumerate(clients):
                        self.assertEqual(client.response()[::2], (200, bytes([index + 1]) * 317))
                        client.send(b'GET / HTTP/1.1\r\nHost: ')
                deadline = time.monotonic() + 3
                while True:
                    captured = metrics(server)
                    if captured['gauges']['connection_buffer_bytes_active'] == 0:
                        break
                    if time.monotonic() >= deadline:
                        self.fail(str(captured))
                    time.sleep(.01)
                allocations = captured['counters']['connection_buffer_allocations_total']
                self.assertEqual(captured['counters']['connection_buffer_exhaustions_total'], 0)
                if repeat == 0:
                    first_allocations = allocations
                else:
                    self.assertEqual(allocations, first_allocations)

    def test_small_pipelines_and_admin_work_without_a_large_buffer_budget(self):
        with Running('--no-access-log', '--large-buffer-bytes', '0', '--max-active', '64') as server:
            with Client(server.port) as client:
                client.send(REQUEST * 33)
                for _ in range(33):
                    self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            captured = metrics(server)
            self.assertEqual(captured['counters']['buffer_allocations_total'], 0)
            self.assertEqual(captured['counters']['buffer_exhaustions_total'], 0)

    def test_fragmented_large_headers_promote_without_losing_the_next_request(self):
        with Running('--no-access-log') as server, Client(server.port) as client:
            request = b'GET / HTTP/1.1\r\nHost: localhost\r\nX-Long: ' + b'x' * 9000 + b'\r\n\r\n'
            for start in range(0, len(request), 613):
                client.send(request[start:start + 613])
            self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            client.send(REQUEST * 16)
            for _ in range(16):
                self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            captured = wait_released(server)
            self.assertGreater(captured['counters']['buffer_allocations_total'], 0)
            self.assertEqual(captured['counters']['buffer_exhaustions_total'], 0)

    def test_large_body_trailers_and_pipeline_survive_promotion_and_reuse(self):
        body = bytes(range(256)) * 256
        request = (b'POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n'
                   b'10000\r\n' + body + b'\r\n0\r\nX-Trailer: ' + b'x' * 2000 + b'\r\n\r\n')
        with Running('--no-access-log') as server, Client(server.port) as client:
            for _ in range(3):
                client.send(request + REQUEST)
                self.assertEqual(client.response()[::2], (200, body))
                self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            captured = wait_released(server)
            self.assertEqual(captured['counters']['buffer_exhaustions_total'], 0)
            self.assertEqual(captured['counters']['buffer_allocations_total'], 2)

    def test_exhaustion_rejects_before_continue_and_disconnect_returns_the_lease(self):
        body = b'x' * 32768
        head = (b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 32768\r\n'
                b'Expect: 100-continue\r\n\r\n')
        with Running('--no-access-log', '--large-buffer-bytes', '65536') as server:
            with Client(server.port) as slow:
                slow.send(head)
                self.assertEqual(slow.response()[0], 100)
                self.assertEqual(metrics(server)['gauges']['buffer_bytes_active'], 65536)
                with Client(server.port) as rejected:
                    rejected.send(head)
                    self.assertEqual(rejected.response()[0], 503)
                    self.assertEqual(rejected.socket.recv(1), b'')
                self.assertEqual(metrics(server)['counters']['buffer_exhaustions_total'], 1)
            wait_released(server)
            with Client(server.port) as recovered:
                recovered.send(head)
                self.assertEqual(recovered.response()[0], 100)
                recovered.send(body)
                self.assertEqual(recovered.response()[::2], (200, body))
                recovered.send(REQUEST)
                self.assertEqual(recovered.response()[::2], (200, b'ZHTPS\n'))
            captured = wait_released(server)
            self.assertEqual(captured['counters']['buffer_allocations_total'], 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
