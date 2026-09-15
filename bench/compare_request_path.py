"""Alternate prebuilt request-path variants using the validated offered-rate driver."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time

from summarize_overload import summarize

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variants", nargs="+")
    parser.add_argument("--workspace", type=Path, default=Path("/tmp/zhtps-experiments"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", choices=("small", "headers", "logging", "echo", "stream", "many", "overload"), default="small")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--schedule", default="50000:2s,100000:6s,300000:6s")
    parser.add_argument("--connections", type=int, default=64)
    parser.add_argument("--capacity", type=int, default=256)
    parser.add_argument("--server-cpus", default="2")
    parser.add_argument("--client-cpus", default="4-7")
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--records", type=Path, default=ROOT / "zig-out/bench/critical-path-experiments")
    parser.add_argument("--churn", action="store_true")
    parser.add_argument("--isolated-loopback", action="store_true")
    parser.add_argument("--observed-cpus")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    temporary = Path("/tmp") / ("zhtps-trials-" + str(time.time_ns()))
    temporary.mkdir()
    empty = temporary / "empty"
    empty.write_bytes(b"")
    body = temporary / "body"
    body.write_bytes(bytes(range(256)) * 256)
    stream = temporary / "stream"
    stream.write_bytes(b"one\ntwo\nthree\n")
    records = []
    binaries = {name: args.workspace / name / "out/bin/zhtps" for name in args.variants}
    hashes = [hashlib.sha256(binary.read_bytes()).hexdigest() for binary in binaries.values()]
    if len(set(hashes)) != len(hashes):
        raise RuntimeError("variant executables must differ; check build cache/source roots")
    for name, binary in binaries.items():
        provenance = json.loads((args.records / (name + "-build.json")).read_text())
        tree = binary.parents[2]
        current_sources = {str(path.relative_to(tree)): hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sorted((tree / "src").rglob("*.zig"))}
        if current_sources != provenance["sources"]:
            raise RuntimeError(f"{name}: source differs from recorded build")
        if hashlib.sha256(binary.read_bytes()).hexdigest() != provenance["binaries"]["zhtps"]:
            raise RuntimeError(f"{name}: executable differs from recorded build")
    metadata = {"case": args.case, "options": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                "binary_hashes": {k: hashlib.sha256(v.read_bytes()).hexdigest() for k, v in binaries.items()},
                "source_hashes": {name: {str(p.relative_to(args.workspace / name)): hashlib.sha256(p.read_bytes()).hexdigest()
                                         for p in sorted((args.workspace / name / "src").rglob("*.zig"))}
                                  for name in args.variants}, "runs": records}
    for repeat in range(args.repeats):
        order = list(reversed(args.variants)) if repeat % 2 else args.variants
        for variant in order:
            name = f"{variant}-{repeat + 1}"
            output = temporary / (name + ".json")
            command = [sys.executable, str(ROOT / "bench/overload.py"), "--server-binary", str(binaries[variant]),
                       "--output", str(output), "--server-cpus", args.server_cpus, "--client-cpus", args.client_cpus,
                       "--workers", str(args.workers), "--connections", str(args.connections), "--max-connections", str(args.capacity),
                       "--max-active", str(args.capacity), "--schedule", args.schedule]
            if args.churn:
                command += ["--churn", "--source-ips", "64"]
            if args.observed_cpus:
                command += ["--observed-cpus", args.observed_cpus]
            if args.case == "logging":
                command += ["--access-log"]
            elif args.case == "headers":
                command += ["--method", "POST", "--path", "/echo", "--expect-body", str(empty),
                            "--content-type", "application/x-" + "a" * 512]
            elif args.case == "echo":
                command += ["--method", "POST", "--path", "/echo", "--request-body", str(body), "--expect-body", str(body)]
            elif args.case == "stream":
                command += ["--path", "/stream", "--allow-chunked", "--expect-body", str(stream)]
            elif args.case == "overload":
                command += ["--rate-limit", "150000", "--burst", "1024"]
            if args.isolated_loopback:
                command = ["unshare", "--user", "--map-root-user", "--net", sys.executable,
                           str(ROOT / "bench/isolated_loopback.py"), *command]
            print(f"{args.case} repeat {repeat + 1}: {variant}", flush=True)
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=180)
            (args.output / (name + ".txt")).write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(f"{name}: {result.stdout} {result.stderr}")
            raw = json.loads(output.read_text())
            phase_summary = summarize(raw)
            for suffix in (".json", ".client.json"):
                shutil.copyfile(output.with_suffix(suffix), args.output / (name + suffix))
            before, after = raw["metrics_before"], raw["metrics_after"]
            completed = after["counters"]["requests_completed_total"] - before["counters"]["requests_completed_total"]
            io = after["counters"]["io_submissions_total"] - before["counters"]["io_submissions_total"]
            log = {"bytes": output.with_suffix(".server.log").stat().st_size, "records": 0, "access_records": 0}
            with output.with_suffix(".server.log").open() as source:
                for line in source:
                    event = json.loads(line)
                    log["records"] += 1
                    log["access_records"] += event["event"] == "request_complete"
            row = {"variant": variant, "repeat": repeat + 1, "summary": phase_summary,
                   "log": log, "io_per_completed": io / completed,
                   "counter_deltas": {key: after["counters"][key] - value for key, value in before["counters"].items()}}
            records.append(row)
            for phase in phase_summary["phases"]:
                phase["cpu_ns_per_success"] = phase["server_cpu_cores"] * 1e9 / phase["goodput"] if phase.get("goodput") and "server_cpu_cores" in phase else None
            (args.output / "summary.json").write_text(json.dumps(metadata, indent=2) + "\n")
            print(json.dumps({"variant": variant, "io_per_completed": row["io_per_completed"], "access_records": log["access_records"],
                              "phases": [{k: p.get(k) for k in ("offered_rate", "goodput", "cpu_ns_per_success", "service_p99_ms", "failures")} for p in phase_summary["phases"]]}), flush=True)
    medians = {}
    for variant in args.variants:
        rows = [r for r in records if r["variant"] == variant]
        medians[variant] = [{key: statistics.median([r["summary"]["phases"][i][key] for r in rows if r["summary"]["phases"][i].get(key) is not None])
                              for key in ("goodput", "cpu_ns_per_success", "service_p99_ms", "success_p99_ms")}
                             for i in range(len(rows[0]["summary"]["phases"]))]
    metadata["medians"] = medians
    (args.output / "summary.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(medians, indent=2), flush=True)


if __name__ == "__main__":
    main()
