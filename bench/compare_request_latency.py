"""Alternate variants at fixed closed-loop concurrency using the existing TCP client."""

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import types

from compare import run_one
from overload import cpu_list


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variants", nargs="+")
    parser.add_argument("--connections", nargs="+", type=int, default=[1, 64])
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--client-cpus", default="4-7")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binaries = {name: Path("/tmp/zhtps-experiments") / name / "out/bin/zhtps" for name in args.variants}
    hashes = [hashlib.sha256(binary.read_bytes()).hexdigest() for binary in binaries.values()]
    if len(set(hashes)) != len(hashes):
        raise RuntimeError("variant executables must differ; check build cache/source roots")
    for name, binary in binaries.items():
        provenance = json.loads((Path(__file__).resolve().parents[1] / "docs/critical-path-experiments" / (name + "-build.json")).read_text())
        tree = binary.parents[2]
        current_sources = {str(path.relative_to(tree)): hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sorted((tree / "src").rglob("*.zig"))}
        if current_sources != provenance["sources"]:
            raise RuntimeError(f"{name}: source differs from recorded build")
        if hashlib.sha256(binary.read_bytes()).hexdigest() != provenance["binaries"]["zhtps"]:
            raise RuntimeError(f"{name}: executable differs from recorded build")
    report = {"binary_hashes": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()}, "client_cpus": args.client_cpus, "runs": []}
    options = types.SimpleNamespace(duration=4, warmup=1, zig_access_log=False, zig_workers=1)
    for connections in args.connections:
        for repeat in range(args.repeats):
            for name in (list(reversed(args.variants)) if repeat % 2 else args.variants):
                result = run_one(name, binaries[name], options, 2, cpu_list(args.client_cpus), connections, repeat)
                report["runs"].append(result)
                args.output.write_text(json.dumps(report, indent=2) + "\n")
                print(json.dumps({"variant": name, "connections": connections, "repeat": repeat,
                                  "goodput": result["window_successes_per_second"], "latency": result.get("latency_us"),
                                  "cpu_percent": result["server_cpu_percent_including_warmup"]}), flush=True)
    for connections in args.connections:
        for name in args.variants:
            rows = [r for r in report["runs"] if r["variant"] == name and r["connections"] == connections]
            print(name, connections, statistics.median(r["window_successes_per_second"] for r in rows), flush=True)


if __name__ == "__main__":
    main()
