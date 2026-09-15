"""Exercise requests crossing the shutdown boundary on real keepalive sockets."""

import contextlib
import json
import queue
import signal
import socket
import threading
import time
import unittest

from wire import Client, Running


REQUEST = b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'


def begin_shutdown(server, sig=signal.SIGTERM, workers=1):
    server.process.send_signal(sig)
    deadline = time.monotonic() + 2
    observed = set()
    while len(observed) < workers:
        try:
            event = server.ready.get(timeout=max(.001, deadline - time.monotonic()))
        except queue.Empty:
            raise AssertionError('shutdown did not start')
        if event.get('event') == 'shutdown_started':
            observed.add(event['worker'])


class ShutdownTests(unittest.TestCase):
    def assert_listeners_refuse_connections(self, server):
        for port in (server.port, server.admin_port):
            for _ in range(4):
                with self.assertRaises(ConnectionRefusedError):
                    with socket.create_connection(('127.0.0.1', port), timeout=.3):
                        pass

    def test_signals_refuse_new_connections_and_finish_uploads_on_every_worker(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            for workers in (1, 3):
                with self.subTest(signal=sig, workers=workers), Running(
                    '--workers', str(workers), '--no-access-log',
                ) as server, contextlib.ExitStack() as stack:
                    clients = []
                    for _ in range(64 if workers > 1 else 2):
                        client = stack.enter_context(Client(server.port))
                        client.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                                    b'Content-Length: 8\r\nExpect: 100-continue\r\n\r\n')
                        self.assertEqual(client.response()[0], 100)
                        client.send(b'infl')
                        clients.append(client)
                    with Client(server.admin_port) as admin:
                        admin.send(b'GET /debug/workers HTTP/1.1\r\nHost: localhost\r\n\r\n')
                        owners = json.loads(admin.response()[2])['workers']
                        self.assertTrue(all(w['requests_active'] > 0 for w in owners))

                    begin_shutdown(server, sig, workers)
                    self.assert_listeners_refuse_connections(server)
                    server.process.send_signal(signal.SIGTERM if sig == signal.SIGINT else signal.SIGINT)
                    for client in clients:
                        client.send(b'ight' + REQUEST)
                        status, fields, body = client.response()
                        self.assertEqual((status, body), (200, b'inflight'))
                        self.assertEqual(fields[b'connection'], b'close')
                        self.assertEqual(client.buffer, b'')
                        self.assertEqual(client.socket.recv(1), b'')
                    self.assertEqual(server.process.wait(timeout=1), 0)

    def test_shutdown_rejects_the_backlog_when_all_connection_slots_are_busy(self):
        with Running('--max-connections', '1', '--no-access-log') as server:
            with Client(server.port) as active:
                active.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                            b'Content-Length: 4\r\nExpect: 100-continue\r\n\r\n')
                self.assertEqual(active.response()[0], 100)
                with Client(server.port) as queued:
                    begin_shutdown(server)
                    self.assert_listeners_refuse_connections(server)
                    queued.socket.settimeout(.3)
                    try:
                        self.assertEqual(queued.socket.recv(1), b'')
                    except ConnectionResetError:
                        pass
                    active.send(b'body')
                    self.assertEqual(active.response()[::2], (200, b'body'))

    def test_response_started_before_signal_is_not_truncated(self):
        body = bytes(range(256)) * 256
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig), Running('--no-access-log') as server:
                with Client(server.port) as client:
                    client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                    client.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                                b'Content-Length: 65536\r\n\r\n' + body)
                    head = client.until(b'\r\n\r\n')
                    self.assertTrue(head.startswith(b'HTTP/1.1 200 '))
                    self.assertIn(b'Content-Length: 65536', head)
                    self.assertEqual(client.take(1), body[:1])
                    server.process.send_signal(sig)
                    time.sleep(.03)
                    self.assertEqual(client.take(len(body) - 1), body[1:])
                    self.assertEqual(client.socket.recv(1), b'')
                    self.assertEqual(server.process.wait(timeout=1), 0)

    def test_repeated_signals_do_not_extend_the_deadline_for_a_stalled_upload(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig), Running(
                '--shutdown-timeout-ms', '250', '--body-timeout-ms', '10000', '--no-access-log',
            ) as server, Client(server.port) as client:
                client.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                            b'Content-Length: 4\r\nExpect: 100-continue\r\n\r\n')
                self.assertEqual(client.response()[0], 100)
                begin = time.monotonic()
                begin_shutdown(server, sig)
                for _ in range(4):
                    time.sleep(.04)
                    self.assertIsNone(server.process.poll())
                    server.process.send_signal(sig)
                self.assertEqual(server.process.wait(timeout=.2), 0)
                elapsed = time.monotonic() - begin
                self.assertGreaterEqual(elapsed, .22)
                self.assertLess(elapsed, .4)
                self.assertEqual(client.socket.recv(1), b'')

    def test_shutdown_finishes_a_backpressured_response_before_closing(self):
        body = bytes(range(256)) * 256
        request = b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65536\r\n\r\n' + body
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig), Running('--no-access-log') as server:
                with Client(server.port) as client, Client(server.admin_port) as admin:
                    client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                    client.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

                    def send_pipeline():
                        try:
                            for _ in range(96):
                                client.send(request)
                        except OSError:
                            pass  # Shutdown discards requests beyond the active response.

                    sender = threading.Thread(target=send_pipeline, daemon=True)
                    sender.start()
                    try:
                        deadline = time.monotonic() + 2
                        previous = None
                        stalled_since = time.monotonic()
                        while True:
                            admin.send(b'GET /debug/connections HTTP/1.1\r\nHost: localhost\r\n\r\n')
                            entries = json.loads(admin.response()[2])['connections']
                            entry = next((c for c in entries
                                          if not c['admin'] and c['phase'] == 'writing'), None)
                            writing = entry['request'] if entry else None
                            now = time.monotonic()
                            if writing is None or writing != previous:
                                stalled_since = now
                            elif now - stalled_since >= .05:
                                expected = entry['requests'] + 1
                                break
                            self.assertLess(now, deadline, entries)
                            previous = writing
                            time.sleep(.01)

                        begin_shutdown(server, sig)
                        self.assert_listeners_refuse_connections(server)
                        client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
                        completed = 0
                        while True:
                            # EOF/reset is legal only between complete responses.
                            if not client.buffer:
                                try:
                                    client.buffer = client.socket.recv(65536)
                                except ConnectionResetError:
                                    break
                                if not client.buffer:
                                    break
                            self.assertEqual(client.response()[::2], (200, body))
                            completed += 1
                        self.assertEqual(completed, expected)
                        self.assertLess(completed, 96)
                        self.assertEqual(server.process.wait(timeout=1), 0)
                    finally:
                        try:
                            client.socket.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
                        sender.join(timeout=1)
                        self.assertFalse(sender.is_alive())

    def test_idle_reuse_arriving_after_shutdown_starts_gets_one_closing_response(self):
        with Running('--no-access-log', '--idle-reclaim-ms', '0') as server:
            with Client(server.port) as idle, Client(server.port) as active:
                idle.send(REQUEST)
                self.assertEqual(idle.response()[::2], (200, b'ZHTPS\n'))
                active.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                            b'Content-Length: 4\r\nExpect: 100-continue\r\n\r\n')
                self.assertEqual(active.response()[0], 100)
                # An old idle connection can race shutdown just like a recent one.
                time.sleep(.15)
                begin_shutdown(server)
                idle.send(REQUEST + REQUEST)
                status, fields, body = idle.response()
                self.assertEqual((status, body), (200, b'ZHTPS\n'))
                self.assertEqual(fields[b'connection'], b'close')
                self.assertEqual(idle.socket.recv(1), b'')
                active.send(b'body')
                self.assertEqual(active.response()[::2], (200, b'body'))

    def test_header_started_before_shutdown_finishes_after_idle_grace(self):
        with Running('--no-access-log') as server:
            with Client(server.port) as client:
                client.send(REQUEST)
                self.assertEqual(client.response()[0], 200)
                client.send(b'GET / HTTP/1.1\r\nHost: local')
                time.sleep(.03)
                begin_shutdown(server)
                time.sleep(.15)
                client.send(b'host\r\n\r\n')
                status, fields, body = client.response()
                self.assertEqual((status, body), (200, b'ZHTPS\n'))
                self.assertEqual(fields[b'connection'], b'close')

    def test_silent_keepalive_does_not_hold_the_whole_shutdown_timeout(self):
        with Running('--no-access-log', '--shutdown-keepalive-ms', '80') as server:
            with Client(server.port) as idle:
                idle.send(REQUEST)
                self.assertEqual(idle.response()[0], 200)
                begin = time.monotonic()
                begin_shutdown(server)
                idle.socket.settimeout(1)
                self.assertEqual(idle.socket.recv(1), b'')
                elapsed = time.monotonic() - begin
                self.assertGreaterEqual(elapsed, .06)
                self.assertLess(elapsed, 1)

    def test_idle_grace_is_capped_by_shutdown_deadline(self):
        with Running('--no-access-log', '--shutdown-timeout-ms', '50',
                     '--shutdown-keepalive-ms', '1000') as server:
            with Client(server.port) as idle:
                idle.send(REQUEST)
                self.assertEqual(idle.response()[0], 200)
                begin = time.monotonic()
                begin_shutdown(server)
                self.assertEqual(idle.socket.recv(1), b'')
                server.process.wait(timeout=.5)
                self.assertLess(time.monotonic() - begin, .5)

    def test_initial_idle_connections_are_closed_without_keepalive_grace(self):
        with Running('--no-access-log', '--shutdown-keepalive-ms', '1000') as server:
            with Client(server.port) as initial, Client(server.port) as established:
                established.send(REQUEST)
                self.assertEqual(established.response()[0], 200)
                begin_shutdown(server)
                initial.socket.settimeout(.3)
                self.assertEqual(initial.socket.recv(1), b'')
                established.send(REQUEST)
                self.assertEqual(established.response()[0], 200)

    def test_final_keepalive_request_still_obeys_active_request_limit(self):
        with Running('--no-access-log', '--max-connections', '2', '--max-active', '1') as server:
            with Client(server.port) as idle, Client(server.port) as active:
                idle.send(REQUEST)
                self.assertEqual(idle.response()[0], 200)
                active.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                            b'Content-Length: 4\r\nExpect: 100-continue\r\n\r\n')
                self.assertEqual(active.response()[0], 100)
                begin_shutdown(server)
                idle.send(REQUEST)
                status, fields, _ = idle.response()
                self.assertEqual(status, 503)
                self.assertEqual(fields[b'connection'], b'close')
                active.send(b'body')
                self.assertEqual(active.response()[::2], (200, b'body'))

    def test_zero_keepalive_grace_preserves_immediate_idle_close(self):
        with Running('--no-access-log', '--shutdown-keepalive-ms', '0') as server:
            with Client(server.port) as idle:
                idle.send(REQUEST)
                self.assertEqual(idle.response()[0], 200)
                # Immediate exit can drop buffered diagnostic logs; socket EOF
                # is the observable contract for the zero-window case.
                server.process.terminate()
                idle.socket.settimeout(.3)
                self.assertEqual(idle.socket.recv(1), b'')


if __name__ == '__main__':
    unittest.main(verbosity=2)
