"""Raw TCP checks against the actual io_uring executable; Python stdlib only."""

import contextlib
import concurrent.futures
import json
import os
import queue
import resource
import socket
import subprocess
import sys
import threading
import time
import unittest


BINARY = sys.argv.pop(1) if len(sys.argv) > 1 else "zig-out/bin/zhtps"


class Running:
    def __init__(self, *options, nofile=None, close_logs=False, automatic=False, affinity=None):
        def limits():
            if nofile is not None:
                resource.setrlimit(resource.RLIMIT_NOFILE, (nofile, nofile))
            if affinity is not None:
                os.sched_setaffinity(0, affinity)
        # Existing wire specifications rely on fixed per-worker capacities.
        # Automatic sizing has separate tests that launch without these overrides.
        defaults = [] if automatic else [
            "--workers", "1", "--max-connections", "256",
            "--large-buffer-bytes", "67108864", "--http2-worker-streams", "256",
            "--http2-memory-bytes", "67108864",
        ]
        self.process = subprocess.Popen(
            [BINARY, "--port", "0", "--admin-port", "0", *defaults, *options],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            preexec_fn=limits if nofile is not None or affinity is not None else None,
        )
        self.events = []
        self.close_logs = close_logs
        self.lines = []
        self.ready = queue.Queue()
        self.reader_gate = threading.Event()
        self.reader_gate.set()
        self.reader = threading.Thread(target=self.read_logs, daemon=True)
        self.reader.start()
        ports = {}
        try:
            while len(ports) < 2:
                event = self.ready.get(timeout=5)
                if event.get("event") == "startup_or_runtime_error":
                    raise RuntimeError(event)
                if event.get("event") in ("listening", "admin_listening"):
                    ports[event["event"]] = event["port"]
        except BaseException:
            self.close()
            raise
        self.port = ports["listening"]
        self.admin_port = ports["admin_listening"]

    def read_logs(self):
        listeners = 0
        for line in self.process.stderr:
            self.reader_gate.wait()
            self.lines.append(line)
            try:
                event = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            self.events.append(event)
            self.ready.put(event)
            if event.get("event") in ("listening", "admin_listening"):
                listeners += 1
                if self.close_logs and listeners == 2:
                    self.process.stderr.close()
                    return

    def close(self):
        self.reader_gate.set()
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError("server did not shut down within its deadline")
        self.reader.join(timeout=1)
        self.process.stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        if exc[0] is None:
            assert self.process.returncode == 0, b"".join(self.lines).decode(errors="replace")


class Client:
    def __init__(self, port):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.buffer = b""

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.socket.close()

    def send(self, data):
        self.socket.sendall(data)

    def until(self, delimiter):
        while delimiter not in self.buffer:
            part = self.socket.recv(65536)
            if not part:
                raise EOFError(self.buffer)
            self.buffer += part
        result, self.buffer = self.buffer.split(delimiter, 1)
        return result

    def take(self, count):
        while len(self.buffer) < count:
            part = self.socket.recv(65536)
            if not part:
                raise EOFError(self.buffer)
            self.buffer += part
        result, self.buffer = self.buffer[:count], self.buffer[count:]
        return result

    def response(self, head=False):
        lines = self.until(b"\r\n\r\n").split(b"\r\n")
        status = int(lines[0].split(b" ")[1])
        fields = {}
        for line in lines[1:]:
            name, value = line.split(b":", 1)
            name = name.lower()
            if name in fields:
                raise AssertionError(f"duplicate response header {name!r}")
            fields[name] = value.strip()
        if head or status < 200 or status in (204, 304):
            return status, fields, b""
        if fields.get(b"transfer-encoding") == b"chunked":
            body = bytearray()
            while True:
                size = int(self.until(b"\r\n"), 16)
                if size == 0:
                    assert self.until(b"\r\n") == b""
                    return status, fields, bytes(body)
                body.extend(self.take(size))
                assert self.take(2) == b"\r\n"
        return status, fields, self.take(int(fields[b"content-length"]))


class WireTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = Running("--verbose", "--header-timeout-ms", "500", "--body-timeout-ms", "500")

    @classmethod
    def tearDownClass(cls):
        cls.server.close()
        assert cls.server.process.returncode == 0, b"".join(cls.server.lines).decode(errors="replace")

    def exchange(self, request, head=False):
        with Client(self.server.port) as client:
            client.send(request)
            return client.response(head)

    def admin_json(self, server, path):
        with Client(server.admin_port) as admin:
            admin.send(f"GET {path} HTTP/1.1\r\nHost: local\r\n\r\n".encode())
            status, _, body = admin.response()
            self.assertEqual(status, 200)
            return json.loads(body)

    def test_admin_listener_cannot_share_a_public_port(self):
        with self.assertRaisesRegex(RuntimeError, "AddressInUse"):
            with Running("--port", str(self.server.port), "--admin-port", str(self.server.port)):
                pass

    def test_rfc_https_targets_are_rejected_before_continue_and_dispatch(self):
        for port, path in ((self.server.port, "/"), (self.server.admin_port, "/healthz")):
            for scheme in ("https", "HTTPS"):
                with self.subTest(port=port, scheme=scheme), Client(port) as client:
                    client.send(f"GET {scheme}://local{path} HTTP/1.1\r\nHost: ignored\r\n"
                                "Content-Length: 1\r\nExpect: 100-continue\r\n\r\n".encode())
                    status, fields, _ = client.response()
                    self.assertEqual(status, 421)
                    self.assertEqual(fields[b"connection"], b"close")
                    self.assertEqual(client.socket.recv(1), b"")
            with Client(port) as client:
                client.send(f"GET http://local{path} HTTP/1.1\r\nHost: ignored\r\n\r\n".encode())
                self.assertEqual(client.response()[0], 200)

    def test_rfc_admin_query_errors_precede_preconditions_and_continue(self):
        for path in ("/debug/workers", "/debug/connections"):
            for query in ("start=nope", "start=999999999", "unknown=1"):
                for condition in ("", "If-None-Match: *\r\n", 'If-Match: "missing"\r\n'):
                    with self.subTest(path=path, query=query, condition=condition), Client(self.server.admin_port) as client:
                        client.send((f"GET {path}?{query} HTTP/1.1\r\nHost: local\r\n{condition}"
                                     "Content-Length: 1\r\nExpect: 100-continue\r\n\r\n").encode())
                        self.assertEqual(client.response()[0], 400)
                        self.assertEqual(client.socket.recv(1), b"")

    def test_rfc_closing_http_1_1_stream_retains_chunk_framing(self):
        with Client(self.server.port) as client:
            client.send(b"GET /stream HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n"
                        b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
            head = client.until(b"\r\n\r\n")
            self.assertIn(b"Transfer-Encoding: chunked", head)
            self.assertIn(b"Connection: close", head)
            wire_body = client.buffer
            while part := client.socket.recv(4096):
                wire_body += part
            self.assertEqual(wire_body, b"4\r\none\n\r\n4\r\ntwo\n\r\n6\r\nthree\n\r\n0\r\n\r\n")

    def test_rfc_unimplemented_methods_are_distinct_from_disallowed_methods(self):
        for method in ("PUT", "DELETE", "PATCH", "TRACE", "CUSTOM"):
            with self.subTest(method=method):
                self.assertEqual(self.exchange(f"{method} / HTTP/1.1\r\nHost: local\r\n\r\n".encode())[0], 501)
        status, fields, _ = self.exchange(b"POST / HTTP/1.1\r\nHost: local\r\n\r\n")
        self.assertEqual(status, 405)
        self.assertEqual(fields[b"allow"], b"GET, HEAD, OPTIONS")
        with Client(self.server.port) as client:
            client.send(b"CONNECT local:443 HTTP/1.1\r\nHost: local\r\n\r\n"
                        b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
            self.assertEqual(client.response()[0], 501)
            self.assertEqual(client.socket.recv(1), b"")

    def test_rfc_equivalent_paths_route_consistently_without_decoding_separators(self):
        for path in ("/%73tream", "/x/../stream", "/./stream", "/x/%2E%2e/stream"):
            with self.subTest(path=path):
                self.assertEqual(self.exchange(f"GET {path} HTTP/1.1\r\nHost: local\r\n\r\n".encode())[2],
                                 b"one\ntwo\nthree\n")
        self.assertEqual(self.exchange(b"GET /%2Fstream HTTP/1.1\r\nHost: local\r\n\r\n")[0], 404)
        with Client(self.server.admin_port) as client:
            client.send(b"GET /%68ealthz HTTP/1.1\r\nHost: local\r\n\r\n")
            self.assertEqual(client.response()[0], 200)

    def test_rfc_errors_have_bounded_explanations_and_head_suppresses_them(self):
        status, fields, body = self.exchange(b"GET /missing HTTP/1.1\r\nHost: local\r\n\r\n")
        self.assertEqual(status, 404)
        self.assertEqual(fields[b"content-type"], b"text/plain; charset=utf-8")
        self.assertIn(b"Not Found", body)
        self.assertLess(len(body), 512)
        status, head_fields, head_body = self.exchange(b"HEAD /missing HTTP/1.1\r\nHost: local\r\n\r\n", head=True)
        self.assertEqual(status, 404)
        self.assertEqual(head_fields[b"content-length"], fields[b"content-length"])
        self.assertEqual(head_body, b"")

    def test_chunk_framing_budget_closes_before_a_pipelined_request(self):
        chunk = b"1;x=" + b"a" * 4000 + b"\r\nx\r\n"
        with Client(self.server.port) as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n"
                        + chunk * 18 + b"0\r\n\r\nGET / HTTP/1.1\r\nHost: local\r\n\r\n")
            status, fields, _ = client.response()
            self.assertEqual(status, 413)
            self.assertEqual(fields[b"connection"], b"close")
            self.assertEqual(client.buffer, b"")
            self.assertEqual(client.socket.recv(1), b"")
        self.assertEqual(self.exchange(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")[0], 200)

    def test_security_sensitive_trailers_are_rejected(self):
        for field in (b"Cookie: session=other", b"If-Match: *", b"If-None-Match: *",
                      b"Range: bytes=0-1", b"Content-Disposition: attachment",
                      b"Content-Language: en", b"Max-Forwards: 0", b"Cache-Control: no-cache"):
            with self.subTest(field=field):
                status, fields, _ = self.exchange(
                    b"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n"
                    b"1\r\nx\r\n0\r\n" + field + b"\r\n\r\n")
                self.assertEqual(status, 400)
                self.assertEqual(fields[b"connection"], b"close")

    def test_chunk_framing_override_applies_to_public_admin_and_reused_connections(self):
        with Running("--max-chunk-framing-bytes", "8") as server:
            for port, target in ((server.port, b"POST /echo"),
                                 (server.admin_port, b"GET /healthz")):
                with self.subTest(port=port), Client(port) as client:
                    head = target + b" HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n"
                    for _ in range(2):
                        client.send(head + b"1\r\nx\r\n0\r\n\r\n")
                        self.assertEqual(client.response()[0], 200)
                    client.send(head + b"1\r\nx\r\n1\r\ny\r\n0\r\n\r\n")
                    status, fields, _ = client.response()
                    self.assertEqual(status, 413)
                    self.assertEqual(fields[b"connection"], b"close")

    def test_workers_own_connections_and_aggregate_metrics(self):
        # Keep the ownership workload independent of automatic admission headroom.
        with Running("--workers", "3", "--max-connections", "64", "--max-active", "64", "--verbose") as server:
            with contextlib.ExitStack() as stack:
                clients = [stack.enter_context(Client(server.port)) for _ in range(96)]
                for client in clients:
                    client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                    self.assertEqual(client.response()[0], 100)
                workers = self.admin_json(server, "/debug/workers")["workers"]
                self.assertEqual({w["id"] for w in workers}, {0, 1, 2})
                self.assertEqual(len({w["thread"] for w in workers}), 3)
                self.assertTrue(all(w["thread"] > 0 and w["requests_admitted_total"] > 0 for w in workers))
                self.assertEqual(sum(w["requests_admitted_total"] for w in workers), 96)
                metrics = self.admin_json(server, "/debug/metrics")
                self.assertEqual(metrics["counters"]["requests_admitted_total"], 96)
                self.assertEqual(metrics["gauges"]["requests_active"], 96)
                entries = []
                start = 0
                while start is not None:
                    page = self.admin_json(server, f"/debug/connections?start={start}")
                    self.assertEqual(page["capacity"], 3 * 64 + 8)
                    entries.extend(c for c in page["connections"] if not c["admin"])
                    self.assertTrue(page["next"] is None or page["next"] > start)
                    start = page["next"]
                self.assertEqual(len(entries), 96)
                self.assertEqual({c["worker"] for c in entries}, {0, 1, 2})
                self.assertEqual(len({(c["worker"], c["id"]) for c in entries}), 96)
                self.assertTrue(all(c["permit"] == "admit" and c["phase"] == "reading" for c in entries))
                for i, client in enumerate(clients):
                    body = f"{i:03}".encode()
                    client.send(body + b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    self.assertEqual(client.response()[2], body)
                    self.assertEqual(client.response()[2], b"ZHTPS\n")
                self.assertEqual(self.admin_json(server, "/debug/metrics")["counters"]["requests_admitted_total"], 192)
            server.reader_gate.set()
            server.process.terminate()
            server.process.wait(timeout=3)
            server.reader.join(timeout=1)
            for line in server.lines:
                json.loads(line)  # Concurrent writers must preserve whole records.
            completed = [e for e in server.events if e["event"] == "request_complete"]
            self.assertEqual({e["worker"] for e in completed}, {0, 1, 2})

    def test_workers_cancel_active_bodies_with_blocked_log_sink(self):
        with Running("--workers", "3", "--verbose", "--shutdown-timeout-ms", "50") as server:
            server.reader_gate.clear()
            with contextlib.ExitStack() as stack:
                for _ in range(96):
                    client = stack.enter_context(Client(server.port))
                    client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                    self.assertEqual(client.response()[0], 100)
                workers = self.admin_json(server, "/debug/workers")["workers"]
                self.assertTrue(all(w["requests_admitted_total"] > 0 for w in workers))
                self.assertEqual(self.admin_json(server, "/debug/metrics")["gauges"]["requests_active"], 96)
                server.process.terminate()
                server.process.wait(timeout=3)
                self.assertEqual(server.process.returncode, 0)

    def test_workers_unwind_partial_startup(self):
        def limits():
            resource.setrlimit(resource.RLIMIT_NOFILE, (8, 8))
        result = subprocess.run([BINARY, "--workers", "4", "--port", "0", "--admin-port", "0"],
                                capture_output=True, timeout=3, preexec_fn=limits)
        self.assertEqual(result.returncode, 1)
        events = [json.loads(line) for line in result.stderr.splitlines()]
        self.assertEqual(events[-1]["event"], "startup_or_runtime_error")
        self.assertFalse(any(e["event"] == "listening" for e in events))

    def test_many_workers_start_with_large_connection_pools(self):
        with Running("--workers", "16", "--max-connections", "2048") as server:
            workers = self.admin_json(server, "/debug/workers")["workers"]
            self.assertEqual(len({w["thread"] for w in workers}), 16)
            with Client(server.port) as client:
                client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_workers_cancel_more_receives_than_submission_slots(self):
        with Running("--workers", "2", "--max-connections", "512", "--max-active", "512",
                     "--shutdown-timeout-ms", "20") as server:
            with contextlib.ExitStack() as stack:
                for _ in range(700):
                    client = stack.enter_context(Client(server.port))
                    client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                    self.assertEqual(client.response()[0], 100)
                workers = self.admin_json(server, "/debug/workers")["workers"]
                self.assertTrue(all(w["requests_active"] > w["sq_entries"] for w in workers))
                server.process.terminate()
                server.process.wait(timeout=3)
                self.assertEqual(server.process.returncode, 0)

    def test_workers_apply_admission_limits_independently(self):
        with Running("--workers", "3", "--max-active", "1") as server:
            with contextlib.ExitStack() as stack:
                held = []
                for _ in range(96):
                    client = stack.enter_context(Client(server.port))
                    client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                    status = client.response()[0]
                    self.assertIn(status, (100, 503))
                    if status == 100:
                        held.append(client)
                    if len(held) == 3:
                        break
                self.assertEqual(len(held), 3)
                for _ in range(12):
                    with Client(server.port) as client:
                        client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                        self.assertEqual(client.response()[0], 503)
                metrics = self.admin_json(server, "/debug/metrics")
                self.assertEqual(metrics["gauges"]["requests_active"], 3)
                self.assertGreaterEqual(metrics["counters"]["requests_rejected_total"], 12)
                for client in held:
                    client.send(b"abc")
                    self.assertEqual(client.response()[2], b"abc")
                    client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    self.assertEqual(client.response()[0], 200)

    def test_access_log_can_be_disabled_without_disabling_metrics(self):
        with Running("--workers", "2", "--no-access-log") as server:
            for _ in range(12):
                with Client(server.port) as client:
                    client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    self.assertEqual(client.response()[2], b"ZHTPS\n")
            metrics = self.admin_json(server, "/debug/metrics")
            self.assertEqual(metrics["counters"]["requests_admitted_total"], 12)
            self.assertEqual(sum(metrics["histograms"]["request_duration_seconds"]["buckets"]), 12)
            self.assertEqual(metrics["counters"]["log_dropped_total"], 0)
        self.assertTrue(any(e["event"] == "listening" for e in server.events))
        self.assertFalse(any(e["event"] == "request_complete" for e in server.events))

    def test_get_head_and_pipelining(self):
        with Client(self.server.port) as client:
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\nHEAD / HTTP/1.1\r\nHost: local\r\n\r\n")
            status, fields, body = client.response()
            self.assertEqual((status, body), (200, b"ZHTPS\n"))
            self.assertIn(b"date", fields)
            status, fields, body = client.response(head=True)
            self.assertEqual((status, body, fields[b"content-length"]), (200, b"", b"6"))
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
            self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_fragmented_chunked_echo_and_trailers(self):
        wire = (b"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n"
                b"3;foo=\"bar\"\r\nabc\r\n2\r\nde\r\n0\r\nDigest: value\r\n\r\n")
        with Client(self.server.port) as client:
            for byte in wire:
                client.send(bytes([byte]))
            self.assertEqual(client.response()[2], b"abcde")
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
            self.assertEqual(client.response()[0], 200)

    def test_expect_continue(self):
        with Client(self.server.port) as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
            self.assertEqual(client.response()[0], 100)
            client.send(b"abc")
            self.assertEqual(client.response()[2], b"abc")

    def test_get_body_does_not_become_next_request(self):
        with Client(self.server.port) as client:
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\nabc"
                        b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
            self.assertEqual(client.response()[0], 200)
            self.assertEqual(client.response()[0], 200)

    def test_post_without_framing_is_empty(self):
        result = self.exchange(b"POST /echo HTTP/1.1\r\nHost: local\r\n\r\n")
        self.assertEqual((result[0], result[2]), (200, b""))

    def test_minor_version_compatibility(self):
        self.assertEqual(self.exchange(b"GET / HTTP/1.9\r\nHost: local\r\n\r\n")[0], 200)

    def test_conditional_root_representation(self):
        status, fields, body = self.exchange(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
        self.assertEqual(status, 200)
        self.assertIn(b"etag", fields)
        tag = fields[b"etag"]
        with Client(self.server.port) as client:
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\nIf-None-Match: W/" + tag + b"\r\n\r\n")
            status, fields, body = client.response()
            self.assertEqual((status, body, fields[b"etag"]), (304, b"", tag))
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\nIf-Match: \"other\"\r\n\r\n")
            self.assertEqual(client.response()[0], 412)

    def test_allow_describes_selected_resource(self):
        status, fields, _ = self.exchange(b"POST / HTTP/1.1\r\nHost: local\r\nContent-Length: 0\r\n\r\n")
        self.assertEqual(status, 405)
        self.assertEqual(set(fields[b"allow"].split(b", ")), {b"GET", b"HEAD", b"OPTIONS"})

    def test_streaming_response_preserves_connection(self):
        with Client(self.server.port) as client:
            client.send(b"GET /stream HTTP/1.1\r\nHost: local\r\n\r\n")
            status, fields, body = client.response()
            self.assertEqual(status, 200)
            self.assertEqual(fields[b"transfer-encoding"], b"chunked")
            self.assertEqual(body, b"one\ntwo\nthree\n")
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
            self.assertEqual(client.response()[0], 200)

    def test_invalid_requests_have_final_errors(self):
        cases = [
            (b"GET / HTTP/1.1\r\n\r\n", 400),
            (b"GET / HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n", 400),
            (b"GET / HTTP/1.1\r\nHost : local\r\n\r\n", 400),
            (b"GET / HTTP/1.1\r\nHost: local\r\nContent-Length: +1\r\n\r\n", 400),
            (b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
            (b"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: gzip, chunked\r\n\r\n", 501),
            (b"POST /echo HTTP/1.1\r\nHost: local\r\nExpect: unknown\r\n\r\n", 417),
            (b"CUSTOM / HTTP/1.1\r\nHost: local\r\n\r\n", 501),
            (b"GET /bad%QQ HTTP/1.1\r\nHost: local\r\n\r\n", 400),
        ]
        for request, expected in cases:
            with self.subTest(request=request):
                status, fields, _ = self.exchange(request)
                self.assertEqual(status, expected)
                self.assertEqual(fields[b"connection"], b"close")

    def test_incomplete_headers_time_out(self):
        self.assertEqual(self.exchange(b"GET / HTTP/1.1\r\nHost:")[0], 408)

    def test_admin_metrics_and_json_logs(self):
        with Client(self.server.admin_port) as client:
            client.send(b"GET /metrics HTTP/1.1\r\nHost: local\r\n\r\n")
            status, fields, body = client.response()
            self.assertEqual(status, 200)
            self.assertEqual(fields[b"content-type"], b"text/plain; version=0.0.4; charset=utf-8")
            self.assertIn(b"zhtps_requests_total", body)
            self.assertIn(b"zhtps_request_duration_seconds_bucket", body)
            client.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
            status, fields, body = client.response()
            self.assertEqual(status, 200)
            self.assertEqual(fields[b"content-type"], b"application/json")
            parsed = json.loads(body)
            self.assertGreater(parsed["counters"]["requests_total"], 0)
        self.assertTrue(all(json.loads(line) for line in self.server.lines))

    def test_tcp_retry_mode_is_selected_and_reported(self):
        for arguments, expected in (((), "thin_linear"),
                                    (("--tcp-retries", "system"), "system"),
                                    (("--tcp-retries", "thin-linear"), "thin_linear")):
            with self.subTest(mode=expected, arguments=arguments):
                with Running(*arguments) as server:
                    self.assertEqual(self.admin_json(server, "/debug/config")["tcp_retries"], expected)
                    with Client(server.port) as client:
                        client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                        self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_admission_rejects_before_continue_and_admin_survives(self):
        with Running("--max-active", "1", "--max-rejecting", "2") as server:
            with Client(server.port) as busy:
                busy.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                self.assertEqual(busy.response()[0], 100)
                with Client(server.port) as rejected:
                    rejected.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 999\r\nExpect: 100-continue\r\n\r\n")
                    self.assertEqual(rejected.response()[0], 503)
                with Client(server.admin_port) as admin:
                    admin.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
                    metrics = json.loads(admin.response()[2])
                    self.assertGreaterEqual(metrics["counters"]["requests_rejected_total"], 1)
                busy.send(b"abc")
                self.assertEqual(busy.response()[2], b"abc")
                busy.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(busy.response()[0], 200)

    def test_default_admission_sheds_before_connection_capacity_and_recovers(self):
        for connections, active in ((4, 3), (8, 6)):
            with self.subTest(connections=connections):
                with Running("--max-connections", str(connections)) as server:
                    with contextlib.ExitStack() as stack:
                        held = []
                        for _ in range(active):
                            client = stack.enter_context(Client(server.port))
                            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                            self.assertEqual(client.response()[0], 100)
                            held.append(client)
                        with Client(server.port) as rejected:
                            rejected.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                            self.assertEqual(rejected.response()[0], 503)
                        config = self.admin_json(server, "/debug/config")
                        self.assertEqual(config["admission"]["max_active"], active)
                        self.assertEqual(config["admission"]["max_rejecting"], 1)
                        self.assertEqual(config["admission"]["burst"], active)
                        self.assertEqual(self.admin_json(server, "/debug/metrics")["gauges"]["requests_active"], active)
                        for client in held:
                            client.send(b"abc")
                            self.assertEqual(client.response()[2], b"abc")
                            client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                            self.assertEqual(client.response()[0], 200)

    def test_rejection_budget_exhaustion_closes_and_recovers(self):
        with Running("--max-active", "1", "--max-rejecting", "0") as server:
            with Client(server.port) as busy:
                busy.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                self.assertEqual(busy.response()[0], 100)
                with Client(server.port) as rejected:
                    rejected.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    with self.assertRaises((EOFError, ConnectionResetError)):
                        rejected.response()
                with Client(server.admin_port) as admin:
                    admin.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
                    metrics = json.loads(admin.response()[2])
                    self.assertGreaterEqual(metrics["counters"]["rejection_aborted_total"], 1)
                busy.send(b"abc")
                self.assertEqual(busy.response()[2], b"abc")
                busy.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(busy.response()[0], 200)

    def test_exhausted_admission_closes_before_parsing_an_incomplete_head(self):
        with Running("--max-active", "1", "--max-rejecting", "0") as server:
            with Client(server.port) as busy:
                busy.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                self.assertEqual(busy.response()[0], 100)
                with Client(server.port) as rejected:
                    rejected.socket.settimeout(.5)
                    rejected.send(b"G")
                    with self.assertRaises((EOFError, ConnectionResetError)):
                        rejected.response()
                metrics = self.admin_json(server, "/debug/metrics")
                self.assertEqual(metrics["counters"]["requests_closed_before_head_total"], 1)
                self.assertEqual(metrics["counters"]["protocol_errors_total"], 0)
                self.assertEqual(metrics["counters"]["requests_rejected_total"], 1)
                busy.send(b"abc")
                self.assertEqual(busy.response()[2], b"abc")
                with Client(server.port) as recovered:
                    recovered.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    self.assertEqual(recovered.response()[0], 200)

    def test_bodyless_rejections_preserve_pipeline_and_recover_on_same_connection(self):
        with Running("--max-active", "1", "--max-rejecting", "1") as server:
            with Client(server.port) as busy, Client(server.port) as rejected:
                busy.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                self.assertEqual(busy.response()[0], 100)
                rejected.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n"
                              b"HEAD / HTTP/1.1\r\nHost: local\r\nContent-Length: 0\r\n\r\n")
                for head in (False, True):
                    status, fields, body = rejected.response(head=head)
                    self.assertEqual(status, 503)
                    self.assertNotEqual(fields.get(b"connection"), b"close")
                    self.assertEqual(body, b"")
                busy.send(b"abc")
                self.assertEqual(busy.response()[2], b"abc")
                rejected.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(rejected.response()[2], b"ZHTPS\n")
                metrics = self.admin_json(server, "/debug/metrics")
                self.assertEqual(metrics["counters"]["requests_rejected_total"], 2)
                self.assertEqual(metrics["gauges"]["rejections_active"], 0)

    def test_early_rate_exhaustion_refills_before_closing_new_traffic(self):
        with Running("--rate", "1", "--burst", "1", "--rejection-rate", "0") as server:
            with Client(server.port) as first:
                first.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(first.response()[0], 200)
            with Client(server.port) as rejected:
                rejected.socket.settimeout(.5)
                rejected.send(b"G")
                with self.assertRaises((EOFError, ConnectionResetError)):
                    rejected.response()
            time.sleep(1.05)
            with Client(server.port) as recovered:
                recovered.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(recovered.response()[0], 200)
            metrics = self.admin_json(server, "/debug/metrics")
            self.assertEqual(metrics["counters"]["requests_closed_before_head_total"], 1)
            self.assertEqual(metrics["counters"]["requests_admitted_total"], 2)

    def test_bodyless_rejections_obey_lifetime_and_response_budgets(self):
        for extra in (("--max-requests", "2"), ("--rejection-rate", "1")):
            with self.subTest(options=extra), Running("--max-active", "1", *extra) as server:
                with Client(server.port) as busy, Client(server.port) as rejected:
                    busy.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                    self.assertEqual(busy.response()[0], 100)
                    rejected.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    status, fields, _ = rejected.response()
                    self.assertEqual(status, 503)
                    self.assertNotEqual(fields.get(b"connection"), b"close")
                    rejected.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    if extra[0] == "--max-requests":
                        status, fields, _ = rejected.response()
                        self.assertEqual(status, 503)
                        self.assertEqual(fields[b"connection"], b"close")
                    with self.assertRaises((EOFError, ConnectionResetError)):
                        rejected.response()
                    busy.send(b"abc")
                    self.assertEqual(busy.response()[2], b"abc")

    def test_rejected_body_and_explicit_close_preserve_connection_boundaries(self):
        requests = (
            b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\nabc",
            b"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n",
            b"GET / HTTP/1.0\r\n\r\n",
        )
        with Running("--max-active", "1", "--max-rejecting", "8") as server:
            with Client(server.port) as busy:
                busy.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                self.assertEqual(busy.response()[0], 100)
                for request in requests:
                    with self.subTest(request=request), Client(server.port) as rejected:
                        rejected.send(request + b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                        status, fields, _ = rejected.response()
                        self.assertEqual(status, 503)
                        self.assertEqual(fields[b"connection"], b"close")
                        with self.assertRaises(EOFError):
                            rejected.response()
                self.assertEqual(self.admin_json(server, "/debug/metrics")["counters"]["requests_rejected_total"], len(requests))
                busy.send(b"abc")
                self.assertEqual(busy.response()[2], b"abc")

    def test_public_connection_capacity_reserves_admin(self):
        with Running("--max-connections", "4") as server:
            with contextlib.ExitStack() as stack:
                for _ in range(4):
                    client = stack.enter_context(Client(server.port))
                    client.send(b"G")
                with Client(server.admin_port) as admin:
                    admin.send(b"GET /healthz HTTP/1.1\r\nHost: local\r\n\r\n")
                    self.assertEqual(admin.response()[0], 200)

    def test_peer_half_close_and_truncated_body(self):
        with Client(self.server.port) as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\nabc")
            client.socket.shutdown(socket.SHUT_WR)
            self.assertEqual(client.response()[2], b"abc")
            self.assertEqual(client.socket.recv(1), b"")
        with Client(self.server.port) as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\na")
            client.socket.shutdown(socket.SHUT_WR)
            self.assertEqual(client.response()[0], 400)

    def test_large_echo_survives_fragmentation(self):
        body = bytes(range(256)) * 256
        with Client(self.server.port) as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 65536\r\n\r\n")
            for start in range(0, len(body), 731):
                client.send(body[start:start + 731])
            self.assertEqual(client.response()[2], body)
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
            self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_stream_not_modified_length_matches_the_selected_representation(self):
        with Client(self.server.port) as client:
            client.send(b"GET /stream HTTP/1.1\r\nHost: local\r\n\r\n")
            status, fields, representation = client.response()
            self.assertEqual(status, 200)
            tag = fields[b"etag"]
            client.send(b"GET /stream HTTP/1.1\r\nHost: local\r\nIf-None-Match: " + tag +
                        b"\r\n\r\nGET / HTTP/1.1\r\nHost: local\r\n\r\n")
            status, fields, body = client.response()
            self.assertEqual((status, body, fields[b"etag"]), (304, b"", tag))
            self.assertEqual(int(fields[b"content-length"]), len(representation))
            self.assertNotIn(b"transfer-encoding", fields)
            self.assertEqual(client.response()[2], b"ZHTPS\n")

    def test_disconnect_churn_reclaims_operation_storage(self):
        with Running("--max-connections", "32", "--header-timeout-ms", "20") as server:
            def churn(worker):
                for count in range(35):
                    with Client(server.port) as client:
                        if (worker + count) % 3 == 0:
                            client.send(b"GET / HTTP/1.1\r\nHost:")
                        elif (worker + count) % 3 == 1:
                            client.send(b"GET /stream HTTP/1.1\r\nHost: local\r\n\r\n")
                        else:
                            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n2\r\na")
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(churn, range(8)))
            with Client(server.admin_port) as admin:
                admin.send(b"GET /healthz HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(admin.response()[0], 200)
            with Client(server.port) as client:
                client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(client.response()[0], 200)

    def test_blocked_log_consumer_drops_without_blocking_network_or_shutdown(self):
        with Running("--verbose", "--max-requests", "4000") as server:
            server.reader_gate.clear()
            with Client(server.port) as client:
                for _ in range(1200):
                    client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    self.assertEqual(client.response()[0], 200)
            with Client(server.admin_port) as admin:
                admin.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
                metrics = json.loads(admin.response()[2])
                self.assertGreater(metrics["counters"]["log_dropped_total"], 0)
                self.assertLessEqual(metrics["gauges"]["log_pending"], 256)
            server.process.terminate()
            server.process.wait(timeout=7)

    def test_shutdown_cancels_slow_active_bodies(self):
        with Running("--body-timeout-ms", "30000") as server:
            with contextlib.ExitStack() as stack:
                for _ in range(12):
                    client = stack.enter_context(Client(server.port))
                    client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
                    self.assertEqual(client.response()[0], 100)
                server.process.terminate()
                server.process.wait(timeout=7)

    def test_chunk_errors_and_resource_limits(self):
        for body in (b"+1\r\na\r\n0\r\n\r\n", b"1\r\naXX", b"0\r\nContent-Length: 0\r\n\r\n"):
            with self.subTest(body=body):
                result = self.exchange(b"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n" + body)
                self.assertEqual(result[0], 400)
        self.assertEqual(self.exchange(b"GET /" + b"a" * 9000 + b" HTTP/1.1\r\nHost: local\r\n\r\n")[0], 414)
        self.assertEqual(self.exchange(b"GET / HTTP/1.1\r\nHost: local\r\nX: " + b"a" * 33000 + b"\r\n\r\n")[0], 431)
        self.assertEqual(self.exchange(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 65537\r\n\r\n")[0], 413)

    def test_expect_list_ignores_empty_members_and_combines_continue(self):
        with Client(self.server.port) as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: , 100-continue, 100-CONTINUE,\r\n\r\n")
            self.assertEqual(client.response()[0], 100)
            client.send(b"abc")
            self.assertEqual(client.response()[2], b"abc")

    def test_admin_inspects_config_and_pending_requests(self):
        with Client(self.server.port) as busy:
            busy.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
            self.assertEqual(busy.response()[0], 100)
            with Client(self.server.admin_port) as admin:
                admin.send(b"GET /debug/config HTTP/1.1\r\nHost: local\r\n\r\n")
                config = json.loads(admin.response()[2])
                self.assertEqual(config["header_timeout_ms"], 500)
                admin.send(b"GET /debug/connections HTTP/1.1\r\nHost: local\r\n\r\n")
                connections = json.loads(admin.response()[2])
                self.assertTrue(any(c["permit"] == "admit" and c["phase"] == "reading" and c["pending"] > 0 for c in connections["connections"]))
                admin.send(b"GET /debug/connections?start=invalid HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(admin.response()[0], 400)
            busy.send(b"abc")
            self.assertEqual(busy.response()[2], b"abc")

    def test_slow_response_reader_hits_write_deadline(self):
        with Running("--write-timeout-ms", "40", "--max-requests", "4000") as server:
            with Client(server.port) as slow:
                slow.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                packet = b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 65536\r\n\r\n" + b"a" * 65536
                def fill():
                    try:
                        for _ in range(150):
                            slow.send(packet)
                    except (BrokenPipeError, ConnectionResetError, socket.timeout):
                        pass
                sender = threading.Thread(target=fill)
                sender.start()
                deadline = time.monotonic() + 4
                with Client(server.admin_port) as admin:
                    while True:
                        admin.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
                        counters = json.loads(admin.response()[2])["counters"]
                        if counters["request_timeouts_total"] > 0 and counters["requests_aborted_total"] > 0:
                            break
                        self.assertLess(time.monotonic(), deadline, "slow reader never hit the write deadline")
                        time.sleep(0.01)
                sender.join(timeout=4)
                self.assertFalse(sender.is_alive())

    def test_load_driver_accounts_for_every_offer(self):
        result = subprocess.run(
            [sys.executable, "tests/load.py", "--port", str(self.server.port),
             "--rate", "1000", "--duration", "0.2", "--connections", "4", "--queue", "8"],
            capture_output=True, check=True, timeout=10,
        )
        report = json.loads(result.stdout)
        self.assertEqual(report["offered"], 200)
        accounted = sum(report["statuses"].values()) + sum(report["transport_errors"].values()) + report["generator_queue_drops"]
        self.assertEqual(accounted, report["offered"])
        self.assertGreater(report["scheduled_to_completion"]["success"]["count"], 0)

    def test_descriptor_exhaustion_is_observable_and_accepts_back_off(self):
        with Running("--max-connections", "64", nofile=32) as server:
            with Client(server.admin_port) as admin:
                admin.send(b"GET /healthz HTTP/1.1\r\nHost: local\r\n\r\n")
                self.assertEqual(admin.response()[0], 200)
                with contextlib.ExitStack() as stack:
                    for _ in range(45):
                        stack.enter_context(Client(server.port))
                    time.sleep(0.2)
                    admin.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
                    counters = json.loads(admin.response()[2])["counters"]
                    self.assertGreater(counters["io_errors_total"], 0)
                    self.assertLess(counters["io_errors_total"], 30)

    def test_closed_log_pipe_does_not_terminate_server(self):
        with Running(close_logs=True) as server:
            with Client(server.port) as client:
                for _ in range(5):
                    client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    self.assertEqual(client.response()[0], 200)
            with Client(server.admin_port) as admin:
                admin.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
                counters = json.loads(admin.response()[2])["counters"]
                self.assertGreater(counters["log_write_errors_total"], 0)

    def test_http_1_0_connection_framing(self):
        with Client(self.server.port) as client:
            client.send(b"GET / HTTP/1.0\r\n\r\n")
            self.assertEqual(client.response()[1][b"connection"], b"close")
            self.assertEqual(client.socket.recv(1), b"")
        with Client(self.server.port) as client:
            for _ in range(2):
                client.send(b"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
                self.assertEqual(client.response()[1][b"connection"], b"keep-alive")
        with Client(self.server.port) as client:
            client.send(b"GET /stream HTTP/1.0\r\n\r\n")
            head = client.until(b"\r\n\r\n")
            self.assertNotIn(b"Transfer-Encoding", head)
            self.assertNotIn(b"Content-Length", head)
            body = client.buffer
            while part := client.socket.recv(4096):
                body += part
            self.assertEqual(body, b"one\ntwo\nthree\n")

    def test_stream_head_options_ranges_and_upgrade(self):
        with Client(self.server.port) as client:
            client.send(b"HEAD /stream HTTP/1.1\r\nHost: local\r\n\r\nGET / HTTP/1.1\r\nHost: local\r\nRange: bytes=0-1\r\nIf-Range: \"other\"\r\n\r\n")
            self.assertEqual(client.response(head=True)[0], 200)
            self.assertEqual(client.response()[2], b"ZHTPS\n")
            client.send(b"OPTIONS * HTTP/1.1\r\nHost: local\r\nIf-Match: \"other\"\r\n\r\n")
            status, fields, body = client.response()
            self.assertEqual((status, body), (204, b""))
            self.assertNotIn(b"content-length", fields)
            self.assertIn(b"POST", fields[b"allow"])
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n")
            self.assertEqual(client.response()[0], 200)

    def test_conditionals_precede_continue_and_follow_normal_checks(self):
        self.assertEqual(self.exchange(b"GET /missing HTTP/1.1\r\nHost: local\r\nIf-Match: \"other\"\r\n\r\n")[0], 404)
        self.assertEqual(self.exchange(b"POST / HTTP/1.1\r\nHost: local\r\nIf-Match: \"other\"\r\n\r\n")[0], 405)
        self.assertEqual(self.exchange(b"GET / HTTP/1.1\r\nHost: local\r\nIf-Match: \"other\"\r\nIf-None-Match: *\r\n\r\n")[0], 412)
        with Client(self.server.port) as client:
            client.send(b"GET / HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\nIf-None-Match: *\r\n\r\n")
            self.assertEqual(client.response()[0], 304)

    def test_admin_preconditions_are_checked_before_continue(self):
        with Client(self.server.admin_port) as admin:
            admin.send(b"GET /metrics HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\nExpect: 100-continue\r\nIf-Match: \"unavailable\"\r\n\r\n")
            self.assertEqual(admin.response()[0], 412)
        with Client(self.server.admin_port) as admin:
            admin.send(b"GET /metrics HTTP/1.1\r\nHost: local\r\nIf-None-Match: *\r\n\r\n")
            status, fields, body = admin.response()
            self.assertEqual((status, body), (304, b""))
            self.assertNotIn(b"content-length", fields)

    def test_transfer_encoding_combines_empty_list_fields(self):
        with Client(self.server.port) as client:
            client.send(b"POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: \r\nTransfer-Encoding: , chunked,\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
            self.assertEqual(client.response()[2], b"abc")

    def test_idle_and_normal_close_do_not_count_as_request_timeouts(self):
        with Running("--idle-timeout-ms", "20", "--close-timeout-ms", "20") as server:
            with Client(server.port) as idle:
                self.assertEqual(idle.socket.recv(1), b"")
            with Client(server.port) as closing:
                closing.send(b"GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n")
                self.assertEqual(closing.response()[0], 200)
                self.assertEqual(closing.socket.recv(1), b"")
                time.sleep(0.05)
                with Client(server.admin_port) as admin:
                    admin.send(b"GET /debug/metrics HTTP/1.1\r\nHost: local\r\n\r\n")
                    counters = json.loads(admin.response()[2])["counters"]
                    self.assertEqual(counters["request_timeouts_total"], 0)
                    self.assertGreaterEqual(counters["connections_idle_closed_total"], 1)

    def test_pipeline_flushes_before_waiting_for_an_incomplete_next_request(self):
        with Running("--header-timeout-ms", "5000") as server:
            with Client(server.port) as client:
                client.socket.settimeout(0.15)
                client.send(b"GET / HTTP/1.1\r\nHost: local\r\n\r\nPOST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\nab")
                # A packet held by MSG_MORE's fallback timer would delay this
                # response by about 200 ms even though it is already complete.
                self.assertEqual(client.response()[2], b"ZHTPS\n")
                client.socket.settimeout(3)
                client.send(b"c")
                self.assertEqual(client.response()[2], b"abc")


if __name__ == "__main__":
    unittest.main(verbosity=2)
