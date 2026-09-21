"""Compare HTTP/2 control frames and HPACK over real TLS connections.

zig build install-response-fixture
python tests/http2_control_comparison.py zig-out/bin/tls-application --output /tmp/h2-control.json
Requires requirements-http2.txt, Node, Go and OpenSSL. Raw frames bypass client validation.
"""

import argparse
import collections
import contextlib
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import ssl
import struct
import subprocess
import tempfile
import time

from hpack import Decoder, Encoder

import wire


PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
NEIGHBOR = 1001


def frame(kind, stream=0, payload=b"", flags=0):
    return len(payload).to_bytes(3, "big") + bytes((kind, flags)) + stream.to_bytes(4, "big") + payload


def u32(number):
    return number.to_bytes(4, "big")


def setting(code, value):
    return struct.pack("!HI", code, value)


def block(path="/metadata", *, upload=False):
    fields = [(":method", "POST" if upload else "GET"), (":scheme", "https"),
              (":authority", "localhost"), (":path", path)]
    if upload:
        fields.append(("content-length", "3"))
    # No dynamic-table references between requests, including after a rejected block.
    return Encoder().encode(fields)


def headers(stream, path="/metadata", *, upload=False):
    return frame(1, stream, block(path, upload=upload), flags=4 if upload else 5)


def cases():
    result = []

    def add(name, payload, *, subject=False):
        result.append({"name": name, "payload": payload, "subject": subject})

    for name, payload in {
        "ping-valid": frame(6, payload=b"12345678"),
        "ping-short": frame(6, payload=b"1234567"),
        "ping-long": frame(6, payload=b"123456789"),
        "ping-stream": frame(6, 3, b"12345678"),
        "ping-unsolicited-ack": frame(6, payload=b"12345678", flags=1),
        "settings-stream": frame(4, 3),
        "settings-invalid-length": frame(4, payload=b"x"),
        "settings-ack-payload": frame(4, payload=setting(1, 0), flags=1),
        "settings-invalid-push": frame(4, payload=setting(2, 2)),
        "settings-window-overflow": frame(4, payload=setting(4, 0x80000000)),
        "settings-frame-too-small": frame(4, payload=setting(5, 16383)),
        "settings-frame-too-large": frame(4, payload=setting(5, 16777216)),
        "settings-unknown": frame(4, payload=setting(0xFF, 7)),
        "settings-duplicate": frame(4, payload=setting(3, 0) + setting(3, 10)),
        "settings-extra-ack": frame(4, flags=1),
        "window-zero-connection": frame(8, payload=u32(0)),
        "window-overflow-connection": frame(8, payload=u32(0x7FFFFFFF)),
        "window-short": frame(8, payload=b"abc"),
        "window-idle-stream": frame(8, 99, u32(1)),
        "rst-connection": frame(3, payload=u32(8)),
        "rst-idle-stream": frame(3, 99, u32(8)),
        "rst-short": frame(3, 3, b"abc"),
        "priority-connection": frame(2, payload=u32(0) + b"\x00"),
        "priority-short": frame(2, 3, u32(0)),
        "priority-idle": frame(2, 99, u32(0) + b"\x00"),
        "headers-zero-stream": frame(1, payload=block(), flags=5),
        "headers-even-stream": headers(2),
        "headers-bad-padding": frame(1, 3, b"\xff" + block(), flags=13),
        "headers-missing-pad-length": frame(1, 3, flags=13),
        "headers-short-priority": frame(1, 3, b"abc", flags=37),
        "headers-self-priority": frame(1, 3, u32(3) + b"\x00" + block(), flags=37),
        "data-zero-stream": frame(0, payload=b"abc"),
        "data-idle-stream": frame(0, 99, b"abc"),
        "data-after-end": headers(3) + frame(0, 3, b"abc", flags=1),
        "goaway-stream": frame(7, 3, u32(0) + u32(0)),
        "goaway-short": frame(7, payload=b"\x00" * 7),
        "goaway-normal": frame(7, payload=u32(0) + u32(0)),
        "client-push-promise": frame(5, 1, u32(2) + block(), flags=4),
        "continuation-without-head": frame(9, 3, block(), flags=4),
        "continuation-wrong-stream": frame(1, 3, block(), flags=1) + frame(9, 5, flags=4),
        "continuation-interleaved-ping": frame(1, 3, block(), flags=1) + frame(6, payload=b"12345678") + frame(9, 3, flags=4),
        "continuation-interleaved-unknown": frame(1, 3, block(), flags=1) + frame(0xFF) + frame(9, 3, flags=4),
        "unknown-connection-frame": frame(0xFF, payload=b"abc"),
        "unknown-stream-frame": frame(0xFF, 3, b"abc"),
        "unknown-frame-16385": frame(0xFF, payload=b"x" * 16385),
        "reserved-stream-bit": frame(1, 0x80000003, block(), flags=5),
    }.items():
        add(name, payload)
    for name, payload in {
        "window-zero-stream": frame(8, 3, u32(0)),
        "window-overflow-stream": frame(8, 3, u32(0x7FFFFFFF)),
        "rst-cancel-stream": frame(3, 3, u32(8)),
        "rst-unknown-code": frame(3, 3, u32(0xFFFFFFFF)),
        "priority-self": frame(2, 3, u32(3) + b"\x00"),
        "data-bad-padding": frame(0, 3, b"\xffabc", flags=8),
        "data-missing-pad-length": frame(0, 3, flags=8),
        "data-frame-16385": frame(0, 3, b"x" * 16385),
    }.items():
        add(name, payload, subject=True)
    for count in (1, 8, 9, 32):
        add(f"continuation-count-{count}", frame(1, 3, block(), flags=1) +
            b"".join(frame(9, 3, flags=4 if i == count - 1 else 0) for i in range(count)))
    for name, payload in {
        "index-zero": b"\x80", "index-absent": b"\xff\x00", "truncated-integer": b"\xff",
        "table-update-after-field": b"\x82\x20" + block(),
        "truncated-string": b"\x00\x05a", "invalid-huffman": b"\x00\x81\xff\x00",
    }.items():
        add("hpack-" + name, frame(1, 3, payload, flags=5))
    encoder = Encoder()
    encoder.header_table_size = 65536
    add("hpack-table-too-large", frame(1, 3, encoder.encode([(":method", "GET")]), flags=5))
    for count in (127, 129):
        add(f"ping-burst-{count}", frame(6, payload=b"12345678") * count)
        add(f"settings-burst-{count}", frame(4) * count)
    add("reset-burst-110", b"".join(headers(stream, "/lifecycle-echo", upload=True) +
                                   frame(3, stream, u32(8)) for stream in range(3, 223, 2)))
    result.append({"name": "unknown-frame-over-advertised-max", "payload": b"", "subject": False,
                   "exceed_advertised_frame": True})
    for name in ("zero-window-resume", "zero-window-deadline", "stream-stall-neighbor",
                 "connection-stall-recovery", "settings-window-reduction"):
        result.append({"name": "flow-" + name, "flow": name, "payload": b"", "subject": False})
    for name in ("upload", "producer"):
        result.append({"name": "fatal-with-waiting-" + name, "fatal_waiting": name,
                       "payload": frame(6, payload=b"1234567"), "subject": False})
    return result


class Client:
    def __init__(self, port, context, window=65535):
        raw = socket.create_connection(("127.0.0.1", port), timeout=1)
        try:
            self.socket = context.wrap_socket(raw, server_hostname="localhost")
        except BaseException:
            raw.close()
            raise
        if self.socket.selected_alpn_protocol() != "h2":
            self.socket.close()
            raise RuntimeError("HTTP/2 was not negotiated")
        self.buffer = b""
        self.decoder = Decoder()
        self.blocks = {}
        self.responses = {}
        self.goaways = []
        self.counts = collections.Counter()
        self.settings = {}
        self.ping_acks = []
        self.terminal = None
        self.windows = collections.Counter()
        self.socket.sendall(PREFACE + frame(4, payload=setting(4, window)))
        self.observe(.8, lambda: self.counts["settings_ack"] > 0 and bool(self.settings))

    def response(self, stream):
        return self.responses.setdefault(str(stream), {"statuses": [], "body_bytes": 0,
                                                      "prefix": "", "ended": False, "reset": None,
                                                      "reset_codes": []})

    def process(self, kind, stream, flags, payload):
        self.counts[str(kind)] += 1
        if kind == 4:
            if flags & 1:
                self.counts["settings_ack"] += 1
            else:
                for offset in range(0, len(payload), 6):
                    code, value = struct.unpack("!HI", payload[offset:offset + 6])
                    self.settings[str(code)] = value
                self.socket.sendall(frame(4, flags=1))
        elif kind == 6:
            if flags & 1:
                self.ping_acks.append(payload.hex())
            else:
                self.socket.sendall(frame(6, payload=payload, flags=1))
        elif kind == 7:
            self.goaways.append({"last_stream": int.from_bytes(payload[:4], "big") & 0x7FFFFFFF,
                                 "code": int.from_bytes(payload[4:8], "big"),
                                 "debug": payload[8:264].decode("latin1")})
        elif kind == 8:
            self.windows[str(stream)] += int.from_bytes(payload, "big") & 0x7FFFFFFF
        elif kind == 3:
            response = self.response(stream)
            code = int.from_bytes(payload, "big")
            response["reset_codes"].append(code)
            if response["reset"] is None:
                response["reset"] = code
        elif kind in (1, 9):
            response = self.response(stream)
            if kind == 1:
                if flags & 8:
                    payload = payload[1:len(payload) - payload[0]]
                if flags & 32:
                    payload = payload[5:]
                self.blocks[stream] = [bytearray(), bool(flags & 1)]
            pending, ending = self.blocks[stream]
            pending.extend(payload)
            if flags & 4:
                fields = dict(self.decoder.decode(bytes(pending)))
                if ":status" in fields:
                    response["statuses"].append(int(fields[":status"]))
                response["ended"] = response["ended"] or ending
                del self.blocks[stream]
        elif kind == 0:
            response = self.response(stream)
            if flags & 8:
                payload = payload[1:len(payload) - payload[0]]
            response["body_bytes"] += len(payload)
            response["prefix"] += payload[:max(0, 64 - len(response["prefix"]))].decode("latin1")
            response["ended"] = response["ended"] or bool(flags & 1)

    def observe(self, seconds, done=lambda: False):
        deadline = time.monotonic() + seconds
        while not self.terminal:
            while len(self.buffer) >= 9:
                size = int.from_bytes(self.buffer[:3], "big") + 9
                if size > 1024 * 1024:
                    raise RuntimeError("response frame exceeds observation budget")
                if len(self.buffer) < size:
                    break
                kind, flags = self.buffer[3:5]
                stream = int.from_bytes(self.buffer[5:9], "big") & 0x7FFFFFFF
                payload, self.buffer = self.buffer[9:size], self.buffer[size:]
                try:
                    self.process(kind, stream, flags, payload)
                except OSError as error:
                    self.terminal = type(error).__name__
                    return
            if done() or time.monotonic() >= deadline:
                return
            self.socket.settimeout(max(.001, deadline - time.monotonic()))
            try:
                part = self.socket.recv(65536)
            except TimeoutError:
                return
            except OSError as error:
                self.terminal = type(error).__name__
                return
            if not part:
                self.terminal = "eof"
                return
            self.buffer += part

    def ended(self, stream):
        return self.response(stream)["ended"] or self.response(stream)["reset"] is not None

    def summary(self):
        return {"responses": self.responses, "goaways": self.goaways, "terminal": self.terminal,
                "frames": dict(self.counts), "settings": self.settings,
                "window_updates": dict(self.windows), "ping_ack_count": len(self.ping_acks)}

    def close(self):
        self.socket.close()


@contextlib.contextmanager
def server(implementation, commands, cert, key):
    if implementation == "zhtps":
        with wire.Running("--tls-certificate", str(cert), "--tls-key", str(key),
                          "--header-timeout-ms", "2000", "--body-timeout-ms", "2000",
                          "--write-timeout-ms", "300") as running:
            yield running.port, running.process, lambda: b"".join(running.lines).decode(errors="replace")
    else:
        with tempfile.TemporaryFile() as logs:
            process = subprocess.Popen([*commands[implementation], str(cert), str(key)],
                                       stdout=subprocess.PIPE, stderr=logs)
            try:
                if not select.select([process.stdout], [], [], 5)[0]:
                    raise RuntimeError("reference did not start")
                port = int(process.stdout.readline())
                yield port, process, lambda: os.pread(logs.fileno(), 65536, 0).decode(errors="replace")
            finally:
                process.terminate()
                process.wait(timeout=3)
                process.stdout.close()


def probe(port, context, case):
    with contextlib.closing(Client(port, context)) as client:
        client.socket.sendall(headers(1, "/lifecycle-echo", upload=True) + frame(6, payload=b"prepared"))
        client.observe(.8, lambda: b"prepared".hex() in client.ping_acks)
        if b"prepared".hex() not in client.ping_acks:
            raise RuntimeError("active upload was not synchronized")
        payload = case["payload"]
        if case.get("exceed_advertised_frame"):
            limit = client.settings.get("5", 16384)
            if limit > 1024 * 1024:
                raise RuntimeError("peer frame limit exceeds this probe's budget")
            payload = frame(0xFF, payload=b"x" * (limit + 1))
        if case["subject"]:
            payload = headers(3, "/lifecycle-echo", upload=True) + payload
        payload += frame(6, payload=b"observed") + headers(NEIGHBOR) + frame(0, 1, b"abc", flags=1)
        # Do not send more DATA on the malformed subject: a second error after its
        # reset could obscure the first error's stream-versus-connection decision.
        try:
            client.socket.sendall(payload)
        except OSError as error:
            client.terminal = type(error).__name__
        client.observe(.8, lambda: bool(client.goaways) or
                       (client.ended(1) and client.ended(NEIGHBOR) and b"observed".hex() in client.ping_acks))
        client.observe(.03)
        result = client.summary()
    with contextlib.closing(Client(port, context)) as recovery:
        recovery.socket.sendall(headers(1))
        recovery.observe(.8, lambda: recovery.ended(1))
        result["fresh_connection"] = recovery.response(1)
    return result


def probe_flow(port, context, name):
    window = 0 if name.startswith("zero-window") else 65535 if name.startswith("connection") else 1024
    observations = {}
    with contextlib.closing(Client(port, context, window=window)) as client:
        client.socket.sendall(headers(1, "/large"))
        target = window
        client.observe(.15, lambda: bool(client.response(1)["statuses"]) and
                       client.response(1)["body_bytes"] >= target)
        observations["initial_body_bytes"] = client.response(1)["body_bytes"]
        client.socket.sendall(headers(3))
        if name.startswith("zero-window"):
            client.socket.sendall(frame(8, 3, u32(1024)))
        if name == "connection-stall-recovery":
            client.observe(.08)
            observations["neighbor_before_credit"] = dict(client.response(3))
            client.socket.sendall(frame(3, 1, u32(8)) + frame(8, payload=u32(65535)))
        client.observe(.2, lambda: client.ended(3))
        observations["neighbor_completed_while_large_stalled"] = client.response(3)["ended"]
        if name == "zero-window-resume":
            client.socket.sendall(frame(8, 1, u32(1024)))
            client.observe(.15, lambda: client.response(1)["body_bytes"] >= 1024)
            observations["body_after_credit"] = client.response(1)["body_bytes"]
        elif name == "zero-window-deadline":
            # ZHTPS has an explicit 300 ms stream write deadline; references use
            # native defaults. Pending reference streams are canceled below.
            client.observe(.6, lambda: client.ended(1))
            observations["large_after_deadline"] = dict(client.response(1))
        elif name == "settings-window-reduction":
            client.socket.sendall(frame(4, payload=setting(4, 0)) + frame(8, 1, u32(1024)))
            client.observe(.06)
            observations["body_at_zero_credit"] = client.response(1)["body_bytes"]
            client.socket.sendall(frame(8, 1, u32(1)))
            client.observe(.1, lambda: client.response(1)["body_bytes"] > 1024)
            observations["body_after_one_byte_credit"] = client.response(1)["body_bytes"]
        if name != "connection-stall-recovery" and not client.ended(1):
            client.socket.sendall(frame(3, 1, u32(8)))
        client.socket.sendall(headers(5, "/lifecycle-echo", upload=True) +
                              frame(8, 5, u32(1024)) + frame(0, 5, b"abc", flags=1))
        client.observe(.6, lambda: client.ended(5))
        result = client.summary()
        result["observations"] = observations
    with contextlib.closing(Client(port, context)) as recovery:
        recovery.socket.sendall(headers(1))
        recovery.observe(.8, lambda: recovery.ended(1))
        result["fresh_connection"] = recovery.response(1)
    return result


def probe_fatal(port, context, case):
    with contextlib.closing(Client(port, context)) as client:
        producer = case["fatal_waiting"] == "producer"
        client.socket.sendall(headers(1, "/stream-cancel" if producer else "/lifecycle-echo",
                                      upload=not producer) + frame(6, payload=b"prepared"))
        client.observe(.8, lambda: b"prepared".hex() in client.ping_acks and
                       (not producer or client.response(1)["body_bytes"] > 0))
        if b"prepared".hex() not in client.ping_acks or (producer and client.response(1)["body_bytes"] == 0):
            raise RuntimeError("waiting stream was not established")
        started = time.monotonic()
        client.socket.sendall(case["payload"])
        client.observe(1.4)
        result = client.summary()
        result["after_error_ms"] = round((time.monotonic() - started) * 1000)
        # Keep the failed connection open while querying cleanup. Closing it here
        # would mask a server that needs the client to release aborted work.
        with contextlib.closing(Client(port, context)) as recovery:
            recovery.socket.sendall(headers(1))
            recovery.observe(.8, lambda: recovery.ended(1))
            result["fresh_connection"] = recovery.response(1)
            if producer:
                recovery.socket.sendall(headers(3, "/inspect"))
                recovery.observe(.8, lambda: recovery.ended(3))
                result["cleanup_before_client_close"] = json.loads(recovery.response(3)["prefix"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--filter", default="")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    results = {"versions": {name: subprocess.check_output(command, text=True).strip() for name, command in {
        "zig": ["zig", "version"], "node": ["node", "--version"], "go": ["go", "version"],
    }.items()}, "fixture_sha256": hashlib.sha256(Path(wire.BINARY).read_bytes()).hexdigest(), "cases": []}
    with tempfile.TemporaryDirectory(prefix="zhtps-h2-control-") as temporary:
        path = Path(temporary)
        cert, key = path / "cert.pem", path / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"], check=True, capture_output=True)
        context = ssl.create_default_context(cafile=str(cert))
        context.set_alpn_protocols(["h2"])
        go_binary = str(path / "go-server")
        subprocess.run(["go", "build", "-o", go_binary, str(directory / "reference_http2_control.go")],
                       check=True, env={**os.environ, "GOCACHE": "/tmp/zhtps-h2-control-go-cache"})
        commands = {"node": ["node", str(directory / "reference_http2_control.cjs")], "go": [go_binary]}
        for case in cases():
            if args.filter not in case["name"]:
                continue
            row = {key: value for key, value in case.items() if key != "payload"}
            row["payload_hex"] = case["payload"].hex()
            for implementation in ("zhtps", "node", "go"):
                with server(implementation, commands, cert, key) as (port, process, diagnostics):
                    if "fatal_waiting" in case:
                        row[implementation] = probe_fatal(port, context, case)
                    elif "flow" in case:
                        row[implementation] = probe_flow(port, context, case["flow"])
                    else:
                        row[implementation] = probe(port, context, case)
                    row[implementation]["exit_code"] = process.poll()
                    row[implementation]["diagnostics"] = diagnostics()
            results["cases"].append(row)
            print(case["name"], *[f"{n}: goaway={[g['code'] for g in row[n]['goaways']]} "
                  f"subject={row[n]['responses'].get('3')} neighbor={row[n]['responses'].get(str(NEIGHBOR))}"
                  for n in ("zhtps", "node", "go")], flush=True)
            args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
