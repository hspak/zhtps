"""Run fixed-rate phases against an isolated local ZHTPS process and record resources."""

import argparse
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import time

from remote_load import RemoteLoad, identity


ROOT = Path(__file__).resolve().parents[1]


def cpu_list(value):
    result = []
    for part in value.split(","):
        ends = part.split("-")
        result.extend(range(int(ends[0]), int(ends[-1]) + 1))
    return result


def proc_sample(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    status = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith(("VmRSS:", "VmHWM:", "VmSwap:")):
            key, amount, _ = line.split()
            status[key[:-1]] = int(amount) * 1024
        elif line.startswith(("voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:")):
            key, amount = line.split()
            status[key[:-1]] = int(amount)
    return dict(status, cpu_seconds=(int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK"),
                user_seconds=int(fields[11]) / os.sysconf("SC_CLK_TCK"),
                system_seconds=int(fields[12]) / os.sysconf("SC_CLK_TCK"),
                minor_faults=int(fields[7]), major_faults=int(fields[9]), last_cpu=int(fields[36]),
                fds=len(list(Path(f"/proc/{pid}/fd").iterdir())))


def kernel_sample():
    lines = Path("/proc/net/netstat").read_text().splitlines()
    selected = ("ListenOverflows", "ListenDrops", "TCPReqQFullDoCookies", "TCPReqQFullDrop", "TCPBacklogDrop")
    for index, line in enumerate(lines):
        if line.startswith("TcpExt:"):
            fields = dict(zip(line.split()[1:], map(int, lines[index + 1].split()[1:])))
            result = {name: fields.get(name, 0) for name in selected}
            for sockets in Path("/proc/net/sockstat").read_text().splitlines():
                if sockets.startswith("TCP:"):
                    parts = sockets.split()[1:]
                    result.update({"tcp_" + parts[i]: int(parts[i + 1]) for i in range(0, len(parts), 2)})
            result["softirqs"] = {parts[0][:-1]: list(map(int, parts[1:]))
                                  for line in Path("/proc/softirqs").read_text().splitlines()
                                  if (parts := line.split()) and parts[0] in ("NET_RX:", "NET_TX:")}
            result["interfaces"] = {}
            for line in Path("/proc/net/dev").read_text().splitlines()[2:]:
                name, values = line.split(":", 1)
                fields = list(map(int, values.split()))
                result["interfaces"][name.strip()] = dict(zip(
                    ("rx_bytes", "rx_packets", "rx_errors", "rx_drops", "tx_bytes", "tx_packets", "tx_errors", "tx_drops"),
                    fields[:4] + fields[8:12]))
            return result
    return {}


def core_sample(cpus):
    names = {f"cpu{cpu}" for cpu in cpus}
    return {parts[0]: list(map(int, parts[1:])) for line in Path("/proc/stat").read_text().splitlines()
            if (parts := line.split()) and parts[0] in names}


def get_json(connection, path):
    connection.request("GET", path)
    response = connection.getresponse()
    body = response.read()
    if response.status != 200:
        raise RuntimeError(f"{path}: HTTP {response.status}")
    return json.loads(body)


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--server-binary", type=Path, default=ROOT / "zig-out/bench/overload/bin/zhtps")
    parser.add_argument("--server-address", default="127.0.0.1")
    parser.add_argument("--server-port", type=int, default=0)
    parser.add_argument("--target-address", help="client destination host:port, e.g. an already configured ingress")
    parser.add_argument("--client-host", help="SSH load-generator host with an existing trusted host key")
    parser.add_argument("--remote-client-binary", help="path to the installed load binary on the generator host")
    parser.add_argument("--remote-timeout", type=float, default=3600)
    parser.add_argument("--allow-same-host-client", action="store_true", help="functional protocol checks only; not separate-host capacity evidence")
    parser.add_argument("--schedule", required=True, help="rate:duration,...; durations use s or m")
    parser.add_argument("--labels", help="comma-separated phase labels")
    parser.add_argument("--server-cpus", default="0")
    parser.add_argument("--client-cpus", default="1-14")
    parser.add_argument("--client-netns-pid", type=int, help="run the local client in an existing owned network namespace")
    parser.add_argument("--observed-cpus", help="CPU accounting set, including separate kernel polling CPUs when relevant")
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--max-connections", type=int, default=512)
    parser.add_argument("--connections", type=int, default=512)
    parser.add_argument("--shards", type=int, default=8)
    parser.add_argument("--queue", type=int, default=128)
    parser.add_argument("--max-lag", default="10ms")
    parser.add_argument("--rate-limit", type=int, default=0)
    parser.add_argument("--burst", type=int)
    parser.add_argument("--max-active", type=int)
    parser.add_argument("--rejection-rate", type=int, default=1000)
    parser.add_argument("--churn", action="store_true")
    parser.add_argument("--access-log", action="store_true")
    parser.add_argument("--source-ips", type=int, default=0)
    parser.add_argument("--method", default="GET")
    parser.add_argument("--path", default="/")
    parser.add_argument("--request-body", type=Path)
    parser.add_argument("--expect-body", type=Path)
    parser.add_argument("--content-type", default="application/octet-stream")
    parser.add_argument("--allow-chunked", action="store_true")
    parser.add_argument("--client-max-requests", type=int, default=0)
    parser.add_argument("--server-max-requests", type=int, default=4294967295)
    parser.add_argument("--timeout", default="1s")
    options = parser.parse_args()
    if options.client_netns_pid is not None and options.client_host:
        parser.error("local network namespaces cannot be combined with a remote client")
    if not options.client_host and set(cpu_list(options.server_cpus)) & set(cpu_list(options.client_cpus)):
        parser.error("server and client CPU lists must not overlap")
    if options.client_host:
        if not options.remote_client_binary or not 0 < options.remote_timeout <= 86400:
            parser.error("remote runs require a binary path and timeout in (0, 86400] seconds")
        if options.source_ips:
            parser.error("loopback source IP sharding is not valid for a remote generator")
        if not options.target_address and ipaddress.ip_address(options.server_address).is_loopback:
            parser.error("remote runs require a reachable --server-address or an explicit --target-address")
    if options.workers > len(cpu_list(options.server_cpus)):
        parser.error("provide at least one server CPU per worker")
    monitor_cpus = set(os.sched_getaffinity(0)) - set(cpu_list(options.server_cpus))
    if not options.client_host:
        monitor_cpus -= set(cpu_list(options.client_cpus))
    if monitor_cpus:
        os.sched_setaffinity(0, {min(monitor_cpus)})
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    needed = options.connections + options.workers * options.max_connections + 256
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(max(soft, needed), hard), hard))
    options.output.parent.mkdir(parents=True, exist_ok=True)
    server_binary = options.server_binary.resolve()
    client_binary = ROOT / "zig-out/bench/load"
    workload_files = {flag: path.resolve() for flag, path in
                      (("-request-body", options.request_body), ("-expect-body", options.expect_body)) if path}
    server_command = ["taskset", "-c", options.server_cpus, str(server_binary),
                      "--address", options.server_address, "--port", str(options.server_port),
                      "--admin-port", "0", "--workers", str(options.workers),
                      "--max-connections", str(options.max_connections), "--rate", str(options.rate_limit),
                      "--rejection-rate", str(options.rejection_rate), "--max-requests", str(options.server_max_requests)]
    if not options.access_log:
        server_command += ["--no-access-log"]
    for flag, value in (("--burst", options.burst), ("--max-active", options.max_active)):
        if value is not None:
            server_command += [flag, str(value)]
    server = client = connection = remote = None
    report = {"status": "running", "started_unix_ns": time.time_ns(), "kernel": platform.release(),
              "machine": platform.machine(), "options": {k: str(v) if isinstance(v, Path) else v for k, v in vars(options).items()},
              "server_command": server_command, "monitor_cpus": sorted(os.sched_getaffinity(0)),
              "server_identity": identity(),
              "samples": [], "kernel_before": kernel_sample(),
              "hashes": {str(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in [server_binary, *([] if options.client_host else [client_binary]),
                                      *sorted((ROOT / "src").rglob("*.zig")), *workload_files.values(),
                                      ROOT / "bench/load/main.go", ROOT / "bench/load/offered.go",
                                      ROOT / "bench/remote_load.py", Path(__file__).resolve()]},
              "toolchains": {name: subprocess.check_output([name, "version"], text=True).strip() for name in ("zig", "go")}}
    raw_path = options.output.with_suffix(".client.json")
    log_path = options.output.with_suffix(".server.log")
    error_path = options.output.with_suffix(".client.log")
    try:
        with log_path.open("w+") as server_log, raw_path.open("w") as client_output, error_path.open("w") as client_error:
            server = subprocess.Popen(server_command, stdout=subprocess.DEVNULL, stderr=server_log)
            ports = {}
            deadline = time.monotonic() + 10
            while len(ports) < 2:
                if server.poll() is not None:
                    raise RuntimeError(f"server exited: {log_path.read_text()}")
                for line in log_path.read_text().splitlines():
                    event = json.loads(line)
                    if event.get("event") in ("listening", "admin_listening"):
                        ports[event["event"]] = event["port"]
                if time.monotonic() > deadline:
                    raise TimeoutError("startup")
                time.sleep(.01)
            connection = http.client.HTTPConnection("127.0.0.1", ports["admin_listening"], timeout=.5)
            report["config"] = get_json(connection, "/debug/config")
            report["workers_before"] = get_json(connection, "/debug/workers")
            report["metrics_before"] = get_json(connection, "/debug/metrics")
            destination = options.target_address or f"{options.server_address}:{ports['listening']}"
            client_arguments = ["-address", destination, "-schedule", options.schedule,
                              "-connections", str(options.connections), "-shards", str(options.shards),
                              "-queue", str(options.queue), "-max-lag", options.max_lag, "-timeout", options.timeout,
                              "-source-ips", str(options.source_ips), "-method", options.method, "-path", options.path,
                              "-content-type", options.content_type, "-max-requests", str(options.client_max_requests)]
            if options.churn:
                client_arguments += ["-churn"]
            if options.allow_chunked:
                client_arguments += ["-allow-chunked"]
            if options.client_host:
                remote = RemoteLoad(options.client_host, client_error)
                separate_kernel = remote.identity["boot_id"] != report["server_identity"]["boot_id"]
                if not separate_kernel and not options.allow_same_host_client:
                    raise ValueError("generator shares the origin kernel; this is not a separate-host run")
                remote.start(options.remote_client_binary, client_arguments, cpu_list(options.client_cpus),
                             options.connections, options.remote_timeout, workload_files)
                client = remote.process
                report["client_command"] = remote.started["command"]
                report["remote_client"] = dict(remote.started, host=options.client_host, identity=remote.identity,
                                                separate_kernel=separate_kernel, samples=remote.samples,
                                                clock_offset_to_server_ns=remote.clock_offset_ns,
                                                clock_uncertainty_ns=remote.clock_uncertainty_ns)
                report["client_pid"] = remote.started["pid"]
            else:
                client_command = ["taskset", "-c", options.client_cpus, str(client_binary), *client_arguments]
                if options.client_netns_pid is not None:
                    client_command = ["nsenter", "--target", str(options.client_netns_pid), "--net", *client_command]
                for flag, path in workload_files.items():
                    client_command.extend((flag, str(path)))
                report["client_command"] = client_command
                client = subprocess.Popen(client_command, stdout=client_output, stderr=client_error,
                                          env=dict(os.environ, GOMAXPROCS=str(len(cpu_list(options.client_cpus)))))
                report["client_pid"] = client.pid
            report["server_pid"] = server.pid
            tick = time.monotonic()
            while True:
                finished = remote.completed() if remote else client.poll() is not None
                if finished:
                    break
                sample = {"unix_ns": time.time_ns(), "server": proc_sample(server.pid), "kernel": kernel_sample(),
                          "server_cores": core_sample(cpu_list(options.observed_cpus or options.server_cpus))}
                if remote:
                    if remote.samples:
                        sample["client"] = remote.samples[-1]
                else:
                    try:
                        sample["client"] = proc_sample(client.pid)
                    except FileNotFoundError:
                        pass
                try:
                    sampled = time.monotonic_ns()
                    metrics = get_json(connection, "/debug/metrics")
                    sample["admin_duration_ns"] = time.monotonic_ns() - sampled
                    sample["counters"], sample["gauges"] = metrics["counters"], metrics["gauges"]
                except (OSError, http.client.HTTPException, RuntimeError) as err:
                    sample["admin_error"] = str(err)
                    connection.close()
                report["samples"].append(sample)
                count = len(report["samples"])
                if count % 15 == 0:
                    options.output.write_text(json.dumps(report, indent=2) + "\n")
                    print(json.dumps({"output": str(options.output), "elapsed_samples": count,
                                      "rss_mib": round(sample["server"]["VmRSS"] / 2**20, 1),
                                      "active": sample.get("gauges", {}).get("requests_active"),
                                      "rejected": sample.get("counters", {}).get("requests_rejected_total")}), flush=True)
                if server.poll() is not None:
                    raise RuntimeError("server exited during load")
                tick += 1
                time.sleep(max(0, tick - time.monotonic()))
            if remote:
                remote.stop()
                remote.collect()
                if client.returncode != 0:
                    raise RuntimeError(f"remote collector exited {client.returncode}")
                client_output.write(json.dumps(remote.result["client"]) + "\n")
                client_output.flush()
                report["client"] = json.loads(json.dumps(remote.result["client"]))
                for phase in report["client"]["phases"]:
                    phase["start_unix_ns"] += remote.clock_offset_ns
                    phase["end_unix_ns"] += remote.clock_offset_ns
                client_error.write(remote.result["stderr"])
            else:
                if client.returncode != 0:
                    raise RuntimeError(f"client exited: {error_path.read_text()}")
                report["client"] = json.loads(raw_path.read_text())
            if options.labels:
                labels = options.labels.split(",")
                if len(labels) != len(report["client"]["phases"]):
                    raise ValueError("phase label count does not match")
                for phase, label in zip(report["client"]["phases"], labels):
                    phase["label"] = label
            report["metrics_after"] = get_json(connection, "/debug/metrics")
            report["workers_after"] = get_json(connection, "/debug/workers")
            report["kernel_after"] = kernel_sample()
            report["status"] = "complete"
            for phase in report["client"]["phases"]:
                print(json.dumps({key: phase[key] for key in ("offered_rate", "duration_seconds", "sent_per_second",
                                                             "window_successes_per_second", "success_latency", "failures")}), flush=True)
    except BaseException as err:
        report["status"], report["error"] = "failed", repr(err)
        raise
    finally:
        if connection is not None:
            connection.close()
        if remote is not None:
            remote.stop()
        stop(client)
        stop(server)
        report["server_exit"] = server.returncode if server is not None else None
        report["finished_unix_ns"] = time.time_ns()
        options.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
