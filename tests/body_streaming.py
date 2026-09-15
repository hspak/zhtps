"""Incremental consumers preserve body framing, borrowing, and application deadlines."""

import contextlib
import json
import signal
import socket
import threading
import time
import unittest
import zlib

from buffer_pools import REQUEST, metrics, wait_released
from wire import Client, Running


def expected(body):
    return f'{len(body)}:{zlib.crc32(body):08x}\n'.encode()


def head(path, size, expect=False):
    return (f'POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {size}\r\n'
            + ('Expect: 100-continue\r\n' if expect else '') + '\r\n').encode()


def inspect(server):
    with Client(server.port) as client:
        client.send(b'GET /inspect HTTP/1.1\r\nHost: localhost\r\n\r\n')
        status, _, body = client.response()
        assert status == 200
        return json.loads(body)


def wait_for(server, field, amount):
    deadline = time.monotonic() + 3
    while True:
        captured = inspect(server)
        if captured[field] == amount:
            return captured
        if time.monotonic() >= deadline:
            raise AssertionError(captured)
        time.sleep(.005)


class BodyStreamingTests(unittest.TestCase):
    def test_repeated_concurrent_upload_bursts_reuse_promoted_buffers(self):
        body = bytes(range(256)) * 256
        with Running('--workers', '1', '--max-connections', '64', '--max-active', '64',
                     '--no-access-log') as server, contextlib.ExitStack() as stack:
            clients = [stack.enter_context(Client(server.port)) for _ in range(32)]
            captured = []
            for _ in range(2):
                # Continue holds every body lease before this burst can finish.
                for client in clients:
                    client.send(head('/upload', len(body), expect=True))
                for client in clients:
                    self.assertEqual(client.response()[0], 100)
                for client in clients:
                    client.send(body)
                for client in clients:
                    self.assertEqual(client.response()[::2], (200, expected(body)))
                captured.append(wait_released(server))
            first = captured[0]['counters']['buffer_allocations_total']
            self.assertGreater(first, 8)
            self.assertEqual(captured[1]['counters']['buffer_allocations_total'], first)

    def test_consumes_before_body_end_with_bounded_storage_and_reuses_keepalive(self):
        body = bytes(range(256)) * 4096
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.send(head('/upload', len(body), expect=True))
            self.assertEqual(client.response()[0], 100)
            client.send(body[:60000])
            captured = wait_for(server, 'consumed', 60000)
            self.assertEqual(captured['completed'], 0)
            self.assertLess(metrics(server)['gauges']['buffer_bytes_active'], len(body))
            client.send(body[60000:])
            self.assertEqual(client.response()[::2], (200, expected(body)))
            client.send(head('/upload', 4) + b'next' + REQUEST)
            self.assertEqual(client.response()[::2], (200, expected(b'next')))
            self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            wait_for(server, 'released', 2)

    def test_chunked_fragments_trailers_and_following_request_preserve_bytes(self):
        body = bytes(range(256)) * 1024
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.send(b'POST /upload HTTP/1.1\r\nHost: localhost\r\n'
                        b'Transfer-Encoding: chunked\r\n\r\n')
            for start in range(0, len(body), 997):
                chunk = body[start:start + 997]
                client.send(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
            client.send(b'0\r\nX-Trailer: valid\r\n\r\n' + REQUEST)
            self.assertEqual(client.response()[::2], (200, expected(body)))
            self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))

    def test_empty_stream_runs_the_final_handler_without_a_consumer_chunk(self):
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.send(head('/upload', 0))
            self.assertEqual(client.response()[::2], (200, expected(b'')))
            self.assertEqual(wait_for(server, 'released', 1)['consumed'], 0)

    def test_invalid_trailer_aborts_after_consumption_without_running_final_handler(self):
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.send(b'POST /upload HTTP/1.1\r\nHost: localhost\r\n'
                        b'Transfer-Encoding: chunked\r\n\r\n4\r\nbody\r\n')
            self.assertEqual(wait_for(server, 'consumed', 4)['completed'], 0)
            client.send(b'0\r\nContent-Length: 4\r\n\r\n' + REQUEST)
            self.assertEqual(client.response()[0], 400)
            self.assertEqual(client.socket.recv(1), b'')
            captured = wait_for(server, 'released', 1)
            self.assertEqual(captured['consumed'], 4)
            self.assertEqual(captured['completed'], 0)

    def test_known_body_limit_precedes_continue_and_consumer(self):
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.send(head('/small', 17, expect=True))
            self.assertEqual(client.response()[0], 413)
            captured = inspect(server)
            self.assertEqual(captured['consumed'], 0)
            self.assertEqual(captured['completed'], 0)

    def test_chunked_limit_closes_without_dispatching_a_pipelined_request(self):
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.send(b'POST /small HTTP/1.1\r\nHost: localhost\r\n'
                        b'Transfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n')
            wait_for(server, 'consumed', 9)
            client.send(b'8\r\nabcdefgh\r\n0\r\n\r\n' + REQUEST)
            self.assertEqual(client.response()[0], 413)
            self.assertEqual(client.socket.recv(1), b'')
            captured = wait_for(server, 'released', 1)
            self.assertEqual(captured['consumed'], 9)
            self.assertEqual(captured['completed'], 0)

    def test_consumer_error_and_head_middleware_stop_ingestion(self):
        for path, status, expect in (('/invalid', 400, False), ('/denied', 403, True)):
            with self.subTest(path=path), Running('--no-access-log') as server, Client(server.port) as client:
                client.send(head(path, 4, expect=expect) + (b'oops' + REQUEST if not expect else b''))
                self.assertEqual(client.response()[0], status)
                captured = wait_for(server, 'released', 1)
                self.assertEqual(captured['consumed'], 0)
                self.assertEqual(captured['completed'], 0)

    def test_blocked_consumer_preserves_borrowed_bytes_and_backpressures_sender(self):
        body = bytes(range(256)) * 32768
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 16384)
            client.socket.settimeout(10)
            client.send(head('/held', len(body)) + body[:65536])
            captured = wait_for(server, 'holding', 1)
            self.assertEqual(captured['consumed'], 0)
            started, done = threading.Event(), threading.Event()
            errors = []

            def send_rest():
                started.set()
                try:
                    client.send(body[65536:])
                except BaseException as error:
                    errors.append(error)
                finally:
                    done.set()

            sender = threading.Thread(target=send_rest)
            sender.start()
            try:
                self.assertTrue(started.wait(1))
                self.assertFalse(done.wait(.05))
                self.assertEqual(inspect(server)['holding'], 1)
                self.assertLess(metrics(server)['gauges']['buffer_bytes_active'], len(body))
            finally:
                server.process.send_signal(signal.SIGUSR1)
                sender.join(timeout=10)
            self.assertFalse(sender.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(client.response()[::2], (200, expected(body)))
            wait_for(server, 'released', 1)

    def test_disconnect_retains_request_until_consumer_returns(self):
        with Running('--no-access-log') as server:
            with Client(server.port) as client:
                client.send(head('/held', 100000) + b'borrowed')
                wait_for(server, 'holding', 1)
            self.assertEqual(inspect(server)['released'], 0)
            server.process.send_signal(signal.SIGUSR1)
            captured = wait_for(server, 'released', 1)
            self.assertEqual(captured['consumed'], 8)
            self.assertEqual(captured['completed'], 0)

    def test_body_callback_does_not_restart_the_application_deadline(self):
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.send(head('/deadline', 1000, expect=True))
            self.assertEqual(client.response()[0], 100)
            time.sleep(.1)
            client.send(b'x')
            wait_for(server, 'consumed', 1)
            client.socket.settimeout(.12)
            self.assertEqual(client.socket.recv(1), b'')
            captured = wait_for(server, 'released', 1)
            self.assertEqual(captured['completed'], 0)
            self.assertEqual(metrics(server)['counters']['application_timeouts_total'], 1)

    def test_final_consumer_expiring_does_not_run_final_handler(self):
        with Running('--no-access-log') as server, Client(server.port) as client:
            client.send(head('/deadline-held', 1) + b'x')
            wait_for(server, 'holding', 1)
            time.sleep(.2)
            server.process.send_signal(signal.SIGUSR1)
            self.assertEqual(client.socket.recv(1), b'')
            captured = wait_for(server, 'released', 1)
            self.assertEqual(captured['consumed'], 1)
            self.assertEqual(captured['completed'], 0)
            self.assertEqual(metrics(server)['counters']['application_timeouts_total'], 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
