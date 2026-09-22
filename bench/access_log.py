"""Measure access logs with a real sink and audit every retained public record."""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time

from overload import proc_sample, stop


USER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")


def metrics(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET", "/debug/metrics")
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f"metrics returned {response.status}")
        return json.loads(response.read())
    finally:
        connection.close()


def ports_from_log(path, process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        ports = {}
        for line in path.read_bytes().splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("event") in ("listening", "admin_listening"):
                ports[event["event"]] = event["port"]
        if len(ports) == 2:
            return ports
        if process.poll() is not None:
            raise RuntimeError(path.read_text())
        time.sleep(.01)
    raise TimeoutError("server startup")


def drain(port):
    deadline = time.monotonic() + 5
    while True:
        captured = metrics(port)
        if captured["gauges"]["log_pending"] <= 1:
            return captured
        if time.monotonic() > deadline:
            raise TimeoutError("log drain")
        time.sleep(.01)


def collect(pipe, sink):
    try:
        while chunk := os.read(pipe.fileno(), 65536):
            sink.write(chunk)
            sink.flush()
    finally:
        pipe.close()


def run_client(args, client, env, seconds):
    command = [*client, "-schedule", f"{args.rate}:{seconds}s"] if args.rate else [
        *client, "-duration", f"{seconds}s"]
    raw = json.loads(subprocess.check_output(command, env=env, timeout=seconds + 10))
    if not args.rate:
        return raw
    phase = raw["phases"][0]
    if (phase["successes"] != phase["sent"] or phase["failures"] or
            phase["successes"] < .99 * phase["offered"]):
        raise RuntimeError(f"offered load missed its target or failed to validate sent requests: {phase}")
    return {"validated_responses": phase["successes"], "elapsed_seconds": raw["elapsed_seconds"],
            "responses_per_second": phase["successes"] / raw["elapsed_seconds"],
            "failures": phase["failures"], "offered": raw}


def trial(args, binary, name, repeat, logging):
    log_path = args.output.parent / f"{name}-{repeat}-{'on' if logging else 'off'}.jsonl"
    command = ["taskset", "-c", args.server_cpus, str(binary), "--port", "0",
               "--admin-port", "0", "--workers", str(args.workers), "--worker-cpus", args.server_cpus,
               "--max-connections", str(args.capacity), "--max-active", str(args.capacity),
               "--max-requests", "4294967295", "--log-slots", str(args.log_slots),
               "--large-buffer-bytes", "67108864", "--http2-worker-streams", "256",
               "--http2-memory-bytes", "67108864"]
    if not logging:
        command.append("--no-access-log")
    with log_path.open("wb") as sink:
        server = subprocess.Popen(command, stderr=subprocess.PIPE if args.sink == "pipe" else sink,
                                  stdout=subprocess.DEVNULL)
        collector = None
        if args.sink == "pipe":
            collector = threading.Thread(target=collect, args=(server.stderr, sink), daemon=True)
            collector.start()
        try:
            ports = ports_from_log(log_path, server)
            client_binary = args.offered_client if args.rate else args.client
            client = ["taskset", "-c", args.client_cpus, str(client_binary),
                      "-address", f"127.0.0.1:{ports['listening']}",
                      "-connections", str(args.connections),
                      "-user-agent", USER_AGENT]
            client += ["-shards", "4", "-queue", "4096", "-max-lag", "100ms"] if args.rate else [
                "-depth", str(args.depth)]
            env = dict(os.environ, GOMAXPROCS=str(len(cpu_set(args.client_cpus))))
            warmup = run_client(args, client, env, .5)
            before_metrics = drain(ports["admin_listening"])
            time.sleep(.05)
            before = proc_sample(server.pid)
            collector_started = time.process_time()
            workload = run_client(args, client, env, args.seconds)
            collector_cpu = time.process_time() - collector_started
            after = proc_sample(server.pid)
            # Draining is outside the measured request interval, and its CPU is
            # reported separately so deferred log work cannot disappear.
            after_metrics = drain(ports["admin_listening"])
            time.sleep(.05)
            drained = proc_sample(server.pid)
        finally:
            stop(server)
            if collector is not None:
                collector.join(timeout=5)
                if collector.is_alive():
                    raise TimeoutError("log collector")
    if server.returncode != 0 or workload["failures"]:
        raise RuntimeError("server or client failed")
    access_records = 0
    record_count = 0
    digest = hashlib.sha256()
    with log_path.open("rb") as source:
        for line in source:
            digest.update(line)
            event = json.loads(line)
            record_count += 1
            if event.get("event") != "request_complete" or event.get("user_agent") != USER_AGENT:
                continue
            if event["status"] != 200 or event["method"] != "GET" or event["bytes"] != 6:
                raise RuntimeError(f"incorrect access record: {event}")
            if "request" in event or "connection" in event:
                raise RuntimeError("obsolete access fields")
            for key in ("worker", "conn_gen", "conn_slot"):
                if type(event[key]) is not int:
                    raise RuntimeError(f"noninteger {key}")
            access_records += 1
    expected = warmup["validated_responses"] + workload["validated_responses"]
    dropped = after_metrics["counters"]["log_dropped_total"]
    errors = after_metrics["counters"]["log_write_errors_total"]
    if access_records > expected or (not logging and access_records):
        raise RuntimeError("incorrect number of access records")
    if logging and access_records < expected and dropped < expected - access_records:
        raise RuntimeError("missing access records not accounted for by dropped logs")
    result = {
        "variant": name, "repeat": repeat, "logging": logging,
        "server_command": command, "client_command": client,
        "workload": workload, "warmup": warmup,
        "cpu_ns_per_response": (after["cpu_seconds"] - before["cpu_seconds"]) * 1e9 /
                               workload["validated_responses"],
        "drain_cpu_seconds": drained["cpu_seconds"] - after["cpu_seconds"],
        "collector_cpu_seconds": collector_cpu,
        "metrics_before": before_metrics, "metrics_after": after_metrics,
        "log": {"records": record_count, "access_records": access_records,
                "expected_access_records": expected if logging else 0,
                "bytes": log_path.stat().st_size, "sha256": digest.hexdigest(),
                "dropped": dropped, "write_errors": errors,
                "complete": access_records == (expected if logging else 0) and dropped == errors == 0},
    }
    if not args.keep_logs:
        log_path.unlink()
    return result


def cpu_set(value):
    result = set()
    for part in value.split(","):
        first, separator, last = part.partition("-")
        result.update(range(int(first), int(last) + 1) if separator else [int(first)])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variants", nargs="+", help="name=/absolute/path/to/zhtps")
    parser.add_argument("--client", type=Path, required=True)
    parser.add_argument("--offered-client", type=Path)
    parser.add_argument("--rate", type=int, default=0, help="offered requests/s; zero uses closed loop")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--seconds", type=float, default=3)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--server-cpus", default="2")
    parser.add_argument("--client-cpus", default="4-7")
    parser.add_argument("--connections", type=int, default=64)
    parser.add_argument("--capacity", type=int, default=256)
    parser.add_argument("--depth", type=int, default=1)
    parser.add_argument("--log-slots", type=int, default=256)
    parser.add_argument("--logging", choices=("on", "off", "both"), default="both")
    parser.add_argument("--sink", choices=("file", "pipe"), default="file")
    parser.add_argument("--keep-logs", action="store_true")
    args = parser.parse_args()
    if min(args.repeats, args.seconds, args.workers, args.connections, args.capacity, args.log_slots) <= 0:
        parser.error("counts and durations must be positive")
    if cpu_set(args.server_cpus) & cpu_set(args.client_cpus):
        parser.error("server and client CPUs must be disjoint")
    if len(cpu_set(args.server_cpus)) != args.workers:
        parser.error("supply exactly one server CPU per worker")
    if args.rate < 0 or (args.rate and (args.offered_client is None or args.depth != 1)):
        parser.error("offered load needs --offered-client and --depth=1")
    monitor = os.sched_getaffinity(0) - cpu_set(args.server_cpus) - cpu_set(args.client_cpus)
    if monitor:
        os.sched_setaffinity(0, {min(monitor)})
    args.client = args.client.resolve()
    if args.offered_client is not None:
        args.offered_client = args.offered_client.resolve()
    variants = {name: Path(path).resolve() for name, path in (v.split("=", 1) for v in args.variants)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "kernel": platform.release(), "machine": platform.machine(),
        "sink": args.sink, "options": {k: str(v) if isinstance(v, Path) else v
                                          for k, v in vars(args).items()},
        "binary_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for name, path in variants.items()},
        "client_sha256": hashlib.sha256(args.client.read_bytes()).hexdigest(), "runs": [],
    }
    if args.offered_client is not None:
        report["offered_client_sha256"] = hashlib.sha256(args.offered_client.read_bytes()).hexdigest()
    modes = [True, False] if args.logging == "both" else [args.logging == "on"]
    cases = [(name, binary, logging) for name, binary in variants.items() for logging in modes]
    for repeat in range(args.repeats):
        for name, binary, logging in (cases if repeat % 2 == 0 else reversed(cases)):
            result = trial(args, binary, name, repeat, logging)
            report["runs"].append(result)
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({k: result[k] for k in
                              ("variant", "repeat", "logging", "cpu_ns_per_response", "log")} |
                             {"rps": result["workload"]["responses_per_second"]}), flush=True)
    report["summary"] = {}
    for name, _, logging in cases:
        runs = [r for r in report["runs"] if r["variant"] == name and r["logging"] == logging]
        report["summary"][name + ("_on" if logging else "_off")] = {
            "median_cpu_ns": statistics.median(r["cpu_ns_per_response"] for r in runs),
            "median_rps": statistics.median(r["workload"]["responses_per_second"] for r in runs),
            "all_logs_complete": all(r["log"]["complete"] for r in runs),
            "retained_fraction": [r["log"]["access_records"] / r["log"]["expected_access_records"]
                                  for r in runs if r["log"]["expected_access_records"]],
        }
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
