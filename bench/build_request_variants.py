"""Build isolated variants with separate local caches and retain compiler provenance."""

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/critical-path-experiments"


def build(name, workspace, output, global_cache=Path("/tmp/zhtps-zig-global")):
    tree = workspace.resolve() / name
    command = ["zig", "build", "install", "install-hot-paths", "--release=safe", "-Dcpu=x86_64_v4",
               "--prefix", str(tree / "out"), "--cache-dir", str(tree / "cache"),
               "--global-cache-dir", str(global_cache), "--verbose"]
    result = subprocess.run(command, cwd=tree, capture_output=True, text=True)
    log = result.stdout + result.stderr
    if result.returncode:
        (output / (name + "-build-failed.txt")).write_text(log)
        raise RuntimeError(f"{name}: {log}")
    sources = {str(p.relative_to(tree)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((tree / "src").rglob("*.zig"))}
    binaries = {name: hashlib.sha256((tree / "out/bin" / name).read_bytes()).hexdigest() for name in ("zhtps", "hot-paths")}
    # Cached builds may omit compiler commands. Accept one only when its existing
    # provenance still identifies this exact tree, source set, and executables.
    if f"-Mzhtps={tree}/src/root.zig" not in log:
        previous = output / (name + "-build.json")
        evidence = output / (name + "-build.txt")
        record = json.loads(previous.read_text()) if previous.exists() else {}
        if (record.get("cwd") != str(tree) or record.get("sources") != sources or
                record.get("binaries") != binaries or not evidence.exists() or
                f"-Mzhtps={tree}/src/root.zig" not in evidence.read_text()):
            raise RuntimeError(f"{name}: missing compiler source-root evidence; use a fresh tree-local cache")
        return record
    (output / (name + "-build.txt")).write_text(log)
    record = {"command": command, "cwd": str(tree), "sources": sources, "binaries": binaries}
    (output / (name + "-build.json")).write_text(json.dumps(record, indent=2) + "\n")
    print(name, binaries["zhtps"], flush=True)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variants", nargs="+")
    parser.add_argument("--workspace", type=Path, default=Path("/tmp/zhtps-experiments"))
    parser.add_argument("--records", type=Path, default=OUTPUT)
    parser.add_argument("--global-cache-dir", type=Path, default=Path("/tmp/zhtps-zig-global"))
    args = parser.parse_args()
    args.records.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        records = list(pool.map(lambda name: build(name, args.workspace, args.records, args.global_cache_dir), args.variants))
    hashes = [r["binaries"]["zhtps"] for r in records]
    if len(hashes) != len(set(hashes)):
        raise RuntimeError("different variants produced identical executables")


if __name__ == "__main__":
    main()
