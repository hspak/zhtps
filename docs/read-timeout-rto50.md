The 50 ms minimum-RTO candidate is **discarded**. It increases read timeouts in
all six pairs against current ZHTPS, increases median latency and CPU cost, and
reduces saturated throughput. Its p99 improvements are preserved in the results.
The experiment remains isolated; no retained server configuration or source
was changed.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The September 13, 2026 comparison contains 18 audited GET runs: three rotated
trials each of current ZHTPS, the isolated candidate, and Go, for 16,384-connection
offered and saturated loads. The high-load measurements last 20 seconds.
Both ZHTPS builds use seven workers on CPUs 9–15; Go uses GOMAXPROCS=32 with normal
GC. The sparse-histogram client runs on the established second host, CPUs 0–7,
with its original two-second deadline. The only server change is setting
`TCP_RTO_MIN_US=50000` on accepted public sockets; exponential backoff remains.
[Plan](runs/read-timeout-rto50.json "Summary of docs/read-timeout-rto50/plan.json; raw artifact retired"), [audit](runs/read-timeout-rto50.json "Summary of docs/read-timeout-rto50/audit.json; raw artifact retired"),
[all results](runs/read-timeout-rto50.json "Summary of docs/read-timeout-rto50/results.json; raw artifact retired"),
patch.

| Metric | Current ZHTPS | RTO50 candidate | Go |
|---|---:|---:|---:|
| 300k offered/s: read timeouts, total | 3,008 | 4,324 | 4,226 |
| 300k offered/s: all failures, total | 3,070 | 4,541 | 4,342 |
| 300k offered/s: median valid responses/s | 294,754 | 296,017 | 291,053 |
| 300k offered/s: median trial p50 | 4.260 ms | 14.877 ms | 3.572 ms |
| 300k offered/s: median trial p99 | 511.71 ms | 333.45 ms | 587.20 ms |
| 300k offered/s: median CPU/valid response | 3.624 µs | 4.660 µs | 23.387 µs |
| Saturated: read timeouts, total | 3,001 | 8,159 | 3,080 |
| Saturated: all failures, total | 3,061 | 8,751 | 3,161 |
| Saturated: median valid responses/s | 322,838 | 295,507 | 315,150 |
| Saturated: median trial p50 | 7.307 ms | 26.870 ms | 6.783 ms |
| Saturated: median trial p99 | 436.21 ms | 358.61 ms | 436.21 ms |
| Saturated: median CPU/valid response | 3.322 µs | 4.435 µs | 23.527 µs |

Totals cover three trials; the other figures are medians of trial metrics.
The candidate's offered read timeouts are 1,415 / 1,328 / 1,581 versus
1,015 / 923 / 1,070 for current ZHTPS. Saturated read timeouts are
2,840 / 2,556 / 2,763 versus 971 / 1,020 / 1,010. No errors were removed.
At 300k offered/s, generator misses are 268,798 / 198,053 / 486,142 for current
ZHTPS / candidate / Go; none sustains the full configured rate. Saturated warmup
errors are 664 / 1,261 / 996, separately from measured failures. Setup errors are
zero. Lower-load results, RSS, trial ranges, and every tied metric remain in the
full ledger. These new controls do not silently replace older measurements.

Per-trial queue snapshots provide new evidence about the cost of aggressive
recovery. In saturated trials, the server's Ethernet qdisc drops are
87 / 95 / 113 for current ZHTPS, **114,891 / 128,751 / 116,163** for the candidate,
and 1 / 3 / 2 for Go. Candidate offered-run server drops are 39,134–47,440 versus
376–750 for current ZHTPS. The load host also shows queue drops in several
trials, predominantly queue-limit drops, and no ECN marks.
These counters cover whole runs including setup, warmup, and cleanup; they cannot
identify the packet responsible for an individual timeout. The repeated increase
with the isolated socket change supports the inference that faster retransmission
amplifies congestion on this path. It does not identify the origin of every
initial packet loss.
[Queue observations and deltas](runs/read-timeout-rto50.json "Summary of docs/read-timeout-rto50/results.json; raw artifact retired").

The candidate also fails the unchanged six-response-packet-loss regression:
it times out after 2.002 seconds with five response packets dropped before the
deadline. The previously tested thin-stream policy passes the same test in
1.249 seconds. The test was not relaxed to admit this candidate.
RTO50 regression failure,
unchanged test source.

A separate socket-timer probe explains why the lower setting offers little
immediate protection on a fresh connection. Current ZHTPS stays near 201–203 ms
through 64 requests. The candidate starts at 201 ms after its first two requests,
then reaches 137 ms after four, 80 ms after eight, 55 ms after sixteen, and 51 ms
after thirty-two. The option changes the minimum; it does not immediately reset
the existing timer estimate. Linux updates the RTT variance estimate as further
acknowledgements arrive. This is consistent with the source and directly observed
socket timers, rather than an assumption that a configured minimum is the actual
current RTO.
Timer probe,
baseline observations,
candidate observations,
[Linux option implementation](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp.c),
[RTT estimator](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp_input.c).

ReleaseSafe correctness validation passed before benchmarking: component, wire,
embedded library, application, and upload/streaming checks. The fixed-loss
regression failure is a separate negative result. The timer probes ran after all
18 decision measurements. Queue snapshots run only before and after each trial;
they introduce no diagnostic process during the measurement interval.
Validation,
[build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/timeout-rto50-v1/build.json; raw artifact retired").

The existing audit assumed two variants per plan. This experiment declares three,
so the audit now derives that count and additionally requires every declared
variant/repeat pair exactly once. The legitimate 18-run plan passes; a negative
plan omitting Go is rejected. No measurement or failure-accounting check was
removed.
[Audit adjustment and negative control](runs/read-timeout-rto50.json "Summary of docs/read-timeout-rto50/auditor-change.json; raw artifact retired").

The subsequent [24-run thin-stream comparison](read-timeout-thin-go.md)
validates substantial failure reductions against fresh Go controls across 8k
and 16k GET loads, while recording the remaining latency gaps. Aggregate pacing remains the leading
architectural proposal for preventing loss; blindly shortening retries is not
supported by these measurements. The broader goal remains active, including
every tied result.
