"""Check the fastest case with four versus eight client cores after compare.py."""

import hashlib
import json
from types import SimpleNamespace

from compare import BUILD, ROOT, available_cores, run_one


def main():
    cores = available_cores()
    if len(cores) < 9:
        raise SystemExit("nine distinct physical cores required")
    binary = BUILD / "release_safe" / "bin" / "zhtps"
    options = SimpleNamespace(duration=3, warmup=1)
    runs = []
    for repeat in range(3):
        for count in ((4, 8) if repeat % 2 == 0 else (8, 4)):
            result = run_one("zig_release_safe", binary, options, cores[0],
                             cores[1:count + 1], 128, repeat + 1)
            result["client_cores"] = count
            runs.append(result)
            print(f"client cores={count}: {result['requests_per_second']:.0f} req/s", flush=True)
    output = ROOT / "docs" / "go-comparison-client-check.json"
    output.write_text(json.dumps({
        "server_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "client_sha256": hashlib.sha256((BUILD / "load").read_bytes()).hexdigest(),
        "runs": runs,
    }, indent=2) + "\n")
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
