"""Run a repeatable admission-overload/recovery sweep against a local executable."""

import argparse
import json
import os
import platform
import subprocess
import sys

from wire import BINARY, Running


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    options = parser.parse_args()
    cpus = sorted(os.sched_getaffinity(0))
    results = []
    with Running("--max-active", "16", "--max-rejecting", "16", "--rate", "1000",
                 "--burst", "32", "--rejection-rate", "2000") as server:
        os.sched_setaffinity(server.process.pid, {cpus[0]})

        def pin_generator():
            os.sched_setaffinity(0, {cpus[min(1, len(cpus) - 1)]})

        for rate in (250, 1500, 6000, 250):
            run = subprocess.run(
                [sys.executable, "tests/load.py", "--port", str(server.port),
                 "--rate", str(rate), "--duration", "2", "--connections", "16", "--queue", "256"],
                preexec_fn=pin_generator, capture_output=True, check=True, timeout=30,
            )
            report = json.loads(run.stdout)
            accounted = sum(report["statuses"].values()) + sum(report["transport_errors"].values()) + report["generator_queue_drops"]
            if accounted != report["offered"]:
                raise AssertionError((accounted, report["offered"]))
            results.append(report)
    with open(options.output, "w") as output:
        json.dump({
            "kernel": platform.release(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "server_cpu": cpus[0],
            "generator_cpu": cpus[min(1, len(cpus) - 1)],
            "binary": BINARY,
            "admission_rate": 1000,
            "admission_burst": 32,
            "max_active": 16,
            "phases": results,
        }, output, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
