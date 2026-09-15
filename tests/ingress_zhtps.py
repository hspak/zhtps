"""Verify ingress rate shedding against the actual ZHTPS executable and load driver."""

import argparse
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy"))
sys.path.insert(0, str(ROOT / "bench"))
from ingress import Options, write_bundle
from summarize_overload import summarize


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class OriginTests(unittest.TestCase):
    def test_excess_payload_requests_stop_at_ingress_and_origin_recovers(self):
        cpus = sorted(os.sched_getaffinity(0))
        if len(cpus) < 4:
            self.skipTest("requires four available CPUs for independent functional test placement")
        with tempfile.TemporaryDirectory(prefix="zhtps-origin-ingress-") as temporary:
            folder = Path(temporary)
            bundle = folder / "ingress"
            options = Options("127.0.0.1", free_port(), "127.0.0.1", free_port(), "lo",
                              200, 8, 2000, 128, 1000, 32, origin_slots=64)
            write_bundle(options, bundle)
            payload = folder / "payload.bin"
            payload.write_bytes(b"payload\n" * 4096)
            proxy_command = ["taskset", "-c", str(cpus[3]), NGINX, "-p", str(bundle) + "/",
                             "-c", "nginx.conf", "-g", "daemon off;"]
            with (folder / "proxy-stderr.log").open("w+") as diagnostics:
                proxy = subprocess.Popen(proxy_command, stdout=subprocess.DEVNULL, stderr=diagnostics)
                try:
                    deadline = time.monotonic() + 5
                    while True:
                        self.assertIsNone(proxy.poll())
                        try:
                            with socket.create_connection((options.listen_address, options.listen_port), .1):
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                self.fail("ingress did not start")
                            time.sleep(.01)
                    output = folder / "result.json"
                    command = [sys.executable, str(ROOT / "bench/overload.py"),
                               "--server-binary", ZHTPS, "--output", str(output),
                               "--server-port", str(options.origin_port),
                               "--target-address", f"127.0.0.1:{options.listen_port}",
                               "--server-cpus", str(cpus[0]), "--client-cpus", f"{cpus[1]},{cpus[2]}",
                               "--connections", "32", "--shards", "4", "--max-connections", "64",
                               "--method", "POST", "--path", "/echo", "--request-body", str(payload),
                               "--expect-body", str(payload), "--client-max-requests", "25",
                               "--server-max-requests", "1000", "--access-log",
                               "--schedule", "100:1s,1000:3s,100:1s", "--labels", "baseline,overload,recovery"]
                    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
                    self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                    report = json.loads(output.read_text())
                    summary = summarize(report)
                    overload = summary["phases"][1]
                    self.assertGreater(overload["sent_rate"], 950)
                    self.assertGreater(overload["goodput"], 150)
                    self.assertLessEqual(overload["goodput"], 205)
                    self.assertGreater(overload["http_failures_per_second"], 700)
                    self.assertEqual(0, overload["transport_failures_per_second"])
                    self.assertLess(overload["rejection_p999_ms"], 100)
                    self.assertGreater(summary["phases"][2]["goodput"], 90)
                    successes = sum(phase["successes"] for phase in report["client"]["phases"])
                    self.assertEqual(successes, report["metrics_after"]["counters"]["requests_admitted_total"])
                    self.assertEqual(0, report["metrics_after"]["counters"]["requests_rejected_total"])
                    self.assertEqual(0, report["config"]["admission"]["requests_per_second"])
                    report["ingress"] = {"options": asdict(options), "command": proxy_command,
                                         "binary_sha256": hashlib.sha256(Path(NGINX).read_bytes()).hexdigest(),
                                         "configuration": (bundle / "nginx.conf").read_text(),
                                         "kernel_policy_applied": False}
                    report["assessment"] = {"purpose": "local functional integration test",
                                            "separate_host": False, "valid_for_capacity": False,
                                            "reason": "Short local test verifies enforcement and accounting, not sustainable capacity."}
                    if RECORD:
                        RECORD.parent.mkdir(parents=True, exist_ok=True)
                        RECORD.write_text(json.dumps(report, indent=2) + "\n")
                finally:
                    proxy.terminate()
                    try:
                        proxy.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proxy.kill()
                        proxy.wait()
                        self.fail("ingress did not stop")
                self.assertEqual(0, proxy.returncode)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--nginx", required=True)
    parser.add_argument("--zhtps", required=True)
    parser.add_argument("--record", type=Path)
    options, remaining = parser.parse_known_args()
    NGINX, ZHTPS = str(Path(options.nginx).resolve()), str(Path(options.zhtps).resolve())
    RECORD = options.record
    unittest.main(argv=[sys.argv[0], *remaining])
