"""Boot-prepared static representations over HTTP/1, TLS and HTTP/2."""

import contextlib
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import unittest

import wire
from wire import Client, Running
from http2 import Client as Http2Client

wire.BINARY = str(Path(wire.BINARY).resolve())


class StaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certificates = tempfile.TemporaryDirectory(prefix="zhtps-static-certs-")
        cls.addClassCleanup(cls.certificates.cleanup)
        root = Path(cls.certificates.name)
        cls.key, cls.cert = root / "key.pem", root / "cert.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-keyout", str(cls.key), "-out", str(cls.cert), "-days", "1", "-subj", "/CN=localhost",
        ], check=True, capture_output=True)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="zhtps-static-root-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.body = b"<p>Boot-time compression preserves the original document.</p>\n" * 4096
        (self.root / "index.html").write_bytes(self.body)
        (self.root / "small.txt").write_bytes(b"small")
        (self.root / "image.png").write_bytes(self.body)
        (self.root / "random.txt").write_bytes(os.urandom(32768))
        (self.root / ".hidden.txt").write_bytes(self.body)
        (self.root / "link.txt").symlink_to("index.html")
        os.mkfifo(self.root / "pipe.txt")
        (self.root / "guide").mkdir()
        (self.root / "guide/index.html").write_bytes(self.body)

    @contextlib.contextmanager
    def server(self, protocol="http1", *options):
        tls = [] if protocol == "http1" else ["--tls-certificate", str(self.cert), "--tls-key", str(self.key)]
        with Running(*tls, *options, cwd=self.root) as server:
            yield server

    @contextlib.contextmanager
    def client(self, server, protocol):
        if protocol == "http1":
            with Client(server.port) as client:
                yield client
            return
        context = ssl.create_default_context(cafile=str(self.cert))
        context.set_alpn_protocols(["h2" if protocol == "h2" else "http/1.1"])
        if protocol == "h2":
            with Http2Client(server.port, context) as client:
                yield client
        else:
            with Client(server.port) as client:
                client.socket = context.wrap_socket(client.socket, server_hostname="localhost")
                yield client

    def request(self, client, path="/", headers=(), method="GET"):
        if isinstance(client, Http2Client):
            response = client.wait(client.request(path, method=method, headers=headers))
            self.assertTrue(response["ended"])
            self.assertIsNone(response["reset"])
            fields = response["headers"]
            return int(fields[":status"]), fields, bytes(response["body"])
        head = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
        head += "".join(f"{name}: {value}\r\n" for name, value in headers)
        client.send((head + "\r\n").encode())
        status, fields, body = client.response(head=method == "HEAD")
        return status, {k.decode(): v.decode() for k, v in fields.items()}, body

    def decode(self, body):
        return subprocess.run(["zstd", "-dq", "--stdout"], input=body, capture_output=True, check=True).stdout

    def test_get_head_conditionals_and_mount_opt_in(self):
        accepted = [("accept-encoding", "zstd")]
        for protocol in ("http1", "tls", "h2"):
            with self.subTest(protocol=protocol), self.server(protocol) as server, self.client(server, protocol) as client:
                status, original, body = self.request(client)
                self.assertEqual((status, body), (200, self.body))
                self.assertEqual(original["vary"], "Accept-Encoding")
                status, compressed, body = self.request(client, headers=accepted)
                self.assertEqual(status, 200)
                self.assertEqual(compressed["content-encoding"], "zstd")
                self.assertEqual(compressed["content-type"], original["content-type"])
                self.assertEqual(int(compressed["content-length"]), len(body))
                self.assertLess(len(body), len(self.body))
                self.assertEqual(self.decode(body), self.body)
                self.assertNotEqual(compressed["etag"], original["etag"])
                status, head, body = self.request(client, headers=accepted, method="HEAD")
                self.assertEqual((status, body), (200, b""))
                for field in ("content-encoding", "content-length", "etag", "vary"):
                    self.assertEqual(head[field], compressed[field])
                status, conditional, body = self.request(client, headers=accepted + [("if-none-match", compressed["etag"])])
                self.assertEqual((status, body), (304, b""))
                self.assertEqual(conditional["vary"], "Accept-Encoding")
                self.assertEqual(conditional["content-length"], compressed["content-length"])
                self.assertEqual(self.request(client, headers=accepted + [("if-none-match", original["etag"])])[0], 200)
                status, failed, _ = self.request(client, headers=accepted + [("if-match", '"missing"')])
                self.assertEqual(status, 412)
                self.assertNotIn("content-encoding", failed)
                status, plain, body = self.request(client, "/plain/", accepted)
                self.assertEqual((status, body), (200, self.body))
                self.assertNotIn("content-encoding", plain)
                self.assertNotIn("vary", plain)

    def test_negotiation_weights_wildcards_repeated_fields_and_rejection(self):
        cases = [
            ([], 200, False),
            ([""], 200, False),
            (["gzip, br"], 200, False),
            (["zstd;q=0"], 200, False),
            (["zstd;q=0, *;q=1"], 200, False),
            (["*"], 200, True),
            (["gzip", "ZSTD;q=1.000"], 200, True),
            (["zstd;q=0.5, identity;q=0.1"], 200, True),
            (["zstd;q=0.1, identity;q=1"], 200, False),
            (["*;q=0, zstd"], 200, True),
            (["zstd;q=0, identity;q=0"], 406, False),
            (["*;q=0"], 406, False),
            (["zstd;q=1.001"], 400, False),
            (["zstd;q=nan"], 400, False),
            (["zstd;q=0", "zstd;q=1"], 400, False),
        ]
        for protocol in ("http1", "h2"):
            with self.server(protocol) as server, self.client(server, protocol) as client:
                for encodings, expected, compressed in cases:
                    with self.subTest(protocol=protocol, encodings=encodings):
                        status, fields, body = self.request(client, headers=[("accept-encoding", e) for e in encodings])
                        self.assertEqual(status, expected)
                        self.assertEqual(fields.get("content-encoding") == "zstd", compressed)
                        if expected == 200:
                            self.assertEqual(self.decode(body) if compressed else body, self.body)
                        if expected == 406:
                            self.assertEqual(fields["vary"], "Accept-Encoding")

    def test_eligibility_indexes_and_filesystem_boundaries(self):
        accepted = [("accept-encoding", "zstd")]
        with self.server() as server, self.client(server, "http1") as client:
            for name in ("small.txt", "image.png", "random.txt"):
                status, fields, body = self.request(client, "/" + name, accepted)
                self.assertEqual((status, body), (200, (self.root / name).read_bytes()))
                self.assertNotIn("content-encoding", fields)
                self.assertEqual(self.request(client, "/" + name, [("accept-encoding", "zstd, identity;q=0")])[0], 406)
            for name in (".hidden.txt", "link.txt", "pipe.txt", "guide%2findex.html", "missing.txt"):
                self.assertEqual(self.request(client, "/" + name, accepted)[0], 404)
            self.assertEqual(self.request(client, "/guide", accepted)[0], 308)
            status, fields, body = self.request(client, "/guide/", accepted)
            self.assertEqual(status, 200)
            self.assertEqual(self.decode(body), self.body)

    def test_changed_deleted_and_new_files_do_not_serve_stale_compression(self):
        accepted = [("accept-encoding", "zstd")]
        for protocol in ("http1", "h2"):
            (self.root / "index.html").write_bytes(self.body)
            with self.server(protocol) as server, self.client(server, protocol) as client:
                self.assertEqual(self.request(client, headers=accepted)[1]["content-encoding"], "zstd")
                replacement = self.body.replace(b"Boot-time", b"Next-boot")
                (self.root / "replacement").write_bytes(replacement)
                (self.root / "replacement").replace(self.root / "index.html")
                status, fields, body = self.request(client, headers=accepted)
                self.assertEqual((status, body), (200, replacement))
                self.assertNotIn("content-encoding", fields)
                self.assertEqual(self.request(client, headers=[("accept-encoding", "zstd, identity;q=0")])[0], 406)
                (self.root / "new.txt").write_bytes(self.body)
                self.assertNotIn("content-encoding", self.request(client, "/new.txt", accepted)[1])
                (self.root / "index.html").unlink()
                self.assertEqual(self.request(client, headers=accepted)[0], 404)

    def test_large_representation_and_canceled_transfers(self):
        expected = os.urandom(256 * 1024) * 40
        (self.root / "large.txt").write_bytes(expected)
        accepted = [("accept-encoding", "zstd")]
        for protocol in ("http1", "tls", "h2"):
            with self.subTest(protocol=protocol), self.server(protocol) as server:
                with self.client(server, protocol) as client:
                    status, fields, body = self.request(client, "/large.txt", accepted)
                    self.assertEqual(status, 200)
                    self.assertGreater(len(body), 32768)
                    self.assertEqual(int(fields["content-length"]), len(body))
                    self.assertEqual(self.decode(body), expected)
                with self.client(server, protocol) as client:
                    if protocol == "h2":
                        stream = client.request("/large.txt", headers=accepted)
                        while not client.responses[stream]["headers"]:
                            client.receive(acknowledge=False)
                        client.h2.reset_stream(stream)
                        client.flush()
                        self.assertEqual(self.request(client, "/small.txt")[2], b"small")
                    else:
                        client.send(b"GET /large.txt HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: zstd\r\n\r\n")
                        self.assertIn(b"200 OK", client.until(b"\r\n\r\n"))
                with self.client(server, protocol) as client:
                    self.assertEqual(self.request(client, "/small.txt")[2], b"small")


if __name__ == "__main__":
    unittest.main()
