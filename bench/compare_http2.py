"""Loopback HTTP/2 comparison: all runtimes on one core, ZHTPS/Go on multiple cores."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import shutil
import socket
import statistics
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def cpu_list(text):
    result = []
    for part in text.split(","):
        ends = list(map(int, part.split("-")))
        result.extend(range(ends[0], ends[-1] + 1))
    if not result or len(set(result)) != len(result):
        raise ValueError("CPU lists must be nonempty with no duplicates")
    return result


def topology(cpu):
    root = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    return tuple(int((root / name).read_text()) for name in ("physical_package_id", "core_id"))


def cpu_text(cpus):
    return ",".join(map(str, cpus))


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def cpu_seconds(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def process_snapshot(pid):
    status = Path(f"/proc/{pid}/status").read_text().splitlines()
    threads = []
    for task in sorted(Path(f"/proc/{pid}/task").iterdir()):
        try:
            fields = (task / "stat").read_text().rsplit(")", 1)[1].split()
            affinity = sorted(os.sched_getaffinity(int(task.name)))
            threads.append({"tid": int(task.name), "cpus": affinity,
                            "cpu_seconds": (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")})
        except (FileNotFoundError, ProcessLookupError):
            continue
    return {"status": [line for line in status if line.startswith(
        ("VmRSS:", "VmHWM:", "Threads:", "Cpus_allowed_list:"))], "threads": threads}


def read_json(process, timeout=60):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise TimeoutError(f"client {process.pid} did not report its phase")
    line = process.stdout.readline()
    if not line:
        raise RuntimeError(f"client {process.pid} exited before reporting its phase")
    return json.loads(line)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def trial(args, name, workers, connections, streams, repeat, cpus, client_cpus, cert, key):
    port = available_port()
    if name == "zhtps":
        command = [args.zhtps, "--port", str(port), "--admin-connections", "0",
                   "--workers", str(workers), "--worker-cpus", cpu_text(cpus),
                   "--no-access-log", "--max-connections", "2048", "--max-active", "2048", "--http2-worker-streams", "2048",
                   "--http2-memory-bytes", "536870912", "--max-requests", "4294967295",
                   "--tls-certificate", str(cert), "--tls-key", str(key)]
    elif name == "go":
        command = [args.go_server, "-listen", f"127.0.0.1:{port}", "-http2",
                   "-tls-certificate", str(cert), "-tls-key", str(key)]
    else:
        command = [getattr(args, name), str(ROOT / "bench/http2_server.cjs"),
                   str(port), str(cert), str(key)]
    command = ["taskset", "-c", cpu_text(cpus), *command]
    processes = min(connections, args.client_processes or max(1, len(client_cpus) // 2))
    placements = [client_cpus[i::processes][:2] for i in range(processes)]
    clients = []
    with tempfile.TemporaryFile() as logs, tempfile.TemporaryFile() as errors:
        server = subprocess.Popen(command, stdout=logs, stderr=logs,
                                  env={**os.environ, "GOMAXPROCS": str(workers)})
        try:
            deadline = time.monotonic() + 10
            while True:
                if server.poll() is not None:
                    raise RuntimeError("server exited during startup")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("server startup")
                    time.sleep(.01)
            commands = []
            for i, placement in enumerate(placements):
                count = connections // processes + (i < connections % processes)
                client_command = ["taskset", "-c", cpu_text(placement), args.client,
                                  "-url", f"https://localhost:{port}/", "-ca", str(cert),
                                  "-connections", str(count), "-streams", str(streams),
                                  "-duration", f"{args.duration}s", "-warmup", f"{args.warmup}s",
                                  "-synchronize"]
                commands.append(client_command)
                clients.append(subprocess.Popen(client_command, stdin=subprocess.PIPE,
                                                stdout=subprocess.PIPE, stderr=errors,
                                                env={**os.environ, "GOMAXPROCS": str(len(placement))}))
            with ThreadPoolExecutor(max_workers=processes) as pool:
                ready = list(pool.map(read_json, clients))
                assert all(item["phase"] == "ready" for item in ready), ready
                before_snapshot = process_snapshot(server.pid)
                start_ns = time.time_ns() + 200_000_000
                for client in clients:
                    client.stdin.write(f"{start_ns}\n".encode())
                    client.stdin.flush()
                time.sleep(max(0, (start_ns - time.time_ns()) / 1e9))
                before_time = time.monotonic()
                before_cpu = cpu_seconds(server.pid)
                finished = list(pool.map(read_json, clients))
                after_cpu = cpu_seconds(server.pid)
                cpu_window = time.monotonic() - before_time
                assert all(item["phase"] == "measured" for item in finished), finished
                after_snapshot = process_snapshot(server.pid)
                # Buffered readers may already hold the final line, so do not select here.
                shards = list(pool.map(lambda client: json.loads(client.stdout.readline()), clients))
            for client in clients:
                if client.wait(timeout=60):
                    raise RuntimeError(f"client failed: {shards}")
            histogram = Counter()
            for shard in shards:
                histogram.update({int(key): value for key, value in shard["latency_us"].items()})
            requests = sum(shard["requests"] for shard in shards)
            failures = sum(shard["errors"] for shard in shards)
            opened = sum(shard["connections_opened"] for shard in shards)
            assert failures == 0 and requests > 0 and opened == connections, shards
            assert sum(histogram.values()) == requests
            elapsed = (max(shard["end_ns"] for shard in shards) -
                       min(shard["start_ns"] for shard in shards)) / 1e9
            quantiles = {}
            count = 0
            for latency, frequency in sorted(histogram.items()):
                count += frequency
                for percentile in (50, 99):
                    if percentile not in quantiles and count > (requests - 1) * percentile // 100:
                        quantiles[percentile] = latency / 1000
            cpu = after_cpu - before_cpu
            run = {"server": name, "workers": workers, "connections": connections, "streams": streams,
                   "repeat": repeat, "server_cpus": cpus, "client_cpus": client_cpus,
                   "client_processes": processes, "client_placements": placements,
                   "requests": requests, "errors": failures,
                   "connections_opened": opened, "seconds": elapsed,
                   "requests_per_second": requests / elapsed,
                   "p50_ms": quantiles[50], "p99_ms": quantiles[99],
                   "server_cpu_seconds": cpu, "server_cpu_window_seconds": cpu_window,
                   "server_cpu_cores": cpu / cpu_window, "server_cpu_us_per_request": cpu * 1e6 / requests,
                   "client_cpu_cores": sum(shard["client_cpu_seconds"] for shard in shards) / elapsed,
                   "client_start_skew_ms": (max(shard["start_ns"] for shard in shards) -
                                            min(shard["start_ns"] for shard in shards)) / 1e6,
                   "server_before": before_snapshot, "server_after": after_snapshot,
                   "server_command": command, "client_commands": commands, "shards": shards}
            return run
        except BaseException:
            logs.seek(0)
            errors.seek(0)
            print(logs.read().decode(errors="replace"), flush=True)
            print(errors.read().decode(errors="replace"), flush=True)
            raise
        finally:
            for client in clients:
                stop(client)
            stop(server)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zhtps", default="zig-out/bin/zhtps")
    parser.add_argument("--go-server", required=True)
    parser.add_argument("--client", required=True)
    parser.add_argument("--node", default="node")
    parser.add_argument("--bun", default="bun")
    parser.add_argument("--servers", default="zhtps,go,node,bun")
    parser.add_argument("--workers", default="1,2,4,8")
    parser.add_argument("--cases", default="1x1,1x32,8x32,64x4")
    parser.add_argument("--server-cpus", help="CPU list; defaults to first half of physical cores")
    parser.add_argument("--client-cpus", help="CPU list; defaults to second half of physical cores and their SMT siblings")
    parser.add_argument("--client-processes", type=int, default=0)
    parser.add_argument("--duration", type=lambda text: float(text.removesuffix("s")), default=8)
    parser.add_argument("--warmup", type=float, default=2)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", default="/tmp/zhtps-http2-comparison.json")
    args = parser.parse_args()
    if args.repeats < 1 or args.duration <= 0 or args.warmup < 0 or args.client_processes < 0:
        parser.error("invalid repeats, duration, warmup or client processes")
    allowed = sorted(os.sched_getaffinity(0))
    physical = list({topology(cpu): cpu for cpu in reversed(allowed)}.values())
    physical.sort()
    split = len(physical) // 2
    server_cpus = cpu_list(args.server_cpus) if args.server_cpus else physical[:split]
    client_cores = set(map(topology, physical[split:]))
    client_cpus = cpu_list(args.client_cpus) if args.client_cpus else [
        cpu for cpu in allowed if topology(cpu) in client_cores]
    workers_list = list(map(int, args.workers.split(",")))
    cases = [tuple(map(int, case.split("x"))) for case in args.cases.split(",")]
    names = args.servers.split(",")
    if not server_cpus or not client_cpus or not set(server_cpus + client_cpus) <= set(allowed):
        parser.error("server and client CPUs must be available")
    if set(map(topology, server_cpus)) & set(map(topology, client_cpus)):
        parser.error("server and client must not share physical cores, including SMT siblings")
    if min(workers_list) < 1 or max(workers_list) > len(server_cpus):
        parser.error("worker counts exceed server CPU budget")
    if args.client_processes > len(client_cpus):
        parser.error("client processes exceed client CPU budget")
    if not set(names) <= {"zhtps", "go", "node", "bun"}:
        parser.error("unknown server")
    if any(len(case) != 2 or case[0] < 1 or not 1 <= case[1] <= 100 or
           case[0] * case[1] > 2048 for case in cases):
        parser.error("cases need positive connections, 1..100 streams, at most 2048 requests in flight")
    output = Path(args.output)
    if output.exists():
        parser.error(f"refusing to overwrite {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    binaries = {"zhtps": args.zhtps, "go": args.go_server, "client": args.client}
    for name in ("node", "bun"):
        if name in names and 1 in workers_list:
            binaries[name] = shutil.which(getattr(args, name))
    sources = [ROOT / "build.zig", ROOT / "build.zig.zon", *sorted((ROOT / "src").rglob("*.zig")),
               ROOT / "bench/compare_http2.py", ROOT / "bench/http2_client/main.go",
               ROOT / "bench/go_server/main.go", ROOT / "bench/http2_server.cjs"]
    report = {
        "started_utc": datetime.now(timezone.utc).isoformat(), "kernel": platform.release(),
        "server_cpu_pool": server_cpus, "client_cpus": client_cpus,
        "cpu_topology": {str(cpu): topology(cpu) for cpu in allowed},
        "go": subprocess.check_output(["go", "version"], text=True).strip(),
        "zig": subprocess.check_output(["zig", "version"], text=True).strip(),
        "openssl": subprocess.check_output(["pkg-config", "--modversion", "openssl"], text=True).strip(),
        "nghttp2": subprocess.check_output(["pkg-config", "--modversion", "libnghttp2"], text=True).strip(),
        "runtime_versions": {name: json.loads(subprocess.check_output(
            [binaries[name], "-p", "JSON.stringify(process.versions)"], text=True))
            for name in ("node", "bun") if name in binaries},
        "cpu": next(line.split(":", 1)[1].strip() for line in
                    Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")),
        "binary_sha256": {name: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                          for name, path in binaries.items()},
        "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in sources},
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "git_status": subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True),
        "arguments": vars(args), "runs": [], "complete": False,
    }
    def save():
        temporary = output.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(output)
    save()
    with tempfile.TemporaryDirectory(prefix="zhtps-h2-bench-") as directory:
        key, cert = Path(directory) / "key.pem", Path(directory) / "cert.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost",
        ], check=True, capture_output=True)
        for workers in workers_list:
            selected = [name for name in names if workers == 1 or name in ("zhtps", "go")]
            for connections, streams in cases:
                if workers > 1 and connections < workers:
                    continue
                for repeat in range(args.repeats):
                    offset = repeat % len(selected) if selected else 0
                    for name in selected[offset:] + selected[:offset]:
                        run = trial(args, name, workers, connections, streams, repeat,
                                    server_cpus[:workers], client_cpus, cert, key)
                        report["runs"].append(run)
                        save()
                        print(f"{name:5} w={workers} {connections}x{streams} r={repeat + 1}: "
                              f"{run['requests_per_second']:,.0f} req/s p99={run['p99_ms']:.3f} ms "
                              f"server={run['server_cpu_cores']:.2f} client={run['client_cpu_cores']:.2f} cores "
                              f"errors={run['errors']}", flush=True)
    report["medians"] = []
    groups = sorted({(run["workers"], run["connections"], run["streams"], run["server"])
                     for run in report["runs"]})
    for workers, connections, streams, name in groups:
        runs = [run for run in report["runs"] if
                (run["workers"], run["connections"], run["streams"], run["server"]) ==
                (workers, connections, streams, name)]
        report["medians"].append({
            "server": name, "workers": workers, "connections": connections, "streams": streams,
            **{key: statistics.median(run[key] for run in runs) for key in
               ("requests_per_second", "p50_ms", "p99_ms", "server_cpu_us_per_request",
                "server_cpu_cores", "client_cpu_cores")},
            "min_requests_per_second": min(run["requests_per_second"] for run in runs),
            "max_requests_per_second": max(run["requests_per_second"] for run in runs),
            "errors": sum(run["errors"] for run in runs),
        })
    for name, path in binaries.items():
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == report["binary_sha256"][name]
    for path in sources:
        assert hashlib.sha256(path.read_bytes()).hexdigest() == report["source_sha256"][str(path.relative_to(ROOT))]
    report["complete"] = True
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    save()


if __name__ == "__main__":
    main()
