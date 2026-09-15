"""Audit completed two-host Go comparisons and summarize per-trial network counters."""

import argparse
import hashlib
import json
from pathlib import Path

from compare import BUILD, ROOT, summarize


def tcp_counters(snapshot):
    lines = snapshot["snmp"].splitlines()
    for names, values in zip(lines[::2], lines[1::2], strict=True):
        if names.startswith("Tcp:"):
            return dict(zip(names.split()[1:], map(int, values.split()[1:]), strict=True))
    raise AssertionError("missing TCP counters")


def audit(path):
    report = json.loads(path.read_text())
    assert "summary" in report, "incomplete report"
    for name, expected in report["source_sha256"].items():
        assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected, name
    binaries = {"zig_debug": BUILD / "debug/bin/zhtps",
                "zig_release_safe": BUILD / "release_safe/bin/zhtps",
                "go": BUILD / "go_server", "load": BUILD / "load"}
    for name, expected in report["binary_sha256"].items():
        assert hashlib.sha256(binaries[name].read_bytes()).hexdigest() == expected, name
    connections = sorted({row["connections"] for row in report["summary"]})
    variants = list(dict.fromkeys(row["variant"] for row in report["summary"]))
    expected = {(c, v, r) for c in connections for v in variants
                for r in range(1, report["repeats"] + 1)}
    actual = [(row["connections"], row["variant"], row["repeat"]) for row in report["runs"]]
    assert len(actual) == len(set(actual)) and set(actual) == expected
    assert summarize(report["runs"], connections, variants) == report["summary"]
    network = []
    for row in report["runs"]:
        remote = row["remote_client"]
        assert remote["separate_kernel"]
        assert remote["identity"]["boot_id"] != report["server_identity"]["boot_id"]
        assert remote["binary_sha256"] == report["binary_sha256"]["load"]
        assert remote["cpus"] == report["client_cpus"]
        assert row["outcome"] == "measured"
        assert row["attempts"] == row["successes"] + row["errors"]
        assert sum((row["failures"] or {}).values()) == row["errors"]
        assert row["connections_ready"] + row["setup_errors"] == row["connections"]
        assert 0 < row["connections_measured"] <= row["connections"]
        if not report["allow_errors"]:
            assert row["setup_errors"] == row["warmup_errors"] == row["errors"] == 0
            assert not row["failures"] and not row["window_failures"]
            assert row["connections_ready"] == row["connections_measured"] == row["connections_opened"] == row["connections"]
        assert row["window_successes_per_second"] == row["window_successes"] / report["duration_seconds"]
        if row["variant"] != "go":
            counters = row["metrics_after"]["counters"]
            if not report["allow_errors"]:
                for name in ("requests_rejected_total", "requests_aborted_total", "protocol_errors_total",
                             "request_timeouts_total", "io_errors_total", "log_write_errors_total"):
                    assert counters[name] == 0, (row["variant"], name, counters[name])
            if row["zig_workers"] > 1:
                assert len(row["workers_after"]["workers"]) == row["zig_workers"]
                assert all(value > 0 for value in row["worker_cpu_seconds_including_warmup"].values())
                assert all(worker["requests_completed_total"] > 0
                           for worker in row["workers_after"]["workers"])
        else:
            expected_procs = 1 if report["go_cpu_mode"] == "single" else len(report["available_cpus"])
            assert row["go_runtime"]["gomaxprocs"] == expected_procs
        before, after = row["server_network_before"], row["server_network_after"]
        seconds = (after["monotonic_ns"] - before["monotonic_ns"]) / 1e9
        tcp_before, tcp_after = tcp_counters(before), tcp_counters(after)
        network.append(dict(connections=row["connections"], variant=row["variant"], repeat=row["repeat"],
                            seconds=seconds,
                            tcp_delta={key: tcp_after[key] - tcp_before[key]
                                       for key in ("InSegs", "OutSegs", "RetransSegs", "InErrs", "OutRsts")},
                            nics={nic: {key: value - before["nics"][nic][key] for key, value in stats.items()}
                                  for nic, stats in after["nics"].items()}))
    return dict(report=str(path), trials=len(report["runs"]),
                validated_window_responses=sum(row["window_successes"] for row in report["runs"]),
                hashes_match=True,
                all_requested_connections_participated=all(row["connections_measured"] == row["connections"]
                                                          for row in report["runs"]),
                errors={name: sum(row[name] for row in report["runs"])
                        for name in ("setup_errors", "warmup_errors", "errors")},
                extra_connection_opens=sum(max(0, row["connections_opened"] - row["connections"])
                                           for row in report["runs"]),
                network=network)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    audits = [audit(path) for path in options.reports]
    options.output.write_text(json.dumps(audits, indent=2) + "\n")
    for result in audits:
        print(f"{result['report']}: {result['trials']} trials, "
              f"{result['validated_window_responses']:,} validated responses; audit passed")
