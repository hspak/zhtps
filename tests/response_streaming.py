"""Generated response streaming through real cleartext and TLS connections."""

import contextlib
import json
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import tempfile
import time
import unittest

from wire import Client, Running


class StreamingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="zhtps-stream-")
        cls.addClassCleanup(cls.directory.cleanup)
        path = Path(cls.directory.name)
        key, cert = path / "key.pem", path / "cert.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
        ], check=True, capture_output=True)
        cls.context = ssl.create_default_context(cafile=str(cert))
        cls.context.set_alpn_protocols(["http/1.1"])
        cls.options = ("--tls-certificate", str(cert), "--tls-key", str(key))

    @contextlib.contextmanager
    def server(self, secure, *options):
        with Running(*(self.options if secure else ()), "--workers", "1", *options) as server:
            yield server

    def client(self, server, secure):
        client = Client(server.port)
        if secure:
            client.socket = self.context.wrap_socket(client.socket, server_hostname="localhost")
        return client

    def request(self, client, path, method="GET", version="1.1"):
        client.send(f"{method} {path} HTTP/{version}\r\nHost: localhost\r\n\r\n".encode())

    def inspect(self, server, secure):
        with self.client(server, secure) as client:
            self.request(client, "/inspect")
            return json.loads(client.response()[2])

    def chunk(self, client):
        size = int(client.until(b"\r\n"), 16)
        data = client.take(size)
        self.assertEqual(client.take(2), b"\r\n")
        return data

    def test_flush_before_wait_neighbor_and_pipeline(self):
        for secure in (False, True):
            with self.subTest(secure=secure), self.server(secure) as server:
                with self.client(server, secure) as client:
                    self.request(client, "/events")
                    self.request(client, "/metadata")
                    head = client.until(b"\r\n\r\n")
                    self.assertIn(b"Transfer-Encoding: chunked", head)
                    self.assertIn(b"text/event-stream", head)
                    self.assertEqual(self.chunk(client), b"data: first\n\n")
                    held = self.inspect(server, secure)
                    self.assertEqual(held["holding"], 1)
                    self.assertEqual(held["released"], 0)
                    with self.client(server, secure) as control:
                        self.request(control, "/unblock")
                        self.assertEqual(control.response()[2], b"ok")
                    self.assertEqual(self.chunk(client), b"data: last\n\n")
                    self.assertEqual(self.chunk(client), b"")
                    self.assertEqual(json.loads(client.response()[2])["path"], "/metadata")
                    self.assertEqual(self.inspect(server, secure)["released"], 1)

    def test_large_generated_body_exceeds_scratch_and_keeps_connection(self):
        for secure in (False, True):
            with self.subTest(secure=secure), self.server(secure) as server:
                with self.client(server, secure) as client:
                    self.request(client, "/generated")
                    status, headers, body = client.response()
                    self.assertEqual(status, 200)
                    self.assertEqual(int(headers[b"content-length"]), 8 * 1024 * 1024)
                    self.assertEqual(body, b"0123456789abcdef" * (512 * 1024))
                    self.request(client, "/metadata")
                    self.assertEqual(client.response()[0], 200)

    def test_head_bodyless_and_empty_skip_or_finish_production(self):
        for secure in (False, True):
            with self.subTest(secure=secure), self.server(secure) as server:
                with self.client(server, secure) as client:
                    self.request(client, "/events", method="HEAD")
                    self.assertEqual(client.response(head=True)[0], 200)
                    self.request(client, "/generated", method="HEAD")
                    self.assertEqual(client.response(head=True)[1][b"content-length"], b"8388608")
                    self.request(client, "/stream-bodyless")
                    self.assertEqual(client.response()[0], 204)
                    self.request(client, "/stream-empty")
                    self.assertEqual(client.response()[2], b"")
                    counters = self.inspect(server, secure)
                    self.assertEqual(counters["holding"], 0)
                    self.assertEqual(counters["generated_bytes"], 0)

    def test_http10_unknown_length_ends_by_closing(self):
        for secure in (False, True):
            with self.subTest(secure=secure), self.server(secure) as server:
                with self.client(server, secure) as control:
                    self.request(control, "/unblock")
                    control.response()
                with self.client(server, secure) as client:
                    self.request(client, "/events", version="1.0")
                    head = client.until(b"\r\n\r\n")
                    self.assertIn(b"Connection: close", head)
                    self.assertNotIn(b"Transfer-Encoding", head)
                    self.assertEqual(client.take(25), b"data: first\n\ndata: last\n\n")
                    self.assertEqual(client.socket.recv(1), b"")

    def test_errors_and_length_mismatches_abort_without_second_response(self):
        for secure in (False, True):
            for path in ("/stream-error", "/stream-short", "/stream-long"):
                with self.subTest(secure=secure, path=path), self.server(secure) as server:
                    with self.client(server, secure) as client:
                        self.request(client, path)
                        self.assertIn(b"200 OK", client.until(b"\r\n\r\n"))
                        data = client.buffer
                        while True:
                            part = client.socket.recv(1024)
                            if not part:
                                break
                            data += part
                        self.assertNotIn(b"HTTP/", data)
                        self.assertNotIn(b"0\r\n\r\n", data)
                        if path == "/stream-short":
                            self.assertEqual(data, b"abc")
                        if path == "/stream-long":
                            self.assertEqual(data, b"")

    def test_deadline_and_shutdown_cancel_waiting_producers(self):
        for secure in (False, True):
            for shutdown in (False, True):
                with self.subTest(secure=secure, shutdown=shutdown):
                    with self.server(secure, "--shutdown-timeout-ms", "50") as server:
                        with self.client(server, secure) as client:
                            self.request(client, "/stream-cancel" if shutdown else "/stream-timeout")
                            client.until(b"\r\n\r\n")
                            self.assertEqual(self.chunk(client), b"data: first\n\n")
                            if shutdown:
                                server.process.terminate()
                            self.assertEqual(client.socket.recv(1), b"")
                            if not shutdown:
                                deadline = time.monotonic() + 1
                                while self.inspect(server, secure)["released"] != 1:
                                    self.assertLess(time.monotonic(), deadline)
                                    time.sleep(0.01)

    def test_reset_cancels_idle_producer_and_releases_its_lane(self):
        for secure in (False, True):
            with self.subTest(secure=secure), self.server(secure) as server:
                with self.client(server, secure) as client:
                    self.request(client, "/stream-cancel")
                    client.until(b"\r\n\r\n")
                    self.assertEqual(self.chunk(client), b"data: first\n\n")
                    client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                deadline = time.monotonic() + 1
                while self.inspect(server, secure)["released"] != 1:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                with self.client(server, secure) as client:
                    self.request(client, "/stream-empty")
                    self.assertEqual(client.response()[2], b"")


    def test_stream_handoff_obeys_buffer_budget_and_recovers(self):
        # Request scratch and response storage exhaust this budget before the
        # streaming handoff is allocated, so the producer must not run.
        with self.server(False, "--large-buffer-bytes", str(96 * 1024)) as server:
            for _ in range(3):
                with self.client(server, False) as client:
                    self.request(client, "/generated")
                    self.assertEqual(client.response()[0], 503)
            with self.client(server, False) as client:
                self.request(client, "/metadata")
                self.assertEqual(client.response()[0], 200)
            self.assertEqual(self.inspect(server, False)["generated_bytes"], 0)


if __name__ == "__main__":
    unittest.main()
