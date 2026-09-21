"""Compare response completion and failure isolation; requires requirements-http2.txt.

zig build install-response-fixture
python tests/response_comparison.py zig-out/bin/tls-application --output /tmp/responses.json
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import resource
import re
import select
import socket
import ssl
import subprocess
import tempfile

from hpack import Decoder, Encoder
from hyperframe.frame import HeadersFrame, SettingsFrame

import wire


NAMES = (
    "fixed", "empty", "status-204", "status-205", "status-304", "body-204", "body-205",
    "status-99", "status-600", "status-103", "duplicate-cookie", "empty-field",
    "invalid-name", "invalid-value", "nul-value", "whitespace-value", "stream", "stream-empty",
    "stream-short", "stream-long", "stream-exact", "stream-error-before", "stream-error-after",
    "stream-error-exact", "stream-trailer", "handler-error", "panic-before", "panic-after",
)


class Reader:
    def __init__(self, client):
        self.client = client
        self.buffer = b""
        self.raw = bytearray()

    def receive(self):
        part = self.client.recv(65536)
        if not part:
            raise EOFError()
        self.raw.extend(part)
        if len(self.raw) > 1024 * 1024:
            raise ValueError("response exceeded the probe budget")
        self.buffer += part

    def take(self, count):
        while len(self.buffer) < count:
            self.receive()
        part, self.buffer = self.buffer[:count], self.buffer[count:]
        return part

    def line(self):
        while b"\r\n" not in self.buffer:
            self.receive()
        part, self.buffer = self.buffer.split(b"\r\n", 1)
        return part


def empty_response():
    return dict(statuses=[], headers=[], body="", complete=False, reset=None)


def response_problems(response, method, protocol):
    """Separate an observed message boundary from semantic/framing correctness."""
    problems = []
    final = [status for status in response["statuses"] if status >= 200]
    if response["complete"] and len(final) != 1:
        problems.append("no unique final status")
    if any(status < 100 or status > 599 for status in response["statuses"]):
        problems.append("status outside 100..599")
    fields = dict(response["headers"])
    for name, value in response["headers"]:
        if name == ":status":
            continue
        if re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) is None:
            problems.append("invalid field name")
        if any((ord(byte) < 32 and byte != "\t") or ord(byte) == 127 for byte in value):
            problems.append("invalid field value")
        if protocol == "h2" and value != value.strip(" \t"):
            problems.append("HTTP/2 field edge whitespace")
    if final and final[-1] in (204, 205, 304) and response["body"]:
        problems.append("body on bodyless status")
    if response["complete"] and "content-length" in fields and method != "HEAD" and final != [304]:
        if int(fields["content-length"]) != len(response["body"].encode("latin1")):
            problems.append("declared length does not match body")
    return problems


def read_http1(reader, response, method):
    while True:
        line = reader.line()
        if not line.startswith(b"HTTP/"):
            raise ValueError("invalid status line: " + repr(line))
        status = int(line.split()[1])
        response["statuses"].append(status)
        headers = []
        while line := reader.line():
            name, value = line.split(b":", 1)
            headers.append([name.decode("latin1").lower(), value.strip().decode("latin1")])
        if status >= 200:
            break
    response["headers"] = headers
    framing = dict(headers)
    if method == "HEAD" or status in (204, 304):
        response["complete"] = True
        return
    if framing.get("transfer-encoding") == "chunked":
        while True:
            size = int(reader.line().split(b";", 1)[0], 16)
            if size == 0:
                response["trailers"] = []
                while line := reader.line():
                    response["trailers"].append(line.decode("latin1"))
                break
            response["body"] += reader.take(size).decode("latin1")
            if reader.take(2) != b"\r\n":
                raise ValueError("invalid chunk terminator")
    elif "content-length" in framing:
        # Retain a truncated prefix when a declared body is not completed.
        remaining = int(framing["content-length"])
        while remaining:
            if not reader.buffer:
                reader.receive()
            count = min(remaining, len(reader.buffer))
            response["body"] += reader.take(count).decode("latin1")
            remaining -= count
    else:
        while True:
            response["body"] += reader.buffer.decode("latin1")
            reader.buffer = b""
            try:
                reader.receive()
            except EOFError:
                break
    response["complete"] = True


def read_http2(reader, decoder, response, stream):
    block = bytearray()
    ending = False
    while True:
        head = reader.take(9)
        length = int.from_bytes(head[:3], "big")
        kind, flags = head[3:5]
        stream_id = int.from_bytes(head[5:], "big") & 0x7fffffff
        payload = reader.take(length)
        if kind == 4 and not flags & 1:
            ack = SettingsFrame(0)
            ack.flags.add("ACK")
            reader.client.sendall(ack.serialize())
        elif kind == 7:
            response["goaway"] = int.from_bytes(payload[4:8], "big")
            return
        elif stream_id == stream:
            if kind in (1, 9):
                if kind == 1:
                    ending = bool(flags & 1)
                    if flags & 8:
                        padding = payload[0]
                        payload = payload[1:len(payload) - padding]
                    if flags & 32:
                        payload = payload[5:]
                block.extend(payload)
                if flags & 4:
                    fields = [list(field) for field in decoder.decode(bytes(block))]
                    block.clear()
                    status = dict(fields).get(":status")
                    if status is not None:
                        response["statuses"].append(int(status))
                        if int(status) >= 200:
                            response["headers"] = fields
                    else:
                        response["trailers"] = fields
                    if ending:
                        response["complete"] = True
                        return
            elif kind == 0:
                if flags & 8:
                    padding = payload[0]
                    payload = payload[1:len(payload) - padding]
                response["body"] += payload.decode("latin1")
                if flags & 1:
                    response["complete"] = True
                    return
            elif kind == 3:
                response["reset"] = int.from_bytes(payload, "big")
                return


def probe(port, context, protocol, name, method):
    result = {"response": empty_response(), "neighbor": empty_response()}
    with socket.create_connection(("127.0.0.1", port), timeout=1) as raw:
        with contextlib.ExitStack() as stack:
            client = raw
            if protocol == "h2":
                client = stack.enter_context(context.wrap_socket(raw, server_hostname="localhost"))
                if client.selected_alpn_protocol() != "h2":
                    raise RuntimeError("HTTP/2 was not negotiated")
            reader = Reader(client)
            decoder, encoder = Decoder(), Encoder()
            for key, path, stream, verb in (("response", "/response-case?" + name, 1, method),
                                            ("neighbor", "/response-case?fixed", 3, "GET")):
                try:
                    if protocol == "h2":
                        if stream == 1:
                            client.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + SettingsFrame(0).serialize())
                        headers = HeadersFrame(stream)
                        headers.data = encoder.encode([(":method", verb), (":scheme", "https"),
                                                       (":authority", "localhost"), (":path", path)])
                        headers.flags.add("END_HEADERS")
                        headers.flags.add("END_STREAM")
                        client.sendall(headers.serialize())
                        read_http2(reader, decoder, result[key], stream)
                    else:
                        client.sendall(f"{verb} {path} HTTP/{protocol}\r\nHost: localhost\r\n\r\n".encode())
                        read_http1(reader, result[key], verb)
                except (OSError, EOFError, ValueError) as error:
                    result[key]["error"] = type(error).__name__ + (": " + str(error) if str(error) else "")
                    break
                if key == "response" and not result[key]["complete"] and result[key]["reset"] is None:
                    break
            if protocol != "h2":
                result["wire"] = reader.raw.decode("latin1")
    for key, verb in (("response", method), ("neighbor", "GET")):
        result[key]["problems"] = response_problems(result[key], verb, protocol)
    return result


def no_core_dumps():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


@contextlib.contextmanager
def server(name, commands, cert, key, protocol):
    if name == "zhtps":
        process = wire.Running(*(["--tls-certificate", str(cert), "--tls-key", str(key)] if protocol == "h2" else []))
        try:
            yield process.port, process.process, lambda: b"".join(process.lines).decode(errors="replace")
        finally:
            process.close()
    else:
        command = commands[name] + ([str(cert), str(key)] if protocol == "h2" else [])
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, preexec_fn=no_core_dumps)
            def diagnostics():
                errors.seek(0)
                return errors.read().decode(errors="replace")
            try:
                if not select.select([process.stdout], [], [], 10)[0]:
                    raise RuntimeError("reference startup timeout: " + diagnostics())
                line = process.stdout.readline()
                if not line:
                    raise RuntimeError("reference startup failed: " + diagnostics())
                yield int(line), process, diagnostics
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--filter", default="")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    no_core_dumps()
    results = {"versions": {name: subprocess.check_output(command, text=True).strip() for name, command in {
        "zig": ["zig", "version"], "node": ["node", "--version"], "go": ["go", "version"],
    }.items()}, "fixture_sha256": hashlib.sha256(Path(wire.BINARY).read_bytes()).hexdigest(), "cases": []}
    with tempfile.TemporaryDirectory(prefix="zhtps-response-") as temporary:
        path = Path(temporary)
        cert, key = path / "cert.pem", path / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"], check=True, capture_output=True)
        context = ssl.create_default_context(cafile=str(cert))
        context.set_alpn_protocols(["h2"])
        go_binary = str(path / "go-server")
        subprocess.run(["go", "build", "-o", go_binary, str(directory / "reference_response.go")], check=True,
                       env={**os.environ, "GOCACHE": str(path / "go-cache")})
        commands = {"node": ["node", str(directory / "reference_response.cjs")], "go": [go_binary]}
        for protocol in ("1.0", "1.1", "h2"):
            cases = [(name, "GET") for name in NAMES] + [("fixed", "HEAD"), ("stream", "HEAD")]
            for name, method in cases:
                label = f"{protocol}/{method}/{name}"
                if args.filter not in label:
                    continue
                row = dict(protocol=protocol, name=name, method=method)
                for implementation in ("zhtps", "node", "go"):
                    with server(implementation, commands, cert, key, protocol) as (port, process, diagnostics):
                        value = probe(port, context, protocol, name, method)
                        if name.startswith("panic"):
                            # EOF can precede process exit; wait only on these intentional crash probes.
                            try:
                                process.wait(timeout=.2)
                            except subprocess.TimeoutExpired:
                                pass
                        value["exit_code"] = process.poll()
                        try:
                            recovery = probe(port, context, protocol, "fixed", "GET")["response"]
                            value["fresh_connection"] = recovery
                        except OSError as error:
                            value["fresh_connection"] = {"error": type(error).__name__}
                        value["diagnostics"] = diagnostics()
                        row[implementation] = value
                results["cases"].append(row)
                print(label, *[f"{n}={row[n]['response']['statuses']} complete={row[n]['response']['complete']} "
                               f"reset={row[n]['response']['reset']} neighbor={row[n]['neighbor']['statuses']} "
                               f"exit={row[n]['exit_code']}" for n in ("zhtps", "node", "go")], flush=True)
                args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
