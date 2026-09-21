"""Compare HTTP/1 deadlines, unread bodies, cancellation and shutdown using real sockets.

zig build install-response-fixture
python3 tests/lifecycle_comparison.py zig-out/bin/tls-application --output /tmp/lifecycle.json

Uses Python's standard library plus native Node and Go fixtures. Timings are diagnostic,
not performance assertions. Read the accompanying audit for differences between APIs.
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import tempfile
import time

import wire


NAMES = (
    "idle-new", "idle-reused", "reuse-before-idle", "partial-request-line", "partial-header",
    "trickle-header", "fixed-body-stall", "trickle-fixed-body", "chunk-size-stall",
    "chunk-data-stall", "trailer-stall", "split-phase-budget", "pipeline-partial-header",
    "half-close-complete", "half-close-truncated", "half-close-pipeline", "half-close-delayed-response",
    "early-unread-stall", "early-fixed-pipeline", "early-chunked-pipeline", "early-expect",
    "slow-response-reader", "sustained-slow-response-reader", "reset-large-response",
    "reset-producer", "half-close-producer",
    "application-deadline", "shutdown-idle", "shutdown-body-complete",
    "shutdown-body-stall", "shutdown-producer", "shutdown-keepalive-reuse",
)


def request(path="/metadata", *, fields=b"", method="GET"):
    return f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n".encode() + fields + b"\r\n"


class Connection:
    def __init__(self, port, small_window=False):
        self.socket = socket.socket()
        if small_window:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        self.socket.settimeout(1.4)
        self.socket.connect(("127.0.0.1", port))
        self.buffer = b""
        self.responses = []
        self.terminal = None
        self.wire_bytes = 0
        self.started = time.monotonic()

    def receive(self):
        try:
            part = self.socket.recv(65536)
        except TimeoutError:
            self.terminal = "observation-timeout"
            raise
        except OSError:
            self.terminal = "reset"
            raise
        if not part:
            self.terminal = "eof"
            raise EOFError()
        self.wire_bytes += len(part)
        if self.wire_bytes > 9 * 1024 * 1024:
            raise ValueError("response exceeded probe budget")
        self.buffer += part

    def take(self, count):
        while len(self.buffer) < count:
            self.receive()
        result, self.buffer = self.buffer[:count], self.buffer[count:]
        return result

    def line(self):
        while b"\r\n" not in self.buffer:
            self.receive()
        result, self.buffer = self.buffer.split(b"\r\n", 1)
        return result

    def read_head(self):
        result = {"status": None, "headers": {}, "body_bytes": 0, "body_prefix": "", "complete": False}
        self.responses.append(result)
        result["status"] = int(self.line().split()[1])
        while line := self.line():
            name, value = line.split(b":", 1)
            result["headers"][name.decode("latin1").lower()] = value.strip().decode("latin1")
        result["headers"].pop("date", None)
        return result

    def body(self, result, count):
        while count:
            if not self.buffer:
                self.receive()
            part = self.take(min(count, len(self.buffer)))
            result["body_bytes"] += len(part)
            result["body_prefix"] += part[:max(0, 256 - len(result["body_prefix"]))].decode("latin1")
            count -= len(part)

    def chunks(self, result):
        while size := int(self.line().split(b";", 1)[0], 16):
            self.body(result, size)
            if self.take(2) != b"\r\n":
                raise ValueError("invalid chunk terminator")
        while self.line():
            pass

    def read(self):
        try:
            result = self.read_head()
            fields = result["headers"]
            if result["status"] < 200 or result["status"] in (204, 304):
                pass
            elif fields.get("transfer-encoding") == "chunked":
                self.chunks(result)
            elif "content-length" in fields:
                self.body(result, int(fields["content-length"]))
            else:
                # Native parser errors can use a response delimited by connection close.
                while True:
                    self.body(result, len(self.buffer))
                    try:
                        self.receive()
                    except EOFError:
                        break
            result["complete"] = True
        except (OSError, EOFError) as error:
            self.responses[-1]["error"] = type(error).__name__

    def finish(self):
        if self.terminal:
            return
        try:
            # Any remaining bytes are retained as an observation of unexpected output.
            while True:
                self.receive()
        except (OSError, EOFError):
            pass

    def summary(self):
        return {"responses": self.responses, "terminal": self.terminal,
                "elapsed_ms": round((time.monotonic() - self.started) * 1000),
                "wire_bytes": self.wire_bytes, "unparsed_prefix": self.buffer[:256].decode("latin1")}


class Server:
    def __init__(self, implementation, commands, reading):
        self.running = None
        self.logs = None
        if implementation == "zhtps":
            self.running = wire.Running(
                "--header-timeout-ms", str(reading), "--body-timeout-ms", str(reading),
                "--write-timeout-ms", "600", "--idle-timeout-ms", "300",
                "--shutdown-timeout-ms", "600", "--shutdown-keepalive-ms", "100",
            )
            self.port, self.process = self.running.port, self.running.process
        else:
            self.logs = tempfile.TemporaryFile()
            self.process = subprocess.Popen([*commands[implementation], str(reading)],
                                            stdout=subprocess.PIPE, stderr=self.logs)
            if not select.select([self.process.stdout], [], [], 5)[0]:
                self.close()
                raise RuntimeError("reference server did not start")
            self.port = int(self.process.stdout.readline())

    def diagnostics(self):
        if self.running:
            return b"".join(self.running.lines).decode(errors="replace")
        return os.pread(self.logs.fileno(), 65536, 0).decode(errors="replace")

    def shutdown(self):
        self.process.terminate()
        deadline = time.monotonic() + 1
        while "shutdown_started" not in self.diagnostics():
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("shutdown was not observed")
            time.sleep(.005)

    def close(self):
        if self.running:
            self.running.close()
        else:
            if self.process.poll() is None:
                self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                raise
            finally:
                self.process.stdout.close()
                self.logs.close()


def fetch(port, path):
    client = Connection(port)
    try:
        client.socket.sendall(request(path, fields=b"Connection: close\r\n"))
        client.read()
        return client.responses[-1]
    finally:
        client.socket.close()


def trickle(client, fragment):
    # Stop writing as soon as a timeout response or close is readable; late writes
    # after server close could otherwise replace an observable 408 with a TCP reset.
    for _ in range(9):
        if select.select([client.socket], [], [], .07)[0]:
            return
        client.socket.sendall(fragment)


def probe(server, name):
    client = Connection(server.port, small_window=name.endswith("slow-response-reader"))
    extra = {}
    fixed = request("/lifecycle-echo", method="POST", fields=b"Content-Length: 5\r\n")
    chunked = request("/lifecycle-echo", method="POST", fields=b"Transfer-Encoding: chunked\r\n")
    try:
        if name == "idle-new":
            pass
        elif name in ("idle-reused", "reuse-before-idle", "shutdown-idle", "shutdown-keepalive-reuse"):
            client.socket.sendall(request())
            client.read()
            if name.startswith("shutdown"):
                server.shutdown()
            if name in ("reuse-before-idle", "shutdown-keepalive-reuse"):
                time.sleep(.03 if name.startswith("shutdown") else .12)
                client.socket.sendall(request(fields=b"Connection: close\r\n"))
        elif name == "partial-request-line":
            client.socket.sendall(b"GET /meta")
        elif name in ("partial-header", "trickle-header"):
            client.socket.sendall(b"GET /metadata HTTP/1.1\r\nHost: local")
            if name == "trickle-header":
                trickle(client, b"a")
        elif name in ("fixed-body-stall", "trickle-fixed-body"):
            client.socket.sendall(fixed if name == "fixed-body-stall" else fixed.replace(b"5", b"50"))
            if name == "trickle-fixed-body":
                trickle(client, b"x")
        elif name in ("chunk-size-stall", "chunk-data-stall", "trailer-stall"):
            suffix = {"chunk-size-stall": b"a", "chunk-data-stall": b"5\r\nxy",
                      "trailer-stall": b"0\r\nx-test: yes"}[name]
            client.socket.sendall(chunked + suffix)
        elif name == "split-phase-budget":
            client.socket.sendall(b"POST /lifecycle-echo HTTP/1.1\r\n")
            time.sleep(.18)
            client.socket.sendall(b"Host: localhost\r\nContent-Length: 5\r\nConnection: close\r\n\r\n")
            time.sleep(.18)
            client.socket.sendall(b"hello")
        elif name == "pipeline-partial-header":
            client.socket.sendall(request() + b"GET /metadata HTTP/1.1\r\nHost: loc")
            client.read()
        elif name.startswith("half-close-") and name != "half-close-producer":
            payload = {"half-close-complete": fixed + b"hello",
                       "half-close-truncated": fixed + b"hi",
                       "half-close-pipeline": request() + fixed + b"hello",
                       "half-close-delayed-response": request("/lifecycle-delay")}[name]
            client.socket.sendall(payload)
            client.socket.shutdown(socket.SHUT_WR)
            if name == "half-close-pipeline":
                client.read()
        elif name.startswith("early-"):
            fields = b"Content-Length: 5\r\n"
            suffix = b""
            if name == "early-expect":
                fields += b"Expect: 100-continue\r\n"
            if name == "early-fixed-pipeline":
                suffix = b"hello" + request(fields=b"Connection: close\r\n")
            if name == "early-chunked-pipeline":
                fields = b"Transfer-Encoding: chunked\r\n"
                suffix = b"5\r\nhello\r\n0\r\n\r\n" + request(fields=b"Connection: close\r\n")
            client.socket.sendall(request("/lifecycle-early", method="POST", fields=fields) + suffix)
            client.read()
            if client.responses[-1]["status"] == 100:
                client.read()
            if name in ("early-fixed-pipeline", "early-chunked-pipeline"):
                client.read()
        elif name.endswith("slow-response-reader"):
            client.socket.sendall(request("/large"))
            # Eight MiB cannot fit into the deliberately small receive window.
            time.sleep(1.8 if name.startswith("sustained") else .85)
        elif name in ("reset-large-response", "reset-producer", "half-close-producer", "shutdown-producer"):
            client.socket.sendall(request("/large" if name == "reset-large-response" else "/stream-cancel"))
            result = client.read_head()
            if name != "reset-large-response":
                size = int(client.line(), 16)
                client.body(result, size)
                if client.take(2) != b"\r\n":
                    raise ValueError("invalid first chunk")
            if name.startswith("reset"):
                client.socket.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                client.socket.close()
                client.terminal = "client-reset"
            elif name == "half-close-producer":
                client.socket.shutdown(socket.SHUT_WR)
            else:
                server.shutdown()
            if name != "reset-large-response" and not name.startswith("shutdown"):
                deadline = time.monotonic() + .9
                while True:
                    extra["cleanup"] = json.loads(fetch(server.port, "/inspect")["body_prefix"])
                    if extra["cleanup"]["released"] or time.monotonic() >= deadline:
                        break
                    time.sleep(.01)
            if client.terminal != "client-reset":
                try:
                    client.chunks(result)
                    result["complete"] = True
                except (OSError, EOFError) as error:
                    result["error"] = type(error).__name__
                client.finish()
        elif name == "application-deadline":
            client.socket.sendall(request("/timeout", fields=b"Connection: close\r\n"))
        elif name in ("shutdown-body-complete", "shutdown-body-stall"):
            client.socket.sendall(fixed + b"he")
            # Allow the request head to enter the body reader before signaling.
            time.sleep(.05)
            server.shutdown()
            if name == "shutdown-body-complete":
                client.socket.sendall(b"llo")
        else:
            raise ValueError(name)
        if not client.terminal and not name.startswith("early-"):
            client.read()
        client.finish()
    except OSError as error:
        extra["send_error"] = type(error).__name__
        client.finish()
    finally:
        result = client.summary()
        client.socket.close()
    result.update(extra)
    if name.startswith("shutdown"):
        server.process.wait(timeout=2)
        result["exit_code"] = server.process.returncode
        try:
            result["new_connection"] = fetch(server.port, "/metadata")
        except OSError as error:
            result["new_connection"] = type(error).__name__
    else:
        result["fresh_connection"] = fetch(server.port, "/metadata")
        result["exit_code"] = server.process.poll()
        if name in ("reset-producer", "half-close-producer"):
            # The first observation measures prompt cancellation. This observation
            # checks cleanup after the producer's transport has actually terminated.
            deadline = time.monotonic() + .5
            while True:
                result["cleanup_after_close"] = json.loads(fetch(server.port, "/inspect")["body_prefix"])
                if result["cleanup_after_close"]["released"] or time.monotonic() >= deadline:
                    break
                time.sleep(.01)
    if server.running and not name.startswith("shutdown"):
        with wire.Client(server.running.admin_port) as admin:
            admin.send(request("/debug/metrics"))
            status, _, body = admin.response()
            if status != 200:
                raise RuntimeError("metrics endpoint did not return 200")
            result["metrics"] = json.loads(body)
    result["diagnostics"] = server.diagnostics()
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
    with tempfile.TemporaryDirectory(prefix="zhtps-lifecycle-") as temporary:
        go_binary = str(Path(temporary) / "go-server")
        subprocess.run(["go", "build", "-o", go_binary, str(directory / "reference_lifecycle.go")],
                       check=True, env={**os.environ, "GOCACHE": "/tmp/zhtps-lifecycle-go-cache"})
        commands = {"node": ["node", str(directory / "reference_lifecycle.cjs")], "go": [go_binary]}
        for name in NAMES:
            if args.filter not in name:
                continue
            reading = 2000 if name.startswith("shutdown") else 300
            row = {"name": name, "read_budget_ms": reading}
            for implementation in ("zhtps", "node", "go"):
                with contextlib.closing(Server(implementation, commands, reading)) as server:
                    row[implementation] = probe(server, name)
            results["cases"].append(row)
            print(name, *[f"{n}={[r['status'] for r in row[n]['responses']]} {row[n]['terminal']}"
                          for n in ("zhtps", "node", "go")], flush=True)
            args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
