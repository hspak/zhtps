"""Verify the remote collector protocol and child cleanup through real processes."""

import hashlib
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench"))
from remote_load import RemoteLoad, identity


class RemoteLoadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zhtps-remote-test-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.binary = self.folder / "client"
        self.binary.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys, time
arguments = sys.argv[1:]
if "fail_report" in arguments:
    print(json.dumps({"errors": 1, "failures": ["response timeout"]}))
    sys.exit(3)
if "fail" in arguments:
    print("intentional client error", file=sys.stderr)
    sys.exit(3)
if "hang" in arguments:
    time.sleep(600)
time.sleep(.65)
body = pathlib.Path(arguments[arguments.index("-request-body") + 1]).read_bytes()
print(json.dumps({"body": list(body), "cpus": sorted(os.sched_getaffinity(0))}))
''')
        self.binary.chmod(0o700)
        self.errors = (self.folder / "errors").open("w+")
        self.addCleanup(self.errors.close)
        self.remote = RemoteLoad("test-transport", self.errors,
                                 transport=[sys.executable, "-u", str(ROOT / "bench/remote_load.py")])
        self.addCleanup(self.remote.stop)
        self.cpus = [min(os.sched_getaffinity(0))]

    def wait(self):
        deadline = time.monotonic() + 5
        while not self.remote.completed():
            if time.monotonic() > deadline:
                self.fail("collector did not complete")
            time.sleep(.02)

    def test_upload_identity_affinity_resources_and_report_are_preserved(self):
        payload = self.folder / "payload"
        payload.write_bytes(b"\x00workload\xff")
        self.remote.start(str(self.binary), [], self.cpus, 1, 3, {"-request-body": payload})
        self.wait()
        self.assertEqual(list(payload.read_bytes()), self.remote.result["client"]["body"])
        self.assertEqual(self.cpus, self.remote.result["client"]["cpus"])
        self.assertEqual(identity()["boot_id"], self.remote.identity["boot_id"])
        self.assertEqual(hashlib.sha256(self.binary.read_bytes()).hexdigest(), self.remote.started["binary_sha256"])
        self.assertEqual(hashlib.sha256(payload.read_bytes()).hexdigest(), self.remote.started["files"]["-request-body"]["sha256"])
        self.assertGreater(len(self.remote.samples), 0)
        self.assertGreater(self.remote.samples[-1]["VmRSS"], 0)
        adjusted = self.remote.samples[-1]["unix_ns"] + self.remote.clock_offset_ns
        self.assertLess(abs(time.time_ns() - adjusted), 2_000_000_000)
        self.remote.process.wait(timeout=3)
        self.assertEqual(0, self.remote.process.returncode)

    def test_client_failure_is_not_reported_as_success(self):
        self.remote.start(str(self.binary), ["fail"], self.cpus, 1, 3, {})
        with self.assertRaisesRegex(RuntimeError, "intentional client error"):
            self.wait()
        self.assertIsNone(self.remote.result)

    def test_failed_client_report_survives_transport(self):
        self.remote.start(str(self.binary), ["fail_report"], self.cpus, 1, 3, {})
        with self.assertRaisesRegex(RuntimeError, "load client exited 3"):
            self.wait()
        self.assertIsNone(self.remote.result)
        self.assertEqual(3, self.remote.failure["exit_code"])
        self.assertEqual({"errors": 1, "failures": ["response timeout"]}, self.remote.failure["client"])

    def test_exit_during_proc_sampling_preserves_success_report(self):
        self.remote.stop()
        agent = "import sys, os; sys.path.insert(0, " + repr(str(ROOT / "bench")) + "); import remote_load\n" + """
def sample_after_exit(pid):
    os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)
    raise PermissionError("proc fd directory became unreadable at exit")
remote_load.sample_process = sample_after_exit
remote_load.agent()
"""
        self.remote = RemoteLoad("test-transport", self.errors,
                                 transport=[sys.executable, "-u", "-c", agent])
        self.addCleanup(self.remote.stop)
        payload = self.folder / "payload"
        payload.write_bytes(b"completed")
        self.remote.start(str(self.binary), [], self.cpus, 1, 3, {"-request-body": payload})
        self.wait()
        self.assertEqual(0, self.remote.result["exit_code"])
        self.assertEqual(list(b"completed"), self.remote.result["client"]["body"])

    def test_parent_disconnect_stops_and_reaps_the_load_process(self):
        self.remote.start(str(self.binary), ["hang"], self.cpus, 1, 60, {})
        pid = self.remote.started["pid"]
        os.kill(pid, 0)
        self.remote.stop()
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_deadline_stops_a_stuck_client(self):
        self.remote.start(str(self.binary), ["hang"], self.cpus, 1, .2, {})
        pid = self.remote.started["pid"]
        with self.assertRaisesRegex(RuntimeError, "exceeded its run deadline"):
            self.wait()
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_silent_parent_cannot_leave_traffic_running(self):
        self.remote.start(str(self.binary), ["hang"], self.cpus, 1, 60, {}, heartbeat_seconds=.2)
        pid = self.remote.started["pid"]
        time.sleep(.8)
        with self.assertRaisesRegex(RuntimeError, "heartbeat expired"):
            self.remote.collect()
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
