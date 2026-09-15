# Response aggregation revisit

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Follow-up: [aggregation is now integrated into the main server](response-aggregation-integrated.md)
for the built-in application, with startup allocation and owned access-log
metadata. This report preserves the preceding isolated prototype and its results.

The revised prototype preserves packet coalescing across short aggregates and
falls back to ordinary sends when the admission budget is too small. This
removes the earlier large regression at the normal budget while retaining useful
pipeline gains when there is room for full batches. It remains an isolated
prototype; [NIC-aware worker placement](nic-placement.md) is integrated into the
main server.

The original [kernel-work report](kernel-work.md) found that short aggregates
reduced SQEs but nearly tripled TCP segment counts. The baseline already used
`MSG_MORE`; the prototype sent every aggregate without it. The first revision
restores `MSG_MORE` when complete request heads remain buffered, with a limit
of 16 responses across consecutive aggregates. Partial sends retain the same
flag. Exhausted input, interim responses, non-batchable responses, and the
coalescing limit flush the output. The existing TCP_NODELAY flush still handles
an incomplete next request.

That change alone fixes packet counts but leaves overhead from short batches.
At the normal 192-permit budget, the repeated coalescing-only variant is about
8% slower at pipeline depth 8 and 12% slower at depth 32, with CPU/response up
10% and 19%. Packet counts are back to baseline. This separates the packet
formation cost from the remaining copying and completion-bookkeeping cost.

The adaptive revision starts an aggregate only when the configured active
permit budget is at least four times the worker's current open connection count
(including its admin connection). Otherwise it uses the existing ordinary send
path. A started aggregate still flushes normally. This is a conservative budget
heuristic, not a measurement of actual batch length: idle connections can suppress
batching, and the existing admission-headroom guard can still shorten a batch.
Four is the tested cutoff, not an exhaustively tuned optimum.

Each case uses 64 persistent connections, one worker on CPU 2, client CPUs 4–7,
a one-second warmup, and five measured seconds. Three trials rotate the order of
baseline, coalescing-only, and adaptive binaries. Builds are ReleaseSafe,
x86-64-v4, Zig 0.16.0. Each admission budget has its own matching baseline;
192 permits uses 256 connection slots, while 1024 permits uses 1024 slots.
No CPU-intensive validation or compilation ran during the repeated comparison.

| Workload | Permits | Baseline responses/s | Adaptive responses/s | Throughput change | CPU/response change | TCP segments/response, baseline → adaptive |
|---|---:|---:|---:|---:|---:|---:|
| Depth 1 | 192 | 516,334 | 519,810 | +0.7% | -1.0% | 2.000 → 2.000 |
| Depth 8 | 192 | 1,330,753 | 1,318,268 | -0.9% | +1.0% | 0.250 → 0.250 |
| Depth 32 | 192 | 1,472,233 | 1,466,720 | -0.4% | +0.6% | 0.125 → 0.125 |
| Depth 8, 8-byte writes | 192 | 499,238 | 501,383 | +0.4% | -0.2% | 5.379 → 5.373 |
| Depth 8 | 1024 | 1,312,365 | 1,583,693 | +20.7% | -18.4% | 0.250 → 0.250 |
| Depth 32 | 1024 | 1,479,855 | 2,049,208 | +38.5% | -27.3% | 0.125 → 0.125 |

At the normal budget, adaptive throughput and CPU/response remain within about
1% of baseline. At 1024 permits, adaptive throughput improves 20.7% at depth 8
and 38.5% at depth 32; CPU/response falls 18.4% and 27.3%. The fragmented case
remains approximately unchanged. These are repeated single-worker loopback
pipeline results; they do not establish multi-worker or physical-NIC capacity.
The pipeline client does not collect latency percentiles.

All 54 trials validated 318,979,563 responses with no client failures or server
rejections, aborts, protocol errors, timeouts, or I/O errors. CPU uses matching
server process samples and completed-response deltas. TCP counters include
requests, responses, ACKs, and background activity across the whole host, so they
are diagnostic packet evidence rather than per-socket response packet counts.
User PMU events ran at 100%; kernel profiling is back at
`perf_event_paranoid=2`, so this pass makes no new kernel-instruction claim.
The failed initial screen caused by perf suffixing software counters with `:u`
is preserved separately; the repeated comparison explicitly requests only
`cycles:u` and `instructions:u`.

[All trial medians and records](runs/response-aggregation-v2.json "Summary of docs/response-aggregation-v2/comparison/summary.json; raw artifact retired"),
[commands and binary provenance](runs/response-aggregation-v2.json "Summary of docs/response-aggregation-v2/comparison/manifest.json; raw artifact retired"),
[audit](runs/response-aggregation-v2.json "Summary of docs/response-aggregation-v2/audit.json; raw artifact retired").

Compiled connection storage is 13,096 bytes in baseline and 13,104 bytes with
aggregation. The optional pointer adds eight bytes per connection; the lazy
batch remains 4,648 bytes, including a 4 KiB byte buffer and 16 completion
records. These changes do not shrink the request footprint. The
[layout records](runs/response-aggregation-v2.json "Summary of docs/response-aggregation-v2/batch-adaptive-layout.json; raw artifact retired") include
static field coverage, which must not be interpreted as measured cache misses.

The coalescing regression test inspects actual prepared SQEs because TCP timing
and autocorking make the flag unreliable to distinguish on the wire. It checks
coalescing across short aggregates and partial sends, the bounded flush, and
flushing with no buffered next request. The exact same test fails against the
original aggregate sender and passes after the fix. The existing wire boundaries
cover fragmented input, interim responses, large bodies, streams, EOF, and a
single active permit; a new retained wire test checks closure after exactly nine
responses in a deeper pipeline. The adaptive prototype passes its full
ReleaseSafe component/declaration and wire suites.
Before-fix failure,
after-fix pass,
full validation.

The runtime changes remain isolated for two concrete API reasons. The prototype
only batches the built-in application with access logging disabled. It reuses
exchange and parser storage before the batch is sent, whereas custom release
hooks and borrowed log fields must remain valid through their documented
completion boundary. It also lazily allocates while serving, which is outside
the public server's current promise that its supplied allocator is unused during
`serve`. General integration therefore needs storage provisioned at initialization
and a bounded representation for deferred application cleanup and logging.
These issues remain even with the improved timing results. The measured fallback
and coalescing behavior are worth carrying into that implementation; the current
prototype is not suitable as a general default.

The [measured source snapshots](runs/response-aggregation-v2.json "Run summaries from docs/response-aggregation-v2/snapshots; raw artifacts retired") preserve the
exact runtime sources and build files. The adaptive patch
applies to the saved baseline and includes the permanent regression test. The
test source and its before/after
hashes are retained separately so the tested change can be reproduced. The
coalescing-only patch isolates the
packet change from the adaptive fallback.

Reproduce the comparison after building the three saved variants:

```sh
python3 bench/aggregation_revisit.py --output /tmp/aggregation-results \
  --variant baseline=/path/to/baseline/zhtps \
  --variant coalescing=/path/to/coalescing/zhtps \
  --variant adaptive=/path/to/adaptive/zhtps --user-perf
```

The harness uses the validated `bench/pipeline/main.go` client at
`/tmp/zhtps-pipeline`, as documented in [the benchmark guide](../bench/README.md).
`--user-perf` omits kernel PMU events when they are unavailable. The transport
semantics follow [send(2)'s MSG_MORE contract](https://man7.org/linux/man-pages/man2/send.2.html).
