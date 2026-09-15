"""Export resource timelines and validated client outcomes from overload reports."""

import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    fig, axes = plt.subplots(4, len(options.reports), figsize=(7 * len(options.reports), 11), squeeze=False)
    colors = {"good": "#187a62", "cpu": "#3167a8", "memory": "#7b549d", "reject": "#c97920"}
    for column, path in enumerate(options.reports):
        report = json.loads(path.read_text())
        phases = report["client"]["phases"]
        origin = phases[0]["start_unix_ns"]
        seconds, admitted, busy, rss = [], [], [], []
        for a, b in zip(report["samples"], report["samples"][1:]):
            if "counters" not in a or "counters" not in b:
                continue
            seconds.append((b["unix_ns"] - origin) / 1e9)
            elapsed = (b["unix_ns"] - a["unix_ns"]) / 1e9
            admitted.append((b["counters"]["requests_admitted_total"] - a["counters"]["requests_admitted_total"]) / elapsed / 1000)
            deltas = [[end - start for start, end in zip(a["server_cores"][cpu], b["server_cores"][cpu])]
                      for cpu in a["server_cores"]]
            total = sum(sum(delta[:8]) for delta in deltas)
            idle = sum(delta[3] + delta[4] for delta in deltas)
            busy.append(100 * (1 - idle / total))
            rss.append(b["server"]["VmRSS"] / 2**20)
        axes[0, column].plot(seconds, admitted, color=colors["good"], linewidth=1, label="Admitted/s, server samples")
        axes[1, column].plot(seconds, busy, color=colors["cpu"], linewidth=1)
        axes[1, column].set_ylim(0, 105)
        axes[2, column].plot(seconds, rss, color=colors["memory"], linewidth=1.5)
        axes[2, column].set_ylim(0, max(rss) * 1.2)
        p99, positions, labels = [], [], []
        for phase in phases:
            begin = (phase["start_unix_ns"] - origin) / 1e9
            end = (phase["end_unix_ns"] - origin) / 1e9
            label = phase.get("label", "")
            if label.startswith("overload"):
                for axis in axes[:3, column]:
                    axis.axvspan(begin, end, color="#eac89b", alpha=.25)
                axes[0, column].text((begin + end) / 2, .96, label.replace("overload_", ""),
                                     transform=axes[0, column].get_xaxis_transform(), ha="center", va="top",
                                     bbox={"facecolor": "white", "alpha": .85, "edgecolor": "none"})
            axes[0, column].hlines(phase["window_successes_per_second"] / 1000, begin, end,
                                  color="#102e29", linewidth=2, linestyles="dashed")
            if label != "warmup":
                positions.append(len(positions))
                labels.append(label.replace("overload_", "").replace("recovery_", "recover "))
                p99.append(phase["success_latency"]["p99_us"] / 1000)
        axes[3, column].plot(positions, p99, "o-", color=colors["good"])
        axes[3, column].axhline(10, color="#aa3838", linestyle="--", linewidth=1, label="10 ms target")
        axes[3, column].legend(fontsize=8)
        axes[3, column].set_xticks(positions, labels, rotation=30, ha="right")
        axes[3, column].set_ylim(bottom=0)
        for axis, ylabel in zip(axes[:, column], ("Requests/s (thousands)", "Server core busy (%)", "Server RSS (MiB)", "Successful-request p99 (ms)")):
            axis.set_ylabel(ylabel)
            axis.grid(alpha=.2)
        for axis in axes[:3, column]:
            axis.set_xlabel("Seconds since first scheduled offer")
        title = "Connection churn" if report["client"]["churn"] else "Connection reuse"
        axes[0, column].set_title(title)
        axes[0, column].plot([], [], color="#102e29", linestyle="--", label="Validated client goodput, phase average")
        axes[0, column].legend(fontsize=8, loc="lower right")
    fig.suptitle("ZHTPS sustained overload\nOne server core; separate generator cores\nShading: nominal overload. Unsent offers are reported separately.", fontsize=12)
    fig.tight_layout(rect=(0, 0, 1, .95))
    fig.savefig(options.output, metadata={"Creator": "bench/plot_overload.py"})


if __name__ == "__main__":
    main()
