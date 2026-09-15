"""Summarize completed overload reports without treating unsent offers as server errors."""

import argparse
import json
from pathlib import Path


def summarize(report):
    if report["status"] != "complete" or report["server_exit"] != 0:
        raise ValueError("require a completed run and clean server exit")
    phases = []
    for phase in report["client"]["phases"]:
        samples = [sample for sample in report["samples"]
                   if phase["start_unix_ns"] <= sample["unix_ns"] <= phase["end_unix_ns"]]
        failures = phase["failures"] or {}
        unsent = phase["generator_queue_drops"] + phase["generator_expired"]
        if phase["successes"] + sum(failures.values()) + unsent != phase["offered"]:
            raise ValueError("offer accounting does not balance")
        row = {"label": phase.get("label"), "offered_rate": phase["offered_rate"],
               "seconds": phase["duration_seconds"], "sent_rate": phase["sent_per_second"],
               "goodput": phase["window_successes_per_second"],
               "success_percent": 100 * phase["successes"] / phase["offered"],
               "unsent_percent": 100 * unsent / phase["offered"],
               "http_failures_per_second": sum(n for kind, n in failures.items() if kind.startswith("http_")) / phase["duration_seconds"],
               "transport_failures_per_second": sum(n for kind, n in failures.items() if not kind.startswith("http_")) / phase["duration_seconds"],
               "success_p99_ms": phase["success_latency"]["p99_us"] / 1000,
               "service_p99_ms": phase["success_service_latency"]["p99_us"] / 1000,
               "rejection_p99_ms": phase["rejection_latency"]["p99_us"] / 1000 if phase["rejection_latency"]["count"] else None,
               "failure_p99_ms": phase["failure_latency"]["p99_us"] / 1000 if phase["failure_latency"]["count"] else None,
               "scheduler_p99_ms": phase["scheduler_lag"]["p99_us"] / 1000,
               "failures": failures, "admin_errors": sum("admin_error" in sample for sample in samples)}
        for label, field in (("success", "success_latency"), ("service", "success_service_latency"),
                             ("rejection", "rejection_latency"), ("failure", "failure_latency"),
                             ("scheduler", "scheduler_lag")):
            distribution = phase[field]
            row[label + "_latency_count"] = distribution["count"]
            for quantile in ("p999", "p9999", "max"):
                value = distribution.get(quantile + "_us")
                row[label + "_" + quantile + "_ms"] = value / 1000 if value is not None and distribution["count"] else None
        row["dial_attempts"] = phase.get("dial_attempts")
        row["request_bytes_written"] = phase.get("request_bytes_written")
        row["response_bytes_validated"] = phase.get("response_bytes_validated")
        row["meets_baseline_target"] = row["success_percent"] >= 99.9 and row["success_p99_ms"] <= 10
        if samples:
            row["rss_min_mib"] = min(s["server"]["VmRSS"] for s in samples) / 2**20
            row["rss_max_mib"] = max(s["server"]["VmRSS"] for s in samples) / 2**20
            row["fds_max"] = max(s["server"]["fds"] for s in samples)
            row["tcp_time_wait_max"] = max(s["kernel"].get("tcp_tw", 0) for s in samples)
            row["tcp_mem_pages_max"] = max(s["kernel"].get("tcp_mem", 0) for s in samples)
        if len(samples) >= 2:
            first, last = samples[0], samples[-1]
            elapsed = (last["unix_ns"] - first["unix_ns"]) / 1e9
            row["server_cpu_cores"] = (last["server"]["cpu_seconds"] - first["server"]["cpu_seconds"]) / elapsed
            client_samples = [sample for sample in samples if "client" in sample]
            if len(client_samples) >= 2:
                client_first, client_last = client_samples[0], client_samples[-1]
                client_elapsed = (client_last["client"].get("unix_ns", client_last["unix_ns"]) -
                                  client_first["client"].get("unix_ns", client_first["unix_ns"])) / 1e9
                if client_elapsed > 0:
                    row["client_cpu_cores"] = (client_last["client"]["cpu_seconds"] -
                                               client_first["client"]["cpu_seconds"]) / client_elapsed
            if "server_cores" in first:
                busy, total = 0, 0
                per_core = {}
                for name, ticks in first["server_cores"].items():
                    delta = [end - begin for begin, end in zip(ticks, last["server_cores"][name])]
                    core_total = sum(delta[:8])
                    core_busy = core_total - delta[3] - delta[4]
                    total += core_total
                    busy += core_busy
                    if core_total:
                        per_core[name] = 100 * core_busy / core_total
                if total:
                    row["server_core_busy_percent"] = 100 * busy / total
                    row["server_core_busy_percent_by_cpu"] = per_core
                    row["server_core_busy_percent_max"] = max(per_core.values())
            if "counters" in first and "counters" in last:
                for name in ("requests_admitted_total", "requests_rejected_total"):
                    row["sampled_" + name + "_per_second"] = (last["counters"][name] - first["counters"][name]) / elapsed
            row["sampled_listen_overflows"] = last["kernel"]["ListenOverflows"] - first["kernel"]["ListenOverflows"]
        phases.append(row)
    return {"config": report["config"], "phases": phases,
            "server_exit": report["server_exit"],
            "kernel_delta": {name: report["kernel_after"][name] - report["kernel_before"][name]
                             for name in ("ListenOverflows", "ListenDrops", "TCPReqQFullDoCookies", "TCPReqQFullDrop", "TCPBacklogDrop")}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()
    results = {str(path): summarize(json.loads(path.read_text())) for path in options.reports}
    text = json.dumps(results, indent=2) + "\n"
    if options.output:
        options.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
