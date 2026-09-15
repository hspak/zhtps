# What the investigation established

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

For the current implementation's strategy inventory, interactions, complexity
assessment, and subsequent regression fixes, see the
[performance strategy composition review](performance-strategies-review.md).
The measurements below describe their original experiment versions; they are
not a guarantee that every historical optimization remains in today's source.

ZHTPS's architecture was not fundamentally broken. Similar throughput at high
connection counts hid substantially lower server CPU use, while both servers
encountered packet-delivery stalls. The most productive changes reduced memory
provisioning, improved application scheduling and upload buffer reuse, and
shortened recovery from response packet loss.

The investigation ended on September 13, 2026 at the user's request. The retained
server is **`tcp-retries-v1`**. No further experiments are scheduled. These results
do not establish superiority on every metric or guarantee zero read timeouts.

## Read the final results first

The retained comparison contains **48 audited runs**: 24 GET and 24 upload runs,
with three rotated trials per server and workload. ZHTPS has higher validated
GET throughput and lower p99 in all four high-load 8k/16k scenarios. Server
process CPU per valid GET is 81–87% lower and sampled RSS is 7–10% lower in those
scenarios. Process CPU excludes some host packet-processing work.

**Higher p50 is acceptable when p99 is lower.** This is the user's final acceptance
preference. Three retained GET comparisons qualify: 8k saturation, 16k at 300k
offered/s, and 16k saturation. Their p50 increases are 7.1%, 33.1%, and 24.5%;
their p99 reductions are 12.8%, 28.9%, and 4.6%, respectively. The measured p50
values remain in the original ledger; the acceptance decision is recorded
separately. This preference does not waive throughput, CPU, memory, or failure
regressions.

The 90 observations contain 45 favorable comparisons with separated trial ranges,
14 lower count totals, 11 unfavorable comparisons, five favorable comparisons
with overlapping ranges, and 15 exact ties. Applying the preference accepts three
of the 11 unfavorable observations, leaving **eight unfavorable comparisons
unaccepted**. All 15 ties remain open, including 200 MiB/s capped throughput and
zero failures. Three observed trial ranges are descriptive evidence, not formal
confidence intervals or guarantees.

[Final GET/upload report](tcp-read-timeout-mitigation.md),
[original comparison ledger](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/comparisons.json; raw artifact retired"),
[acceptance record](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/acceptance.json; raw artifact retired"),
[investigation wrap-up](go-performance-wrap-up.md).

## Changes retained, and what each actually improved

The percentages below belong to each experiment's own before/after comparison.
They are **not additive**, and changes in workload, CPU placement, configuration,
or generator version prevent treating the rows as one continuous speedup curve.

| Change | Measured benefit | Tradeoff or scope | Detailed evidence |
|---|---|---|---|
| NIC/cache-aware worker placement | Matched seven-worker placement saved 22.3% process CPU and 42.0% p99 at 200k/s; whole-host busy CPU fell 31%. | Placement depends on actual NIC IRQ, cache and SMT topology. | [Architecture review](architecture-review.md), [launcher implementation](architecture-implementation.md) |
| Bounded pools for larger connection buffers | RSS fell 4,864 → 946 MiB, about 81%, at 8k connections. | Cold allocations remain possible; CPU was essentially neutral. Keep the 16 KiB initial receive buffer and conservative cancellation/CQ bounds. | [Buffer implementation and trials](architecture-implementation.md) |
| Shared bounded application lanes and inline generated heads | Fast-handler CPU fell 20% at 50k/s; mixed-handler p99 fell 83% at 2.5k/s. | Applies to generated applications; socket ownership stays with the transport worker. Hook concurrency and lifetime contracts are explicit. | [Application scheduling](architecture-implementation.md) |
| Request storage leased separately from connection slots | RSS fell about 948 → 609 MiB, 36%; CPU fell 6–12% in matched-rate tests. | Request state remains owned through pending application work, pipelines and send completion. | [nginx-inspired change 1](nginx-implementation.md) |
| Optional idle keepalive reclamation | The 50 ms candidate admitted all 3,072 newcomers versus none with reclamation off; all 24,576 returning requests succeeded. Warmed normal-load CPU changed by less than 0.4% at 100k/200k requests/s. | Default remains 0 (disabled): returning-client confirmation p99 rose 8.29 → 9.42 ms (13.6%), including 627 reconnections. This fails the condition to change the default only without a substantial negative result. | [Default-policy follow-up](keepalive-policy.md), [original experiment](nginx-implementation.md) |
| Bounded final keepalive request during shutdown | Regressions that previously reset concurrent idle reuse or rejected an already-started header now receive a closing response. | Default `--shutdown-keepalive-ms 100`, capped by the overall shutdown deadline; ordinary admission limits still apply. Silent established peers can add this wait to shutdown. Clients still handle closure after the final cutoff. | [Shutdown design and regressions](keepalive-policy.md) |
| Optional streaming request-body consumer with backpressure | Upload RSS fell about 75–88%; paced 8 MiB p99 improved about 33% in the original comparison. | Tested against a baseline that really accepts and buffers the same body. Original large-body CPU rose 8–9%; saturated throughput tied and tails were mixed. The consumer must clean up partially processed input. | [nginx-inspired change 3](nginx-implementation.md) |
| Hardware IEEE CRC32 in the upload fixture | Checksum microbenchmark fell 1,706.6 → 25.78 CPU µs/MiB, about 66× faster, reaching Go's checksum cost. | Application benchmark code, not HTTP transport; ordinary GET does not use it. Portable fallback and independent checksum validation remain. | [CRC stack and implementation](upload-parity.md) |
| Larger bounded returned-buffer caches | Isolated small-upload CPU fell 688.10 → 317.05 µs/MiB, 54%, at unchanged throughput; measured fresh allocations and minor faults fell to zero. | Allows more idle cached memory within documented size limits; active lease limits stay unchanged. | [Buffer churn evidence](upload-parity.md) |
| Final fixed-length consumer and handler in one application task | Isolated confirmation reduced CPU about 2.7%, with unchanged throughput and tail latency. | One controlled confirmation pair; incremental gain on top of the final cache was not isolated. Deadline and trailer validation remain. | [Finalization control](upload-parity.md) |
| Common connection buffers allocated when accepted | RSS fell about 609 → 246 MiB at 8k and → 454 MiB at 16k, approximately 60% and 25%. | Retained for memory despite a measured 3–5% GET CPU cost versus previous ZHTPS. | [Connection-buffer follow-up](go-performance-followup.md) |
| Sparse histograms in the load generator | Client peak RSS fell about 17 GiB → 2 GiB, and low/mid-rate generator misses fell for both servers. | Fixture correction shared by both servers; all quantile boundaries, counts and validation are preserved. Earlier ledgers remain available. | [Generator correction](go-performance-followup.md) |
| Bounded thin-stream TCP retries on public listeners | In the retained comparison, 16k read timeouts were 21 vs Go's 5,946 offered, and 2 vs 2,593 saturated. An unchanged six-packet-loss regression now succeeds within the original two-second deadline. | Additional retransmissions and some latency costs; residual failures remain. Public default is `thin-linear`, admin uses system policy, and `--tcp-retries system` is available. | [Retained retry policy](tcp-read-timeout-mitigation.md) |

## Experiments rejected or left unchanged

A successful correctness test or a smaller internal operation count did not by
itself justify retaining a candidate. Favorable observations from discarded
candidates remain in their reports.

| Experiment or proposal | Decision and evidence | Detailed record |
|---|---|---|
| Increase ZHTPS to 32 workers | Did not solve the high-connection bottleneck. Compared with the preceding 16-worker batch: +1.1% throughput at 8k, −1.8% at 16k. Per-worker capacity and CQ sizes also changed to preserve total slots; batches were sequential. | [32-worker LAN trials and startup limit](go-comparison-lan-workers32.md) |
| Immediate nonblocking response sends | Discarded: roughly halved SQEs/CQEs, but 200k GET CPU rose 4.762 → 4.879 µs/response; larger-response results overlapped. | [Architecture implementation](architecture-implementation.md) |
| Shrink initial receive storage to 4 KiB | Reverted after the unchanged full-suite slow-reader failure; 16 KiB passed. | [Buffer correctness and live socket evidence](architecture-implementation.md) |
| Expand access-log drains from 16 to 64 | No reliable CPU, latency or record-completeness benefit in twelve rotated two-host trials; retain 16. | [Logging comparison](architecture-implementation.md) |
| Change completion budget to 16 or 256 | Rotated trials overlapped and remained lossy; retain 64. | [Ranked architecture review](architecture-review.md) |
| Move live sockets across workers or globalize request admission | No demonstrated gain under measured uniform load; substantial ownership and synchronization costs. Shared application lanes address the reproduced scheduling skew. | [Architecture assessment](architecture-implementation.md) |
| Generalize custom-response batching; revise timers or accepts | Conditional opportunities remain workload-dependent. Existing cleanup/cancellation guarantees, measured idle-scan cost and churn counterevidence do not justify a general rewrite. | [Architecture assessment](architecture-implementation.md), [remaining request path](request-path-remaining.md) |
| Upload runtime variants | Opportunistic body reads, coalesced completion notifications, eventfd polling, combined ring submit/wait, and signaling after queue unlock were tested and reverted for no material overall improvement. | [Upload decision history](upload-parity.md) |
| Connection-buffer offset variant V3 | Discarded: small CPU gains (about 1.9% at 8k, 0.17% at 16k) accompanied worse p99 in every pair. | [Buffer-layout follow-up](go-performance-followup.md) |
| Process ready application completions earlier | Discarded: uncapped upload p99 improved, paced p99 worsened in every pair, and throughput did not improve. | [Upload timing and completion-order experiment](go-performance-followup/upload-trace-findings.md) |
| Standalone 50 ms minimum TCP RTO | Discarded after 18 runs: read failures and queue drops increased, with CPU/p50 costs despite some p99 improvements. This did not test every possible combination with thin retries. | [RTO experiment](read-timeout-rto50.md) |
| Fixed response pacing | Discarded after 24 audited decision trials. Initial offered timeouts fell 20 → 9; longer confirmation fell 29 → 24, while saturated timeouts tied 1/1 and CPU/RSS/p50 costs persisted. | [Fixed pacing and confirmation](send-pacing.md) |
| Ten-microsecond server NAPI polling | Discarded after 18 runs: offered read failures tied 14/14 and saturated tied 1/1, while whole-server CPU rose 80–84%. Lower-load latency benefits are retained in the record. | [NAPI experiment](napi-polling.md) |
| Adaptive response pacing | Discarded after 18 audited runs: offered read timeouts fell 21 → 3 and saturated 5 → 0, with lower p99, but throughput fell 20–30%, process CPU per success more than doubled, and RSS nearly doubled. Higher p50 is now acceptable for lower p99; the throughput and resource regressions still prevent adoption. | [Adaptive experiment and storage backlog](adaptive-send-pacing.md) |

Earlier parser, clock, batching, buffer-layout, multishot, accept, kernel, SIMD,
admission and overload experiments are also included in the full report library.
Their individual controls, retained changes, rejected variants and invalidated
measurements remain verbatim in the corresponding reports.

## What caused the upload slowdown

Three measured mechanisms mattered. First, the upload application's original
software CRC32 was expensive; it runs after HTTP body parsing in the bounded
application executor. Second, FQ-CoDel flow collisions on the client could make
two uploads share a queue's service allocation. A controlled collision reproduced
the long tail in both servers. Third, undersized returned-buffer caches caused
repeated allocation, page faults and zeroing during concurrent bursts.

Hardware CRC and cache reuse address distinct CPU costs. Queue calibration is
a separate diagnostic workload, not a reason to delete natural-connection
outliers. Final configuration changes also matter: the upload comparison uses
one ZHTPS network worker with the whole process pinned to CPU 9, versus Go with
GOMAXPROCS=32. These are tuned configurations, not equal CPU allocations.
[Complete attribution and validation](upload-parity.md).

## How to interpret the GET latency tradeoff

p50 is the median successful exchange; p99 is the point below which 99% of
successful exchanges fall. A lower p99 with higher p50 can mean fewer very slow
successes while ordinary requests take slightly longer. These two quantiles
alone do not describe the whole latency distribution or count failed requests.

In the three accepted retained GET cases, the additional median delay is about
0.262 ms, 0.786 ms and 1.311 ms. The corresponding p99 reductions are about
32.506 ms, 184.549 ms and 20.972 ms. Both directions have separated observed
trial ranges. This matches the user's preference for lower tail latency.

The client measures request write through complete response validation. Offered
`success_service_latency` excludes waiting in the generator queue; failures and
unsent offers are accounted for separately. Server-local timing begins only when
received input starts processing, after request storage is acquired, and ends
at local send completion. It excludes earlier scheduling and subsequent network
delivery. A short server-local interval therefore does not prove that the server
contributed no scheduling delay. The rare-timeout traces also do not directly
explain median latency. No complete stage-by-stage timing study of ordinary
successful requests was completed before the investigation stopped.
[Client measurement code](../bench/load/offered.go),
[reported quantiles](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/get-results.json; raw artifact retired"),
[socket correlation](server-timeout-correlation.md).

## What remains unresolved

- The retained default-queue 64 KiB upload p99 is 13.944 ms versus Go's 8.084 ms,
  72.5% higher, with separated trial ranges. Some other upload differences are
  much smaller and overlap, but remain recorded.
- Residual 16k read timeouts remain despite the major reduction. Paired socket
  traces located 17 failures after response bytes were handed to TCP. Two sampled
  failures repeatedly reached driver transmit timestamps without response ACKs.
  This does not identify the exact NIC, switch, wire or receiver loss point.
- Generator misses remain at high offered load. The retained 16k run did not
  sustain all 300k intended offers/s. Small unfavorable lower-load counts and
  throughput observations remain in the ledger.
- Every exact tie remains open, including zero failures and capped throughput.
- Ethernet pause negotiation, reliable short-interval NIC loss sampling with
  reset checks, receiver-ingress correlation and verified ECN participation are
  untested ideas. Both hosts had RX/TX pause disabled; the NIC missed counter's
  export width was verified as 16 bits, without inventing wrap-corrected loss
  totals. No such deployment change was made or scheduled.

[Final delivery evidence](read-timeout-followup.md),
[NIC findings and limits](adaptive-send-pacing.md),
[terminal verification and retained hashes](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/wrap-up.json; raw artifact retired").

## Methods and provenance

The final LAN server is `benchmark-server` (Ryzen AI Max+ 395, 16 physical cores / 32 logical
CPUs); the generator is the second host, `benchmark-client` / `client.example` (Ryzen 8745HS,
eight physical cores / 16 logical CPUs), connected over 2.5 Gb/s Ethernet. GET
uses seven ZHTPS workers on CPUs 9–15 and client CPUs 0–7. Go HTTP uses
**GOMAXPROCS=32 with normal GC**. The checksum-only microbenchmark's Go probe uses
one core; the remote GET generator uses eight. These are different processes.

Final GET trials use ReleaseSafe, HTTP/1.1 keepalive, a validated six-byte body,
one outstanding request per connection, no TLS and no access logging. High-load
windows last 20 seconds; lower offered-rate windows last ten seconds. GET uses
the original two-second deadline. Uploads use 32 connections, independent body
length and IEEE CRC32 validation, and a 20-second socket timeout; 64 KiB windows
last 20 seconds and 8 MiB windows 30 seconds, after five seconds of warmup.

Failure counts are summed across trials; throughput, CPU, RSS and quantiles are
medians of trial metrics. Quantiles are not pooled. RSS comes from active-window
samples, not the smaller post-disconnect value. Whole-host CPU includes process
CPU, so the two must not be added. Whole-run network counters may include setup,
cleanup and unrelated traffic; they do not locate individual losses.

The final adaptive pacing runs are a separate comparison block with their own
retained-server controls. They do not replace the retained 48-run matrix. Earlier
loopback, worker-count, upload and generator versions also remain separate.
nginx supplied architectural inspiration; it was not a benchmark participant.

The retained implementation passed 65 build steps, 97 Zig tests and the complete
wire, embedded-library, application and upload/streaming suites. The unchanged
loss regression drops six response packets: the retained default succeeds in
1.247 s; explicit system retries reproduce a timeout in 2.002 s. Build receipts, summarized results, and run descriptions remain linked from each
report. Raw artifacts and source snapshots were removed; recorded hashes identify
the measured versions. The HTML embeds retained reports and summaries.
