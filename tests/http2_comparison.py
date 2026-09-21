"""Compare malformed HTTP/2 streams over TLS; requires tests/requirements-http2.txt.

Run: python3 tests/http2_comparison.py zig-out/bin/zhtps --output /tmp/http2.json
"""

import argparse
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import ConnectionTerminated, DataReceived, InformationalResponseReceived, ResponseReceived, StreamEnded, StreamReset

import wire
from http1_comparison import reference


def cases():
    base = [(":method", "GET"), (":scheme", "https"), (":authority", "localhost"), (":path", "/")]
    result = []

    def add(name, *, fields=None, extra=(), body=None, trailers=None):
        result.append(dict(name=name, fields=(base if fields is None else fields) + list(extra),
                           body=body, trailers=trailers))

    add("ordinary_get")
    for name, extra in {
        "host_matches": [("host", "localhost")], "host_mismatch": [("host", "other")],
        "duplicate_host": [("host", "localhost"), ("host", "other")],
        "duplicate_authority": [(":authority", "other")], "unknown_pseudo": [(":unknown", "x")],
        "connection": [("connection", "close")], "transfer_encoding": [("transfer-encoding", "chunked")],
        "te_trailers": [("te", "trailers")], "te_gzip": [("te", "gzip")],
        "uppercase_header": [("X-Foo", "bar")], "header_nul": [("x-foo", "a\x00b")],
        "header_leading_space": [("x-foo", " bar")], "header_trailing_space": [("x-foo", "bar ")],
        "cl_plus": [("content-length", "+0")], "cl_negative": [("content-length", "-1")],
        "duplicate_cl": [("content-length", "0"), ("content-length", "0")],
        "cl_nonzero_ended": [("content-length", "1")],
        "expect_unknown": [("expect", "other")], "expect_empty": [("expect", "")],
        "expect_list": [("expect", ", 100-continue,")],
        "expect_duplicate_unknown": [("expect", "100-continue"), ("expect", "other")],
    }.items():
        add(name, extra=extra)
    for name, value in {
        "empty_path": "", "relative_path": "relative", "absolute_path": "https://localhost/",
        "asterisk_get": "*", "path_fragment": "/#fragment", "path_invalid_percent": "/%GG",
        "path_nul": "/\x00", "query_only_path": "?query", "query_only_empty": "?",
    }.items():
        add(name, fields=[(key, value if key == ":path" else old) for key, old in base])
    for key in (":method", ":scheme", ":authority", ":path"):
        add("missing_" + key[1:], fields=[field for field in base if field[0] != key])
    add("host_without_authority", fields=[field for field in base if field[0] != ":authority"],
        extra=[("host", "localhost")])
    upload = [(key, "POST" if key == ":method" else "/echo" if key == ":path" else value) for key, value in base]
    add("fixed_body", fields=upload, extra=[("content-length", "3")], body="abc")
    add("cl_short_body", fields=upload, extra=[("content-length", "5")], body="abc")
    add("cl_long_body", fields=upload, extra=[("content-length", "2")], body="abc")
    for name, value in (("continue", "100-continue"), ("list", ", 100-continue,"), ("empty", "")):
        add("upload_expect_" + name, fields=upload, extra=[("expect", value)], body="abc")
    for name in ("x-checksum", "authorization", "content-length", "host"):
        add("trailer_" + name, fields=upload, body="abc", trailers=[(name, "0")])
    return result


def probe(port, context, case):
    result = {"statuses": [], "body": "", "reset": None, "ended": False, "neighbor": None}
    config = H2Configuration(client_side=True, header_encoding="utf-8",
                             validate_outbound_headers=False, normalize_outbound_headers=False)
    connection = H2Connection(config=config)
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2) as raw, \
             context.wrap_socket(raw, server_hostname="localhost") as client:
            if client.selected_alpn_protocol() != "h2":
                raise RuntimeError("HTTP/2 was not negotiated")
            connection.initiate_connection()
            connection.send_headers(1, case["fields"], end_stream=case["body"] is None)
            if case["body"] is not None:
                connection.send_data(1, case["body"].encode(), end_stream=case["trailers"] is None)
            if case["trailers"] is not None:
                connection.send_headers(1, case["trailers"], end_stream=True)
            client.sendall(connection.data_to_send())
            waiting = 1
            while True:
                data = client.recv(65536)
                if not data:
                    result["terminal"] = "eof"
                    return result
                complete = False
                for event in connection.receive_data(data):
                    if isinstance(event, ConnectionTerminated):
                        result["goaway"] = int(event.error_code)
                        return result
                    if isinstance(event, (ResponseReceived, InformationalResponseReceived)):
                        status = int(dict(event.headers)[":status"])
                        if event.stream_id == 1:
                            result["statuses"].append(status)
                        else:
                            result["neighbor"] = status
                    if isinstance(event, DataReceived):
                        connection.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                        if event.stream_id == 1:
                            result["body"] += event.data.decode("latin1")
                    if isinstance(event, (StreamEnded, StreamReset)) and event.stream_id == waiting:
                        complete = True
                        if waiting == 1:
                            if isinstance(event, StreamReset):
                                result["reset"] = int(event.error_code)
                            else:
                                result["ended"] = True
                if complete:
                    if waiting == 3:
                        return result
                    waiting = 3
                    connection.send_headers(3, [(":method", "GET"), (":scheme", "https"),
                                               (":authority", "localhost"), (":path", "/")], end_stream=True)
                client.sendall(connection.data_to_send())
    except (OSError, EOFError) as error:
        result["terminal"] = type(error).__name__
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--filter", default="")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    results = {"versions": {name: subprocess.check_output(command, text=True).strip() for name, command in {
        "node": ["node", "--version"], "go": ["go", "version"], "zig": ["zig", "version"],
    }.items()}, "cases": []}
    with tempfile.TemporaryDirectory(prefix="zhtps-http2-") as temporary:
        path = Path(temporary)
        key, cert = path / "key.pem", path / "cert.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"], check=True, capture_output=True)
        context = ssl.create_default_context(cafile=str(cert))
        context.set_alpn_protocols(["h2"])
        go_binary = str(path / "go-server")
        subprocess.run(["go", "build", "-o", go_binary, str(directory / "reference_http1.go")], check=True,
                       env={**os.environ, "GOCACHE": str(path / "go-cache")})
        with reference(["node", str(directory / "reference_http2.cjs"), str(cert), str(key)]) as node_port, \
             reference([go_binary, str(cert), str(key)]) as go_port, \
             wire.Running("--tls-certificate", str(cert), "--tls-key", str(key)) as zhtps:
            for case in cases():
                if args.filter not in case["name"]:
                    continue
                row = dict(case)
                for name, port in (("node", node_port), ("go", go_port), ("zhtps", zhtps.port)):
                    row[name] = probe(port, context, case)
                results["cases"].append(row)
                print(case["name"], *[f"{name}={row[name]}" for name in ("zhtps", "node", "go")], flush=True)
                args.output.write_text(json.dumps(results, indent=2) + "\n")
                if zhtps.process.poll() is not None:
                    raise RuntimeError("ZHTPS exited during comparison: " + b"".join(zhtps.lines).decode(errors="replace"))


if __name__ == "__main__":
    main()
