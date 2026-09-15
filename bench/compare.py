"""Build and compare ZHTPS Debug/ReleaseSafe and a minimal Go net/http server."""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import resource
import shlex
import socket
import ssl
import statistics
import subprocess
import time

from remote_load import RemoteLoad, identity


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "zig-out" / "bench"
VARIANTS = ("zig_debug", "zig_release_safe", "go")


def command(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, **kwargs)


def available_cores():
    cores = {}
    for cpu in sorted(os.sched_getaffinity(0)):
        topology = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
        key = (topology.joinpath("physical_package_id").read_text().strip(),
               topology.joinpath("core_id").read_text().strip())
        cores.setdefault(key, cpu)
    return list(cores.values())


def free_port(address="127.0.0.1"):
    with socket.socket() as listener:
        listener.bind((address, 0))
        return listener.getsockname()[1]


def cpu_seconds(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def wait_ready(process, port, address="127.0.0.1", tls=False):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server exited with {process.returncode}; io_uring must be permitted")
        if tls:
            context = ssl._create_unverified_context()
            context.minimum_version = ssl.TLSVersion.TLSv1_3
            context.maximum_version = ssl.TLSVersion.TLSv1_3
            context.set_alpn_protocols(["http/1.1"])
            connection = http.client.HTTPSConnection(address, port, timeout=0.2, context=context)
        else:
            connection = http.client.HTTPConnection(address, port, timeout=0.2)
        try:
            connection.request("GET", "/")
            response = connection.getresponse()
            if response.status != 200 or response.read() != b"ZHTPS\n":
                raise AssertionError("server response does not match workload")
            return dict(response.getheaders())
        except (OSError, http.client.HTTPException):
            time.sleep(0.02)
        finally:
            connection.close()
    raise TimeoutError("server did not become ready")


def build():
    BUILD.mkdir(parents=True, exist_ok=True)
    commands = [
        ["zig", "build", "-Doptimize=Debug", "--prefix", "zig-out/bench/debug"],
        ["zig", "build", "--release=safe", "--prefix", "zig-out/bench/release_safe"],
        ["go", "build", "-o", "zig-out/bench/go_server", "bench/go_server/main.go"],
        ["go", "build", "-o", "zig-out/bench/load", "bench/load/main.go", "bench/load/offered.go"],
    ]
    env = dict(os.environ, GOCACHE="/tmp/zhtps-go-cache")
    for args in commands:
        if args[0] == "zig":
            args += ["--cache-dir", "/tmp/zhtps-zig-cache", "--global-cache-dir",
                     "/tmp/zhtps-zig-global-cache", "--summary", "all"]
        print("Building:", " ".join(args), flush=True)
        command(args, env=env)
    return commands


def admin_json(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f"admin {path}: HTTP {response.status}")
        return json.loads(response.read())
    finally:
        connection.close()


def run_one(variant, binary, options, server_cpu, client_cpus, connections, repeat):
    address = getattr(options, "server_address", "127.0.0.1")
    client_host = getattr(options, "client_host", None)
    port = free_port(address)
    admin_port = free_port()
    while admin_port == port:
        admin_port = free_port()
    allow_errors = getattr(options, "allow_errors", False)
    zig_capacity = getattr(options, "zig_max_connections", None)
    if zig_capacity is None:
        zig_capacity = min(max(connections, 256), 8168) if allow_errors else max(connections, 256)
    zig_active = getattr(options, "zig_max_active", None) or zig_capacity
    zig_workers = getattr(options, "zig_workers", 1)
    zig_unrestricted = variant != "go" and zig_workers > 1
    go_unrestricted = variant == "go" and getattr(options, "go_cpu_mode", "unrestricted") == "unrestricted"
    args = [str(binary)] if go_unrestricted or zig_unrestricted else ["taskset", "-c", str(server_cpu), str(binary)]
    if variant == "go":
        args += ["-listen", f"{address}:{port}"]
    else:
        args += ["--port", str(port), "--admin-port", str(admin_port), "--max-requests", "4294967295"]
        args += ["--address", address]
        if zig_workers > 1:
            args += ["--workers", str(zig_workers)]
        if not getattr(options, "zig_access_log", True):
            args += ["--no-access-log"]
        args += ["--max-connections", str(zig_capacity), "--max-active", str(zig_active)]
        # Preserve the current server's capacity contract. Verify its rejection
        # rather than changing the implementation or silently lowering concurrency.
        if zig_capacity + 8 > 8176:
            probe = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=10)
            if probe.returncode != 2 or '"reason":"InvalidLimit"' not in probe.stderr:
                raise RuntimeError(f"unexpected capacity probe: {probe.returncode} {probe.stderr}")
            return {
                "variant": variant, "repeat": repeat, "connections": connections,
                "outcome": "unsupported", "reason": "InvalidLimit",
                "server_command": args, "server_returncode": probe.returncode,
                "server_stderr": probe.stderr, "public_connection_limit": 8168,
            }
    use_tls = bool(getattr(options, "tls_certificate", None))
    if use_tls:
        prefix = "-" if variant == "go" else "--"
        args += [prefix + "tls-certificate", str(options.tls_certificate.resolve()),
                 prefix + "tls-key", str(options.tls_key.resolve())]
    env = dict(os.environ)
    if go_unrestricted:
        env.pop("GOMAXPROCS", None)
    else:
        env["GOMAXPROCS"] = "1"
    process = subprocess.Popen(args, cwd=ROOT, env=env,
                               stdout=subprocess.PIPE if variant == "go" else subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
    remote = None
    try:
        go_runtime = json.loads(process.stdout.readline()) if variant == "go" else None
        headers = wait_ready(process, port, address, tls=use_tls)
        if client_host:
            transport = None
            if options.ssh_config:
                transport = ["ssh", "-F", str(options.ssh_config), "-T", "-o", "BatchMode=yes",
                             "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
                             "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", client_host,
                             shlex.join(["python3", "-u", "-c",
                                         (ROOT / "bench/remote_load.py").read_text()])]
            remote = RemoteLoad(client_host, None, transport=transport)
            if remote.identity["boot_id"] == identity()["boot_id"]:
                raise ValueError("load generator shares the server kernel")
        affinity = sorted(os.sched_getaffinity(process.pid))
        workers_before = admin_json(admin_port, "/debug/workers") if zig_workers > 1 and variant != "go" else None
        worker_cpu_start = {w["thread"]: cpu_seconds(f"{process.pid}/task/{w['thread']}")
                            for w in workers_before["workers"]} if workers_before else {}
        cpu_start = cpu_seconds(process.pid)
        network_before = network_sample() if remote else None
        started = time.monotonic()
        load_arguments = ["-address", f"{address}:{port}", "-connections", str(connections),
                     "-duration", f"{options.duration}s", "-warmup", f"{options.warmup}s"]
        if use_tls:
            load_arguments += ["-tls"]
        if allow_errors:
            load_arguments += ["-allow-errors"]
        if remote:
            timeout = options.duration + options.warmup + 90
            remote.start(options.remote_client_binary, load_arguments, client_cpus,
                         connections, timeout, {})
            if remote.started["binary_sha256"] != hashlib.sha256((BUILD / "load").read_bytes()).hexdigest():
                raise ValueError("remote load binary does not match this build")
            deadline = time.monotonic() + timeout
            while not remote.completed():
                if time.monotonic() >= deadline:
                    raise TimeoutError("remote load did not finish")
                if process.poll() is not None:
                    raise RuntimeError("server exited during remote load")
                time.sleep(.05)
            result = remote.result["client"]
            load_args = remote.started["command"]
        else:
            load_args = ["taskset", "-c", ",".join(map(str, client_cpus)), str(BUILD / "load"),
                         *load_arguments]
            run = subprocess.run(load_args, cwd=ROOT,
                                 env=dict(os.environ, GOMAXPROCS=str(len(client_cpus))),
                                 capture_output=True, text=True,
                                 timeout=options.duration + options.warmup + 90)
            if run.returncode != 0:
                raise RuntimeError(f"load failed: {run.stdout}\n{run.stderr}")
            result = json.loads(run.stdout)
        elapsed = time.monotonic() - started
        cpu = cpu_seconds(process.pid) - cpu_start
        if remote:
            result.update(remote_client=dict(remote.started, identity=remote.identity,
                                             separate_kernel=True, samples=remote.samples,
                                             clock_offset_ns=remote.clock_offset_ns,
                                             clock_uncertainty_ns=remote.clock_uncertainty_ns),
                          server_network_before=network_before, server_network_after=network_sample())
        if result["attempts"] != result["successes"] + result["errors"]:
            raise AssertionError("load outcomes do not account for every attempt")
        if not allow_errors and (result["connections_ready"] != connections or result["connections_measured"] != connections):
            raise AssertionError("not every requested connection participated")
        if not allow_errors and result["connections_opened"] != connections:
            raise AssertionError("connection turnover invalidates a persistent-connection trial")
        workers_after = admin_json(admin_port, "/debug/workers") if zig_workers > 1 and variant != "go" else None
        worker_cpu_seconds = {str(tid): cpu_seconds(f"{process.pid}/task/{tid}") - before
                              for tid, before in worker_cpu_start.items()}
        metrics_after = admin_json(admin_port, "/debug/metrics") if variant != "go" else None
        result.update(variant=variant, repeat=repeat, server_command=args,
                      client_command=load_args, response_headers=headers,
                      outcome="measured", server_cpus=affinity, go_runtime=go_runtime,
                      zig_workers=zig_workers if variant != "go" else None,
                      workers_before=workers_before, workers_after=workers_after,
                      worker_cpu_seconds_including_warmup=worker_cpu_seconds,
                      metrics_after=metrics_after,
                      zig_connection_capacity=zig_capacity if variant != "go" else None,
                      zig_max_active=zig_active if variant != "go" else None,
                      server_cpu_percent_including_warmup=100 * cpu / elapsed)
        return result
    finally:
        if remote:
            remote.stop()
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise RuntimeError("server did not stop within eight seconds")
        if process.returncode not in (0, -15):
            raise RuntimeError(f"server exited with {process.returncode}")
        if process.stdout is not None:
            process.stdout.close()


def network_sample():
    return {"monotonic_ns": time.monotonic_ns(),
            "nics": {nic.name: {path.name: int(path.read_text())
                                for path in (nic / "statistics").iterdir()}
                     for nic in Path("/sys/class/net").iterdir() if (nic / "device").exists()},
            "snmp": Path("/proc/net/snmp").read_text(),
            "netstat": Path("/proc/net/netstat").read_text()}


def summarize(runs, concurrency, variants=VARIANTS):
    rows = []
    for connections in concurrency:
        for variant in variants:
            group = [run for run in runs if run["variant"] == variant and
                     run["connections"] == connections]
            if all(run["outcome"] == "unsupported" for run in group):
                rows.append({"variant": variant, "connections": connections,
                             "outcome": "unsupported", "reason": group[0]["reason"]})
                continue
            rates = [run["requests_per_second"] for run in group]
            rows.append({
                "variant": variant,
                "connections": connections,
                "outcome": "measured",
                "requests_per_second_median": statistics.median(rates),
                "requests_per_second_min": min(rates),
                "requests_per_second_max": max(rates),
                "window_successes_per_second_median": statistics.median(
                    run["window_successes_per_second"] for run in group),
                "window_successes_per_second_min": min(run["window_successes_per_second"] for run in group),
                "window_successes_per_second_max": max(run["window_successes_per_second"] for run in group),
                "window_failures_per_run": [run["window_failures"] or {} for run in group],
                "latency_us_median_of_runs": {
                    key: statistics.median(run["latency_us"][key] for run in group)
                    for key in ("p50", "p95", "p99")
                },
                "errors": sum(run["errors"] + run["warmup_errors"] for run in group),
                "server_cpu_percent_median": statistics.median(
                    run["server_cpu_percent_including_warmup"] for run in group),
                "generator_cpu_percent_median": statistics.median(
                    run["generator_cpu_percent_including_warmup"] for run in group),
            })
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=5)
    parser.add_argument("--warmup", type=float, default=1)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--connections", type=int, nargs="+", default=[1, 16, 128])
    parser.add_argument("--go-cpu-mode", choices=("unrestricted", "single"), default="unrestricted")
    parser.add_argument("--client-cores", type=int, default=4)
    parser.add_argument("--server-address", default="127.0.0.1")
    parser.add_argument("--client-host", help="SSH host for a load generator on a separate kernel")
    parser.add_argument("--remote-client-binary", help="remote path to an exact copy of zig-out/bench/load")
    parser.add_argument("--ssh-config", type=Path, help="optional SSH configuration for the client host")
    parser.add_argument("--variants", choices=VARIANTS, nargs="+", default=list(VARIANTS))
    parser.add_argument("--allow-errors", action="store_true",
                        help="measure successes while continuing across rejections and connection failures")
    parser.add_argument("--zig-workers", type=int, default=1)
    parser.add_argument("--zig-access-log", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--zig-max-connections", type=int)
    parser.add_argument("--zig-max-active", type=int)
    parser.add_argument("--tls-certificate", type=Path, help="shared PEM certificate; enables TLS 1.3")
    parser.add_argument("--tls-key", type=Path, help="shared PEM private key")
    parser.add_argument("--output", type=Path, default=ROOT / "zig-out/bench/go-comparison.json")
    options = parser.parse_args()
    if bool(options.tls_certificate) != bool(options.tls_key):
        parser.error("TLS requires both --tls-certificate and --tls-key")
    if not (0 < options.duration <= 60 and 0 < options.warmup <= 30 and
            1 <= options.repeats <= 20 and all(1 <= c <= 16384 for c in options.connections) and
            1 <= options.client_cores <= 16):
        parser.error("require duration (0,60], warmup (0,30], repeats 1..20, connections 1..16384, client cores 1..16")
    if not 1 <= options.zig_workers <= 32:
        parser.error("require 1..32 Zig workers")
    if options.zig_max_connections is not None and not 1 <= options.zig_max_connections <= 8168:
        parser.error("Zig public connection capacity must be 1..8168")
    if options.zig_max_active is not None and not 1 <= options.zig_max_active <= 8192:
        parser.error("Zig active-request capacity must be 1..8192")
    cores = available_cores()
    if options.client_host:
        if not options.remote_client_binary or options.server_address in ("127.0.0.1", "0.0.0.0", "localhost"):
            parser.error("remote load requires a binary path and a reachable --server-address")
        server_cpu, client_cpus = cores[0], list(range(options.client_cores))
    elif len(cores) < options.client_cores + 1:
        parser.error("require one physical core for Zig plus the requested client cores")
    else:
        server_cpu, client_cpus = cores[0], cores[1:options.client_cores + 1]
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    required = max(options.connections) + 256
    if hard != resource.RLIM_INFINITY and hard < required:
        parser.error(f"RLIMIT_NOFILE hard limit {hard} is below required {required}")
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, required), hard))
    commands = build()
    binaries = {
        "zig_debug": BUILD / "debug" / "bin" / "zhtps",
        "zig_release_safe": BUILD / "release_safe" / "bin" / "zhtps",
        "go": BUILD / "go_server",
    }
    sources = [ROOT / "build.zig", ROOT / "build.zig.zon"]
    sources += sorted((ROOT / "src").rglob("*.zig")) + sorted((ROOT / "bench").rglob("*.go"))
    sources.append(Path(__file__).resolve())
    sources.append(ROOT / "bench/remote_load.py")
    report = {
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kernel": platform.release(),
        "machine": platform.machine(),
        "cpu": command(["lscpu"], capture_output=True).stdout,
        "zig": command(["zig", "version"], capture_output=True).stdout.strip(),
        "go": command(["go", "version"], capture_output=True).stdout.strip(),
        "go_environment": json.loads(command(["go", "env", "-json", "GOAMD64", "GOEXPERIMENT"],
                                              capture_output=True).stdout),
        "server_cpu": server_cpu,
        "client_cpus": client_cpus,
        "server_identity": identity(),
        "server_address": options.server_address,
        "client_host": options.client_host,
        "go_cpu_mode": options.go_cpu_mode,
        "tls": {"enabled": bool(options.tls_certificate),
                "version": "TLS 1.3" if options.tls_certificate else None,
                "certificate_verification": False if options.tls_certificate else None,
                "openssl": ssl.OPENSSL_VERSION,
                "certificate_sha256": hashlib.sha256(options.tls_certificate.read_bytes()).hexdigest()
                if options.tls_certificate else None},
        "allow_errors": options.allow_errors,
        "zig_workers": options.zig_workers,
        "zig_access_log": options.zig_access_log,
        "zig_max_connections": options.zig_max_connections,
        "zig_max_active": options.zig_max_active,
        "available_cpus": sorted(os.sched_getaffinity(0)),
        "nofile_limits": resource.getrlimit(resource.RLIMIT_NOFILE),
        "build_commands": commands,
        "binary_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for name, path in {**binaries, "load": BUILD / "load"}.items()},
        "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in sources},
        "workload": "HTTP/1.1 GET /, 6-byte ZHTPS\\n body, keep-alive, no pipelining, closed loop",
        "duration_seconds": options.duration,
        "warmup_seconds": options.warmup,
        "repeats": options.repeats,
        "runs": [],
    }
    options.output.parent.mkdir(parents=True, exist_ok=True)
    for repeat in range(options.repeats):
        offset = repeat % len(options.variants)
        order = options.variants[offset:] + options.variants[:offset]
        for connections in options.connections:
            for variant in order:
                result = run_one(variant, binaries[variant], options, server_cpu,
                                 client_cpus, connections, repeat + 1)
                report["runs"].append(result)
                options.output.write_text(json.dumps(report, indent=2) + "\n")
                if result["outcome"] == "unsupported":
                    print(f"run {repeat + 1} c={connections} {variant}: unsupported ({result['reason']})", flush=True)
                    continue
                print(f"run {repeat + 1} c={connections:3} {variant:16} "
                      f"{result['window_successes_per_second'] if options.allow_errors else result['requests_per_second']:10.0f} req/s "
                      f"p99={result['latency_us']['p99']:9.1f} us "
                      f"failures={result['window_failures'] or {}} "
                      f"server_cpu={result['server_cpu_percent_including_warmup']:.1f}% "
                      f"client_cpu={result['generator_cpu_percent_including_warmup']:.1f}%", flush=True)
    report["summary"] = summarize(report["runs"], options.connections, options.variants)
    options.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Wrote {options.output}", flush=True)


if __name__ == "__main__":
    main()
