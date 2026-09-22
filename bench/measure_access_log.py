"""Alternate access-log microbenchmarks and check byte counts and queue accounting."""

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variants", nargs="+", help="name=/absolute/path/to/access-log")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cpu", type=int, default=2)
    parser.add_argument("--iterations", type=int, default=2_000_000)
    parser.add_argument("--repeats", type=int, default=5)
    args = parser.parse_args()
    if args.iterations < 1 or args.repeats < 1:
        parser.error("iterations and repeats must be positive")
    variants = {name: Path(path).resolve() for name, path in (v.split("=", 1) for v in args.variants)}
    report = {"iterations": args.iterations, "cpu": args.cpu, "runs": [],
              "sha256": {name: hashlib.sha256(binary.read_bytes()).hexdigest()
                         for name, binary in variants.items()}}
    reference = None
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for repeat in range(args.repeats):
        order = list(variants) if repeat % 2 == 0 else list(reversed(variants))
        for name in order:
            result = subprocess.run(["taskset", "-c", str(args.cpu), str(variants[name]),
                                     str(args.iterations)], capture_output=True, text=True, check=True)
            rows = [json.loads(line) for line in result.stderr.splitlines()]
            signature = [(r["case"], r["batch"], r["iterations"], r["bytes"], r["checksum"], r["dropped"])
                         for r in rows]
            if len(rows) != 12 or any(r["dropped"] for r in rows):
                raise RuntimeError("missing benchmark cases or dropped records")
            if reference is None:
                reference = signature
            elif signature != reference:
                raise RuntimeError("variants produced different sizes, checksums, or accounting")
            report["runs"].append({"variant": name, "repeat": repeat, "rows": rows})
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({"variant": name, "repeat": repeat,
                              "browser_ns": next(r["elapsed_ns"] / r["iterations"] for r in rows
                                                 if r["case"] == "browser" and r["batch"] == 16)}),
                  flush=True)
    report["summary"] = {}
    for name in variants:
        cases = {}
        for run in report["runs"]:
            if run["variant"] != name:
                continue
            for row in run["rows"]:
                cases.setdefault(f"{row['case']}_{row['batch']}", []).append(
                    row["elapsed_ns"] / row["iterations"])
        report["summary"][name] = {
            case: {"median_ns": statistics.median(values), "min_ns": min(values), "max_ns": max(values)}
            for case, values in cases.items()}
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
