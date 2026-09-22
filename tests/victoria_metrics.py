"""Metric push checks against a local collector using real server processes."""

import json
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import wire
import victoria_logs
from wire import BINARY, Client, Running
from victoria_logs import Collector, DirectServer, free_port, wait_for

APPLICATION = sys.argv.pop(1)
certificate = victoria_logs.VictoriaLogsTests.certificate


def request(port, path="/"):
    with Client(port) as client:
        client.send(f"GET {path} HTTP/1.1\r\nHost: local\r\n\r\n".encode())
        status, _, body = client.response()
        assert status == 200
        return body


def counters(server):
    return json.loads(request(server.admin_port, "/debug/metrics"))["counters"]


def samples(payload):
    return {name: float(value) for line in payload.decode().splitlines()
            if not line.startswith("#") for name, value in [line.split()]}


class VictoriaMetricsTests(unittest.TestCase):
    def test_flag_validation_and_help(self):
        for url in ("localhost:8428", "ftp://host", "http://", "http://host:0",
                    "http://host:99999", "http://host/path", "http://host?x=y",
                    "http://host#fragment", "http://user:secret@host", "http://bad host",
                    "http://host\r\nInjected: header", "http://[::1]junk",
                    "http://[invalid]", "http://" + "a" * 256, "http://host%20name"):
            with self.subTest(url=url):
                result = subprocess.run([BINARY, "--victoria-metrics", url],
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(b"InvalidVictoriaMetricsUrl", result.stderr)
        result = subprocess.run([BINARY, "--victoria-metrics"], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"MissingArgument", result.stderr)
        result = subprocess.run([BINARY, "--help"], capture_output=True, timeout=5)
        self.assertIn(b"--victoria-metrics URL", result.stdout)

    def test_periodic_aggregate_and_final_snapshot_reuse_connection(self):
        begin_ms = int(time.time() * 1000)
        with Collector() as collector:
            with Running("--victoria-metrics", collector.url + "/", "--workers", "2",
                         "--worker-cpus", "inherit", "--no-access-logs") as server:
                wait_for(lambda: collector.posts)
                for _ in range(40):
                    request(server.port)
                wait_for(lambda: len(collector.posts) >= 2, timeout=14)
                snapshot = samples(collector.posts[-1][2])
                self.assertGreaterEqual(snapshot["zhtps_requests_completed_total"], 40)
                self.assertEqual(snapshot["zhtps_request_duration_seconds_count"], 40)
                self.assertEqual(snapshot['zhtps_request_duration_seconds_bucket{le="+Inf"}'], 40)
                self.assertGreater(snapshot["zhtps_request_duration_seconds_sum"], 0)
                exposed = samples(request(server.admin_port, "/metrics"))
                self.assertEqual(snapshot.keys(), exposed.keys())
                self.assertEqual(counters(server)["metrics_push_errors_total"], 0)
                self.assertGreaterEqual(counters(server)["metrics_pushes_total"], 2)
                periodic_count = len(collector.posts)
                request(server.port)
            self.assertEqual(len(collector.posts), periodic_count + 1)
            final = samples(collector.posts[-1][2])
            self.assertEqual(final["zhtps_request_duration_seconds_count"], 41)
            self.assertEqual(final["zhtps_draining"], 1)
            self.assertEqual(len(set(collector.peers)), 1)
            end_ms = int(time.time() * 1000)
            timestamps = []
            for path, headers, payload, status in collector.posts:
                target = urlsplit(path)
                query = parse_qs(target.query)
                self.assertEqual(target.path, "/api/v1/import/prometheus")
                self.assertEqual(set(query["extra_label"]), {
                    "job=zhtps", f"host={socket.gethostname()}",
                    f"instance=[127.0.0.1]:{server.port}",
                })
                self.assertEqual(headers["content-type"], "text/plain; version=0.0.4; charset=utf-8")
                self.assertEqual(status, 204)
                self.assertTrue(payload.endswith(b"\n"))
                timestamp = int(query["timestamp"][0])
                self.assertLessEqual(begin_ms, timestamp)
                self.assertLessEqual(timestamp, end_ms)
                timestamps.append(timestamp)
            self.assertGreaterEqual(timestamps[1] - timestamps[0], 10_000)

    def test_no_content_without_length_reuses_connection(self):
        # Real VictoriaMetrics omits Content-Length on its bodyless 204 reply.
        with Collector(content_length=False) as collector:
            with Running("--victoria-metrics", collector.url, "--no-access-log") as server:
                wait_for(lambda: counters(server)["metrics_pushes_total"] > 0)
                request(server.port)
                wait_for(lambda: counters(server)["metrics_pushes_total"] >= 2, timeout=14)
                self.assertEqual(counters(server)["metrics_push_errors_total"], 0)
            self.assertGreaterEqual(len(collector.posts), 3)
            self.assertEqual(len(set(collector.peers)), 1)
            self.assertEqual(samples(collector.posts[-1][2])["zhtps_request_duration_seconds_count"], 1)

    def test_unframed_response_body_deadline_preserves_service(self):
        # Cancellation can fail at the transport layer without an HTTP body error.
        with Collector(status=200, content_length=False, stalled_body=True) as collector:
            with Running("--victoria-metrics", collector.url, "--no-access-log") as server:
                wait_for(lambda: counters(server)["metrics_push_errors_total"] > 0)
                for _ in range(10):
                    request(server.port)
                begin = time.monotonic()
            self.assertLess(time.monotonic() - begin, 3.5)

    def test_custom_application_metrics_merge_workers(self):
        with Collector() as collector, patch.object(wire, "BINARY", APPLICATION):
            with Running("--victoria-metrics", collector.url, "--workers", "2",
                         "--worker-cpus", "inherit", "--no-access-log") as server:
                for _ in range(80):
                    request(server.port)
            final = samples(collector.posts[-1][2])
            self.assertEqual(final["example_greetings_total"], 80)
            self.assertEqual(final["example_workers_seen"], 2)
            self.assertEqual(final['example_greeting_duration_seconds_bucket{le="0.00001"}'], 0)
            self.assertEqual(final['example_greeting_duration_seconds_bucket{le="0.000025"}'], 80)
            self.assertEqual(final['example_greeting_duration_seconds_bucket{le="+Inf"}'], 80)
            self.assertEqual(final["example_greeting_duration_seconds_count"], 80)
            self.assertAlmostEqual(final["example_greeting_duration_seconds_sum"], .002)

    def test_collector_errors_recover_on_next_interval(self):
        with Collector(status=503) as collector:
            with Running("--victoria-metrics", collector.url, "--no-access-log") as server:
                wait_for(lambda: counters(server)["metrics_push_errors_total"] > 0)
                request(server.port)
                collector.status = 204
                wait_for(lambda: counters(server)["metrics_pushes_total"] > 0, timeout=14)
                self.assertEqual(counters(server)["metrics_push_errors_total"], 1)
                self.assertEqual([post[3] for post in collector.posts], [503, 204])

    def test_stalled_collector_preserves_service_and_bounded_shutdown(self):
        with Collector(stalled=True) as collector:
            with Running("--victoria-metrics", collector.url, "--no-access-log") as server:
                wait_for(lambda: collector.posts)
                begin = time.monotonic()
                for _ in range(30):
                    request(server.port)
                self.assertLess(time.monotonic() - begin, 1.5)
                begin = time.monotonic()
            self.assertLess(time.monotonic() - begin, 3.5)

    def test_connection_refused_does_not_stop_serving(self):
        # Keep the port reserved without listening so connect reliably fails.
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            url = f"http://127.0.0.1:{reserved.getsockname()[1]}"
            with Running("--victoria-metrics", url, "--no-access-log") as server:
                wait_for(lambda: counters(server)["metrics_push_errors_total"] > 0)
                request(server.port)

    def test_push_works_without_admin_listener(self):
        port = free_port()
        with Collector() as collector, tempfile.TemporaryFile() as logs:
            process = subprocess.Popen([
                BINARY, "--port", str(port), "--admin-connections", "0",
                "--workers", "1", "--max-connections", "8", "--no-access-log",
                "--victoria-metrics", collector.url,
            ], stdout=subprocess.DEVNULL, stderr=logs)
            try:
                wait_for(lambda: collector.posts)
                request(port)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise
            self.assertEqual(process.returncode, 0)
            self.assertEqual(samples(collector.posts[-1][2])["zhtps_request_duration_seconds_count"], 1)

    def test_logs_and_metrics_can_share_a_collector_origin(self):
        with Collector() as collector:
            with DirectServer(collector.url, "--victoria-metrics", collector.url) as server:
                server.request()
            paths = [urlsplit(post[0]).path for post in collector.posts]
            self.assertIn("/insert/jsonline", paths)
            self.assertIn("/api/v1/import/prometheus", paths)

    def test_https_rejects_untrusted_certificate(self):
        with certificate(self) as (_, tls), Collector(tls=tls) as collector:
            with Running("--victoria-metrics", collector.url, "--no-access-log") as server:
                wait_for(lambda: counters(server)["metrics_push_errors_total"] > 0)
                request(server.port)
            self.assertEqual(collector.posts, [])

    def test_https_trust_and_hostname_verification(self):
        if not shutil.which("bwrap"):
            self.skipTest("bwrap is needed to isolate the test CA trust store")
        prefix = ["bwrap", "--ro-bind", "/", "/", "--unshare-user", "--uid", "0", "--gid", "0"]
        if subprocess.run([*prefix, "true"], capture_output=True).returncode:
            self.skipTest("user mount namespaces are unavailable")
        trust_store = str(Path("/etc/ssl/certs/ca-certificates.crt").resolve())
        if not Path(trust_store).is_file():
            self.skipTest("system trust bundle path is unavailable")
        with certificate(self) as (cert, tls), Collector(tls=tls) as collector, Collector() as logs:
            command = [*prefix, "--ro-bind", cert, trust_store]
            with DirectServer(logs.url, "--victoria-metrics", collector.url,
                              command_prefix=command) as server:
                wait_for(lambda: server.metrics()["metrics_pushes_total"] > 0)
                self.assertEqual(server.metrics()["metrics_push_errors_total"], 0)
            before = len(collector.posts)
            with DirectServer(logs.url, "--victoria-metrics",
                              collector.url.replace("localhost", "127.0.0.1"),
                              command_prefix=command) as server:
                wait_for(lambda: server.metrics()["metrics_push_errors_total"] > 0)
            self.assertEqual(len(collector.posts), before)


if __name__ == "__main__":
    unittest.main()
