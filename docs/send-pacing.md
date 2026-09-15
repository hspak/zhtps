The fixed-rate send-pacing-v1 prototype is **discarded from adoption** after
24 audited decision runs. Initial offered-load read timeouts fell from 20 to 9;
longer confirmation narrowed that to 29 versus 24. The smaller lower count
remains recorded, but saturated failures tie, p99 gains do not hold in the
longer runs, and CPU, memory and typical latency costs persist. That evidence
does not justify this fixed pacing default. Retained production source remains
`tcp-retries-v1`; the isolated patch, binaries and results are preserved.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

This experiment follows [paired timeout traces](server-timeout-correlation.md)
showing complete responses outstanding in TCP at all 17 captured ZHTPS failures.
The candidate paces send submissions per worker at 100,000/s with a burst of
four, using a bounded FIFO with one entry per connection. Admin output bypasses
pacing; queued writes keep their original deadline, and cancellation removes
borrowed send descriptions before buffer reuse. Seven independent workers do
not constitute a single global packet-rate limiter, and a large send can
produce multiple packets.
Reviewable patch,
[frozen build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/send-pacing-v1/build.json; raw artifact retired").

The initial decision matrix has 18 runs: retained ZHTPS, pacing ZHTPS, and Go;
three rotated trials each for 16,384-connection offered and saturated workloads.
Both ZHTPS variants use seven workers on CPUs 9–15. The unchanged second-host
client uses CPUs 0–7, the two-second exchange deadline, and full response
validation. Go uses GOMAXPROCS=32 and normal GC. High-load windows last 20 seconds;
offered warmup and 100k/200k phases last ten seconds each. No diagnostic client
or socket observer runs in these trials. All 18 runs passed the audit, with no
exclusions. Builds and correctness tests completed before benchmarking.
[Plan](runs/send-pacing.json "Summary of docs/send-pacing/plan.json; raw artifact retired"), [audit](runs/send-pacing.json "Summary of docs/send-pacing/audit.json; raw artifact retired"),
[all results and ranges](runs/send-pacing.json "Summary of docs/send-pacing/results.json; raw artifact retired").

The table totals read timeouts across trials and takes the median of each
trial's other measurements. Throughput counts validated responses within the
measurement window. Latencies describe successful exchanges; failures remain
counted separately.

| Workload and metric | Retained ZHTPS | Pacing prototype | Go |
|---|---:|---:|---:|
| 300k offered/s: read timeouts | 20 | 9 | 6,792 |
| 300k offered/s: valid responses/s | 294,822 | 295,396 | 290,220 |
| 300k offered/s: p50 ms | 4.588 | 4.817 | 3.473 |
| 300k offered/s: p99 ms | 452.985 | 450.888 | 633.340 |
| 300k offered/s: CPU µs/valid response | 3.772 | 3.822 | 23.452 |
| 300k offered/s: sampled RSS MiB | 452.660 | 457.078 | 500.277 |
| Saturated: read timeouts | 1 | 1 | 3,467 |
| Saturated: valid responses/s | 320,583 | 320,028 | 315,283 |
| Saturated: p50 ms | 7.766 | 7.733 | 6.586 |
| Saturated: p99 ms | 436.208 | 438.305 | 438.305 |
| Saturated: CPU µs/valid response | 3.466 | 3.590 | 23.486 |
| Saturated: sampled RSS MiB | 453.855 | 456.395 | 500.313 |

Offered read timeouts are 9 / 5 / 6 before and 4 / 1 / 4 with pacing: a lower
count in every pair and 55% fewer observed failures overall. The sample remains
small. Saturated read timeouts are 0 / 1 / 0 before and 0 / 0 / 1 with pacing;
the totals tie. Saturated warmup errors are 2 before, 1 with pacing, and 1,182
for Go. Setup errors are zero. All measured ZHTPS failures are read timeouts;
Go also has 169 offered and 92 saturated dial timeouts. None of these categories
is removed from the ledger to improve a result.

Relative to retained ZHTPS, pacing raises high-load CPU per valid response
1.33% offered and 3.56% saturated, with separated trial ranges. RSS also rises
in both loads, with separated ranges. Offered goodput improves 0.19% and p99
improves 0.46%, but ranges overlap. Offered p50 rises 5.0%, also with overlap.
Saturated throughput falls 0.17%; p50 improves 0.42%; p99 worsens 0.48%.
Those saturated ranges overlap or touch. Three trial ranges are descriptive
evidence, not confidence intervals.

At 100k/s, median throughput, p50 and p99 exactly tie retained ZHTPS, while
CPU rises 0.65% and RSS rises 0.91%. At 200k/s, p50 ties, median throughput is
6.4 responses/s lower, and median p99 is 0.438 ms versus 0.340 ms with overlapping
ranges. CPU rises 1.07% and RSS rises 0.89%. Lower-load CPU and memory ranges
are separated. Both variants have zero HTTP failures at 100k/200k; generator
misses are 1 / 2 before/pacing at 100k and 249 / 642 at 200k. At 300k, misses
fall from 264,804 to 243,999. Every tie and unfavorable result remains open.

Against Go, pacing leads throughput, CPU and RSS in both high-load workloads,
with separated ranges, and has far fewer read failures. Offered p99 is lower;
saturated p99 is an exact median tie. Both high-load p50 comparisons remain
worse. The complete candidate-versus-Go ledger has 16 separated leads,
eight lower count totals, six ties, two unfavorable medians and one favorable
comparison with overlapping trials. These do not replace the retained server's
broader 48-run GET/upload ledger.

Whole-trial server qdisc drops are 988 / 617 / 628 before and 794 / 692 / 663
with pacing under offered load. Saturated counts are 257 / 326 / 328 before
and 322 / 269 / 262 with pacing. There is no consistent per-pair drop reduction.
All saturated clients, including Go, record roughly 5.7k–6.1k queue-limit drops.
Two offered ZHTPS trials also have about 4.4k–4.7k client queue drops, one for
each variant. These host-wide counters include setup, warmup, every offered
phase, and cleanup; they cannot attribute a specific timeout. No ECN marks
were recorded. The wrapped NIC missed counter is not converted into a guessed
loss total.

Correctness validation passed 65/65 ReleaseSafe build steps and 100/100 Zig
tests, 62 wire tests, and the library/application/upload suites. Three added
wire tests cover admin responsiveness while a response waits for credit,
write-deadline cancellation followed by connection-slot reuse, and shutdown
with queued output. Existing tests remain intact.
Full validation log,
[ownership and validation note](send-pacing/validation-note.md).

The six confirmation runs preserve both exact binaries, client, deadline and
workload settings, extending only the final offered phase to 60 seconds for
three rotated trials per ZHTPS variant. All six passed the same provenance and
failure-accounting audit, without exclusions. They are separate from the
initial trials; no unfavorable run was replaced.
[Confirmation plan](runs/send-pacing-confirmation.json "Summary of docs/send-pacing-confirmation/plan.json; raw artifact retired"),
[audit](runs/send-pacing-confirmation.json "Summary of docs/send-pacing-confirmation/audit.json; raw artifact retired"),
[results](runs/send-pacing-confirmation.json "Summary of docs/send-pacing-confirmation/results.json; raw artifact retired").

| Longer 300k/s offered result | Retained ZHTPS | Pacing prototype |
|---|---:|---:|
| Read timeouts by trial | 13 / 5 / 11 | 12 / 5 / 7 |
| Total read timeouts | 29 | 24 |
| Median valid responses/s | 296,151 | 296,381 |
| Median p50 ms | 3.473 | 3.752 |
| Median p99 ms | 450.888 | 450.888 |
| Median CPU µs/valid response | 3.896 | 3.960 |
| Median sampled RSS MiB | 454.773 | 458.117 |

The observed timeout count is 17.2% lower, with one tied pair. This does not
reproduce the initial effect size. Throughput improves only 0.078%, with
interleaved trial values. Every corresponding p99 quantile ties exactly.
P50 is worse in every pair, with an 8.0% higher median and overlapping ranges.
CPU rises 1.67% and RSS 0.74%, both with separated ranges. At 300k, generator
misses fall from 617,961 to 599,898; neither server sustains the full offered
rate. Both retain zero lower-load HTTP failures. At 200k, generator misses
rise from 345 to 722, despite a favorable throughput median. The full ledger
preserves all of these differences and ties.

Server qdisc drops rise in every longer pair: 1,368 / 1,471 / 1,653 before
versus 1,603 / 1,681 / 2,012 with pacing. Client qdisc drops are substantially
lower with pacing: 0 / 357 / 1 versus 5,709 / 3,108 / 9,762. These are whole-run
host counters, not matched failing-packet traces; they do not prove why the
five fewer HTTP timeouts occurred. No ECN marks were recorded.

The decision is to keep the simpler retained worker implementation. The
prototype shows a lower offered failure count, but does not establish enough
benefit to justify predictable resource costs, worse typical latency and no
saturated failure improvement. This rejects this fixed 100k/s, burst-four
policy; it does not establish that every form of output pacing is ineffective.
No 8k or upload adoption trials are needed for a candidate being discarded.
Adaptive pacing based on delivery feedback remains a separate, unproven design.

Additional unimplemented strategies and source-review limits are recorded in
[the follow-up review](send-pacing/further-strategies.md).
