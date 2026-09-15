ZHTPS now defaults public connections to bounded thin-stream TCP retries.
The integrated implementation substantially reduces read timeouts with the
original two-second GET deadline. It is retained after full correctness checks,
a fail-before/pass-after packet-loss regression, 36 prototype upload trials,
and 48 fresh decision trials on the exact integrated binaries. Remaining
timeouts, unfavorable results, and every tied comparison stay open.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

`--tcp-retries thin-linear` is the default; `--tcp-retries system` leaves kernel
retry defaults unchanged. Library users select `Config.tcp_retries`. The public
listener receives the socket option before binding, and accepted IPv4 and IPv6
sockets inherit it. Admin listeners use system defaults. Unsupported operation
fails startup with `TcpThinRetriesUnavailable`, avoiding the prototype's
per-accept failure path. `/debug/config` reports the selected mode. HTTP
deadlines and the minimum TCP retransmission timeout are unchanged. The policy
can increase retransmission traffic; it improves recovery rather than removing
the source of packet loss.
Implementation patch,
[adoption and source hashes](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/adoption-manifest.json; raw artifact retired"),
[Linux retry mechanism](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp_timer.c).

The September 13, 2026 decision matrix has three rotated trials per server
in each of four GET and four upload workloads, on the existing second host.
GET uses seven ZHTPS workers on CPUs 9–15, the unchanged sparse-histogram client
on CPUs 0–7, and Go with GOMAXPROCS=32 and normal GC. High-load windows last
20 seconds; lower offered-load phases last ten seconds. All 48 runs passed
the audit, with no exclusions. The build uses ReleaseSafe. The retained root
matches 53 core, build, test, and documentation files in the tested snapshot.
[Plan](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/plan.json; raw artifact retired"),
[audit](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/audit.json; raw artifact retired"),
[build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/tcp-retries-v1/build.json; raw artifact retired").

Failure counts below total three trials; throughput is the median trial's
validated responses/s.

| GET workload | ZHTPS read timeouts | Go read timeouts | ZHTPS valid responses/s | Go valid responses/s |
|---|---:|---:|---:|---:|
| 8k, 300k offered/s | 0 | 1,974 | 299,909 | 297,762 |
| 8k, saturated | 0 | 295 | 359,757 | 348,204 |
| 16k, 300k offered/s | 21 | 5,946 | 295,778 | 289,511 |
| 16k, saturated | 2 | 2,593 | 328,050 | 315,474 |

The 16k timeout reductions against these Go controls are 99.65% and 99.92%.
The integrated 16k trials have 9 / 8 / 4 read timeouts offered and 0 / 1 / 1
saturated. All eight measured 100k/200k server/workload combinations have zero
HTTP failures. GET high-load throughput improves 0.72%, 3.32%, 2.16%, and
3.99% in the table's order, with separated trial ranges. Those ranges are
descriptive evidence from three trials, not confidence intervals.
[Full GET results and ranges](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/get-results.json; raw artifact retired").

| GET workload | ZHTPS / Go p50 ms | ZHTPS / Go p99 ms |
|---|---:|---:|
| 8k, 300k offered/s | 0.153 / 0.373 | 3.473 / 448.791 |
| 8k, saturated | 3.965 / 3.703 | 222.298 / 254.804 |
| 16k, 300k offered/s | 3.162 / 2.376 | 452.985 / 637.534 |
| 16k, saturated | 6.652 / 5.341 | 434.110 / 455.082 |

These are medians of each trial's successful-exchange quantiles. Failed
exchanges remain counted separately. High-load p99 improves in all four fresh
comparisons with separated ranges, including the previously tied saturated
scenarios. Median latency is still worse at 8k saturation (+7.1%), 16k offered
load (+33.1%), and 16k saturation (+24.5%), with separated ranges. Lower-load
p50 and p99 favor ZHTPS. High-load server process CPU per valid response is
81–87% lower and sampled RSS 7–10% lower, with separated ranges. Process CPU
does not include all host packet-processing work.

All HTTP failures for ZHTPS / Go are 0 / 1,974, 0 / 296, 21 / 6,094, and
2 / 2,665 in table order. Saturated setup errors are zero for both servers;
warmup errors are 0 / 117 at 8k and 0 / 937 at 16k. At 300k offered/s,
generator misses are 4,271 / 112,211 at 8k and 227,398 / 577,918 at 16k.
ZHTPS does not sustain the complete 16k offered rate. At 100k, generator
misses are unfavorable: 2 / 0 at 8k and 5 / 3 at 16k. The 16k/100k throughput
median is also 0.2 responses/s lower, with overlapping ranges. These small
unfavorable results remain recorded.

Uploads use 32 connections and the original length-plus-CRC32 response
validation, with one ZHTPS network worker and its process on CPU 9. Go retains
GOMAXPROCS=32. The 64 KiB measurements last 20 seconds and the 8 MiB measurements
30 seconds, after five seconds of warmup. The upload client retains its
20-second socket timeout; it is not the GET client's two-second exchange
deadline. Every upload trial has zero failures.

| Upload workload | ZHTPS / Go MiB/s | ZHTPS / Go p99 ms | ZHTPS / Go CPU µs/MiB |
|---|---:|---:|---:|
| 64 KiB, default queue mapping | 279.341 / 279.347 | 13.944 / 8.084 | 322.641 / 557.974 |
| 64 KiB, distinct client queues | 247.191 / 246.616 | 12.871 / 12.924 | 269.697 / 521.192 |
| 8 MiB, distinct client queues | 281.067 / 281.333 | 916.090 / 915.916 | 293.640 / 336.508 |
| 8 MiB, paced at 200 MiB/s | 200 / 200 | 30.531 / 30.754 | 174.664 / 188.553 |

Server CPU and sampled RSS favor ZHTPS in all four upload workloads. The
default-queue 64 KiB p99 is 72.5% worse, with separated ranges; this is a
material open comparison. Large-body throughput is 0.095% lower, and its p50
and p99 also have unfavorable medians, with overlapping ranges. The calibrated
small-body case is favorable. Earlier experiments demonstrated sensitivity to
client qdisc flow collisions, but that does not prove the cause of every
current tail or justify dropping an unfavorable trial.
[Upload results](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/upload-results.json; raw artifact retired"),
[prior upload queue investigation](go-performance-followup.md).

The prior three-way upload comparison with retained V2 found a 0.41% large-body
CPU cost for the retry prototype, with separated ranges; all other V2 metric
comparisons overlapped. The original controlled 16k comparison also recorded
additional retransmissions, higher p50, and a small saturated-throughput cost.
Those costs remain part of the retention decision. The large failure reduction
is the reason to retain this policy, not an across-the-board performance claim.
[Three-way uploads](thin-retry-upload.md),
[original retained-server comparison](read-timeout-mitigations.md).

The fresh ledgers contain 90 applicable metric/count comparisons: 45 favorable
with separated ranges, 14 lower count totals, 11 unfavorable, five favorable
with overlapping ranges, and 15 ties. Capped throughput and zero failures are
included among the open ties. Historical ledgers and their ties are preserved;
the new results do not erase earlier observations.

Correctness validation passed all 65 build steps, 97 Zig tests, and the complete
wire, embedded-library, application, and upload/streaming suites. New checks
exercise configuration parsing, real IPv4/IPv6 accepted-socket inheritance,
public/admin listener policy, and the HTTP configuration endpoint.
Validation log.

The permanent packet-loss regression is unchanged. It drops the first six
response packets inside a disposable network namespace. The integrated default
delivers the correct response in 1.247 seconds after all six drops. The same
binary with `--tcp-retries system` times out in 2.002 seconds after five
transmissions, reproducing the original behavior. The original V2 binary also
fails this regression. No host firewall, sysctl, IRQ, or queue settings were
changed.
Default recovery,
explicit system-mode failure,
unchanged regression.

A subsequent diagnostic run captured nine residual ZHTPS timeouts: requests
were acknowledged by TCP, no new response data had arrived, and client deadline
wakeup lateness stayed below one millisecond. The next step is server-side
correlation, followed by an evidence-driven test of aggregate response pacing.
[Connection-level evidence](read-timeout-socket-info.md). Whole-run counters
still show server qdisc drops for integrated 16k traffic and client queue-limit
drops at 16k saturation. These counters include setup and cleanup and cannot
identify the loss behind an individual timeout. Faster recovery has not
eliminated transport pressure. ECN negotiation remains a deployment-dependent
candidate; lowering the minimum RTO to 50 ms alone remains discarded after its
measured increase in failures and queue drops.
[Remaining-timeout diagnostic and pacing design](thin-retry-integration/remaining-timeouts.md),
[rejected minimum-RTO experiment](read-timeout-rto50.md).

A subsequent [paired socket investigation](server-timeout-correlation.md)
locates 17 residual failures on the response-delivery path. An isolated
[pacing experiment](send-pacing.md) records a lower offered timeout count in
its initial trials, but its longer confirmation has a smaller benefit alongside
persistent CPU/RSS and p50 costs. That fixed-rate candidate is discarded from
adoption after 24 audited decision runs. The retained policy above remains
unchanged.

An additional [18-run NAPI polling comparison](napi-polling.md) also rejects
its isolated candidate. Read timeout totals tie with retained ZHTPS in both
16k workloads, while whole-server CPU rises about 80%. Its lower-load latency
improvements and overlapping saturated gains remain recorded. The retained
retry policy and all open ties above remain in force.
