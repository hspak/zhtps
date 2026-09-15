The investigation ended at the user’s request on September 13, 2026.
See the [final wrap-up](go-performance-wrap-up.md) for retained changes,
discarded experiments and unresolved results. The work plans below are
historical; no further experiments are scheduled.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

ZHTPS uses less CPU and memory than Go in most of this rerun, but it does not
win every result. **The goal remains open. Every tie remains open**, including
200 MiB/s paced throughput, equal large-upload throughput, the original tied GET p99, and
zero upload failures.

A subsequent [read-timeout investigation](read-timeout-mitigations.md) adds
twelve separately audited GET runs. An isolated TCP retry-policy candidate
reduces 16k read timeouts by 99.7–99.9%, with residual failures and measured
performance costs. It is not applied to the retained server and does not replace
or close the comparisons below.
The follow-up now also includes a [discarded 50 ms RTO experiment](read-timeout-rto50.md)
with 18 runs and a [fresh thin-stream comparison against Go](read-timeout-thin-go.md)
with 24 runs. The thin-stream candidate improves high-load goodput and failures,
while retaining median-latency gaps and saturated p99 ties. It remains isolated
pending upload validation and integration.

The current primary comparison contains 48 HTTP trials: three rotated trials
per server for every original GET/upload scenario, using the corrected sparse
histogram client for GET. The upload client and retained server binaries are
unchanged. Including historical controls, rejected experiments and client
placement/trace diagnostics, the [audit](runs/go-performance-followup.json "Summary of docs/go-performance-followup/audit.json; raw artifact retired")
validates **192 recorded runs**. No failed HTTP requests or load-generator drops
were removed. The failed 10k/s churn control remains recorded as client-port
exhaustion, not server capacity.

The [current ledger](runs/go-performance-followup.json "Summary of docs/go-performance-followup/sparse-comparisons.json; raw artifact retired") has 82
metric comparisons: **42 with separated favorable trial ranges, 15 unfavorable
aggregate results, 12 ties, and 13 favorable aggregates with overlapping trial
ranges**. Three trial ranges describe these runs; they are not a formal
confidence interval. Every tie, unfavorable result and overlapping result stays
open. The [original-client ledger](runs/go-performance-followup.json "Summary of docs/go-performance-followup/current-comparisons.json; raw artifact retired")
is preserved separately, including its 82 primary and 37 placement-diagnostic
comparisons. Changing the fixture does not silently close its tied results.

Both servers ran on benchmark-server, with load from the established second host benchmark-client over
the 2.5 Gb/s wired LAN. Go HTTP uses **GOMAXPROCS=32 and normal GC**. GET uses
seven ZHTPS workers on CPUs 9–15, 4,096 public slots per worker, access logging
disabled and the existing 50 ms idle-pressure policy. Uploads use one ZHTPS
network worker and one thread per application lane, with the whole process
on CPU 9; Go remains unrestricted. Primary clients use CPUs 0–7. Placement
diagnostics use CPUs 0–6, leaving NIC CPU 7 and its SMT sibling 15 free of
load-generator execution. No host IRQ, qdisc or TCP setting was changed.

**Retained server change: allocate common buffers for accepted sockets.**
Previously, all 28,672 configured public slots reserved their roughly 20 KiB
sets even when only 8k or 16k sockets were present. Public buffers now follow
accepted sockets, with up to 64 sets reserved initially and cached per worker.
Release waits for application cleanup and the end of socket I/O. Admin buffers
remain reserved. Allocation failure closes the affected public socket, records
the failure and briefly backs off public acceptance. Large-body buffer limits
remain separate. [Design and ownership](go-performance-followup/connection-buffer-design.md),
[exact retained source and binaries](runs/nginx-implementation.json "Summary of docs/nginx-implementation/go-connection-buffers-v2/build.json; raw artifact retired").

Three rotated before/after pairs at 200k offered requests/s establish the
tradeoff:

| Connections | Previous / current RSS | Previous / current CPU per response |
|---|---:|---:|
| 8,192 | 609.43 / 245.56 MiB | 4.079 / 4.213 µs |
| 16,384 | 609.10 / 454.03 MiB | 4.612 / 4.823 µs |

The change is retained for the 60%/25% memory reduction. Its **3–5% GET CPU
cost versus previous ZHTPS remains documented**. A cache-offset experiment
recovered 1.9% CPU at 8k and only 0.17% at 16k, while worsening p99 in every
pair at both counts; that experiment is reverted.
[Before/after plan](runs/go-performance-followup.json "Summary of docs/go-performance-followup/connection-buffer-plan.json; raw artifact retired"),
[offset experiment](runs/go-performance-followup.json "Summary of docs/go-performance-followup/connection-buffer-offset-plan.json; raw artifact retired"),
[decisions](runs/go-performance-followup.json "Summary of docs/go-performance-followup/connection-buffer-candidate.json; raw artifact retired").

The permanent RSS regression failed on unchanged ZHTPS: raising capacity from
64 to 4,096 with one exercised connection increased RSS by 86,978,560 bytes.
It passes unchanged on the retained implementation. Both ReleaseSafe and Debug
pass 65/65 build steps and 94/94 component/CRC tests, plus the wire, streaming,
executor and embedded suites. The existing embedded guarantee of bounded
allocation-free operation was preserved: an initial prototype broke that test,
and reserving 64 common sets restored it without changing the test.
Before failure,
ReleaseSafe,
Debug.

Some current GET results illustrate both the gains and remaining gaps. Entries
are ZHTPS / Go; goodput and latency are trial medians, and failures are totals
across three trials. Failure counts must be read with generator drops and
preparation/warmup errors in the complete records.

| Workload | Valid responses/s | p99 | HTTP failures |
|---|---:|---:|---:|
| 8k, 300k offered/s | 299,957 / 297,516 | 3.16 / 444.60 ms | 0 / 741 |
| 16k, 300k offered/s | 292,304 / 288,530 | 641.73 / 633.34 ms | 3,448 / 3,255 |
| 8k saturated | 358,620 / 350,404 | 222.30 / 239.08 ms | 120 / 84 |
| 16k saturated | 323,810 / 308,616 | 432.01 / 484.44 ms | 1,510 / 2,334 |

Saturated p50 is 3.817 / 4.014 ms at 8k, with overlapping trial ranges;
at 16k it remains worse at 6.128 / 4.981 ms. Under-load RSS is
246.12 / 266.53 MiB and 455.48 / 492.19 MiB; interval CPU estimates are
3.068 / 24.284 µs and 3.404 / 24.135 µs per valid response. These estimates
divide interior process CPU rate by whole-window valid goodput; separately
executing IRQ work is not process CPU. Warmup failures also remain in the
ledger: the saturated 16k totals are 953 / 795, another unfavorable result.
[GET aggregates](runs/go-performance-followup.json "Summary of docs/go-performance-followup/get-aggregate.json; raw artifact retired"),
[8k offered and saturated commands](runs/go-performance-followup.json "Summary of docs/go-performance-followup/sparse-get-plan.json; raw artifact retired"),
[16k offered pairs](runs/go-performance-followup.json "Summary of docs/go-performance-followup/client-histogram-plan.json; raw artifact retired").

The closed-loop client now exports its existing measurement start/end times.
This output-only change lets the audit measure CPU and RSS while connections
are active. Post-run RSS is kept separately: ZHTPS frees public buffers when
clients disconnect, so its roughly 60 MiB post-run RSS is **not** presented as
live 8k/16k memory use. The original executable is preserved. The new client's
tests pass and its complete Go build settings match the original's.
Client receipt,
[measurement rationale](go-performance-followup/client-window-design.md).

Current uploads also retain meaningful gaps. Entries are ZHTPS / Go medians;
all responses passed independent length and IEEE CRC validation and every
upload trial had zero failures.

| Upload workload | Goodput MiB/s | p99 ms | CPU µs/MiB |
|---|---:|---:|---:|
| Fresh 64 KiB | 279.388 / 279.363 | 8.026 / 7.862 | 315.1 / 541.4 |
| Calibrated, distinct-queue 64 KiB | 246.647 / 246.994 | 12.864 / 12.842 | 266.2 / 514.6 |
| Distinct-queue 8 MiB | 281.067 / 281.067 | 927.832 / 916.226 | 291.1 / 341.5 |
| Paced 8 MiB | 200 / 200 | 30.413 / 29.930 | 179.8 / 185.2 |

Upload RSS favors ZHTPS in every row. Paced CPU trial ranges overlap. The fresh
small-upload tail varies with the previously demonstrated qdisc flow collisions;
calibration changes TCP behavior and is kept as a distinct workload. Large-body
throughput is quantized in 8 MiB / 30 s increments and is near the LAN ceiling.
None of these limitations closes a tie.
[Upload aggregates](runs/go-performance-followup.json "Summary of docs/go-performance-followup/aggregate.json; raw artifact retired"),
[commands](runs/go-performance-followup.json "Summary of docs/go-performance-followup/current-upload-plan.json; raw artifact retired").

Remaining investigations, ordered by current evidence and useful impact:

1. **Load-generator histogram allocation: fixed, with residual results open.**
   The offered client retained four 64 KiB histograms per connection per phase.
   Sparse allocation preserves every quantile boundary and count while cutting
   peak client RSS from about 17 GiB to 2 GiB in three rotated pairs per server.
   At 16k/100k offered/s, generator drops across three trials fall from
   43,216 / 43,255 for ZHTPS / Go to 1 / 2. At 200k they fall from
   123,422 / 128,527 to 281 / 914. The unchanged integration regression fails
   on status quo with 290,724,616 allocated bytes and passes the candidate's
   96 MiB bound; all client tests pass. This fixture correction applies to both
   servers. The original comparisons remain in their separate ledger. At 300k, sparse
   client p99 is still 641.73 / 633.34 ms and HTTP failure totals are
   3,448 / 3,255: ZHTPS has not won those results.
   [Paired results](runs/go-performance-followup.json "Summary of docs/go-performance-followup/client-histogram-aggregate.json; raw artifact retired"),
   [design and decision](go-performance-followup/client-sparse-design.md),
   before failure.
2. **Packet loss and saturated request latency.** Interior samples show roughly
   531k–558k server retransmissions in the original 16k/300k baseline trials.
   Reserving the load host's NIC core improves offered-load tails for both
   servers. At 16k/300k, p99 changes from 638 to 474 ms for ZHTPS and 633 to
   528 ms for Go. Saturated diagnostics remain difficult: with that core free,
   Go reaches 367,028/s versus ZHTPS's 361,757/s at 8k, and 16k throughput is
   essentially tied. ZHTPS's saturated median latency remains higher. These
   diagnostics do not replace or close the original-placement comparisons.
   [Placement evidence](runs/go-performance-followup.json "Summary of docs/go-performance-followup/client-nic-placement.json; raw artifact retired"),
   [paired diagnostic](runs/go-performance-followup.json "Summary of docs/go-performance-followup/client-placement-aggregate.json; raw artifact retired"),
   [closed-loop packet records](runs/go-performance-followup.json "Summary of docs/go-performance-followup/current-closed-network.json; raw artifact retired").
3. **Upload tail latency and remaining throughput differences.** Hardware CRC
   and the previous streaming changes remain in the build. The current gaps
   are small relative to the earlier CRC problem, but remain open. Traced paced
   controls show only 5–8 of 750 uploads with retransmissions per trial, enough
   to shift p99. Conditional p99 without retransmissions is around 29.8 ms for
   both servers; all requests stay in the benchmark totals. A completion-order
   experiment passes all tests and improves uncapped p99, but worsens paced
   p99 in every pair and provides no throughput gain. It is discarded.
   [Traces and experiment](go-performance-followup/upload-trace-findings.md).
4. **Residual buffer-layout CPU cost.** The retained memory reduction costs
   measurable GET CPU versus previous ZHTPS. The first offset experiment was
   unsuccessful overall; further layout changes need controlled measurements.
5. **Every exact tie.** Capped throughput and zero errors have mathematical
   bounds, but the user explicitly requires these results to remain open.

Some NIC missed-counter differences are negative. Upstream r8169 exposes a
16-bit hardware missed counter, so rollover can explain those readings. Raw
readings are preserved; negative differences are not reported as negative loss
or converted into assumed wrap counts.
[Driver source](https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/r8169_main.c).
