"""Direct ingestion against a local collector, using the real server executable."""

import concurrent.futures
import contextlib
import http.server
import json
import os
import signal
import socket
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from wire import BINARY, Client


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.02)
    raise AssertionError("condition did not become true before deadline")


class Collector:
    def __init__(self, status=204, stalled=False, tls=None):
        self.status = status
        self.stalled = stalled
        self.posts = []
        self.release = threading.Event()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self):
                payload = self.rfile.read(int(self.headers["Content-Length"]))
                owner.posts.append((self.path, {k.lower(): v for k, v in self.headers.items()}, payload, owner.status))
                if owner.stalled:
                    owner.release.wait(10)
                try:
                    self.send_response(owner.status)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        if tls:
            self.server.socket = tls.wrap_socket(self.server.socket, server_side=True)
        self.url = f"{'https' if tls else 'http'}://localhost:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def records(self, accepted=False):
        return [json.loads(line) for _, _, payload, status in list(self.posts)
                if not accepted or 200 <= status < 300
                for line in payload.splitlines()]

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class DirectServer:
    def __init__(self, url, *options, command_prefix=()):
        self.port = free_port()
        self.admin_port = free_port()
        self.stderr_file = tempfile.TemporaryFile()
        self.wrapper_info = tempfile.TemporaryFile() if command_prefix else None
        if self.wrapper_info:
            command_prefix = [*command_prefix, "--info-fd", str(self.wrapper_info.fileno())]
        self.process = subprocess.Popen([
            *command_prefix, BINARY, "--port", str(self.port), "--admin-port", str(self.admin_port),
            "--workers", "2", "--worker-cpus", "inherit", "--max-connections", "64",
            "--large-buffer-bytes", "1048576", "--http2-worker-streams", "64",
            "--http2-memory-bytes", "1048576", "--victoria-logs", url, *options,
        ], stdout=subprocess.DEVNULL, stderr=self.stderr_file,
            pass_fds=(self.wrapper_info.fileno(),) if self.wrapper_info else ())
        try:
            wait_for(self.ready)
        except BaseException:
            try:
                self.close()
            finally:
                self.stderr_file.close()
                if self.wrapper_info:
                    self.wrapper_info.close()
            raise

    def ready(self):
        if self.process.poll() is not None:
            raise AssertionError((self.process.returncode, self.stderr()))
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=.1):
                return True
        except OSError:
            return False

    def stderr(self):
        self.stderr_file.seek(0)
        return self.stderr_file.read()

    def metrics(self):
        with Client(self.admin_port) as client:
            client.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
            status, _, body = client.response()
            assert status == 200
            return json.loads(body)["counters"]

    def request(self, agent="victoria-test"):
        with Client(self.port) as client:
            client.send(f"GET / HTTP/1.1\r\nHost: local\r\nUser-Agent: {agent}\r\n\r\n".encode())
            assert client.response()[0] == 200

    def close(self):
        if self.process.poll() is None:
            if self.wrapper_info:
                self.wrapper_info.seek(0)
                info = json.load(self.wrapper_info)
                os.kill(info["child-pid"], signal.SIGTERM)
            else:
                self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError("log delivery prevented bounded shutdown")
        assert self.process.returncode == 0, (self.process.returncode, self.stderr())
        assert self.stderr() == b"", self.stderr()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        try:
            self.close()
        finally:
            self.stderr_file.close()
            if self.wrapper_info:
                self.wrapper_info.close()


class VictoriaLogsTests(unittest.TestCase):
    def test_flags_reject_conflicts_in_both_orders_and_invalid_origins(self):
        for flag in ("--no-access-log", "--no-access-logs"):
            for args in ([flag, "--victoria-logs", "http://localhost:9428"],
                         ["--victoria-logs", "http://localhost:9428", flag]):
                result = subprocess.run([BINARY, *args], capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertIn(b"mutually exclusive", result.stderr)
        for url in ("localhost:9428", "ftp://localhost", "http://", "http://host:0",
                    "http://host:99999", "http://host/insert/jsonline", "http://host?x=y",
                    "http://host#fragment", "http://user:secret@host", "http://bad host",
                    "http://host\r\nInjected: header", "http://[::1]junk",
                    "http://[invalid]", "http://" + "a" * 256, "http://host%20name"):
            with self.subTest(url=url):
                result = subprocess.run([BINARY, "--victoria-logs", url], capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(b"InvalidVictoriaLogsUrl", result.stderr)
        result = subprocess.run([BINARY, "--victoria-logs"], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"MissingArgument", result.stderr)

    def test_posts_original_events_in_batches_with_stable_stream_fields(self):
        begin = time.time_ns()
        agent = 'victoria-test "quoted" \\ utf8-é'
        with Collector() as collector:
            with DirectServer(collector.url + "/") as server:
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    list(pool.map(lambda _: server.request(agent), range(80)))
                wait_for(lambda: len([r for r in collector.records()
                                     if r.get("user_agent") == agent]) == 80)
                self.assertEqual(server.stderr(), b"")
                self.assertEqual(server.metrics()["log_write_errors_total"], 0)
                expected_instance = f"[127.0.0.1]:{server.port}"
            rows = collector.records()
            self.assertEqual(len([r for r in rows if r.get("user_agent") == agent]), 80)
            self.assertEqual({r["worker"] for r in rows if r["event"] == "shutdown_started"}, {0, 1})
            self.assertTrue(any(r["event"] == "listening" for r in rows))
            self.assertTrue(any(r["event"] == "resources_resolved" for r in rows))
            self.assertTrue(any(len(p[2].splitlines()) > 1 for p in collector.posts))
            end = time.time_ns()
            for path, headers, payload, _ in collector.posts:
                target = urlsplit(path)
                self.assertEqual(target.path, "/insert/jsonline")
                self.assertEqual(parse_qs(target.query), {
                    "_msg_field": ["event"], "_time_field": ["timestamp_ns"],
                    "_stream_fields": ["app,host,instance"],
                })
                self.assertEqual(headers["content-type"], "application/stream+json")
                self.assertTrue(payload.endswith(b"\n"))
            for row in rows:
                self.assertTrue(row["event"])
                self.assertLessEqual(begin, row["timestamp_ns"])
                self.assertLessEqual(row["timestamp_ns"], end)
                self.assertEqual(row["app"], "zhtps")
                self.assertEqual(row["host"], socket.gethostname())
                self.assertEqual(row["instance"], expected_instance)

    def test_http_errors_drop_batches_and_recover_without_stderr(self):
        with Collector(status=503) as collector, DirectServer(collector.url) as server:
            server.request()
            wait_for(lambda: server.metrics()["log_write_errors_total"] > 0)
            self.assertGreater(server.metrics()["log_dropped_total"], 0)
            collector.status = 204
            server.request("after-recovery")
            wait_for(lambda: any(r.get("user_agent") == "after-recovery"
                                 for r in collector.records(accepted=True)))

    def test_stalled_collector_preserves_service_and_shutdown_deadline(self):
        with Collector(stalled=True) as collector:
            with DirectServer(collector.url, "--log-slots", "8") as server:
                wait_for(lambda: collector.posts)
                begin = time.monotonic()
                for _ in range(100):
                    server.request()
                self.assertLess(time.monotonic() - begin, 2)
                wait_for(lambda: server.metrics()["log_write_errors_total"] > 0)
                self.assertGreater(server.metrics()["log_dropped_total"], 0)
                begin = time.monotonic()
                server.close()
                self.assertLess(time.monotonic() - begin, 3)

    def test_startup_error_uses_configured_collector(self):
        with Collector() as collector, socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            result = subprocess.run([
                BINARY, "--port", str(occupied.getsockname()[1]), "--workers", "1",
                "--max-connections", "2", "--victoria-logs", collector.url,
            ], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, b"")
            rows = collector.records()
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["event"], "startup_or_runtime_error")
            self.assertEqual(rows[0]["reason"], "AddressInUse")

    @contextlib.contextmanager
    def certificate(self):
        with tempfile.TemporaryDirectory(prefix="victoria-tls-") as directory:
            cert, key = (str(Path(directory) / name) for name in ("cert.pem", "key.pem"))
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost",
                "-addext", "subjectAltName=DNS:localhost",
            ], check=True, capture_output=True)
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(cert, key)
            yield cert, tls

    def test_https_rejects_untrusted_certificate_without_stderr(self):
        with self.certificate() as (_, tls):
            with Collector(tls=tls) as collector, DirectServer(collector.url) as server:
                server.request()
                wait_for(lambda: server.metrics()["log_write_errors_total"] > 0)
                self.assertEqual(collector.posts, [])

    def test_https_posts_with_trusted_certificate_and_checks_hostname(self):
        if not shutil.which("bwrap"):
            self.skipTest("bwrap is needed to isolate the test CA trust store")
        prefix = ["bwrap", "--ro-bind", "/", "/", "--unshare-user", "--uid", "0", "--gid", "0"]
        available = subprocess.run([*prefix, "true"], capture_output=True)
        if available.returncode:
            self.skipTest("user mount namespaces are unavailable")
        with self.certificate() as (cert, tls), Collector(tls=tls) as collector:
            trust_store = str(Path("/etc/ssl/certs/ca-certificates.crt").resolve())
            if not Path(trust_store).is_file():
                self.skipTest("system trust bundle path is unavailable")
            command = [*prefix, "--ro-bind", cert, trust_store]
            with DirectServer(collector.url, command_prefix=command) as server:
                server.request("trusted-https")
                wait_for(lambda: any(r.get("user_agent") == "trusted-https"
                                     for r in collector.records()))
                self.assertEqual(server.metrics()["log_write_errors_total"], 0)
            before = len(collector.posts)
            with DirectServer(collector.url.replace("localhost", "127.0.0.1"),
                              command_prefix=command) as server:
                server.request()
                wait_for(lambda: server.metrics()["log_write_errors_total"] > 0)
                self.assertEqual(len(collector.posts), before)


if __name__ == "__main__":
    unittest.main()
