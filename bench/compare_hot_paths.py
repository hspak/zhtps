"""Compare two prebuilt hot-path benchmarks with alternating order and CPU affinity."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--iterations", type=int, default=100_000_000)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if options.cpu not in os.sched_getaffinity(0) or options.iterations <= 0 or options.repeats <= 0:
        parser.error("require an available CPU and positive iterations/repeats")
    binaries = {name: getattr(options, name).resolve() for name in ("before", "after")}
    report = {
        "kernel": platform.release(),
        "cpu": options.cpu,
        "cpu_model": next(line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                          if line.startswith("model name")),
        "binary_hashes": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()},
        "harness_hash": hashlib.sha256(Path(__file__).with_name("hot_paths.zig").read_bytes()).hexdigest(),
        "runs": [],
    }
    expected = None
    for repeat in range(options.repeats):
        for name in (("before", "after") if repeat % 2 == 0 else ("after", "before")):
            command = ["taskset", "-c", str(options.cpu), str(binaries[name]), str(options.iterations)]
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            rows = [json.loads(line) for line in result.stderr.splitlines()]
            outcomes = [{key: value for key, value in row.items() if key != "elapsed_ns"} for row in rows]
            if expected is None:
                expected = outcomes
            if outcomes != expected or not rows or any(row["elapsed_ns"] <= 0 for row in rows):
                raise RuntimeError("benchmark workloads or results differ")
            report["runs"].append({"variant": name, "repeat": repeat, "command": command, "cases": rows})
            print(f"finished {name} repeat {repeat + 1}", flush=True)
    report["summary"] = {}
    for row in expected:
        case = row["case"]
        summary = {}
        for name in binaries:
            samples = [sample["elapsed_ns"] / sample["iterations"] for run in report["runs"]
                       if run["variant"] == name for sample in run["cases"] if sample["case"] == case]
            summary[name] = {"median_ns": statistics.median(samples), "min_ns": min(samples), "max_ns": max(samples)}
        summary["change_percent"] = 100 * (summary["after"]["median_ns"] / summary["before"]["median_ns"] - 1)
        report["summary"][case] = summary
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
