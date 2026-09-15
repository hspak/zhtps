"""Run the remote harness path through the collector's local process transport.

These checks exercise protocol integration and clock alignment, not SSH access
or separate-host performance. Both limitations are retained in the report.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

LAUNCHER = '''
import sys
sys.path.insert(0, "bench")
import overload, remote_load
class LocalTransport(remote_load.RemoteLoad):
    def __init__(self, host, error_file):
        super().__init__(host, error_file, transport=[sys.executable, "-u", "bench/remote_load.py"])
overload.RemoteLoad = LocalTransport
overload.main()
'''


class RemoteHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zhtps-remote-harness-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.output = self.folder / "report.json"
        cpus = sorted(os.sched_getaffinity(0))
        if len(cpus) < 3:
            self.skipTest("requires three available CPUs")
        # target-address only avoids remote loopback rejection during this local
        # protocol check; it is replaced after the origin chooses its port.
        launcher = LAUNCHER.replace("overload.main()", '''
original_start = LocalTransport.start
def start(self, binary, arguments, *args, **kwargs):
    # The listening event is already recorded when the collector starts.
    import json, pathlib
    log = pathlib.Path(sys.argv[sys.argv.index("--output") + 1]).with_suffix(".server.log")
    for line in log.read_text().splitlines():
        event = json.loads(line)
        if event.get("event") == "listening":
            arguments[arguments.index("-address") + 1] = "127.0.0.1:" + str(event["port"])
    return original_start(self, binary, arguments, *args, **kwargs)
LocalTransport.start = start
overload.main()
''')
        self.command = [sys.executable, "-c", launcher, "--server-binary", ZHTPS,
                        "--output", str(self.output), "--client-host", "local-protocol-test",
                        "--remote-client-binary", str(ROOT / "zig-out/bench/load"),
                        "--target-address", "127.0.0.1:1", "--server-cpus", str(cpus[0]),
                        "--client-cpus", str(cpus[1]), "--connections", "4", "--shards", "2",
                        "--max-connections", "16", "--schedule", "100:2s,100:2s",
                        "--labels", "baseline,recovery"]

    def test_refuses_to_claim_same_kernel_is_a_separate_host(self):
        result = subprocess.run(self.command, cwd=ROOT, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(0, result.returncode)
        report = json.loads(self.output.read_text())
        self.assertEqual("failed", report["status"])
        self.assertIn("shares the origin kernel", report["error"])
        self.assertEqual(0, report["server_exit"])
        self.assertNotIn("client_pid", report)

    def test_remote_resources_and_clock_offset_survive_harness_collection(self):
        result = subprocess.run([*self.command, "--allow-same-host-client"], cwd=ROOT,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        report = json.loads(self.output.read_text())
        raw = json.loads(self.output.with_suffix(".client.json").read_text())
        self.assertEqual("complete", report["status"])
        self.assertFalse(report["remote_client"]["separate_kernel"])
        self.assertEqual(0, report["server_exit"])
        self.assertGreater(len(report["remote_client"]["samples"]), 0)
        self.assertEqual(hashlib.sha256((ROOT / "zig-out/bench/load").read_bytes()).hexdigest(),
                         report["remote_client"]["binary_sha256"])
        for original, normalized in zip(raw["phases"], report["client"]["phases"]):
            self.assertEqual(report["remote_client"]["clock_offset_to_server_ns"],
                             normalized["start_unix_ns"] - original["start_unix_ns"])
            self.assertEqual(original["successes"], normalized["successes"])
            self.assertGreaterEqual(normalized["successes"], 195)
        self.assertTrue(any("client" in sample and sample["client"]["VmRSS"] > 0 for sample in report["samples"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--zhtps", required=True)
    options, remaining = parser.parse_known_args()
    ZHTPS = str(Path(options.zhtps).resolve())
    unittest.main(argv=[sys.argv[0], *remaining])
