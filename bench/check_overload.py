"""Audit sustained ingress evidence without mistaking unsent load for server shedding.

Targets are explicit engineering defaults, not server guarantees. A failed audit
retains every unmet criterion instead of accepting a smaller successful subset.
"""

import argparse
from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path

from summarize_overload import summarize


@dataclass(frozen=True)
class Targets:
    baseline_seconds: float = 60
    overload_seconds: float = 180
    recovery_seconds: float = 30
    max_unsent_percent: float = .1
    min_goodput_ratio: float = .9
    max_success_p99_ms: float = 10
    max_failure_p999_ms: float = 100
    max_core_busy_percent: float = 85
    max_rss_growth_percent: float = 5
    max_clock_uncertainty_ms: float = 50

    def validate(self):
        if any(not math.isfinite(value) or value < 0 for value in asdict(self).values()):
            raise ValueError("targets must be finite, nonnegative numbers")
        if self.baseline_seconds < 60 or self.overload_seconds < 180 or self.recovery_seconds < 30:
            raise ValueError("sustained evidence requires at least 60/180/30-second baseline/overload/recovery phases")
        if not 0 < self.min_goodput_ratio <= 1 or not self.max_unsent_percent < 100:
            raise ValueError("invalid goodput or unsent-offer target")
        if not 0 < self.max_core_busy_percent <= 100:
            raise ValueError("invalid CPU headroom target")


def audit(report, targets=Targets()):
    targets.validate()
    summary = summarize(report)
    issues = []
    remote = report.get("remote_client", {})
    origin_boot = report.get("server_identity", {}).get("boot_id")
    client_boot = remote.get("identity", {}).get("boot_id")
    if not origin_boot or not client_boot or origin_boot == client_boot or not remote.get("separate_kernel"):
        issues.append("separate generator kernel has not been demonstrated")
    uncertainty = remote.get("clock_uncertainty_ns")
    if uncertainty is None or uncertainty / 1e6 > targets.max_clock_uncertainty_ms:
        issues.append("clock alignment is missing or too uncertain")
    phases = {phase["label"]: phase for phase in summary["phases"]}
    if len(phases) != len(summary["phases"]):
        issues.append("phase labels are not unique")
    baseline = phases.get("baseline")
    if baseline is None:
        issues.append("missing baseline phase")
    required = [("baseline", targets.baseline_seconds)]
    for multiple in (2, 5, 10):
        required.extend(((f"overload_{multiple}x", targets.overload_seconds),
                         (f"recovery_{multiple}x", targets.recovery_seconds)))
    raw_phases = {phase.get("label"): phase for phase in report["client"]["phases"]}
    for label, seconds in required:
        phase = phases.get(label)
        if phase is None:
            issues.append(f"{label}: missing phase")
            continue
        raw = raw_phases[label]
        if phase["seconds"] < seconds:
            issues.append(f"{label}: duration {phase['seconds']} s is below {seconds} s")
        if phase["success_p99_ms"] > targets.max_success_p99_ms:
            issues.append(f"{label}: successful p99 exceeds target")
        if phase["admin_errors"]:
            issues.append(f"{label}: admin sampling failed")
        if baseline and ("rss_max_mib" not in phase or "rss_max_mib" not in baseline or
                         phase["rss_max_mib"] > baseline["rss_max_mib"] * (1 + targets.max_rss_growth_percent / 100)):
            issues.append(f"{label}: bounded server RSS has not been demonstrated")
        if label.startswith("overload_"):
            multiple = int(label.split("_")[1][:-1])
            if baseline and phase["offered_rate"] < multiple * baseline["offered_rate"]:
                issues.append(f"{label}: scheduled rate is below its claimed multiple")
            attempted = raw.get("dial_attempts") if report["client"]["churn"] else raw["sent"]
            if attempted is None or attempted < raw["offered"] * (1 - targets.max_unsent_percent / 100):
                issues.append(f"{label}: insufficient network attempts/writes; nominal offers are not delivered pressure")
            if baseline and phase["goodput"] < baseline["goodput"] * targets.min_goodput_ratio:
                issues.append(f"{label}: useful throughput fell below the baseline retention target")
            busy = phase.get("server_core_busy_percent_max")
            if busy is None or busy > targets.max_core_busy_percent:
                issues.append(f"{label}: required per-core CPU headroom is missing")
            for kind in ("rejection", "failure"):
                if phase[kind + "_latency_count"]:
                    tail = phase.get(kind + "_p999_ms")
                    if tail is None or tail > targets.max_failure_p999_ms:
                        issues.append(f"{label}: {kind} p99.9 is missing or exceeds the failure target")
        elif phase["success_percent"] < 99.9:
            issues.append(f"{label}: fewer than 99.9% of scheduled offers succeeded")
    return {"passed": not issues, "targets": asdict(targets), "issues": issues,
            "scope": "one workload/configuration; does not prove a production workload matrix",
            "summary": summary}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    for name, default in asdict(Targets()).items():
        parser.add_argument("--" + name.replace("_", "-"), type=float, default=default)
    arguments = vars(parser.parse_args())
    reports, output = arguments.pop("reports"), arguments.pop("output")
    targets = Targets(**arguments)
    try:
        targets.validate()
    except ValueError as error:
        parser.error(str(error))
    results = {str(path): audit(json.loads(path.read_text()), targets) for path in reports}
    rendered = json.dumps(results, indent=2) + "\n"
    if output:
        output.write_text(rendered)
    else:
        print(rendered, end="")
    raise SystemExit(0 if all(result["passed"] for result in results.values()) else 1)


if __name__ == "__main__":
    main()
