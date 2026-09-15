"""Exercise the generated NGINX gate against real upstream HTTP connections."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy"))
from ingress import Options, write_bundle


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class Origin(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.requests = 0
        self.peers = set()
        self.lock = threading.Lock()
        self.ready = threading.Condition(self.lock)
        self.release = threading.Event()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        with self.server.ready:
            self.server.requests += 1
            self.server.peers.add(self.client_address)
            self.server.ready.notify_all()
        if self.path == "/hold":
            self.server.release.wait(5)
        self.send_response(200)
        self.send_header("Content-Length", "6")
        self.end_headers()
        self.wfile.write(b"ZHTPS\n")

    def log_message(self, *args):
        pass


class IngressTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zhtps-ingress-")
        self.addCleanup(self.temporary.cleanup)
        self.origin = Origin()
        self.thread = threading.Thread(target=self.origin.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_origin)
        self.options = Options("127.0.0.1", free_port(), "127.0.0.1", self.origin.server_port,
                               "lo", 10, 0, 1, 1, 1, 1, access_log=True)
        self.proxy = None
        self.addCleanup(self.stop_proxy)

    def stop_origin(self):
        self.origin.release.set()
        self.origin.shutdown()
        self.origin.server_close()
        self.thread.join()

    def stop_proxy(self):
        if self.proxy:
            self.proxy.terminate()
            try:
                self.proxy.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proxy.kill()
                self.proxy.wait()
                self.fail("NGINX did not shut down")
            self.assertEqual(0, self.proxy.returncode)

    def start(self, **changes):
        self.options = replace(self.options, **changes)
        self.folder = Path(self.temporary.name)
        write_bundle(self.options, self.folder)
        self.proxy = subprocess.Popen([NGINX, "-p", str(self.folder) + "/", "-c", "nginx.conf",
                                       "-g", "daemon off;"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(self.proxy.stderr.close)
        deadline = time.monotonic() + 5
        while True:
            if self.proxy.poll() is not None:
                self.fail(self.proxy.stderr.read().decode())
            try:
                connection = socket.create_connection(("127.0.0.1", self.options.listen_port), .1)
                connection.close()
                break
            except OSError:
                if time.monotonic() >= deadline:
                    self.fail("NGINX did not listen")
                time.sleep(.01)

    def request(self, path="/"):
        connection = HTTPConnection("127.0.0.1", self.options.listen_port, timeout=3)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_rate_rejections_never_reach_origin_and_keep_client_alive(self):
        self.start()
        client = HTTPConnection("127.0.0.1", self.options.listen_port, timeout=3)
        self.addCleanup(client.close)
        results = []
        started = time.monotonic()
        peer = None
        for _ in range(30):
            client.request("GET", "/")
            response = client.getresponse()
            body = response.read()
            self.assertFalse(response.will_close)
            if peer is None:
                peer = client.sock.getsockname()
            self.assertEqual(peer, client.sock.getsockname())
            if response.status == 200:
                self.assertEqual(b"ZHTPS\n", body)
            else:
                self.assertEqual(503, response.status)
            results.append(response.status)
        elapsed = time.monotonic() - started
        admitted = results.count(200)
        self.assertGreater(admitted, 0)
        self.assertGreater(results.count(503), 0)
        self.assertLessEqual(admitted, int(elapsed * 10) + 2)
        self.assertEqual(admitted, self.origin.requests)
        time.sleep(.12)
        self.assertEqual((200, b"ZHTPS\n"), self.request())

    def test_upstream_connection_reuse_absorbs_frontend_churn(self):
        self.start(request_rate=10000, request_burst=100)
        for _ in range(20):
            self.assertEqual((200, b"ZHTPS\n"), self.request())
        self.assertEqual(20, self.origin.requests)
        self.assertEqual(1, len(self.origin.peers))

    def test_request_rate_is_global_across_source_ips_and_proxy_workers(self):
        self.start(proxy_workers=2)
        statuses = []
        started = time.monotonic()
        for index in range(50):
            client = HTTPConnection("127.0.0.1", self.options.listen_port, timeout=3,
                                    source_address=(f"127.0.0.{index + 2}", 0))
            try:
                client.request("GET", "/")
                response = client.getresponse()
                statuses.append(response.status)
                response.read()
            finally:
                client.close()
        admitted = statuses.count(200)
        self.assertGreater(admitted, 0)
        self.assertLessEqual(admitted, int((time.monotonic() - started) * 10) + 2)
        self.assertEqual(admitted, self.origin.requests)
        self.assertEqual(50, admitted + statuses.count(503))

    def test_concurrency_limit_rejects_without_waiting_for_busy_origin(self):
        self.start(origin_slots=4, request_rate=10000, request_burst=100)
        with ThreadPoolExecutor(max_workers=2) as pool:
            held = [pool.submit(self.request, "/hold") for _ in range(2)]
            try:
                with self.origin.ready:
                    self.assertTrue(self.origin.ready.wait_for(lambda: self.origin.requests == 2, 3))
                started = time.monotonic()
                self.assertEqual(503, self.request()[0])
                self.assertLess(time.monotonic() - started, 1)
                self.assertEqual(2, self.origin.requests)
            finally:
                self.origin.release.set()
            for result in held:
                self.assertEqual((200, b"ZHTPS\n"), result.result())
        self.assertEqual((200, b"ZHTPS\n"), self.request())

    def test_configuration_scales_counts_but_preserves_explicit_rates(self):
        self.start(origin_workers=4, proxy_workers=2)
        limits = json.loads((self.folder / "limits.json").read_text())
        self.assertEqual(1536, limits["origin_connection_budget"])
        self.assertEqual(1472, limits["origin_active_budget"])
        self.assertEqual(10, limits["request_rate"])
        self.assertEqual(1, limits["connection_rate"])
        self.assertEqual((200, b"ZHTPS\n"), self.request())

    def test_explicit_origin_active_budget_bounds_forwarded_concurrency(self):
        self.start(origin_active_per_worker=1, request_rate=10000, request_burst=100)
        with ThreadPoolExecutor(max_workers=1) as pool:
            held = pool.submit(self.request, "/hold")
            try:
                with self.origin.ready:
                    self.assertTrue(self.origin.ready.wait_for(lambda: self.origin.requests == 1, 3))
                self.assertEqual(503, self.request()[0])
                self.assertEqual(1, self.origin.requests)
            finally:
                self.origin.release.set()
            self.assertEqual((200, b"ZHTPS\n"), held.result())

    def test_invalid_budget_or_injection_is_rejected_before_writing(self):
        for changes in ({"request_rate": 0}, {"origin_slots": 1}, {"interface": "lo; flush ruleset"},
                        {"table": "bad name"}, {"origin_address": "127.0.0.1;"},
                        {"listen_address": "0.0.0.0"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                write_bundle(replace(self.options, **changes), Path(self.temporary.name) / "invalid")
        self.assertFalse((Path(self.temporary.name) / "invalid").exists())

    def test_cli_uses_effective_origin_snapshot_and_rejects_conflicting_counts(self):
        folder = Path(self.temporary.name)
        snapshot = {"workers": 1, "max_connections": 64, "admission": {"max_active": 4}}
        source = folder / "origin.json"
        source.write_text(json.dumps(snapshot))
        command = [sys.executable, str(ROOT / "deploy/ingress.py"), "--origin-config", str(source),
                   "--listen-address", "127.0.0.1", "--listen-port", "8081",
                   "--origin-address", "127.0.0.1", "--origin-port", "8080", "--interface", "lo",
                   "--request-rate", "10", "--request-burst", "1", "--connection-rate", "2",
                   "--connection-burst", "1", "--reset-rate", "1", "--reset-burst", "1"]
        result = subprocess.run([*command, "--output", str(folder / "bundle")], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        limits = json.loads((folder / "bundle/limits.json").read_text())
        self.assertEqual(48, limits["origin_connection_budget"])
        self.assertEqual(4, limits["origin_active_budget"])
        self.assertEqual(snapshot, json.loads((folder / "bundle/origin-config.json").read_text()))
        result = subprocess.run([*command, "--origin-slots", "512", "--output", str(folder / "conflict")],
                                capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("conflicts", result.stderr)
        self.assertFalse((folder / "conflict").exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--nginx", default=shutil.which("nginx"))
    options, remaining = parser.parse_known_args()
    if not options.nginx:
        parser.error("provide --nginx PATH to an NGINX 1.30+ executable")
    NGINX = str(Path(options.nginx).resolve())
    unittest.main(argv=[sys.argv[0], *remaining])
