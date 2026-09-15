"""Measure idle pool cost or syscall shape; trace timing is not throughput evidence."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import socket
import subprocess
import time

from overload import proc_sample, core_sample


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--trace", action="store_true")
    parser.add_argument("--idle-connections", type=int, default=0)
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--capacity", type=int, default=8168)
    parser.add_argument("--rate", type=int, help="run validated small GET traffic instead of idle sockets")
    parser.add_argument("--perf", action="store_true", help="sample cpu-clock while running --rate")
    args = parser.parse_args()
    if args.perf and not args.rate:
        parser.error("--perf requires --rate")
    if args.trace and args.rate:
        parser.error("--trace and --rate are separate experiments")
    os.sched_setaffinity(0, {0})
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(max(soft, args.idle_connections * 2 + 256), hard), hard))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = ["taskset", "-c", "2", str(args.binary), "--port", "0", "--admin-port", "0", "--max-connections", str(args.capacity), "--no-access-log", "--idle-timeout-ms", "60000", "--max-requests", "4294967295"]
    if args.trace:
        command = ["strace", "-f", "-qq", "-c", "-e", "trace=io_uring_enter", "-o", str(args.output.with_suffix(".trace")), *command]
    report = {"command": command, "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "trace": args.trace, "idle_connections": args.idle_connections, "samples": []}
    sockets = []
    client_process = None
    profile = None
    profile_log = None
    with args.output.with_suffix(".log").open("w+") as log:
        process = subprocess.Popen(command, stderr=log, stdout=subprocess.DEVNULL)
        try:
            until = time.monotonic() + 10
            ports = {}
            while len(ports) < 2:
                if process.poll() is not None:
                    raise RuntimeError(log.read())
                log.seek(0)
                for line in log:
                    event = json.loads(line)
                    if event["event"] in ("listening", "admin_listening"):
                        ports[event["event"]] = event["port"]
                if time.monotonic() >= until:
                    raise TimeoutError("startup")
                time.sleep(.01)
            if args.trace:
                client = socket.create_connection(("127.0.0.1", ports["listening"]), timeout=5)
                sockets.append(client)
                stream = client.makefile("rb")
                for i in range(10000):
                    client.sendall(b"GET / HTTP/1.1\r\nHost: local\r\n\r\n")
                    status = stream.readline()
                    assert status == b"HTTP/1.1 200 OK\r\n", status
                    while (line := stream.readline()) != b"\r\n":
                        if not line:
                            raise EOFError("incomplete response headers")
                    assert stream.read(6) == b"ZHTPS\n"
                stream.close()
                report["requests"] = 10000
            elif args.rate:
                if args.perf:
                    profile_log = args.output.with_suffix(".perf.txt").open("w")
                    perf_command = ["perf", "record", "-q", "-e", "cpu-clock", "-F", "199", "-g", "-o",
                                    str(args.output.with_suffix(".perf.data")), "-p", str(process.pid)]
                    report["perf_command"] = perf_command
                    profile = subprocess.Popen(perf_command, stdout=subprocess.DEVNULL, stderr=profile_log)
                    time.sleep(.2)
                load_binary = Path(__file__).resolve().parents[1] / "zig-out/bench/load"
                load_command = ["taskset", "-c", "4-7", str(load_binary), "-address", f"127.0.0.1:{ports['listening']}",
                                "-connections", "64", "-schedule", f"{args.rate}:{args.seconds}s"]
                report["load_command"] = load_command
                with args.output.with_suffix(".client.json").open("w") as client_output:
                    client_process = subprocess.Popen(load_command, stdout=client_output, stderr=subprocess.PIPE)
                    deadline = time.monotonic() + args.seconds + 10
                    while True:
                        fields = Path(f"/proc/{process.pid}/stat").read_text().rsplit(")", 1)[1].split()
                        sample = proc_sample(process.pid)
                        sample.update(user_seconds=int(fields[11]) / os.sysconf("SC_CLK_TCK"),
                                      system_seconds=int(fields[12]) / os.sysconf("SC_CLK_TCK"))
                        report["samples"].append({"ns": time.monotonic_ns(), "process": sample, "core": core_sample([2])})
                        if client_process.poll() is not None:
                            if client_process.returncode:
                                raise RuntimeError(client_process.stderr.read().decode())
                            break
                        if time.monotonic() > deadline:
                            raise TimeoutError("load")
                        time.sleep(1)
                report["client"] = json.loads(args.output.with_suffix(".client.json").read_text())
            else:
                for i in range(args.idle_connections):
                    sockets.append(socket.create_connection(("127.0.0.1", ports["listening"]), timeout=2))
                    if i % 64 == 63:
                        time.sleep(.002)
                time.sleep(.5)
                for i in range(int(args.seconds) + 1):
                    report["samples"].append({"ns": time.monotonic_ns(), "process": proc_sample(process.pid), "core": core_sample([2])})
                    if i < int(args.seconds):
                        time.sleep(1)
        finally:
            if client_process is not None:
                if client_process.poll() is None:
                    client_process.kill()
                client_process.wait(timeout=5)
                client_process.stderr.close()
            if profile is not None:
                if profile.poll() is None:
                    profile.send_signal(2)
                report["perf_exit"] = profile.wait(timeout=10)
                profile_log.close()
            for client in sockets:
                client.close()
            # strace forwards SIGTERM when it is sent to the tracee, not itself.
            if args.trace:
                children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
                for child in children:
                    os.kill(int(child), 15)
            else:
                process.terminate()
            process.wait(timeout=10)
            report["exit"] = process.returncode
            args.output.write_text(json.dumps(report, indent=2) + "\n")
    if report["samples"]:
        first, last = report["samples"][0], report["samples"][-1]
        cpu = (last["process"]["cpu_seconds"] - first["process"]["cpu_seconds"]) / ((last["ns"] - first["ns"]) / 1e9)
        print(json.dumps({"output": str(args.output), "cpu_cores": cpu, "rss_mib": last["process"]["VmRSS"] / 2**20}), flush=True)
    else:
        print(args.output.with_suffix(".trace").read_text(), flush=True)


if __name__ == "__main__":
    main()
