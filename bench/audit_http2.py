"""Audit recorded HTTP/2 benchmark accounting, placement and aggregate statistics."""

from collections import Counter
import json
from pathlib import Path
import statistics
import sys


def audit(path):
    report = json.loads(Path(path).read_text())
    assert report["complete"], "benchmark did not finish"
    args = report["arguments"]
    expected = Counter()
    for workers in map(int, args["workers"].split(",")):
        for case in args["cases"].split(","):
            connections, streams = map(int, case.split("x"))
            if workers > 1 and connections < workers:
                continue
            for name in args["servers"].split(","):
                if workers > 1 and name in ("node", "bun"):
                    continue
                expected[workers, connections, streams, name] = args["repeats"]
    actual = Counter((run["workers"], run["connections"], run["streams"], run["server"])
                     for run in report["runs"])
    assert actual == expected, (actual, expected)
    for run in report["runs"]:
        cpus = set(run["server_cpus"])
        server_cores = {tuple(report["cpu_topology"][str(cpu)]) for cpu in cpus}
        client_cores = {tuple(report["cpu_topology"][str(cpu)])
                        for placement in run["client_placements"] for cpu in placement}
        assert len(server_cores) == run["workers"]
        assert not server_cores & client_cores
        for snapshot in (run["server_before"], run["server_after"]):
            assert all(set(thread["cpus"]) <= cpus for thread in snapshot["threads"])
        assert run["errors"] == 0
        assert run["connections_opened"] == run["connections"]
        assert sum(shard["requests"] for shard in run["shards"]) == run["requests"]
        assert sum(shard["connections"] for shard in run["shards"]) == run["connections"]
        elapsed = (max(shard["end_ns"] for shard in run["shards"]) -
                   min(shard["start_ns"] for shard in run["shards"])) / 1e9
        assert run["seconds"] == elapsed
        assert run["requests_per_second"] == run["requests"] / elapsed
        assert run["server_cpu_us_per_request"] == run["server_cpu_seconds"] * 1e6 / run["requests"]
        histogram = Counter()
        for shard in run["shards"]:
            assert shard["errors"] == 0 and shard["first_error"] == ""
            assert shard["connections_opened"] == shard["connections"]
            assert shard["streams"] == run["streams"]
            assert shard["warmup_requests"] > 0 or args["warmup"] == 0
            assert shard["seconds"] >= args["duration"]
            assert sum(shard["latency_us"].values()) == shard["requests"]
            histogram.update({int(key): value for key, value in shard["latency_us"].items()})
        for percentile in (50, 99):
            rank = (run["requests"] - 1) * percentile // 100
            for micros, count in sorted(histogram.items()):
                if rank < count:
                    assert run[f"p{percentile}_ms"] == micros / 1000
                    break
                rank -= count
            else:
                raise AssertionError("percentile missing from histogram")
    assert len(report["medians"]) == len(expected)
    for row in report["medians"]:
        runs = [run for run in report["runs"] if all(
            run[key] == row[key] for key in ("server", "workers", "connections", "streams"))]
        assert sorted(run["repeat"] for run in runs) == list(range(args["repeats"]))
        for key in ("requests_per_second", "p50_ms", "p99_ms", "server_cpu_us_per_request",
                    "server_cpu_cores", "client_cpu_cores"):
            assert row[key] == statistics.median(run[key] for run in runs)
        assert row["min_requests_per_second"] == min(run["requests_per_second"] for run in runs)
        assert row["max_requests_per_second"] == max(run["requests_per_second"] for run in runs)
    print(f"Audited {len(report['runs'])} trials, {len(expected)} groups, "
          f"{sum(run['requests'] for run in report['runs']):,} successful responses")


if __name__ == "__main__":
    audit(sys.argv[1])
