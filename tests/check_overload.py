"""Check that evidence gates reject the known ways an overload trial can mislead."""

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench"))
from check_overload import Targets, audit


def fixture():
    counters = {name: 0 for name in ("ListenOverflows", "ListenDrops", "TCPReqQFullDoCookies",
                                    "TCPReqQFullDrop", "TCPBacklogDrop")}
    report = {"status": "complete", "server_exit": 0, "config": {}, "samples": [],
              "kernel_before": dict(counters), "kernel_after": dict(counters),
              "server_identity": {"boot_id": "origin"},
              "remote_client": {"identity": {"boot_id": "generator"}, "separate_kernel": True,
                                "clock_uncertainty_ns": 1000000},
              "client": {"churn": False, "phases": []}}
    phases = [("baseline", 100, 60)]
    for multiple in (2, 5, 10):
        phases.extend(((f"overload_{multiple}x", 100 * multiple, 180), (f"recovery_{multiple}x", 50, 30)))
    start = 1000
    for label, rate, seconds in phases:
        successes = min(rate, 100) * seconds
        rejections = rate * seconds - successes
        def latency(count):
            return {"count": count, "p99_us": 1000, "p999_us": 2000, "p9999_us": 3000, "max_us": 4000}
        phase = {"label": label, "offered_rate": rate, "duration_seconds": seconds,
                 "start_unix_ns": start * 10**9, "end_unix_ns": (start + seconds) * 10**9,
                 "offered": rate * seconds, "sent": rate * seconds, "sent_per_second": rate,
                 "successes": successes, "window_successes_per_second": successes / seconds,
                 "failures": {"http_503": rejections} if rejections else {},
                 "generator_queue_drops": 0, "generator_expired": 0,
                 "success_latency": latency(successes), "success_service_latency": latency(successes),
                 "rejection_latency": latency(rejections), "failure_latency": latency(0),
                 "scheduler_lag": latency(rate * seconds)}
        report["client"]["phases"].append(phase)
        for second in (start + 1, start + seconds - 1):
            report["samples"].append({"unix_ns": second * 10**9,
                                      "server": {"VmRSS": 85 * 2**20, "fds": 32, "cpu_seconds": second * .3},
                                      "client": {"cpu_seconds": second * .5}, "kernel": dict(counters),
                                      "server_cores": {"cpu0": [second * 80, 0, 0, second * 20, 0, 0, 0, 0]}})
        start += seconds
    return report


class AuditTests(unittest.TestCase):
    def test_complete_evidence_passes(self):
        self.assertEqual([], audit(fixture())["issues"])

    def test_high_goodput_cannot_hide_unsent_offers(self):
        report = fixture()
        phase = report["client"]["phases"][5]
        phase["generator_queue_drops"] = 90000
        phase["failures"]["http_503"] -= 90000
        phase["sent"] -= 90000
        phase["sent_per_second"] = phase["sent"] / phase["duration_seconds"]
        issues = audit(report)["issues"]
        self.assertTrue(any("insufficient network attempts/writes" in issue for issue in issues))

    def test_p99_cannot_hide_missing_or_slow_failure_tail(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                report = fixture()
                latency = report["client"]["phases"][1]["rejection_latency"]
                if missing:
                    del latency["p999_us"]
                else:
                    latency["p999_us"] = 1000000
                self.assertTrue(any("rejection p99.9" in issue for issue in audit(report)["issues"]))

    def test_mean_cpu_cannot_hide_a_saturated_core(self):
        report = fixture()
        for sample in report["samples"]:
            second = sample["unix_ns"] // 10**9
            sample["server_cores"] = {"cpu0": [second * 100, 0, 0, 0, 0, 0, 0, 0],
                                      "cpu1": [second * 40, 0, 0, second * 60, 0, 0, 0, 0]}
        result = audit(report)
        self.assertEqual(70, result["summary"]["phases"][1]["server_core_busy_percent"])
        self.assertTrue(any("per-core CPU headroom" in issue for issue in result["issues"]))

    def test_recovery_memory_growth_fails(self):
        report = fixture()
        report["samples"][-1]["server"]["VmRSS"] *= 2
        self.assertTrue(any("recovery_10x: bounded server RSS" in issue for issue in audit(report)["issues"]))

    def test_remote_label_does_not_override_identical_kernel_identity(self):
        report = fixture()
        report["remote_client"]["identity"]["boot_id"] = "origin"
        self.assertTrue(any("separate generator kernel" in issue for issue in audit(report)["issues"]))

    def test_missing_long_phase_is_not_treated_as_complete(self):
        report = fixture()
        report["client"]["phases"].pop(5)
        self.assertIn("overload_10x: missing phase", audit(report)["issues"])
        with self.assertRaises(ValueError):
            audit(fixture(), Targets(overload_seconds=2))

    def test_lost_offer_is_rejected(self):
        report = fixture()
        report["client"]["phases"][1]["successes"] -= 1
        with self.assertRaisesRegex(ValueError, "offer accounting"):
            audit(report)


if __name__ == "__main__":
    unittest.main()
