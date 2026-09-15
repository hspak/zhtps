# Current ZHTPS versus Go: September 12 rerun

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The subsequent [two-host LAN comparison](go-comparison-lan.md) repeats these
server configurations with the load generator on `client.example`.

The current worktree's ReleaseSafe build reached **505,366 responses/s** at 128
connections on one CPU, **2.69× Go** and **9.1% above the original
single-CPU result**. With 16 workers and 4,096 connections it reached
**1,321,145 responses/s**, **1.63× Go**, but **10.8% below the earlier
16-worker result**. Go was also 10.9% below its earlier multicore result.

These are fresh Debug, ReleaseSafe, Go server, and load-generator builds from
the current worktree, including its uncommitted changes. The historical reports
and summarized measurements are retained. The run records include SHA-256 hashes
for all 37 measured source files and all four binaries.

All **54 trials** completed: **165,858,760 validated responses inside the measurement
windows**, **zero setup, warmup, or measured client errors**, **zero reconnects**,
and participation by every requested connection. ZHTPS recorded no request
rejections, aborted requests, protocol errors, request timeouts, or I/O errors.

## Original single-CPU setup

Both servers were pinned to CPU 0; Go used `GOMAXPROCS=1`. The client ran on
physical cores 1–4 with `GOMAXPROCS=4`. ZHTPS used one worker, 256 public slots,
256 active-request permits, and default access logging. Each row is the median
of three five-second trials after one second of warmup; ranges span those trials.
Latency columns are medians of each trial's quantiles, not pooled percentiles.
Changes use the [original September 11 results](go-comparison.md).

| Connections | Server | Responses/s | Trial range | Change vs. earlier | p50 µs | p95 µs | p99 µs |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | ZHTPS Debug | 103,672 | 103,529–103,990 | +4.9% | 9.535 | 10.687 | 12.927 |
| 1 | ZHTPS ReleaseSafe | 161,879 | 161,086–162,803 | +16.4% | 5.887 | 7.167 | 9.023 |
| 1 | Go net/http | 109,678 | 109,491–110,786 | +21.1% | 8.639 | 11.007 | 13.887 |
| 16 | ZHTPS Debug | 164,063 | 162,545–164,389 | -12.6% | 97.791 | 101.375 | 114.175 |
| 16 | ZHTPS ReleaseSafe | 440,734 | 440,670–443,063 | +5.5% | 36.095 | 39.935 | 59.391 |
| 16 | Go net/http | 196,996 | 196,403–197,146 | +5.7% | 78.847 | 148.479 | 194.559 |
| 128 | ZHTPS Debug | 193,413 | 193,030–193,541 | -5.0% | 655.359 | 716.799 | 823.295 |
| 128 | ZHTPS ReleaseSafe | 505,366 | 498,978–505,511 | +9.1% | 251.903 | 270.335 | 327.679 |
| 128 | Go net/http | 187,543 | 187,255–188,077 | +5.2% | 688.127 | 1253.375 | 1482.751 |

ReleaseSafe improved by 5.5–16.4% across these connection counts. Debug improved
at one connection but fell 12.6% at 16 and 5.0% at 128. Go improved by 5.2–21.1%.
At 128 connections, ReleaseSafe p99 fell from 444.4 µs historically to 327.7 µs;
Go's current p99 was 1,482.8 µs.

**Access logging was enabled, but the bounded logger dropped records.** At 128
connections, 74.2–74.9% of attempted log records were dropped across the Zig
trials. There were 9,929,049 dropped records across all single-worker trials,
including setup and warmup, and zero log write errors. This is the current
server's default logging behavior; it does not measure lossless access logging.
Both servers' output was directed to `/dev/null`.

[Raw single-CPU results](runs/standalone.json "Summary of docs/go-comparison-current-single.json; raw artifact retired").

## Sixteen-worker setup

ZHTPS used 16 workers, each with 2,048 public slots and active-request permits
(32,768 public slots total), plus eight admin slots on worker zero. Each ring
retained 256 SQ and 16,384 CQ entries. All 16 workers completed requests and
accumulated CPU time in every Zig trial.

Both servers could use all 32 logical CPUs. Go had no `GOMAXPROCS` override and
reported `GOMAXPROCS=32`. The client used physical cores 1–15 with
`GOMAXPROCS=15`, sharing the host with the servers. Access logging was disabled
as in the [earlier multicore comparison](go-comparison-workers.md); admission
checks, counters, and latency histograms remained enabled. There were no dropped
log records in these trials.

| Connections | Server | Responses/s | Trial range | Change vs. earlier | p50 ms | p95 ms | p99 ms |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 4,096 | ZHTPS Debug | 1,270,885 | 1,241,621–1,286,809 | -9.4% | 3.064 | 4.424 | 6.619 |
| 4,096 | ZHTPS ReleaseSafe | 1,321,145 | 1,301,075–1,327,032 | -10.8% | 2.966 | 4.112 | 5.538 |
| 4,096 | Go net/http | 810,651 | 810,188–819,803 | -10.9% | 4.456 | 9.044 | 14.418 |
| 8,192 | ZHTPS Debug | 1,059,764 | 1,054,939–1,068,277 | -13.0% | 7.569 | 9.699 | 12.714 |
| 8,192 | ZHTPS ReleaseSafe | 1,103,151 | 1,091,379–1,107,152 | -13.9% | 7.373 | 8.323 | 11.534 |
| 8,192 | Go net/http | 760,441 | 758,030–764,177 | -12.3% | 10.027 | 16.318 | 21.627 |
| 16,384 | ZHTPS Debug | 948,449 | 946,325–950,396 | -13.9% | 17.039 | 19.923 | 25.166 |
| 16,384 | ZHTPS ReleaseSafe | 992,166 | 986,924–992,716 | -15.3% | 16.384 | 17.957 | 23.724 |
| 16,384 | Go net/http | 736,026 | 735,153–741,048 | -12.8% | 21.103 | 30.278 | 39.059 |

ReleaseSafe was 1.63×, 1.45×, and
1.35× Go at 4,096, 8,192, and 16,384 connections respectively.
Absolute ReleaseSafe throughput fell 10.8–15.3% from the earlier multicore run;
Go fell 10.9–12.8%. ReleaseSafe p99 rose from 4.653/9.896/19.923 ms historically
to 5.538/11.534/23.724 ms. Its throughput advantage over Go at 4,096 connections
was effectively unchanged; the advantage narrowed at the two higher counts.

[Raw multicore results](runs/standalone.json "Summary of docs/go-comparison-current-workers.json; raw artifact retired").

## CPU observations

One CPU is 100%. Values are medians of trial process CPU measurements, including
warmup; server CPU also includes connection preparation. They exclude separately
accounted interrupt work and are not normalized efficiency measurements.

| Setup | Connections | Server | Server CPU | Client CPU |
| --- | ---: | --- | ---: | ---: |
| Single CPU | 1 | ZHTPS Debug | 85.8% | 38.8% |
| Single CPU | 1 | ZHTPS ReleaseSafe | 70.3% | 54.8% |
| Single CPU | 1 | Go net/http | 62.1% | 41.4% |
| Single CPU | 16 | ZHTPS Debug | 87.9% | 60.2% |
| Single CPU | 16 | ZHTPS ReleaseSafe | 70.1% | 155.9% |
| Single CPU | 16 | Go net/http | 83.8% | 64.4% |
| Single CPU | 128 | ZHTPS Debug | 86.4% | 67.9% |
| Single CPU | 128 | ZHTPS ReleaseSafe | 66.2% | 169.1% |
| Single CPU | 128 | Go net/http | 84.3% | 66.7% |
| 16 workers | 4,096 | ZHTPS Debug | 1124.4% | 1143.2% |
| 16 workers | 4,096 | ZHTPS ReleaseSafe | 662.2% | 1136.3% |
| 16 workers | 4,096 | Go net/http | 1539.1% | 807.8% |
| 16 workers | 8,192 | ZHTPS Debug | 1096.8% | 1136.4% |
| 16 workers | 8,192 | ZHTPS ReleaseSafe | 668.6% | 1134.3% |
| 16 workers | 8,192 | Go net/http | 1522.7% | 845.3% |
| 16 workers | 16,384 | ZHTPS Debug | 973.9% | 1064.2% |
| 16 workers | 16,384 | ZHTPS ReleaseSafe | 596.2% | 1072.8% |
| 16 workers | 16,384 | Go net/http | 1459.6% | 857.1% |

The multicore client's roughly 11-core consumption and shared loopback path
limit what these measurements can establish about isolated server capacity.
CPU affinity constrains placement; it does not reserve cores against host work.

## Method and comparison limits

The workload remains HTTP/1.1 `GET /` on loopback TCP: one outstanding request per
persistent connection, no TLS or pipelining. Every success requires HTTP 200,
`Content-Length: 6`, and exactly `ZHTPS\n`. Both servers send the same Content-Type
and ETag. The current bundled root handler and common HTTP server path are
exercised; custom endpoint routing, JSON handlers, request bodies, and application
hooks require different workloads.

Each trial starts a fresh server. The client prepares and validates every
connection before the shared warmup, opening at most 64 concurrently. Server
order rotates across repeats. ZHTPS's per-connection request limit is raised to
4,294,967,295 to preserve connections; the request-rate limiter stays disabled.
The Go baseline has no application metrics or access logger, so it does not
provide feature parity with ZHTPS.

The single-CPU table uses successes from requests started during measurement,
divided by elapsed time including their final drain, matching the original
report's `requests_per_second`. The multicore table uses validated completions
inside the fixed five-second window, matching the earlier worker report's
`window_successes_per_second`. The multicore runner retains `--allow-errors`
to record any failures, but none occurred. Both rate fields remain in raw JSON.

Latency runs from immediately before sending through validation of the complete
response. The histogram rounds upward by less than 0.8%. This is a closed-loop
workload: slower responses reduce offered load. Its percentiles do not establish
fixed-arrival-rate latency or correct coordinated omission. This rerun does not
repeat the separate overload, connection-churn, or remote-network experiments.

Historical changes are observations across runs, **not an isolated measurement
of the code changes**. The current build defaults to `x86_64_v4`; the original
reports recorded a native target. Go changed from `go1.27.0-X:nodwarf5` to
`go1.27.1-X:nodwarf5`. The harness, logging, and metric implementations have also
evolved. The broadly similar multicore slowdown in Go makes attributing the
entire ZHTPS difference to its new code unsupported by this comparison.

## Environment and validation

| Setting | Current run |
| --- | --- |
| Single-CPU start (UTC) | `2026-09-12T16:23:09Z` |
| Multicore start (UTC) | `2026-09-12T16:26:08Z` |
| CPU | AMD Ryzen AI Max+ 395; 16 physical cores / 32 logical CPUs |
| Kernel | `7.2.4-arch1-2-strixhalo` |
| CPU policy observed | `performance`, `amd-pstate-epp`, boost enabled |
| Zig | `0.16.0`; Debug and ReleaseSafe; default `x86_64_v4` target |
| Go | `go version go1.27.1-X:nodwarf5 linux/amd64` |
| Go build environment | `GOAMD64=v1`, `GOEXPERIMENT=nodwarf5` |
| Source revision | `1e466b9` plus the current uncommitted worktree; exact source hashes in both reports |

Debug and ReleaseSafe each passed **79 Zig tests**, all **18 compile-time endpoint
declaration checks**, and **58 raw TCP regression tests**. The raw TCP suites
used the exact binaries that were benchmarked. The Go load-client tests passed.
Real socket and io_uring operations ran outside the workspace sandbox.

The [audit](runs/standalone.json "Summary of docs/go-comparison-current-audit.json; raw artifact retired") verified source and binary hashes
against the measured worktree, identical binaries and sources between both
setups, all 54 trial outcomes and connection counts, all worker participation,
and recomputed throughput summaries and median latency quantiles.

## Reproduce

From the repository root, run sequentially to avoid benchmark interference:

```sh
python3 bench/compare.py --connections 1 16 128 \
  --go-cpu-mode single --client-cores 4 \
  --duration 5 --warmup 1 --repeats 3 \
  --output docs/go-comparison-current-single.json

python3 bench/compare.py --connections 4096 8192 16384 --zig-workers 16 \
  --zig-max-connections 2048 --zig-max-active 2048 --no-zig-access-log \
  --go-cpu-mode unrestricted --client-cores 15 --allow-errors \
  --duration 5 --warmup 1 --repeats 3 \
  --output docs/go-comparison-current-workers.json
```

These commands overwrite their named output files; choose new paths to retain
this rerun. See the [benchmark guide](../bench/README.md) for harness details and
[the offline browser report](benchmarks.html) for all compiled reports.
