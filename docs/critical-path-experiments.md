**Critical-path experiments — 2026-09-11**

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

This report records the first optimization pass. The
[remaining experiments and current cost budget](request-path-remaining.md)
add the subsequent transport, formatting, timer, and local-network results.
Numbers and source archives below describe the first pass independently.

The local experiments favor cooperative completion handling, reuse of timestamps,
vectorized field validation with fixed-size header copies, and bounded log batching.
These changes are retained in the working tree and passed combined validation.
Submission/wait merging, poll-first receive, speculative complete-head parsing, and
separate parser allocation are parked. Physical-network work remains unmeasured:
there is no separate load-generator host available.

The [earlier review](request-critical-path.md) gives the complete request dependency
chain and separates component measurements from kernel cost estimates. This report
records the experiments behind the updated decisions. “Parked” means do not spend
more time on this candidate without the stated new evidence; it does not establish
a theoretical optimum for the surrounding subsystem.

The baseline is the tree at the start of this pass, saved in
baseline.tar.gz, identified by
[source hashes](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/baseline-hashes.json; raw artifact retired"). It includes newer
admission/overload behavior than the earlier review. All runtime changes are available
as a single reviewable patch.

**Combined implementation results**

These are fresh comparisons of the archived baseline against the exact retained
source, with three alternating-order trials for each workload. The retained changes
are in [server.zig](../src/server/worker.zig), [Logger.zig](../src/Logger.zig),
[Exchange.zig](../src/application/Exchange.zig), [Parser.zig](../src/http/Parser.zig),
and [syntax.zig](../src/http/syntax.zig).

| Workload | Offered rate | Baseline CPU / response | Retained CPU / response | Reduction |
|---|---:|---:|---:|---:|
| Small GET, no access log | 100k/s | 1.540 µs | 1.440 µs | 6.5% |
| Small GET, no access log | 300k/s | 1.640 µs | 1.507 µs | 8.1% |
| Longer-header POST, no access log | 100k/s | 3.060 µs | 2.420 µs | 20.9% |
| Longer-header POST, no access log | 300k/s | 2.634 µs | 2.240 µs | 15.0% |
| Small GET, access log to tmpfs | 20k/s | 3.501 µs | 2.200 µs | 37.1% |
| Small GET, access log to tmpfs | 100k/s | 3.180 µs | 1.980 µs | 37.7% |

[Small GET trials](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/retained-small/summary.json; raw artifact retired"),
[header trials](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/retained-headers/summary.json; raw artifact retired"),
[logging trials](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/retained-logging/summary.json; raw artifact retired").
The retained logging runs completed about 2.19 million requests with zero recorded
log drops, versus 839 dropped events in the matching baseline runs. The earlier
isolated batch experiment did record occasional drops; the logger remains bounded
and lossy under pressure.

The pinned server core's overall busy fraction fell from **83.5% to 80.9%** for
small GETs at 300k/s, and **99.8% to 93.2%** for the longer-header case. Those are
smaller relative changes than process CPU savings: process accounting does not
capture all work on the core. Neither number establishes physical-network capacity.

Small-GET service p99 improved from 131 to 124 µs at 100k/s and 132 to 129 µs at
300k/s. Logging service p99 at 100k/s was essentially unchanged, 151 to 150 µs.
Longer-header service p99 at 300k/s had medians 190 to 185 µs, but retained trials
ranged 181–281 µs. Intended-offer p99 increased from 0.319 to 1.106 ms in that case,
coinciding with generator scheduling p99 rising from 0.056 to 0.819 ms. The CPU gain
does not imply a universal latency improvement.

The combined closed-loop comparison reached median throughput of **506k → 526k/s**
at 64 connections, with service p99 **195 → 183 µs**. At one connection, throughput
was essentially unchanged (**146k → 147k/s**) and p99 was **9.28 → 9.02 µs**. These
are three-trial local observations, not a physical-network capacity claim.
[Combined latency trials](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/retained-latency.json; raw artifact retired").

Additional one-pair checks exercised 64 KiB echo, chunked streaming, and admission
recovery. Echo at 20k/s used 8.70 → 8.40 µs CPU; streaming at 100k/s used
5.16 → 5.14 µs. Both validated every sent response with no HTTP/transport failures.
Some service tails increased, including echo p99 287 → 307 µs, so these short
checks do not establish small speedups or universal tail improvements.
[Echo](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/retained-echo/summary.json; raw artifact retired"),
[streaming](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/retained-stream/summary.json; raw artifact retired").

With admission limited to 150k/s and offered load raised to 300k/s, both builds
completed about 150.2k/s. The existing bounded rejection policy shed most excess
traffic by closing sockets: the retained overload phase had 739,150 EOFs and
5,992 HTTP 503 responses. Recovery returned to roughly 100k/s, with four residual
EOFs versus two in baseline. Admin requests remained available, no sampled listen
or TCP backlog drops appeared, and all servers exited cleanly. This checks preserved
shedding/recovery behavior; it is not a failure-free overload result or a sustained
SLO certification. [Overload and recovery](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/retained-overload/summary.json; raw artifact retired").

For a normal small GET, the retained clock change removes three reads: six
monotonic plus two realtime calls become four plus one, excluding loop-amortized
calls. At the earlier measured ~16.4 ns/read, that suggests ~49 ns less work, which
is consistent with the isolated whole-server saving. Parser component work is
~168 ns for a short head and ~765 ns for the longer benchmark head. A retained
log now amortizes its write over a batch; formatting still costs roughly the
previously measured 191 ns plus its clock read. The kernel rows in the
[original cost table](request-critical-path.md) remain estimates, calibrated by
the aggregate CPU and syscall observations below, not replaced by invented
per-function timings.

**Correctness checks**

The retained source passed all **47 component tests** in ReleaseSafe on x86-64-v3
and baseline CPU targets, and in Debug on the baseline CPU target. All **46 raw TCP
tests** passed in both ReleaseSafe and Debug, including multi-worker startup,
partial-startup failure, blocked and closed log sinks, large fragmented bodies,
streaming, overload recovery, cancellation with a full submission queue, and slow
readers. The parser fuzzer completed **101,814 runs** without a failure.
Commands and exits,
fuzz report.

The added parser specification tries every byte at every offset in field values
of lengths 31, 32, 33, 63, 64, 65, and 96: 98,304 cases spanning vector boundaries.
It also passed against the baseline. The existing fragmentation fuzzer retains
all previous seeds and adds a longer valid header. A logger test covers partial
records across queue wrap and enqueuing another record before the remainder is
consumed. Existing tests were preserved; these are optimization-preservation checks,
not claims of a previously failing bug regression.

All twelve isolated server variants also passed the existing 46 raw TCP tests
with verified distinct executables. Relevant component test logs are retained
under verified-tests/. `zig fmt` was
applied to the changed Zig files. The archived patch reconstructs exactly the
source identified by [retained-build.json](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/retained-build.json; raw artifact retired").

**Isolated measurements**

Unless stated otherwise: Linux 7.2.4, Zig 0.16.0 ReleaseSafe, x86-64-v3, one worker on
CPU 2, 64 persistent connections, 256 public slots, clients on CPUs 4–7, three trials
with alternating variant order. Tables show medians. CPU cost is sampled process
CPU divided by successful responses/s, not latency. The six-second measured phases
are experiments, not sustained capacity certifications. Warmup is excluded from the
cost tables. [Environment](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/environment.json; raw artifact retired").

| Small GET variant | CPU at 100k/s | CPU at 300k/s | Decision |
|---|---:|---:|---|
| Baseline | 1.620 µs | 1.669 µs | Reference |
| Combine submit and wait | 1.640 µs | 1.688 µs | Park: no benefit |
| Poll-first receive | 1.700 µs | 1.674 µs | Park: no benefit |
| COOP_TASKRUN | 1.540 µs | 1.569 µs | Retain: about 5–6% less CPU |
| Reuse timestamps | 1.580 µs | 1.614 µs | Retain: about 2–3% less CPU |
| Combined wait + SINGLE_ISSUER + DEFER_TASKRUN | 1.500 µs | 1.527 µs | Park: small additional saving over cooperative handling, greater complexity |

[Transport results](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/transport-verified/summary.json; raw artifact retired").
These savings are not additive: the combined implementation is measured separately.
All requests actually sent in these trials succeeded; some offers expired in the
load generator before transmission. At fixed offered rates, throughput is mostly
fixed by the generator, so the table establishes a CPU saving rather than extra
server capacity.

At closed-loop concurrency 1, median p99 was 9.47 µs for baseline, 9.22 µs for
cooperative handling, and 10.43 µs for deferred task work. At concurrency 64 the
medians were 164, 172, and 172 µs; throughput was 511k, 510k, and 519k responses/s.
Cooperative handling therefore has no demonstrated closed-loop throughput gain.
Deferred task work adds about 2.7% CPU savings over cooperative handling in the
300k offered-rate case, with a worse single-connection p99 and only 1.7% higher
closed-loop throughput. It also needs worker-owned ring enabling and Linux 6.1
capability handling, whereas the project supports Linux 6.0. Cooperative handling
has been available since Linux 5.19. The ownership and version constraints are
documented in [liburing’s setup contract](https://raw.githubusercontent.com/axboe/liburing/master/man/io_uring_setup.2).
That tradeoff does not justify retaining deferred handling here. [Latency trials](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/latency-verified.json; raw artifact retired").

| Parser variant | Short head | Longer head | Decision |
|---|---:|---:|---|
| Baseline | 168 ns | 890 ns | Reference |
| Vectorized field validation | 169 ns | 844 ns | Combine with fixed copy |
| Fixed 16-byte delimiter-free copy | 170 ns | 830 ns | Combine with validation |
| Both | 168 ns | 765 ns | Retain: 14% less longer-head work |
| Speculative complete-head parse | 131 ns | 941 ns | Reject: regresses longer headers |

The component workload includes framing, copying, semantic validation and reset;
the longer head includes a 256-byte cookie and additional fields. Three repeated
measurements show the combined longer-head range at 765–771 ns, versus 889–900 ns
for baseline. [Component results](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/components-verified.json; raw artifact retired").

A full-server POST /echo with an empty body and a 526-byte Content-Type value
reduced CPU from **3.180 to 2.500 µs at 100k/s** and **2.641 to 2.394 µs at 300k/s**.
Service p99 improved from 205 to 185 µs and 193 to 184 µs. Intended-offer p99 at
300k/s increased from 0.297 to 1.090 ms; it includes local generator scheduling.
This is a CPU improvement, not a claim that every latency measure improved.
[Header workload](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/headers-verified/summary.json; raw artifact retired").

| Access logging to tmpfs | Baseline | Batch up to 16 records |
|---|---:|---:|
| CPU at 20k/s | 3.400 µs | 2.300 µs |
| CPU at 100k/s | 3.201 µs | 2.080 µs |
| I/O submissions / completed response, whole run | 3.002 | 2.158 |
| Dropped events across three runs | 1,183 / 2.190M completions | 130 / 2.190M completions |
| Service p99 at 100k/s | 150 µs | 159 µs |

The batching gain is about one third of process CPU while retaining more records.
Both queues can still drop events during bursts: the drop fractions were 0.054%
and 0.0059%. JSON records in the actual sink were parsed and counted. This does not
measure disk durability or remote collector cost. Service p99 rose by about 6–9 µs
at 20k–100k/s; intended-offer p99 was unchanged. The batch starts immediately with
whatever is queued, retains its fixed prefix through partial writes, and preserves
shared stderr ownership until that prefix completes.
[Logging workload](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/logging-verified/summary.json; raw artifact retired").

At 4,096 active connections in an 8,168-slot public pool, moving parsers into a
separate allocation changed CPU at 100k/s from **3.881 to 3.961 µs**. Service p99
changed from 317 to 371 µs. The 200k/s phase exceeded what this local setup could
deliver: both configurations completed only about 173k–174k/s, with unsent offers
and roughly 25 ms service p99. Some warmups also had dial timeouts. Those phases
cannot establish clean server capacity. The layout change is not retained.
[Large-pool workload](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/many-verified/summary.json; raw artifact retired").

**Kernel, event-loop, and idle-pool evidence**

A separate ten-second baseline run completed 999,924 validated requests. The
process accrued **0.35 s user CPU and 1.19 s system CPU** over the surrounding
sample window: about **0.35 µs userspace + 1.19 µs charged kernel CPU per response**.
This is aggregate attribution, not a breakdown of TCP, copying, polling, and ring
management; it omits network work charged to other contexts. Hardware kernel-cycle
counters reported unsupported, and the software recording produced only 97 samples
of `cpu-clock:u`. Its sample summary
cannot establish a kernel call graph or precise percentage budget. The effective
user-only event is explicit in that report. [CPU samples and validated traffic](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/cpu-profile.json; raw artifact retired").

For 10,000 serial GETs, baseline and cooperative handling each made 20,010
`io_uring_enter` calls; combined submit/wait and deferred handling each made 20,006.
That is effectively **two enters per request** in every case. Traced durations are
perturbed and are not throughput evidence.
Syscall traces.

A separate instrumented 50k/100k offered-rate run recorded about **11.35 CQEs per
loop** for baseline and **10.16** for submit/wait merging. Both had a median batch
of 1 and a p99 of 64. Every 1,024th loop sampled setup, submit/wait, and dispatch
separately. Baseline's 121 sampled loops measured about 46 ns setup per loop and
293 ns dispatch per CQE. The 98 µs mean submit/wait interval includes sleeping and
scheduling; it is not active kernel CPU. This confirms why the existing
`event_loop_duration_seconds` metric, recorded before dispatch/wait, is not a
whole-loop cost metric. These probes are retained as experiments, without adding
permanent instrumentation overhead to the server.
Baseline probe,
wait probe.

With 8,176 total slots and either zero or 4,096 idle sockets, baseline consumed
about **0.1% of one CPU**. Separate parser allocation remained around 0.1% with no
sockets and around 0.2% with 4,096 idle sockets. RSS stayed about **1,317 MiB** in both
layouts: moving parsers changes stride, not reserved capacity. Measurements are
three ten-second trials per configuration, with 10 ms process-CPU accounting
resolution. This leaves little reason to build a timer wheel for this pool and
workload. Idle trials.

**Where to stop, and what remains open**

| Area | Status and reason | Evidence needed to reopen |
|---|---|---|
| Admission arithmetic, histogram classification, free-slot lookup | CAPPED for this workload; roughly nanosecond arithmetic and O(1) lookup | A profile shows these operations or cache contention are material |
| Hot-path allocation | CAPPED: no per-request heap allocation | An application hook introduces allocation or capacity requirements change |
| Clock implementation, cached Date formatting, tiny-body copying | CAPPED: retain vDSO reads, once-per-second formatting, one small combined send | A substantially different response/application mix |
| Further clock coalescing | PARKED after removing three reads on a normal GET | Safe reuse that preserves per-request timing and shows a whole-server gain |
| Submit/wait merging, poll-first receive | PARKED after repeated negative experiments | A different readiness pattern or physical-network profile identifies the relevant cost |
| Deferred task work | PARKED: small marginal saving, ownership/version complexity, worse serial tail | A Linux 6.1+ deployment and a workload showing a meaningful advantage over COOP_TASKRUN |
| Complete-head speculative parser | REJECTED: longer-header regression and extra malformed-input fallback work | A design that improves longer headers and preserves fragmentation/error behavior |
| Separate parser allocation and timer redesign | PARKED: active workload regressed; idle cost about 0.1% of a CPU | Material idle CPU, timer-tail cost, or cache/TLB evidence at the deployment's pool size |
| Larger-header parsing | IMPROVED; stop tuning the current pair without new evidence | A profile of a representative header mix identifies remaining scan/validation cost |
| Log formatting and additional batching work | PARKED after the bounded batch improvement | The real sink and retained-record requirement make further work material |
| Multishot receive, registered buffers/files | OPEN architectural follow-up, not implemented in this pass; [multishot receives consume provided buffers and require CQE lifetime handling](https://raw.githubusercontent.com/axboe/liburing/master/man/io_uring_prep_recv.3) | A profile justifies ownership/cancellation complexity and a meaningful saving over the current receive path |
| NIC queues, IRQ/RSS placement, coalescing, offloads | OPEN / UNMEASURED | A separate client host and physical-network counters |
| SQPOLL, busy polling, kernel bypass | PARKED | A physical-network latency/CPU target that simpler mechanisms cannot meet; count extra polling CPU |

**Measurement integrity and reproduction**

Initial server/hot-path comparisons were invalidated after their hashes showed
identical baseline executables at every output path. A shared Zig local cache
reused the compiler source root across isolated trees. Those results and test
logs remain under [invalid/](runs/critical-path-experiments.json "Run summaries from docs/critical-path-experiments/invalid; raw artifacts retired") and are not evidence
for any retained variant. The corrected build runner gives every tree its own
local cache, records the compiler's absolute module paths, and checks executable
hashes. Benchmark runners verify the recorded executable hashes before running.
See [the invalidation record](runs/critical-path-experiments.json "Summary of docs/critical-path-experiments/initial-results-invalid.json; raw artifact retired").

The old client affinity 4–11 crossed two L3 cache groups and produced large baseline
variation. Corrected comparisons use clients 4–7 and server 2 within one L3 group.
This also explains why their absolute CPU costs should not be directly compared
with the earlier review's 2–4 µs anchor. Neither CPU policy nor kernel tunables were
changed. Process CPU omits some network work charged elsewhere; loopback additionally
runs both endpoints on this machine.

The archived baseline plus each `*.patch` reproduces the corresponding source tree.
Build separate trees with [build_request_variants.py](../bench/build_request_variants.py)
and separate local caches. The verbose `*-build.txt` files and `*-build.json` records
identify the actual compiler module roots and hashes. Do not share a Zig local
cache between variant source trees.

```sh
python3 docs/critical-path-experiments/prepare.py baseline retained --from-patches
python3 bench/build_request_variants.py baseline retained
python3 bench/compare_request_path.py baseline retained \
  --case small --output /tmp/zhtps-compare-small
python3 bench/compare_request_path.py baseline retained \
  --case headers --output /tmp/zhtps-compare-headers
python3 bench/compare_request_path.py baseline retained \
  --case logging --schedule 5000:2s,20000:6s,100000:6s \
  --output /tmp/zhtps-compare-logging
python3 bench/compare_request_latency.py baseline retained \
  --output /tmp/zhtps-compare-latency.json
```

The restore and build runners default to `/tmp/zhtps-experiments/<variant>`;
`--workspace` selects another parent. Restore refuses to overwrite an existing tree.
Restoring both archived patches into fresh trees was checked against the measured
source hashes. Run CPU comparisons sequentially without concurrent builds
or test suites. Network/io_uring tests require an environment that permits those
operations. No remote host or deployment was used.
