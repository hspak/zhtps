Follow-up: [production integration and 48 fresh decision trials](tcp-read-timeout-mitigation.md)
are complete. The prototype results below remain separate historical evidence.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The thin-stream retry candidate substantially reduces failures against fresh Go
controls and delivers higher valid throughput in all four high-load GET
scenarios. It also uses less server process CPU per valid response and lower
sampled RSS in every scenario. It does **not** beat Go on every metric:
high-load median latency remains unfavorable in three aggregates, saturated
p99 remains tied, and a few 16k failures remain. Every tie stays open.

The September 13, 2026 comparison contains 24 audited GET runs, three rotated
trials per server for offered and saturated loads at 8,192 and 16,384 connections.
It uses the frozen `timeout-thin-linear-v1` candidate, Go with GOMAXPROCS=32 and
normal GC, and the same sparse-histogram client on the second host. ZHTPS uses
seven workers on CPUs 9–15; the client uses CPUs 0–7. The two-second exchange
deadline is unchanged. High-load measurements last 20 seconds, so this ledger
remains separate from the earlier 10-second comparisons.
[Plan](runs/read-timeout-thin-go.json "Summary of docs/read-timeout-thin-go/plan.json; raw artifact retired"), [audit](runs/read-timeout-thin-go.json "Summary of docs/read-timeout-thin-go/audit.json; raw artifact retired"),
[all trials](runs/read-timeout-thin-go.json "Summary of docs/read-timeout-thin-go/get-trials.json; raw artifact retired"),
[build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/timeout-thin-linear-v1/build.json; raw artifact retired").

| Workload | ZHTPS read timeouts | Go read timeouts | ZHTPS valid responses/s | Go valid responses/s |
|---|---:|---:|---:|---:|
| 8k, 300k offered/s | 0 | 2,094 | 299,905 | 296,905 |
| 8k, saturated | 0 | 74 | 358,474 | 354,069 |
| 16k, 300k offered/s | 11 | 4,872 | 294,999 | 291,307 |
| 16k, saturated | 1 | 2,686 | 321,760 | 317,348 |

Failures are totals across three trials; throughput is the median trial's
valid responses/s. Candidate read-timeout trials are 0 / 0 / 0 at both 8k
loads, 7 / 2 / 2 at 16k offered load, and 0 / 1 / 0 at 16k saturation.
The four throughput gains are 1.01%, 1.24%, 1.27%, and 1.39%, respectively,
with separated trial ranges in each comparison. Three trial ranges are
descriptive evidence, not formal confidence intervals.

| Workload | ZHTPS median trial p50 | Go median trial p50 | ZHTPS median trial p99 | Go median trial p99 |
|---|---:|---:|---:|---:|
| 8k, 300k offered/s | 0.143 ms | 0.297 ms | 3.785 ms | 444.596 ms |
| 8k, saturated | 4.653 ms | 4.620 ms | 221.250 ms | 221.250 ms |
| 16k, 300k offered/s | 3.949 ms | 3.424 ms | 450.888 ms | 629.146 ms |
| 16k, saturated | 7.832 ms | 6.816 ms | 436.208 ms | 436.208 ms |

Offered-load p99 improves 99.1% at 8k and 28.3% at 16k. The candidate's median
latency is 0.7% higher at 8k saturation and 15.3% higher at 16k offered load,
with overlapping trial ranges in those two comparisons. At 16k saturation,
candidate p50 is 14.9% higher and worse in every pair. The two saturated p99
ties remain open. At 100k and 200k offered load, candidate p50 and p99 are
lower in every scenario, with separated trial ranges.

Server process CPU per valid response is 77.5–87.1% lower than Go across the
eight load/rate scenarios. This is process CPU, not total host CPU including
all packet-processing work. Sampled RSS is 7.0–9.4% lower. For example, at
16k saturation, CPU is 3.453 versus 23.493 microseconds/valid response and RSS
is 454.54 versus 494.31 MiB. All CPU and sampled-RSS comparisons have separated
trial ranges. Post-drain RSS remains recorded separately and is not substituted
for memory during measurement.
[Aggregates and ranges](runs/read-timeout-thin-go.json "Summary of docs/read-timeout-thin-go/get-aggregate.json; raw artifact retired").

All failure categories and generator misses remain counted. Total HTTP failures
for candidate / Go are 0 / 2,094 at 8k offered load, 0 / 75 at 8k saturation,
11 / 5,020 at 16k offered load, and 1 / 2,748 at 16k saturation. Saturated warmup
errors are 0 / 59 at 8k and 1 / 832 at 16k; setup errors are zero. The one
candidate warmup error is separate from the one measured error. No trial was
excluded.

At 300k offered/s, generator misses are 2,614 / 163,848 at 8k and
249,662 / 460,005 at 16k for candidate / Go. The candidate nearly sustains the
8k target but does not sustain the full 16k target. At 8k/200k, generator misses
are 10 versus 9: that unfavorable count remains open. At 16k/100k, median
goodput is exactly tied at 99,998.8/s and generator misses tie at three. Zero
HTTP failures at the lower offered rates also remain tied and open.

The comparison ledger contains 66 applicable metric/count comparisons: 33
favorable with separated trial ranges, 14 lower failure or generator-miss totals,
14 ties, four unfavorable aggregates/counts, and one favorable aggregate with
overlapping ranges. Setup/warmup counts apply to saturated runs; generator
misses apply to offered runs. This candidate ledger does not replace the
earlier retained-server ledger or close its tied results.
[Comparison ledger](runs/read-timeout-thin-go.json "Summary of docs/read-timeout-thin-go/results.json; raw artifact retired").

Transport evidence remains important. At 16k offered load, median interior
server retransmission rates are about 59,561/s for the candidate and 58,160/s
for Go; at saturation they are 66,545/s and 64,367/s. Fewer client timeouts do
not mean loss has disappeared. At 8k offered load, the corresponding server
rates are much lower for the candidate: 1,048/s versus 23,059/s. The recorded
server-side timeout, rejection, abort, I/O, refusal, and buffer-exhaustion
counters remain zero for the candidate. Local HTTP completion still does not
establish peer receipt.
[Interior transport evidence](runs/read-timeout-thin-go.json "Summary of docs/read-timeout-thin-go/network-evidence.json; raw artifact retired").

Whole-run queue deltas show 517–631 server qdisc drops for the candidate's
16k offered runs versus 7–17 for Go. At 16k saturation, both load-host queues
drop roughly 5,400–6,100 packets per run, predominantly at the queue limit;
server drops are 241–311 for the candidate versus 4–14 for Go. These are
host-wide counters including preparation and cleanup, not identification of
the loss behind a particular failed request. They support continuing to
investigate aggregate traffic bursts and packet-processing limits.
[Queue snapshots and deltas](runs/read-timeout-thin-go.json "Summary of docs/read-timeout-thin-go/results.json; raw artifact retired").

The candidate remains isolated from the retained server. Its prior full
ReleaseSafe correctness checks and unchanged fail-before/pass-after loss
regression still apply to this exact recorded binary. This round adds GET
performance evidence; it does not establish upload performance for the retry
policy. No host sysctl, queue, IRQ, or firewall policy was changed.
[Candidate validation and loss regression](read-timeout-mitigations.md).

The next adoption gate is upload coverage for the thin-stream policy, followed
by a deliberate integration into the server's socket policy. The next latency
investigation should capture bounded connection-level TCP diagnostics on the
remaining failures and test aggregate response pacing. The separate 50 ms
minimum-RTO candidate is discarded because it amplified queue drops and
increased timeouts; its p99 gains remain recorded.
[Rejected RTO experiment](read-timeout-rto50.md).
