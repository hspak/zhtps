"""Collect a bounded load-client run over SSH with remote resource/clock evidence.

The module is also the self-contained remote agent: only Python's standard
library and an already installed load binary are needed on the generator host.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import resource
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time


def identity():
    return {"hostname": platform.node(), "kernel": platform.release(), "machine": platform.machine(),
            "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            "allowed_cpus": sorted(os.sched_getaffinity(0))}


def sample_process(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    result = {"unix_ns": time.time_ns(),
              "cpu_seconds": (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith(("VmRSS:", "VmHWM:", "VmSwap:")):
            key, amount, _ = line.split()
            result[key[:-1]] = int(amount) * 1024
    result["fds"] = len(list(Path(f"/proc/{pid}/fd").iterdir()))
    return result


def stop_child(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def emit(kind, **fields):
    print(json.dumps(dict(kind=kind, **fields), separators=(",", ":")), flush=True)


def agent():
    child = None
    stopping = threading.Event()
    for name in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(name, lambda *_: stopping.set())
    try:
        emit("hello", identity=identity())
        while True:
            line = sys.stdin.readline()
            if not line:
                return
            command = json.loads(line)
            if command["kind"] == "clock":
                emit("clock", unix_ns=time.time_ns())
            elif command["kind"] == "run":
                break
            else:
                raise ValueError("unsupported agent command")
        cpus = set(command["cpus"])
        if not cpus or not cpus <= os.sched_getaffinity(0):
            raise ValueError("client CPU list is not available on this host")
        binary = Path(command["binary"]).resolve()
        binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
        os.sched_setaffinity(0, cpus)
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        needed = command["connections"] + 256
        if hard < needed:
            raise ValueError("remote hard descriptor limit is below the requested client capacity")
        resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, needed), hard))
        with tempfile.TemporaryDirectory(prefix="zhtps-remote-load-") as temporary:
            folder = Path(temporary)
            arguments = [str(binary), *command["arguments"]]
            uploads = {}
            for flag, encoded in command.get("files", {}).items():
                if flag not in ("-request-body", "-expect-body"):
                    raise ValueError("unsupported workload file")
                content = base64.b64decode(encoded, validate=True)
                if len(content) > 64 * 1024 * 1024:
                    raise ValueError("workload file exceeds 64 MiB")
                path = folder / flag[1:]
                path.write_bytes(content)
                arguments.extend((flag, str(path)))
                uploads[flag] = {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}
            with (folder / "result.json").open("w+") as output, (folder / "stderr.log").open("w+") as errors:
                child = subprocess.Popen(arguments, stdout=output, stderr=errors,
                                         env=dict(os.environ, GOMAXPROCS=str(len(cpus))))
                emit("started", pid=child.pid, command=arguments, binary_sha256=binary_hash,
                     cpus=sorted(cpus), files=uploads)
                last_contact = [time.monotonic()]

                def watch_parent():
                    # Parent closes stdin on cancellation or transport loss.
                    while os.read(sys.stdin.fileno(), 4096):
                        last_contact[0] = time.monotonic()
                    stopping.set()

                threading.Thread(target=watch_parent, daemon=True).start()
                deadline = time.monotonic() + command["max_seconds"]
                while child.poll() is None:
                    if stopping.is_set():
                        raise RuntimeError("parent disconnected or cancelled the run")
                    if time.monotonic() - last_contact[0] > command.get("heartbeat_seconds", 15):
                        raise RuntimeError("parent heartbeat expired")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("remote client exceeded its run deadline")
                    try:
                        emit("sample", sample=sample_process(child.pid))
                    except (FileNotFoundError, PermissionError) as sample_error:
                        # /proc/PID/fd can become unreadable between poll() and
                        # sampling when the child exits. Preserve its final report.
                        try:
                            child.wait(timeout=.1)
                        except subprocess.TimeoutExpired:
                            raise sample_error
                        break
                    stopping.wait(.5)
                child.wait(timeout=5)
                errors.seek(0)
                diagnostics = errors.read(8192)
                if (folder / "result.json").stat().st_size > 16 * 1024 * 1024:
                    raise ValueError("load report exceeds 16 MiB")
                if child.returncode != 0:
                    output.seek(0)
                    try:
                        failed_report = json.load(output)
                    except (ValueError, OSError):
                        failed_report = None
                    emit("error", error=f"load client exited {child.returncode}: {diagnostics}",
                         client=failed_report, exit_code=child.returncode)
                    return
                output.seek(0)
                result = json.load(output)
                emit("result", client=result, stderr=diagnostics, exit_code=child.returncode)
    except BaseException as error:
        stop_child(child)
        emit("error", error=repr(error))
        raise SystemExit(1)
    finally:
        stop_child(child)


class RemoteLoad:
    def __init__(self, host, error_file, *, transport=None):
        if host.startswith("-") or any(character.isspace() for character in host):
            raise ValueError("invalid SSH host")
        source = Path(__file__).read_text()
        remote_command = shlex.join(["python3", "-u", "-c", source])
        self.command = transport or ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                                     "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5",
                                     "-o", "ServerAliveCountMax=3", host, remote_command]
        self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=error_file, text=True, bufsize=1)
        self.events = queue.Queue()
        self.samples = []
        self.started = self.result = self.error = self.failure = None
        self.clock_offset_ns = self.clock_uncertainty_ns = None
        self.last_heartbeat = 0
        self.reader = threading.Thread(target=self.read_events, daemon=True)
        self.reader.start()
        try:
            hello = self.next_event("hello", 15)
            self.identity = hello["identity"]
            estimates = []
            for _ in range(5):
                begin_wall, begin = time.time_ns(), time.monotonic_ns()
                self.send({"kind": "clock"})
                response = self.next_event("clock", 5)
                elapsed = time.monotonic_ns() - begin
                estimates.append((elapsed // 2, begin_wall + elapsed // 2 - response["unix_ns"]))
            self.clock_uncertainty_ns, self.clock_offset_ns = min(estimates)
        except BaseException:
            self.stop()
            raise

    def read_events(self):
        try:
            for line in self.process.stdout:
                self.events.put(json.loads(line))
        except BaseException as error:
            self.events.put({"kind": "error", "error": repr(error)})
        finally:
            self.events.put({"kind": "eof"})

    def send(self, message):
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def next_event(self, expected, timeout):
        event = self.events.get(timeout=timeout)
        if event["kind"] != expected:
            raise RuntimeError(f"expected {expected}, received {event}")
        return event

    def start(self, binary, arguments, cpus, connections, max_seconds, files, *, heartbeat_seconds=15):
        uploads = {}
        for flag, path in files.items():
            with path.open("rb") as file:
                content = file.read(64 * 1024 * 1024 + 1)
            if len(content) > 64 * 1024 * 1024:
                raise ValueError("workload file exceeds 64 MiB")
            uploads[flag] = base64.b64encode(content).decode("ascii")
        self.send({"kind": "run", "binary": binary, "arguments": arguments, "cpus": cpus,
                   "connections": connections, "max_seconds": max_seconds, "files": uploads,
                   "heartbeat_seconds": heartbeat_seconds})
        self.started = self.next_event("started", 30)

    def collect(self):
        while True:
            try:
                event = self.events.get_nowait()
            except queue.Empty:
                break
            if event["kind"] == "sample":
                self.samples.append(event["sample"])
            elif event["kind"] == "result":
                self.result = event
            elif event["kind"] == "error":
                self.failure = event
                self.error = event["error"]
            elif event["kind"] == "eof":
                if self.result is None and self.error is None:
                    self.error = "remote agent closed without a result"
            else:
                self.error = f"unexpected remote event: {event}"
        if self.error:
            raise RuntimeError(self.error)
        if self.started and self.result is None and time.monotonic() - self.last_heartbeat >= 1:
            try:
                self.send({"kind": "heartbeat"})
                self.last_heartbeat = time.monotonic()
            except BrokenPipeError:
                # A just-finished agent can close stdin before its result is read.
                pass

    def completed(self):
        self.collect()
        return self.result is not None

    def stop(self):
        if self.process.stdin and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            self.process.wait(timeout=7)
        except subprocess.TimeoutExpired:
            stop_child(self.process)
        self.reader.join(timeout=2)
        self.process.stdout.close()


if __name__ == "__main__":
    agent()
