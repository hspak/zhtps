"""HTTP/2 integration against real TLS sockets (requires h2==4.3.0)."""

import contextlib
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, InformationalResponseReceived, PingAckReceived, ResponseReceived, StreamEnded, StreamReset
from h2.settings import SettingCodes

FIXTURE = sys.argv.pop(2) if len(sys.argv) > 2 and not sys.argv[2].startswith("-") else None
import wire
from wire import Running


class Client:
    def __init__(self, port, context, window=None):
        raw = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.socket = context.wrap_socket(raw, server_hostname="localhost", suppress_ragged_eofs=False)
        assert self.socket.selected_alpn_protocol() == "h2"
        self.h2 = H2Connection(config=H2Configuration(client_side=True, header_encoding="utf-8"))
        self.h2.initiate_connection()
        if window is not None:
            self.h2.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: window})
        self.responses = {}
        self.events = []
        self.goaways = []
        self.buffer = bytearray()
        self.flush()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.socket.close()

    def flush(self):
        data = self.h2.data_to_send()
        if data:
            self.socket.sendall(data)

    def request(self, path="/", method="GET", headers=(), end=True):
        stream = self.h2.get_next_available_stream_id()
        self.responses[stream] = {"headers": {}, "body": bytearray(), "ended": False, "reset": None}
        self.h2.send_headers(stream, [
            (":method", method), (":scheme", "https"),
            (":authority", "localhost"), (":path", path), *headers,
        ], end_stream=end)
        self.flush()
        return stream

    def receive(self, acknowledge=True):
        data = self.socket.recv(65536)
        if not data:
            raise EOFError("HTTP/2 connection closed")
        self.buffer.extend(data)
        events = []
        while len(self.buffer) >= 9:
            size = 9 + int.from_bytes(self.buffer[:3], "big")
            if len(self.buffer) < size:
                break
            frame = bytes(self.buffer[:size])
            del self.buffer[:size]
            if frame[3] == 7:
                # hyper-h2 marks the entire connection closed on GOAWAY. A real
                # graceful drain must still accept responses on existing streams.
                self.goaways.append((int.from_bytes(frame[9:13], "big"), int.from_bytes(frame[13:17], "big")))
            else:
                events.extend(self.h2.receive_data(frame))
        self.events.extend(events)
        for event in events:
            stream = self.responses.get(getattr(event, "stream_id", None))
            if isinstance(event, ResponseReceived):
                stream["headers"] = dict(event.headers)
            elif isinstance(event, DataReceived):
                stream["body"].extend(event.data)
                if acknowledge:
                    self.h2.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            elif isinstance(event, StreamEnded):
                stream["ended"] = True
            elif isinstance(event, StreamReset):
                stream["reset"] = event.error_code
        self.flush()
        return events

    def wait(self, stream, acknowledge=True):
        response = self.responses[stream]
        while not response["ended"] and response["reset"] is None:
            self.receive(acknowledge)
        return response

    def upload(self, stream, body, end=True):
        offset = 0
        while offset < len(body):
            credit = self.h2.local_flow_control_window(stream)
            if credit == 0:
                self.receive()
                continue
            count = min(credit, self.h2.max_outbound_frame_size, len(body) - offset)
            self.h2.send_data(stream, body[offset:offset + count], end_stream=end and offset + count == len(body))
            offset += count
            self.flush()

    def synchronize(self):
        payload = b"syncsync"
        self.h2.ping(payload)
        self.flush()
        while True:
            if any(isinstance(event, PingAckReceived) and event.ping_data == payload for event in self.receive()):
                return


class Http2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="zhtps-h2-")
        cls.addClassCleanup(cls.directory.cleanup)
        path = Path(cls.directory.name)
        key, cert = path / "key.pem", path / "cert.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost",
        ], check=True, capture_output=True)
        cls.context = ssl.create_default_context(cafile=str(cert))
        cls.context.set_alpn_protocols(["http/1.1", "h2"])
        cls.options = ("--tls-certificate", str(cert), "--tls-key", str(key))

    @contextlib.contextmanager
    def server(self, *options, fixture=False):
        previous = wire.BINARY
        if fixture:
            if FIXTURE is None:
                self.skipTest("application fixture unavailable")
            wire.BINARY = FIXTURE
        try:
            with Running(*self.options, *options) as server:
                yield server
        finally:
            wire.BINARY = previous

    def success(self, response, body=None):
        self.assertIsNone(response["reset"])
        self.assertEqual(response["headers"][":status"], "200")
        self.assertTrue(response["ended"])
        self.assertNotIn("connection", response["headers"])
        self.assertNotIn("transfer-encoding", response["headers"])
        if body is not None:
            self.assertEqual(response["body"], body)

    def test_access_logs_include_client_ip_for_completed_and_reset_streams(self):
        with self.server() as server, Client(server.port, self.context) as client:
            streams = [client.request(headers=[("x-forwarded-for", "198.51.100.1")])
                       for _ in range(4)]
            for stream in streams:
                self.success(client.wait(stream), b"ZHTPS\n")
            stream = client.request("/echo", method="POST", end=False)
            client.synchronize()
            client.h2.reset_stream(stream)
            client.flush()
            client.synchronize()
            records = []
            deadline = time.monotonic() + 3
            while len(records) < 5 and time.monotonic() < deadline:
                records = [e for e in server.events
                           if e["event"] in ("request_complete", "request_aborted")]
                time.sleep(.01)
            self.assertEqual(len(records), 5)
            self.assertEqual([e["event"] for e in records],
                             ["request_complete"] * 4 + ["request_aborted"])
            self.assertTrue(all(e["phase"] == "http2" for e in records))
            self.assertEqual([e.get("client_ip") for e in records], ["127.0.0.1"] * 5)

    def test_alpn_multiplexed_responses_and_keepalive(self):
        with self.server() as server, Client(server.port, self.context) as client:
            streams = [client.request("/stream" if i % 2 else "/") for i in range(40)]
            for i, stream in enumerate(streams):
                self.success(client.wait(stream), b"one\ntwo\nthree\n" if i % 2 else b"ZHTPS\n")
            self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_static_files_get_head_and_conditional_response(self):
        expected = Path("docs/testing.md").read_bytes()
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            response = client.wait(client.request("/static/docs/testing.md"))
            self.success(response, expected)
            head = client.wait(client.request("/static/docs/testing.md", method="HEAD"))
            self.success(head, b"")
            self.assertEqual(head["headers"]["content-length"], str(len(expected)))
            conditional = client.wait(client.request("/static/docs/testing.md", headers=[
                ("if-none-match", response["headers"]["etag"]),
            ]))
            self.assertEqual(conditional["headers"][":status"], "304")
            self.assertEqual(conditional["body"], b"")
            self.assertTrue(conditional["ended"])
            self.assertIsNone(conditional["reset"])
            self.success(client.wait(client.request("/origin")))

    def test_response_field_encoding_preserves_duplicates_and_rejects_invalid_metadata(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            stream = client.request("/response-fields")
            response = client.wait(stream)
            self.success(response, b"ok")
            self.assertEqual(response["headers"]["x-mixed"], "abc")
            self.assertEqual(response["headers"]["content-length"], "2")
            for name in ("keep-alive", "upgrade", "proxy-connection"):
                self.assertNotIn(name, response["headers"])
            headers = next(event.headers for event in client.events
                           if isinstance(event, ResponseReceived) and event.stream_id == stream)
            self.assertEqual([value for name, value in headers if name == "set-cookie"], ["a=1", "b=2"])
            for invalid in ("invalid-name", "invalid-value", "reserved"):
                with self.subTest(invalid=invalid):
                    response = client.wait(client.request("/response-fields?" + invalid))
                    self.assertIsNotNone(response["reset"])
                    self.assertFalse(response["ended"])
            self.success(client.wait(client.request("/origin")))

    def test_response_field_count_and_buffer_boundary_preserve_neighbor(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            self.success(client.wait(client.request("/response-count?61")), b"ok")
            self.assertIsNotNone(client.wait(client.request("/response-count?62"))["reset"])
            prefix = b"HTTP/1.1 200 OK\r\nDate: " + b"x" * 29 + b"\r\nContent-Length: 2\r\nx-large: "
            maximum = 32768 - len(prefix + b"\r\n\r\n")
            response = client.wait(client.request(f"/response-budget?{maximum}"))
            self.success(response, b"ok")
            self.assertEqual(response["headers"]["x-large"], "x" * maximum)
            self.assertIsNotNone(client.wait(client.request(f"/response-budget?{maximum + 1}"))["reset"])
            self.success(client.wait(client.request("/origin")))

    def test_response_name_growth_preserves_previously_encoded_fields(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            response = client.wait(client.request("/response-uppercase"))
            self.success(response, b"ok")
            for i in range(40):
                self.assertEqual(response["headers"][f"x-custom-header-{i}-padding"], f"value-{i}")

    def test_request_storage_growth_preserves_cookies_fields_and_target(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            cookies = [("cookie", "a" * 2000), ("cookie", "b" * 2000)]
            fields = [("x-large", "x" * 3000), *cookies]
            fields += [(f"x-extra-{i}", "v" * 8) for i in range(30)]
            response = client.wait(client.request("/headers", headers=fields))
            self.success(response)
            self.assertEqual(json.loads(response["body"])["cookie"], "a" * 2000 + "; " + "b" * 2000)
            response = client.wait(client.request("/" + "x" * 3000 + "/../headers", headers=[("cookie", "kept")]))
            self.success(response)
            self.assertEqual(json.loads(response["body"])["cookie"], "kept")

    def test_trailer_storage_growth_preserves_a_blocked_consumers_header_borrow(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            stream = client.request("/upload", "POST", headers=[("x-hold", "1"), ("x-preserve", "unchanged")], end=False)
            client.upload(stream, b"hello", end=False)
            deadline = time.monotonic() + 1
            while json.loads(client.wait(client.request("/inspect"))["body"])["holding"] != 1:
                self.assertLess(time.monotonic(), deadline)
            trailers = [(f"x-result-{i:02}", chr(97 + i % 26) * 40) for i in range(40)]
            client.h2.send_headers(stream, trailers, end_stream=True)
            client.flush()
            client.synchronize()
            self.success(client.wait(client.request("/origin")))
            self.success(client.wait(client.request("/unblock")))
            response = client.wait(stream)
            self.success(response)
            self.assertEqual(json.loads(response["body"]), {
                "bytes": 5, "preserved": "unchanged",
                "trailers": [{"name": name, "value": value} for name, value in trailers],
            })

    def test_generated_stream_flush_wait_and_multiplexing(self):
        with self.server("--workers", "1", fixture=True) as server, Client(server.port, self.context) as client:
            stream = client.request("/events")
            while not client.responses[stream]["body"]:
                client.receive()
            self.assertEqual(client.responses[stream]["body"], b"data: first\n\n")
            self.assertFalse(client.responses[stream]["ended"])
            neighbor = client.wait(client.request("/inspect"))
            self.success(neighbor)
            self.assertEqual(json.loads(neighbor["body"])["released"], 0)
            self.success(client.wait(client.request("/unblock")), b"ok")
            self.success(client.wait(stream), b"data: first\n\ndata: last\n\n")

    def test_generated_stream_flow_control_bounds_production_and_reset_wakes_writer(self):
        with self.server("--workers", "1", fixture=True) as server, Client(server.port, self.context, window=1024) as client:
            stream = client.request("/generated")
            while not client.responses[stream]["body"]:
                client.receive(acknowledge=False)
            time.sleep(0.05)
            counters = json.loads(client.wait(client.request("/inspect"), acknowledge=False)["body"])
            self.assertGreater(counters["generated_bytes"], 0)
            self.assertLessEqual(counters["generated_bytes"], 32 * 1024)
            self.assertEqual(len(client.responses[stream]["body"]), 1024)
            client.h2.reset_stream(stream)
            client.flush()
            deadline = time.monotonic() + 1
            while json.loads(client.wait(client.request("/inspect"))["body"])["released"] != 1:
                self.assertLess(time.monotonic(), deadline)
            # The sole default lane was occupied by the blocked writer.
            self.success(client.wait(client.request("/stream-empty")), b"")

    def test_generated_stream_large_body_head_and_failure_boundaries(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            head = client.wait(client.request("/generated", "HEAD"))
            self.success(head, b"")
            self.assertEqual(head["headers"]["content-length"], "8388608")
            for path in ("/stream-error", "/stream-short", "/stream-long"):
                failed = client.wait(client.request(path))
                self.assertIsNotNone(failed["reset"], path)
                self.assertFalse(failed["ended"], path)
            large = client.wait(client.request("/generated"))
            self.success(large, b"0123456789abcdef" * (512 * 1024))
            self.success(client.wait(client.request("/stream-empty")), b"")

    def test_generated_stream_deadline_and_reset_cancel_application_wait(self):
        for path in ("/events", "/stream-timeout"):
            with self.subTest(path=path), self.server(fixture=True) as server, Client(server.port, self.context) as client:
                stream = client.request(path)
                while not client.responses[stream]["body"]:
                    client.receive()
                if path == "/events":
                    client.h2.reset_stream(stream)
                    client.flush()
                else:
                    self.assertIsNotNone(client.wait(stream)["reset"])
                deadline = time.monotonic() + 1
                while json.loads(client.wait(client.request("/inspect"))["body"])["released"] != 1:
                    self.assertLess(time.monotonic(), deadline)
                self.success(client.wait(client.request("/stream-empty")), b"")

    def test_generated_stream_stalled_window_times_out_without_blocking_neighbor(self):
        with self.server("--write-timeout-ms", "80", fixture=True) as server, Client(server.port, self.context, window=0) as client:
            stream = client.request("/generated")
            failed = client.wait(stream, acknowledge=False)
            self.assertIsNotNone(failed["reset"])
            self.assertEqual(failed["body"], b"")
            client.h2.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 65535})
            client.flush()
            self.success(client.wait(client.request("/stream-empty")), b"")

    def test_generated_stream_shutdown_wakes_backpressured_writer(self):
        with self.server("--shutdown-timeout-ms", "50", fixture=True) as server, Client(server.port, self.context, window=0) as client:
            stream = client.request("/generated")
            while not client.responses[stream]["headers"]:
                client.receive(acknowledge=False)
            server.process.terminate()
            server.process.wait(timeout=1)
            self.assertEqual(server.process.returncode, 0)

    def test_generated_stream_failure_without_window_resets_promptly(self):
        with self.server(fixture=True) as server, Client(server.port, self.context, window=0) as client:
            started = time.monotonic()
            failed = client.wait(client.request("/stream-error?early=1"))
            self.assertIsNotNone(failed["reset"])
            self.assertLess(time.monotonic() - started, 1)

    def test_upload_flow_control_and_neighbor(self):
        with self.server() as server, Client(server.port, self.context) as client:
            body = bytes(range(251)) * 250
            upload = client.request("/echo", "POST", [("content-length", str(len(body)))], end=False)
            neighbor = client.request()
            self.success(client.wait(neighbor), b"ZHTPS\n")
            client.upload(upload, body)
            self.success(client.wait(upload), body)

    def test_head_options_errors_and_conditional(self):
        with self.server() as server, Client(server.port, self.context) as client:
            head = client.wait(client.request(method="HEAD"))
            self.success(head, b"")
            self.assertEqual(head["headers"]["content-length"], "6")
            options = client.wait(client.request("*", "OPTIONS"))
            self.assertEqual(options["headers"][":status"], "204")
            self.assertNotIn("content-length", options["headers"])
            cached = client.wait(client.request(headers=[("if-none-match", '"zhtps-root-v1"')]))
            self.assertEqual(cached["headers"][":status"], "304")
            self.assertEqual(cached["body"], b"")
            missing = client.wait(client.request("/missing"))
            self.assertEqual(missing["headers"][":status"], "404")
            self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_receive_stream_reset_preserves_connection(self):
        with self.server() as server, Client(server.port, self.context) as client:
            stream = client.request("/echo", "POST", end=False)
            client.h2.send_data(stream, b"partial")
            client.h2.reset_stream(stream)
            client.flush()
            self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_content_length_mismatch_resets_only_one_stream(self):
        with self.server() as server, Client(server.port, self.context) as client:
            invalid = client.request("/echo", "POST", [("content-length", "5")], end=False)
            client.upload(invalid, b"shorter than declared")
            self.assertIsNotNone(client.wait(invalid)["reset"])
            self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_continue_and_early_response_before_upload(self):
        with self.server() as server, Client(server.port, self.context) as client:
            upload = client.request("/echo", "POST", [("content-length", "3"), ("expect", "100-continue")], end=False)
            while not any(isinstance(event, InformationalResponseReceived) and event.stream_id == upload for event in client.events):
                client.receive()
            client.upload(upload, b"abc")
            self.success(client.wait(upload), b"abc")
            denied = client.request("/missing", "POST", end=False)
            response = client.wait(denied)
            self.assertEqual(response["headers"][":status"], "404")
            self.assertTrue(response["ended"])
            self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_invalid_field_bytes_reset_stream_instead_of_discarding_fields(self):
        fields = [
            ("authorization", "a\x00b"), ("x-test", "a\rb"), ("x-test", "a\nb"),
            ("x-test", "a\x01b"), ("x-test", "a\x7fb"), ("bad name", "value"),
            ("x-test", " leading"), ("x-test", "trailing\t"),
        ]
        with self.server() as server, Client(server.port, self.context) as client:
            client.h2.config.validate_outbound_headers = False
            client.h2.config.normalize_outbound_headers = False
            for field in fields:
                with self.subTest(field=field):
                    invalid = client.request(headers=[field])
                    response = client.wait(invalid)
                    self.assertEqual(response["reset"], 1)
                    self.assertEqual(response["headers"], {})
                    self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_invalid_trailer_bytes_reset_stream_instead_of_discarding_fields(self):
        with self.server() as server, Client(server.port, self.context) as client:
            client.h2.config.validate_outbound_headers = False
            client.h2.config.normalize_outbound_headers = False
            for field in (("x-checksum", "a\x00b"), ("bad name", "value"), ("x-checksum", " value")):
                with self.subTest(field=field):
                    invalid = client.request("/echo", "POST", end=False)
                    client.upload(invalid, b"abc", end=False)
                    client.h2.send_headers(invalid, [field], end_stream=True)
                    client.flush()
                    response = client.wait(invalid)
                    self.assertEqual(response["reset"], 1)
                    self.assertEqual(response["headers"], {})
                    self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_expect_lists_and_repeated_fields_continue_before_upload(self):
        for values in ((", 100-Continue,",), ("", "100-continue"), ("100-continue", "100-continue")):
            with self.subTest(values=values), self.server() as server, Client(server.port, self.context) as client:
                upload = client.request("/echo", "POST", [("expect", value) for value in values], end=False)
                while not any(getattr(event, "stream_id", None) == upload and isinstance(
                    event, (InformationalResponseReceived, ResponseReceived, StreamReset)
                ) for event in client.events):
                    client.receive()
                informational = [event for event in client.events if isinstance(event, InformationalResponseReceived)
                                 and event.stream_id == upload]
                self.assertEqual(len(informational), 1)
                self.assertEqual(dict(informational[0].headers)[":status"], "100")
                client.upload(upload, b"abc")
                self.success(client.wait(upload), b"abc")
                self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_unknown_expectation_in_any_field_rejects_before_continue(self):
        for values in (("100-continue", "other"), ("", "other"), ("100-continue, other",)):
            with self.subTest(values=values), self.server() as server, Client(server.port, self.context) as client:
                invalid = client.request("/echo", "POST", [("expect", value) for value in values], end=False)
                # Complete input to expose implementations that examine only the first field.
                client.upload(invalid, b"abc")
                response = client.wait(invalid)
                self.assertEqual(response["headers"].get(":status"), "417")
                self.assertTrue(response["ended"])
                self.assertFalse(any(isinstance(event, InformationalResponseReceived)
                                     and event.stream_id == invalid for event in client.events))
                self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_empty_expectation_is_ignored_without_continue(self):
        with self.server() as server, Client(server.port, self.context) as client:
            upload = client.request("/echo", "POST", [("expect", "")], end=False)
            client.upload(upload, b"abc")
            self.success(client.wait(upload), b"abc")
            self.assertFalse(any(isinstance(event, InformationalResponseReceived)
                                 and event.stream_id == upload for event in client.events))
            self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_worker_stream_limit_and_reset_reclaims_capacity(self):
        with self.server("--http2-worker-streams", "1") as server:
            with Client(server.port, self.context) as first, Client(server.port, self.context) as second:
                held = first.request("/echo", "POST", end=False)
                first.synchronize()
                rejected = second.wait(second.request())
                self.assertEqual(rejected["reset"], 7)
                first.h2.reset_stream(held)
                first.synchronize()
                self.success(second.wait(second.request()), b"ZHTPS\n")

    def test_decoded_header_limit_preserves_neighbor(self):
        with self.server() as server, Client(server.port, self.context) as client:
            invalid = client.request(headers=[("x-large", "a" * 40000)])
            self.assertIsNotNone(client.wait(invalid)["reset"])
            self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_forbidden_trailers_preserve_header_policy(self):
        with self.server() as server, Client(server.port, self.context) as client:
            for name in ("authorization", "cookie", "if-match", "content-type"):
                with self.subTest(name=name):
                    stream = client.request("/echo", "POST", end=False)
                    client.upload(stream, b"abc", end=False)
                    client.h2.send_headers(stream, [(name, "late")], end_stream=True)
                    client.flush()
                    self.assertIsNotNone(client.wait(stream)["reset"])
            self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_memory_budget_exhaustion_releases_connection_allocations(self):
        with self.server("--http2-memory-bytes", "1048576") as server:
            with Client(server.port, self.context) as client:
                with self.assertRaises((EOFError, OSError, ssl.SSLError)):
                    for _ in range(100):
                        client.request("/echo", "POST", end=False)
                        client.synchronize()
            with Client(server.port, self.context) as recovered:
                self.success(recovered.wait(recovered.request()), b"ZHTPS\n")

    def test_six_small_uploads_fit_one_mebibyte(self):
        with self.server("--workers", "1", "--http2-memory-bytes", "1048576") as server:
            with Client(server.port, self.context) as client:
                streams = []
                for _ in range(6):
                    streams.append(client.request("/echo", "POST", end=False))
                    client.synchronize()
                for stream in streams:
                    client.upload(stream, b"small body")
                    self.success(client.wait(stream), b"small body")
                self.success(client.wait(client.request()), b"ZHTPS\n")

    def test_request_limit_sends_goaway_after_accepted_streams(self):
        with self.server("--max-requests", "3") as server, Client(server.port, self.context) as client:
            streams = [client.request() for _ in range(3)]
            for stream in streams:
                self.success(client.wait(stream), b"ZHTPS\n")
            while not client.goaways:
                client.receive()
            self.assertEqual(client.goaways, [(5, 0)])

    def test_generated_metadata_and_large_response(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            origin = client.wait(client.request("/x/../metadata?q=raw%20query"))
            self.success(origin)
            self.assertEqual(json.loads(origin["body"]), {
                "scheme": "https", "authority": "localhost", "version": "http_2",
                "path": "/metadata", "query": "q=raw%20query",
            })
            self.success(client.wait(client.request("/large")), b"0123456789abcdef" * (512 * 1024))

    def test_blocked_handler_does_not_serialize_neighbor_and_reset_defers_release(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            held = client.request("/hold")
            self.wait_holding(client)
            client.h2.reset_stream(held)
            client.flush()
            inspect = client.wait(client.request("/inspect"))
            self.assertEqual(json.loads(inspect["body"])["released"], 0)
            self.success(client.wait(client.request("/origin")))
            self.success(client.wait(client.request("/unblock")), b"ok")
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                inspect = client.wait(client.request("/inspect"))
                if json.loads(inspect["body"])["released"] == 1:
                    break
                time.sleep(.005)
            else:
                self.fail("reset exchange was not released after its hook returned")

    def wait_holding(self, client):
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            response = client.wait(client.request("/inspect"))
            if json.loads(response["body"])["holding"]:
                return
            time.sleep(.005)
        self.fail("hook did not start")

    def test_application_deadline_resets_only_its_stream(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            slow = client.request("/timeout")
            self.assertIsNotNone(client.wait(slow)["reset"])
            self.success(client.wait(client.request("/origin")))
            time.sleep(.3)
            self.success(client.wait(client.request("/origin")))

    def test_running_hook_observes_stream_cancellation(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            canceled = client.request("/cancel")
            self.wait_holding(client)
            client.h2.reset_stream(canceled)
            client.flush()
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                response = client.wait(client.request("/inspect"))
                if json.loads(response["body"])["released"] == 1:
                    break
                time.sleep(.005)
            else:
                self.fail("running hook did not observe its reset")
            self.success(client.wait(client.request("/origin")))

    def test_connection_disconnect_cancels_running_hook(self):
        with self.server(fixture=True) as server:
            with Client(server.port, self.context) as client:
                client.request("/cancel")
                self.wait_holding(client)
            with Client(server.port, self.context) as observer:
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline:
                    response = observer.wait(observer.request("/inspect"))
                    if json.loads(response["body"])["released"] == 1:
                        break
                    time.sleep(.005)
                else:
                    self.fail("disconnected connection retained its running hook")

    def test_split_cookie_fields_are_joined_for_application(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            response = client.wait(client.request("/headers", headers=[("cookie", "a=1"), ("cookie", "b=2")]))
            self.success(response)
            self.assertEqual(json.loads(response["body"]), {"cookie": "a=1; b=2", "chunked": False})

    def test_shutdown_goaway_allows_existing_response_to_finish(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            held = client.request("/hold")
            self.wait_holding(client)
            last = client.h2.highest_outbound_stream_id
            server.process.terminate()
            self.success(client.wait(held), b"released")
            while not client.goaways:
                client.receive()
            self.assertEqual(client.goaways, [(last, 0)])
            self.assertEqual(client.socket.recv(1), b"")
            server.process.wait(timeout=3)
            self.assertEqual(server.process.returncode, 0)

    def assert_fatal_protocol_close(self, client):
        # A seven-byte PING is a connection-level FRAME_SIZE_ERROR. Keep the
        # client open so its own disconnect cannot release the server's work.
        client.socket.sendall(b"\x00\x00\x07\x06\x00\x00\x00\x00\x00" + b"1234567")
        deadline = time.monotonic() + 1
        while True:
            client.socket.settimeout(max(.001, deadline - time.monotonic()))
            try:
                client.receive()
            except TimeoutError:
                self.fail("fatal GOAWAY retained the connection until a stream deadline")
            except (EOFError, ConnectionResetError, ssl.SSLEOFError):
                break
            self.assertLess(time.monotonic(), deadline)
        self.assertTrue(any(code == 6 for _, code in client.goaways), client.goaways)

    def test_fatal_protocol_error_closes_pending_upload_without_body_timeout(self):
        with self.server("--body-timeout-ms", "5000", fixture=True) as server, Client(server.port, self.context) as client:
            client.request("/lifecycle-echo", "POST", [("content-length", "3")], end=False)
            client.synchronize()
            self.assert_fatal_protocol_close(client)
            with Client(server.port, self.context) as observer:
                self.success(observer.wait(observer.request("/metadata")))

    def test_fatal_protocol_error_cancels_waiting_producer(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            stream = client.request("/stream-cancel")
            while not client.responses[stream]["body"]:
                client.receive()
            self.assert_fatal_protocol_close(client)
            with Client(server.port, self.context) as observer:
                deadline = time.monotonic() + 1
                while True:
                    response = observer.wait(observer.request("/inspect"))
                    self.success(response)
                    if json.loads(response["body"])["released"] == 1:
                        break
                    self.assertLess(time.monotonic(), deadline, "fatal error retained its producer")
                    time.sleep(.005)
                self.success(observer.wait(observer.request("/stream-empty")), b"")

    def test_streaming_upload_consumption_and_trailers(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            stream = client.request("/upload", "POST", end=False)
            client.upload(stream, b"abcdefgh" * (256 * 1024), end=False)
            client.h2.send_headers(stream, [("x-checksum", "verified")], end_stream=True)
            client.flush()
            response = client.wait(stream)
            self.success(response)
            self.assertEqual(json.loads(response["body"]), {
                "bytes": 2 * 1024 * 1024,
                "trailers": [{"name": "x-checksum", "value": "verified"}],
            })

    def test_stalled_consumer_withholds_stream_credit_but_not_connection_credit(self):
        with self.server(fixture=True) as server, Client(server.port, self.context) as client:
            stream = client.request("/upload", "POST", [("x-hold", "1")], end=False)
            client.upload(stream, b"x" * 65535, end=False)
            self.wait_holding(client)
            self.assertEqual(client.h2.local_flow_control_window(stream), 0)
            neighbor = client.request("/origin")
            self.success(client.wait(neighbor))
            self.assertGreater(client.h2.outbound_flow_control_window, 0)
            self.success(client.wait(client.request("/unblock")))
            client.upload(stream, b"more")
            response = client.wait(stream)
            self.success(response)
            self.assertEqual(json.loads(response["body"])["bytes"], 65539)

    def test_send_window_stall_does_not_hold_neighbor(self):
        with self.server(fixture=True) as server, Client(server.port, self.context, window=1024) as client:
            large = client.request("/large")
            origin = client.request("/origin")
            self.success(client.wait(origin, acknowledge=False))
            while len(client.responses[large]["body"]) < 1024:
                client.receive(acknowledge=False)
            self.assertFalse(client.responses[large]["ended"])
            client.h2.reset_stream(large)
            client.flush()
            self.success(client.wait(client.request("/origin")))


if __name__ == "__main__":
    unittest.main()
