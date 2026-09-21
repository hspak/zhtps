"""Record raw HTTP/1 edge cases against ZHTPS, Node and Go; stdlib only.

This is a differential experiment, not an oracle: disagreements require review.
Run: python3 tests/http1_comparison.py zig-out/bin/zhtps --output /tmp/http1.json
"""

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile

import wire


def request(headers=b"", body=b"", line=b"GET / HTTP/1.1", host=b"Host: local\r\n"):
    return line + b"\r\n" + host + headers + b"Connection: close\r\n\r\n" + body


def cases():
    result = []

    def add(name, data, *, half_close=False, fragment=None):
        result.append(dict(name=name, request=data, half_close=half_close, fragment=fragment))

    add("ordinary_get", request())
    add("head", request(line=b"HEAD / HTTP/1.1"))
    for version in (b"1.0", b"1.9", b"2.0", b"0.9", b"01.1", b"1.10"):
        add("version_" + version.decode(), request(line=b"GET / HTTP/" + version))
    for name, line in {
        "tab_separator": b"GET\t/ HTTP/1.1", "double_space": b"GET  / HTTP/1.1",
        "lowercase_method": b"get / HTTP/1.1", "unknown_method": b"CUSTOM / HTTP/1.1",
        "invalid_method": b"G(ET / HTTP/1.1", "absolute_target": b"GET http://local/ HTTP/1.1",
        "https_on_cleartext": b"GET https://local/ HTTP/1.1", "bad_percent": b"GET /%GG HTTP/1.1",
        "fragment_in_target": b"GET /#x HTTP/1.1", "raw_non_ascii": b"GET /\xff HTTP/1.1",
        "connect": b"CONNECT local:443 HTTP/1.1", "asterisk_get": b"GET * HTTP/1.1",
    }.items():
        add(name, request(line=line))
    add("leading_crlf", b"\r\n" + request())
    add("nine_leading_crlf", b"\r\n" * 9 + request())
    add("bare_lf", request().replace(b"\r\n", b"\n"))
    for name, host in {
        "missing_host": b"", "empty_host": b"Host:\r\n", "duplicate_host": b"Host: a\r\nHost: b\r\n",
        "host_space": b"Host: a b\r\n", "host_bad_port": b"Host: local:xyz\r\n",
        "host_bad_ipv6": b"Host: [bad]\r\n", "host_userinfo": b"Host: a@b\r\n",
    }.items():
        add(name, request(host=host))
    for name, header in {
        "header_space_before_colon": b"Name : x\r\n", "obs_fold": b"Name: x\r\n y\r\n",
        "header_nul": b"Name: x\x00y\r\n", "header_del": b"Name: x\x7fy\r\n",
        "header_obs_text": b"Name: \xff\r\n", "empty_header_name": b": x\r\n",
        "duplicate_cl_equal": b"Content-Length: 0\r\nContent-Length: 0\r\n",
        "duplicate_cl_different": b"Content-Length: 0\r\nContent-Length: 1\r\n",
        "cl_list": b"Content-Length: 0, 0\r\n", "cl_plus": b"Content-Length: +0\r\n",
        "cl_negative": b"Content-Length: -1\r\n", "cl_hex": b"Content-Length: 0x0\r\n",
        "cl_leading_zero": b"Content-Length: 000\r\n", "cl_empty": b"Content-Length:\r\n",
        "cl_overflow": b"Content-Length: 18446744073709551616\r\n",
        "te_and_cl": b"Content-Length: 0\r\nTransfer-Encoding: chunked\r\n",
        "te_unsupported": b"Transfer-Encoding: gzip\r\n",
        "te_before_chunked": b"Transfer-Encoding: gzip, chunked\r\n",
        "te_after_chunked": b"Transfer-Encoding: chunked, gzip\r\n",
        "te_duplicate_chunked": b"Transfer-Encoding: chunked, chunked\r\n",
        "te_parameter": b"Transfer-Encoding: chunked;x=y\r\n",
        "te_empty": b"Transfer-Encoding:\r\n",
        "te_list_empty_members": b"Transfer-Encoding: , chunked,\r\n",
        "te_repeated_empty_field": b"Transfer-Encoding:\r\nTransfer-Encoding: chunked\r\n",
        "connection_invalid_token": b"Connection: cl ose\r\n",
        "expect_unknown": b"Expect: something\r\n", "expect_empty": b"Expect:\r\n",
    }.items():
        add(name, request(header, b"0\r\n\r\n" if b"Transfer-Encoding" in header else b""))
    for name, chunk in {
        "ordinary_chunk": b"3\r\nabc\r\n0\r\n\r\n",
        "chunk_extension": b"3;foo=bar\r\nabc\r\n0\r\n\r\n",
        "chunk_quoted_extension": b'3;foo="a\\\"b"\r\nabc\r\n0\r\n\r\n',
        "chunk_extension_whitespace": b"3 \t; foo = bar\r\nabc\r\n0\r\n\r\n",
        "chunk_trailing_whitespace": b"3 \r\nabc\r\n0\r\n\r\n",
        "chunk_plus": b"+3\r\nabc\r\n0\r\n\r\n", "chunk_hex_prefix": b"0x3\r\nabc\r\n0\r\n\r\n",
        "chunk_overflow": b"10000000000000000\r\n", "chunk_invalid_extension": b"3;=x\r\nabc\r\n0\r\n\r\n",
        "chunk_bare_lf": b"3\nabc\n0\n\n", "chunk_bad_delimiter": b"3\r\nabcXX0\r\n\r\n",
        "trailer": b"0\r\nX-Checksum: ok\r\n\r\n", "trailer_content_length": b"0\r\nContent-Length: 0\r\n\r\n",
        "trailer_authorization": b"0\r\nAuthorization: secret\r\n\r\n",
        "trailer_obs_fold": b"0\r\nX-Foo: x\r\n y\r\n\r\n",
    }.items():
        add(name, request(b"Transfer-Encoding: chunked\r\n", chunk, b"POST /echo HTTP/1.1"))
    for name, fields, body in (
        ("expect_continue", b"Content-Length: 3\r\nExpect: 100-continue\r\n", b"abc"),
        ("expect_list", b"Content-Length: 3\r\nExpect: , 100-continue,\r\n", b"abc"),
        ("expect_zero_body", b"Content-Length: 0\r\nExpect: 100-continue\r\n", b""),
        ("fixed_body", b"Content-Length: 3\r\n", b"abc"),
        ("unframed_post", b"", b""),
    ):
        add(name, request(fields, body, b"POST /echo HTTP/1.1"))
    for name, data in (
        ("truncated_head", b"GET / HTTP/1.1\r\nHost: loc"),
        ("truncated_fixed", request(b"Content-Length: 3\r\n", b"ab", b"POST /echo HTTP/1.1")),
        ("truncated_chunk", request(b"Transfer-Encoding: chunked\r\n", b"3\r\nab", b"POST /echo HTTP/1.1")),
        ("truncated_trailer", request(b"Transfer-Encoding: chunked\r\n", b"0\r\nX: y\r\n", b"POST /echo HTTP/1.1")),
        ("complete_half_close", request()),
    ):
        add(name, data, half_close=True)
    add("fragmented_chunk", request(b"Transfer-Encoding: chunked\r\n", b"3\r\nabc\r\n0\r\n\r\n",
                                    b"POST /echo HTTP/1.1"), fragment=1)
    add("pipeline", b"GET / HTTP/1.1\r\nHost: local\r\n\r\n" + request())
    add("pipeline_fixed_body", b"POST /echo HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\nabc" + request())
    add("pipeline_malformed_then_get", request(b"Content-Length: +0\r\n") + request())
    add("pipeline_close_then_get", request() + request())
    add("header_count_129", request(b"X: y\r\n" * 128))
    add("header_bytes_40k", request(b"X: " + b"a" * 40000 + b"\r\n"))
    add("target_bytes_9k", request(line=b"GET /" + b"a" * 9000 + b" HTTP/1.1"))
    return result


@contextlib.contextmanager
def reference(command):
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors)
        try:
            if not select.select([process.stdout], [], [], 10)[0]:
                raise RuntimeError(f"reference failed to start: {command}")
            line = process.stdout.readline()
            if not line:
                errors.seek(0)
                raise RuntimeError(errors.read().decode())
            yield int(line)
            if process.poll() is not None:
                raise RuntimeError(f"reference exited: {command}")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            process.stdout.close()


def probe(port, case):
    received = bytearray()
    with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
        client.settimeout(2)
        data = case["request"]
        terminal = "eof"
        try:
            size = case["fragment"] or len(data)
            for offset in range(0, len(data), size):
                client.sendall(data[offset:offset + size])
            if case["half_close"]:
                client.shutdown(socket.SHUT_WR)
            while part := client.recv(65536):
                received.extend(part)
                if len(received) > 1024 * 1024:
                    raise RuntimeError("unbounded response")
        except socket.timeout:
            terminal = "timeout"
        except (ConnectionResetError, BrokenPipeError):
            terminal = "reset"
    statuses = []
    # Walk framing rather than searching the payload for status-like bytes.
    stream = io.BytesIO(received)
    while line := stream.readline():
        if not line.startswith(b"HTTP/"):
            break
        statuses.append(int(line.split()[1]))
        headers = {}
        while (line := stream.readline()) not in (b"\r\n", b""):
            name, value = line.split(b":", 1)
            headers[name.lower()] = value.strip()
        if statuses[-1] < 200 or statuses[-1] in (204, 304) or case["name"] == "head":
            continue
        if headers.get(b"transfer-encoding") == b"chunked":
            while line := stream.readline():
                count = int(line.split(b";", 1)[0], 16)
                stream.read(count + 2)
                if count == 0:
                    break
        elif b"content-length" in headers:
            stream.read(int(headers[b"content-length"]))
        else:
            break
    return dict(statuses=statuses, terminal=terminal, wire=received.decode("latin1"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--filter", default="")
    args = parser.parse_args()
    selected = [case for case in cases() if args.filter in case["name"]]
    versions = {name: subprocess.check_output(command, text=True).strip() for name, command in {
        "node": ["node", "--version"], "go": ["go", "version"], "zig": ["zig", "version"],
    }.items()}
    results = {"versions": versions, "cases": []}
    directory = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="zhtps-http1-") as temporary:
        go_binary = str(Path(temporary) / "go-server")
        subprocess.run(["go", "build", "-o", go_binary, str(directory / "reference_http1.go")], check=True,
                       env={**os.environ, "GOCACHE": str(Path(temporary) / "go-cache")})
        with reference(["node", str(directory / "reference_http1.cjs")]) as node_port, \
             reference([go_binary]) as go_port, wire.Running() as zhtps:
            for case in selected:
                row = {"name": case["name"], "request": case["request"].decode("latin1"),
                       "half_close": case["half_close"], "fragment": case["fragment"]}
                for name, port in (("zhtps", zhtps.port), ("node", node_port), ("go", go_port)):
                    row[name] = probe(port, case)
                results["cases"].append(row)
                print(case["name"], *[f"{name}={row[name]['statuses']}/{row[name]['terminal']}"
                                       for name in ("zhtps", "node", "go")], flush=True)
                args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
