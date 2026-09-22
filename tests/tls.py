"""TLS wire checks with real OpenSSL clients and ephemeral test credentials."""

import concurrent.futures
import contextlib
import json
import os
from pathlib import Path
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest

FIXTURE = sys.argv.pop(2) if len(sys.argv) > 2 and not sys.argv[2].startswith("-") else None

import wire
from wire import BINARY, Client, Running


REQUEST = b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"


class SecureClient(Client):
    def __init__(self, port, context, session=None):
        super().__init__(port)
        try:
            self.socket = context.wrap_socket(
                self.socket, server_hostname="localhost", session=session,
                suppress_ragged_eofs=False,
            )
        except BaseException:
            self.socket.close()
            raise


class FragmentedClient(Client):
    """Control TLS record fragmentation independently of HTTP write boundaries."""

    def __init__(self, port, context):
        super().__init__(port)
        self.raw = self.socket
        self.incoming = ssl.MemoryBIO()
        self.outgoing = ssl.MemoryBIO()
        self.ssl = context.wrap_bio(self.incoming, self.outgoing, server_hostname="localhost")
        try:
            while True:
                try:
                    self.ssl.do_handshake()
                    self.flush(fragment=3)
                    break
                except ssl.SSLWantReadError:
                    self.flush(fragment=3)
                    self.feed()
        except BaseException:
            self.raw.close()
            raise
        self.socket = self

    def feed(self):
        data = self.raw.recv(65536)
        if data:
            self.incoming.write(data)
        else:
            self.incoming.write_eof()

    def flush(self, fragment=65536):
        data = self.outgoing.read()
        for offset in range(0, len(data), fragment):
            self.raw.sendall(data[offset:offset + fragment])

    def sendall(self, data):
        self.ssl.write(data)
        self.flush(fragment=7)

    def recv(self, size):
        while True:
            try:
                return self.ssl.read(size)
            except ssl.SSLWantReadError:
                self.flush()
                self.feed()

    def close(self):
        self.raw.close()


class TlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="zhtps-tls-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.path = Path(cls.directory.name)
        cls.key = cls.path / "key.pem"
        cls.cert = cls.path / "cert.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-keyout", str(cls.key), "-out", str(cls.cert), "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-addext", "keyUsage=critical,digitalSignature,keyCertSign,cRLSign",
        ], check=True, capture_output=True)
        cls.context = ssl.create_default_context(cafile=str(cls.cert))
        # HTTP/1 framing checks explicitly negotiate that protocol now that h2
        # has its own integration suite and is preferred when both are offered.
        cls.context.set_alpn_protocols(["http/1.1"])
        cls.options = ("--tls-certificate", str(cls.cert), "--tls-key", str(cls.key))
        cls.server = Running(*cls.options, "--workers", "2", "--verbose")
        cls.addClassCleanup(cls.server.close)

    def client(self, server=None, context=None):
        return SecureClient((server or self.server).port, context or self.context)

    def metrics(self, server):
        with Client(server.admin_port) as client:
            client.send(b"GET /debug/metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
            status, _, body = client.response()
            self.assertEqual(status, 200)
            return json.loads(body)

    def redirect_port(self, server):
        with Client(server.admin_port) as client:
            client.send(b"GET /debug/config HTTP/1.1\r\nHost: localhost\r\n\r\n")
            status, _, body = client.response()
            self.assertEqual(status, 200)
            return json.loads(body)["http_redirect_port"]

    def test_http_redirect_requires_https_before_listening(self):
        result = subprocess.run([BINARY, "--http-redirect"], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"HttpsRequired", result.stderr)
        self.assertNotIn(b'"event":"listening"', result.stderr)

    def test_http_redirect_preserves_target_and_https_serves_normally(self):
        with Running(*self.options, "--http-redirect", "--http-redirect-port", "0",
                     "--workers", "2") as server:
            port = self.redirect_port(server)
            cases = (
                (b"/a%2Fb/../c?x=%2F&y=1", b"example.test:1234", b"example.test", b"/a%2Fb/../c?x=%2F&y=1"),
                (b"//other.test/path?", b"example.test", b"example.test", b"//other.test/path?"),
                (b"/", b"[::1]:8080", b"[::1]", b"/"),
                (b"http://example.test:1234/a?b", b"ignored.test", b"example.test", b"/a?b"),
                (b"http://example.test?", b"ignored.test", b"example.test", b"/?"),
                (b"/", b"", b"127.0.0.1", b"/"),
                (b"/" + b"a" * 8000, b"localhost", b"localhost", b"/" + b"a" * 8000),
            )
            for target, host, destination, suffix in cases:
                with self.subTest(target=target, host=host), Client(port) as client:
                    client.send(b"GET " + target + b" HTTP/1.1\r\nHost: " + host + b"\r\n\r\n")
                    status, fields, body = client.response()
                    self.assertEqual((status, body), (308, b""))
                    self.assertEqual(fields[b"location"], b"https://" + destination
                                     + f":{server.port}".encode() + suffix)
            with Client(port) as client:
                client.send(b"GET / HTTP/1.0\r\n\r\n")
                self.assertEqual(client.response()[1][b"location"],
                                 f"https://127.0.0.1:{server.port}/".encode())
            with self.client(server) as client:
                client.send(REQUEST)
                self.assertEqual(client.response()[0], 200)
            with Client(server.admin_port) as client:
                client.send(b"GET /debug/metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
                self.assertEqual(client.response()[0], 200)

    def test_http_redirect_precedes_continue_and_application_dispatch(self):
        with Running(*self.options, "--http-redirect", "--http-redirect-port", "0") as server:
            port = self.redirect_port(server)
            for framing in (b"Content-Length: 100", b"Transfer-Encoding: chunked"):
                with self.subTest(framing=framing), Client(port) as client:
                    client.send(b"POST /echo?upload=1 HTTP/1.1\r\nHost: localhost\r\n"
                                + framing + b"\r\nExpect: 100-continue\r\n\r\n")
                    status, fields, body = client.response()
                    self.assertEqual((status, body), (308, b""))
                    self.assertEqual(fields[b"connection"], b"close")
                    self.assertEqual(fields[b"location"],
                                     f"https://localhost:{server.port}/echo?upload=1".encode())

    def test_http_redirect_keepalive_and_invalid_requests(self):
        with Running(*self.options, "--http-redirect", "--http-redirect-port", "0") as server:
            port = self.redirect_port(server)
            with Client(port) as client:
                client.send(REQUEST * 3 + b"HEAD /missing HTTP/1.1\r\nHost: localhost\r\n\r\n")
                for _ in range(4):
                    self.assertEqual(client.response()[0], 308)
            for request, expected in (
                (b"GET / HTTP/1.1\r\n\r\n", 400),
                (b"GET / HTTP/1.1\r\nHost: evil/path\r\n\r\n", 400),
                (b"GET https://localhost/ HTTP/1.1\r\nHost: localhost\r\n\r\n", 421),
                (b"CONNECT localhost:80 HTTP/1.1\r\nHost: localhost\r\n\r\n", 400),
                (b"OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\n", 400),
            ):
                with self.subTest(request=request), Client(port) as client:
                    client.send(request)
                    status, fields, _ = client.response()
                    self.assertEqual(status, expected)
                    self.assertNotIn(b"location", fields)

    def test_http_redirect_bind_failure_stops_startup(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            result = subprocess.run([
                BINARY, *self.options, "--port", "0", "--http-redirect",
                "--http-redirect-port", str(occupied.getsockname()[1]),
                "--workers", "2", "--max-connections", "2",
            ], capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"AddressInUse", result.stderr)
            self.assertNotIn(b'"event":"listening"', result.stderr)

    def test_http_redirect_skips_embedded_handlers(self):
        with self.application("--http-redirect", "--http-redirect-port", "0") as server:
            port = self.redirect_port(server)
            with Client(port) as client:
                client.send(b"GET /origin HTTP/1.1\r\nHost: localhost\r\n\r\n")
                status, fields, body = client.response()
                self.assertEqual((status, body), (308, b""))
                self.assertEqual(fields[b"location"], f"https://localhost:{server.port}/origin".encode())
            with self.client(server) as client:
                client.send(b"GET /origin HTTP/1.1\r\nHost: localhost\r\n\r\n")
                self.assertEqual(json.loads(client.response()[2])["scheme"], "https")

    def test_verified_https_keepalive_pipeline_and_stream(self):
        with self.client() as client:
            self.assertEqual(client.socket.version(), "TLSv1.3")
            self.assertEqual(client.socket.selected_alpn_protocol(), "http/1.1")
            client.send(REQUEST * 40 + b"GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
            for _ in range(40):
                status, _, body = client.response()
                self.assertEqual((status, body), (200, b"ZHTPS\n"))
            self.assertEqual(client.response()[2], b"one\ntwo\nthree\n")
            client.send(REQUEST)
            self.assertEqual(client.response()[0], 200)

    def test_upload_spanning_records_and_continue(self):
        body = bytes(range(256)) * 250
        with self.client() as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: localhost\r\n"
                        b"Content-Length: 64000\r\nExpect: 100-continue\r\n\r\n")
            self.assertEqual(client.response()[0], 100)
            for offset in range(0, len(body), 7919):
                client.send(body[offset:offset + 7919])
            self.assertEqual(client.response()[2], body)
            client.send(REQUEST)
            self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_access_logs_include_client_ip_over_tls(self):
        with Running(*self.options) as server:
            with self.client(server) as client:
                client.send(REQUEST * 4)
                for _ in range(4):
                    self.assertEqual(client.response()[0], 200)
                records = []
                deadline = time.monotonic() + 3
                while len(records) < 4 and time.monotonic() < deadline:
                    records = [e for e in server.events if e["event"] == "request_complete"]
                    time.sleep(.01)
                self.assertEqual(len(records), 4)
                self.assertEqual([e.get("client_ip") for e in records], ["127.0.0.1"] * 4)

    def test_pipeline_batches_across_tls_records(self):
        with Running(*self.options, "--max-connections", "1024", "--max-active", "1024") as server:
            with FragmentedClient(server.port, self.context) as client:
                for _ in range(40):
                    client.ssl.write(REQUEST)
                client.flush()
                for _ in range(40):
                    status, _, body = client.response()
                    self.assertEqual((status, body), (200, b"ZHTPS\n"))
                counters = self.metrics(server)["counters"]
                self.assertGreater(counters["responses_batched_total"], 0)
                self.assertGreater(counters["responses_batched_total"], counters["response_batches_total"])

    def test_partial_next_record_does_not_hold_ready_responses(self):
        with FragmentedClient(self.server.port, self.context) as client:
            client.ssl.write(REQUEST)
            client.ssl.write(REQUEST)
            ready = client.outgoing.read()
            client.ssl.write(REQUEST)
            partial = client.outgoing.read()
            client.raw.sendall(ready + partial[:7])
            for _ in range(2):
                self.assertEqual(client.response()[2], b"ZHTPS\n")
            client.raw.sendall(partial[7:])
            self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_coalesced_records_preserve_body_and_following_request(self):
        body = bytes(range(251)) * 139
        with FragmentedClient(self.server.port, self.context) as client:
            client.ssl.write(REQUEST)
            client.ssl.write(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: "
                             + str(len(body)).encode() + b"\r\n\r\n")
            for offset in range(0, len(body), 997):
                client.ssl.write(body[offset:offset + 997])
            client.ssl.write(REQUEST)
            client.flush()
            self.assertEqual(client.response()[2], b"ZHTPS\n")
            self.assertEqual(client.response()[2], body)
            self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_coalesced_records_before_close_notify_are_delivered(self):
        with FragmentedClient(self.server.port, self.context) as client:
            for _ in range(3):
                client.ssl.write(REQUEST)
            with self.assertRaises(ssl.SSLWantReadError):
                client.ssl.unwrap()
            client.flush()
            for _ in range(3):
                self.assertEqual(client.response()[2], b"ZHTPS\n")
            with self.assertRaises(ssl.SSLZeroReturnError):
                client.recv(1)

    def test_corrupt_record_after_valid_record_never_dispatches_its_request(self):
        with Running(*self.options) as server:
            with FragmentedClient(server.port, self.context) as client:
                client.ssl.write(REQUEST)
                valid = client.outgoing.read()
                client.ssl.write(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nbad")
                corrupt = bytearray(client.outgoing.read())
                corrupt[-1] ^= 1
                client.raw.sendall(valid + corrupt)
                # The authenticated first response may precede the fatal alert.
                try:
                    self.assertEqual(client.response()[2], b"ZHTPS\n")
                except ssl.SSLError:
                    pass
                else:
                    with self.assertRaises(ssl.SSLError):
                        client.response()
            counters = self.metrics(server)["counters"]
            self.assertEqual(counters["tls_errors_total"], 1)
            self.assertLessEqual(counters["requests_total"], 2)

    def test_fragmented_handshake_and_records(self):
        with FragmentedClient(self.server.port, self.context) as client:
            for fragment in (b"GET / HTTP/1.1\r\n", b"Host: localhost\r\n", b"\r\n"):
                client.send(fragment)
            self.assertEqual(client.response()[2], b"ZHTPS\n")
            client.send(REQUEST * 3)
            for _ in range(3):
                self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_corrupt_record_never_reaches_http(self):
        with Running(*self.options) as server:
            with FragmentedClient(server.port, self.context) as client:
                client.ssl.write(REQUEST)
                ciphertext = bytearray(client.outgoing.read())
                ciphertext[-1] ^= 1
                client.raw.sendall(ciphertext)
                with self.assertRaises(ssl.SSLError):
                    client.response()
            metrics = self.metrics(server)["counters"]
            self.assertEqual(metrics["tls_errors_total"], 1)
            # The admin metrics request is the only HTTP request dispatched.
            self.assertEqual(metrics["requests_total"], 1)

    def test_plaintext_on_tls_port_is_not_dispatched(self):
        with Client(self.server.port) as client:
            client.send(REQUEST)
            try:
                reply = client.socket.recv(1024)
            except ConnectionResetError:
                reply = b""
            self.assertNotIn(b"HTTP/1.1", reply)
        with self.client() as client:
            client.send(REQUEST)
            self.assertEqual(client.response()[0], 200)

    def test_shutdown_finishes_upload_and_sends_close_notify(self):
        from shutdown import begin_shutdown
        with Running(*self.options) as server, self.client(server) as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: localhost\r\n"
                        b"Content-Length: 4\r\nExpect: 100-continue\r\n\r\n")
            self.assertEqual(client.response()[0], 100)
            begin_shutdown(server)
            client.send(b"body")
            status, fields, body = client.response()
            self.assertEqual((status, body), (200, b"body"))
            self.assertEqual(fields[b"connection"], b"close")
            self.assertEqual(client.socket.recv(1), b"")

    def test_shutdown_bounds_unfinished_handshakes(self):
        with Running(*self.options, "--tls-handshake-timeout-ms", "10000",
                     "--shutdown-timeout-ms", "100") as server:
            with socket.create_connection(("127.0.0.1", server.port), timeout=3) as stalled:
                stalled.sendall(b"\x16\x03")
                server.process.terminate()
                self.assertEqual(server.process.wait(timeout=1), 0)

    def test_idle_shutdown_sends_close_notify(self):
        with Running(*self.options) as server, self.client(server) as client:
            client.send(REQUEST)
            self.assertEqual(client.response()[0], 200)
            server.process.terminate()
            self.assertEqual(client.socket.recv(1), b"")

    def test_slow_reader_preserves_full_response(self):
        body = bytes(range(256)) * 256
        with self.client() as client:
            client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            client.send(b"POST /echo HTTP/1.1\r\nHost: localhost\r\n"
                        b"Content-Length: 65536\r\n\r\n" + body)
            time.sleep(.05)
            self.assertEqual(client.response()[2], body)

    @contextlib.contextmanager
    def application(self, *options):
        if FIXTURE is None:
            self.skipTest("run zig build test-tls to include the embedded application fixture")
        previous = wire.BINARY
        wire.BINARY = FIXTURE
        try:
            with Running(*self.options, *options) as server:
                yield server
        finally:
            wire.BINARY = previous

    def test_embedded_handler_sees_https_origin(self):
        with self.application() as server, self.client(server) as client:
            client.send(b"GET /origin HTTP/1.0\r\n\r\n")
            result = json.loads(client.response()[2])
            self.assertEqual(result, {"scheme": "https", "authority": f"127.0.0.1:{server.port}"})

    def test_library_initialization_unwinds_all_allocator_failures(self):
        if FIXTURE is None:
            self.skipTest("run zig build test-tls to include the embedded application fixture")
        result = subprocess.run([FIXTURE, "--check-allocations", "--port", "0", *self.options],
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_http_redirect_initialization_unwinds_all_allocator_failures(self):
        if FIXTURE is None:
            self.skipTest("run zig build test-tls to include the embedded application fixture")
        result = subprocess.run([
            FIXTURE, "--check-allocations", "--port", "0", *self.options,
            "--http-redirect", "--http-redirect-port", "0",
        ], capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_large_response_survives_partial_sends_and_shutdown(self):
        with self.application("--write-timeout-ms", "10000", "--shutdown-timeout-ms", "10000") as server:
            with self.client(server) as client:
                client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
                client.send(b"GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n")
                time.sleep(.1)
                client.until(b"\r\n\r\n")
                server.process.terminate()
                self.assertEqual(client.take(8 * 1024 * 1024), b"0123456789abcdef" * (512 * 1024))
                self.assertEqual(client.socket.recv(1), b"")

    def test_write_deadline_reclaims_backpressured_tls_connection(self):
        with self.application("--write-timeout-ms", "100") as server:
            with self.client(server) as client:
                client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                client.send(b"GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n")
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    metrics = self.metrics(server)
                    if metrics["counters"]["write_timeouts_total"]:
                        break
                    time.sleep(.01)
                self.assertEqual(metrics["counters"]["write_timeouts_total"], 1)
                self.assertEqual(metrics["counters"]["requests_aborted_total"], 1)
                self.assertEqual(metrics["gauges"]["requests_active"], 0)

    def test_chunked_request_and_pipeline(self):
        with self.client() as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
                        b"3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n" + REQUEST)
            self.assertEqual(client.response()[2], b"abcde")
            self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_scheme_matches_transport(self):
        with self.client() as client:
            client.send(b"GET HTTPS://localhost/ HTTP/1.1\r\nHost: ignored\r\n\r\n")
            self.assertEqual(client.response()[0], 200)
            client.send(b"GET http://localhost/ HTTP/1.1\r\nHost: localhost\r\n"
                        b"Content-Length: 1\r\nExpect: 100-continue\r\n\r\n")
            self.assertEqual(client.response()[0], 421)
        with Client(self.server.admin_port) as client:
            client.send(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
            self.assertEqual(client.response()[0], 200)

    def test_only_tls13(self):
        context = ssl.create_default_context(cafile=str(self.cert))
        context.maximum_version = ssl.TLSVersion.TLSv1_2
        with self.assertRaises(ssl.SSLError):
            with self.client(context=context):
                pass

    def test_no_alpn_supported_and_unknown_protocol_rejected(self):
        context = ssl.create_default_context(cafile=str(self.cert))
        with self.client(context=context) as client:
            self.assertIsNone(client.socket.selected_alpn_protocol())
            client.send(REQUEST)
            self.assertEqual(client.response()[0], 200)
        context.set_alpn_protocols(["unsupported"])
        with self.assertRaises(ssl.SSLError):
            with self.client(context=context):
                pass

    def test_cipher_allowlist(self):
        suites = ("TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384",
                  "TLS_CHACHA20_POLY1305_SHA256", "TLS_AES_128_CCM_SHA256")
        for suite in suites:
            with self.subTest(suite=suite):
                result = subprocess.run([
                    "openssl", "s_client", "-connect", f"127.0.0.1:{self.server.port}",
                    "-servername", "localhost", "-CAfile", str(self.cert), "-verify_return_error",
                    "-tls1_3", "-ciphersuites", suite, "-brief", "-ign_eof",
                ], input=REQUEST.replace(b"\r\n\r\n", b"\r\nConnection: close\r\n\r\n"),
                    capture_output=True, timeout=5)
                if suite.endswith("CCM_SHA256"):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn(b"200 OK", result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(suite.encode(), result.stderr)
                    self.assertIn(b"ZHTPS\n", result.stdout)

    def test_tls13_key_update(self):
        with subprocess.Popen([
            "openssl", "s_client", "-connect", f"127.0.0.1:{self.server.port}",
            "-servername", "localhost", "-CAfile", str(self.cert), "-verify_return_error",
            "-tls1_3", "-brief",
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0) as client:
            try:
                client.stdin.write(b"K\n")
                output = b""
                deadline = time.monotonic() + 3
                while b"KEYUPDATE" not in output:
                    remaining = deadline - time.monotonic()
                    self.assertGreater(remaining, 0, output)
                    self.assertTrue(select.select([client.stderr], [], [], remaining)[0], output)
                    part = os.read(client.stderr.fileno(), 4096)
                    self.assertTrue(part, output)
                    output += part
                client.stdin.write(REQUEST.replace(b"\r\n\r\n", b"\r\nConnection: close\r\n\r\n"))
                self.assertEqual(client.wait(timeout=3), 0)
                self.assertIn(b"ZHTPS\n", client.stdout.read())
            finally:
                if client.poll() is None:
                    client.kill()
                    client.wait()

    def test_rsa_certificate_and_weak_key_rejection(self):
        for bits in (2048, 1024):
            cert = self.path / f"rsa{bits}.pem"
            key = self.path / f"rsa{bits}.key"
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", f"rsa:{bits}", "-nodes",
                "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
                "-addext", "subjectAltName=DNS:localhost",
            ], check=True, capture_output=True)
            options = ("--tls-certificate", str(cert), "--tls-key", str(key))
            if bits == 1024:
                result = subprocess.run([BINARY, "--port", "0", *options], capture_output=True, timeout=3)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"InvalidCertificate", result.stderr)
            else:
                context = ssl.create_default_context(cafile=str(cert))
                with Running(*options) as server, self.client(server, context) as client:
                    client.send(REQUEST)
                    self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_close_notify(self):
        with self.client() as client:
            client.send(REQUEST.replace(b"\r\n\r\n", b"\r\nConnection: close\r\n\r\n"))
            self.assertEqual(client.response()[2], b"ZHTPS\n")
            # suppress_ragged_eofs=False distinguishes close_notify from bare TCP EOF.
            self.assertEqual(client.socket.recv(1), b"")
            raw = client.socket.unwrap()
            raw.close()
        with self.client() as client:
            client.send(REQUEST)
            self.assertEqual(client.response()[0], 200)
            raw = client.socket.unwrap()
            raw.close()

    def test_header_and_body_deadlines_send_encrypted_408(self):
        with Running(*self.options, "--header-timeout-ms", "100", "--body-timeout-ms", "100") as server:
            for request in (b"GET / HTTP/1.1\r\nHost:",
                            b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nx"):
                with self.subTest(request=request), self.client(server) as client:
                    client.send(request)
                    self.assertEqual(client.response()[0], 408)
                    self.assertEqual(client.socket.recv(1), b"")

    def test_stalled_handshake_does_not_block_other_clients(self):
        with Running(*self.options, "--tls-handshake-timeout-ms", "100") as server:
            with socket.create_connection(("127.0.0.1", server.port), timeout=3) as stalled:
                stalled.sendall(b"\x16\x03")
                with self.client(server) as client:
                    client.send(REQUEST)
                    self.assertEqual(client.response()[0], 200)
                self.assertEqual(stalled.recv(1), b"")
            self.assertGreaterEqual(self.metrics(server)["counters"]["tls_handshake_timeouts_total"], 1)

    def test_resumption_across_workers(self):
        with self.client() as client:
            client.send(REQUEST)
            self.assertEqual(client.response()[0], 200)
            session = client.socket.session
            self.assertTrue(session.has_ticket)
        for _ in range(8):
            with SecureClient(self.server.port, self.context, session=session) as client:
                client.send(REQUEST)
                self.assertEqual(client.response()[0], 200)
                self.assertTrue(client.socket.session_reused)

    def test_concurrent_clients_and_abrupt_disconnects(self):
        def exchange(index):
            with self.client() as client:
                if index % 3 == 0:
                    client.send(b"GET /")
                    return
                client.send(REQUEST * 3)
                for _ in range(3):
                    self.assertEqual(client.response()[2], b"ZHTPS\n")
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(exchange, range(80)))
        with self.client() as client:
            client.send(REQUEST)
            self.assertEqual(client.response()[0], 200)

    def test_invalid_credentials_fail_before_listening(self):
        for options, error in (
            (("--tls-certificate", str(self.cert)), b"InvalidOption"),
            (("--tls-key", str(self.key)), b"InvalidOption"),
            (("--tls-certificate", str(self.path / "missing"), "--tls-key", str(self.key)), b"InvalidCertificate"),
            (("--tls-certificate", str(self.cert), "--tls-key", str(self.cert)), b"InvalidPrivateKey"),
        ):
            with self.subTest(options=options):
                result = subprocess.run([BINARY, "--port", "0", *options],
                                        capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertNotIn(b'"event":"listening"', result.stderr)

    def test_certificate_chain_key_match_and_encrypted_key(self):
        def openssl(*arguments):
            subprocess.run(["openssl", *map(str, arguments)], check=True, capture_output=True)

        intermediate_key = self.path / "intermediate.key"
        intermediate_csr = self.path / "intermediate.csr"
        intermediate_cert = self.path / "intermediate.pem"
        intermediate_ext = self.path / "intermediate.ext"
        intermediate_ext.write_text("basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n")
        leaf_key = self.path / "leaf.key"
        leaf_csr = self.path / "leaf.csr"
        leaf_cert = self.path / "leaf.pem"
        leaf_ext = self.path / "leaf.ext"
        leaf_ext.write_text("basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:localhost\n"
                            "keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n")
        for key, csr, subject in ((intermediate_key, intermediate_csr, "/CN=Intermediate"),
                                  (leaf_key, leaf_csr, "/CN=localhost")):
            openssl("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-keyout", key, "-out", csr, "-subj", subject)
        openssl("x509", "-req", "-in", intermediate_csr, "-CA", self.cert, "-CAkey", self.key,
                "-set_serial", "2", "-days", "1", "-extfile", intermediate_ext, "-out", intermediate_cert)
        openssl("x509", "-req", "-in", leaf_csr, "-CA", intermediate_cert, "-CAkey", intermediate_key,
                "-set_serial", "3", "-days", "1", "-extfile", leaf_ext, "-out", leaf_cert)
        chain = self.path / "chain.pem"
        chain.write_bytes(leaf_cert.read_bytes() + intermediate_cert.read_bytes())
        with Running("--tls-certificate", str(chain), "--tls-key", str(leaf_key)) as server:
            with self.client(server) as client:
                client.send(REQUEST)
                self.assertEqual(client.response()[0], 200)
        with Running("--tls-certificate", str(leaf_cert), "--tls-key", str(leaf_key)) as server:
            with self.assertRaises(ssl.SSLCertVerificationError):
                with self.client(server):
                    pass
        encrypted = self.path / "encrypted.key"
        openssl("pkey", "-in", leaf_key, "-aes-256-cbc", "-passout", "pass:fixture", "-out", encrypted)
        for key in (self.key, encrypted):
            result = subprocess.run([
                BINARY, "--port", "0", "--tls-certificate", str(chain), "--tls-key", str(key),
            ], capture_output=True, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"InvalidPrivateKey", result.stderr)


if __name__ == "__main__":
    unittest.main()
