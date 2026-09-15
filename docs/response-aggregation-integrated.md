# Response aggregation in the main server

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The built-in application now aggregates small pipelined responses in the main
server. This carries forward the admission gate and bounded `MSG_MORE` behavior
from [the second experiment](response-aggregation-v2.md), while removing its
serve-time allocations and access-log restriction. Custom applications retain
ordinary sends: their cleanup callbacks, scratch storage, and borrowed access
fields remain valid through the existing completion boundary.

## Storage and completion ownership

`Config.response_batches` / `--response-batches` defaults to 64 buffers per worker,
capped at the worker's public connection capacity. Zero disables the pool. A
custom application or an active-request budget below four allocates no pool.
Exhaustion falls back immediately to an ordinary send; it cannot stall a worker
waiting for another connection to release storage.

Each batch owns up to 4,096 serialized bytes and 16 completion records. Compiled
sizes on the supported x86-64 target are:

| Structure | Before | Integrated |
|---|---:|---:|
| Built-in connection | 13,096 B | 13,104 B |
| Completion record | — | 32 B |
| Batch including payload and records | — | 4,648 B |
| Default pool per worker | — | 297,472 B (290.5 KiB) |

The 16 completion records occupy 512 bytes. They store timestamps, request IDs,
response boundaries, status, body byte count, and an owned short method. They
retain neither a parser nor an application exchange. Serialized bytes are copied
once; no allocation occurs while serving. This adds bounded copy/metadata work in
exchange for fewer send operations and completions. The layout is compact, but
these measurements do not establish a cache-hit-rate improvement.
Before layout,
integrated layout,
[layout commands](runs/response-aggregation-integrated.json "Summary of docs/response-aggregation-integrated/layout-commands.json; raw artifact retired").

A new batch requires an active-request budget at least four times the worker's
current live connection count, including admin connections. Existing batches
flush before consuming the admission headroom reserved for other connections.
This retains the ordinary path at the 64-client / 192-permit operating point
that regressed in the original experiment. The gate is a measured heuristic,
not a promise that every workload benefits above that ratio.

Only complete small admitted responses qualify. The worker flushes before waiting
for input and before interim, streaming, large, rejected, or closing responses.
Short batches preserve `MSG_MORE`; aggregation and ordinary sends share the same
16-response coalescing bound. Partial sends retain that flag and the oldest
batch write deadline. A partially parsed next request keeps its own deadline
when execution resumes.

A completion releases a request's admission permit and emits its success metrics
and access log only after all its bytes have completed. First-byte metrics are
recorded once even when a send ends inside a response. A canceled batch returns
to the pool only after both send and cancellation completions have arrived;
remaining response permits then abort once. Graceful shutdown treats a queued
batch as pending output even after its parser has reset for the next request.

The integration review found another ordering case: after admitting the first
request, a rate bucket with no rejection allowance could close the connection
while that first response was still queued. The permanent wire regression fails
with an empty EOF against the pre-fix integration and passes unchanged after
flushing the earlier batch before evaluating the close again.
Failure,
passing result,
[test and binary hashes](runs/response-aggregation-integrated.json "Summary of docs/response-aggregation-integrated/rate-close-regression.json; raw artifact retired").

`/debug/workers` exposes `response_batch_capacity`. Three counters distinguish
initial batch submissions (`response_batches_total`), responses included in those
submissions (`responses_batched_total`), and eligible responses using ordinary
sends because no pool buffer was available (`response_batch_fallbacks_total`).
Submission counters include batches later aborted; completion counters keep their
existing meaning.

## Performance comparison

The final comparison uses the saved NIC-placement baseline and the corrected
integrated binary, both Zig 0.16.0 ReleaseSafe with x86-64-v4. A single worker runs
on CPU 2; the validated Go generator runs on CPUs 4–7, using 64 loopback
connections. Each run uses a separate one-second warmup invocation followed by a
five-second measurement. Three trials rotate variant order for each of six
workloads. The admission budget and configured connection capacity match within
each pair. Access logs are disabled for these transport measurements.

Medians of the three final trials:

| Workload / permits | Baseline responses/s | Integrated responses/s | Throughput change | CPU/response change |
|---|---:|---:|---:|---:|
| Serial / 192 | 534,193 | 534,086 | -0.02% | +0.11% |
| Depth 8 / 192 | 1,357,430 | 1,378,973 | +1.59% | -1.56% |
| Depth 32 / 192 | 1,529,750 | 1,521,943 | -0.51% | +0.51% |
| Depth 8, 8-byte writes / 192 | 542,048 | 540,793 | -0.23% | -0.03% |
| Depth 8 / 1,024 | 1,379,834 | 1,854,079 | +34.37% | -27.78% |
| Depth 32 / 1,024 | 1,517,521 | 2,173,843 | +43.25% | -30.03% |

The larger budget permits full aggregates. The ordinary-budget cases stay within
1.6% of baseline in this pass. Full aggregates reduce both ring submissions and
completions while retaining the same packet formation:

| Depth / permits | Variant | CPU/response | SQEs/response | CQEs/response | TCP OutSegs/response |
|---|---|---:|---:|---:|---:|
| 8 / 1,024 | baseline | 0.636 µs | 1.125 | 1.125 | 0.250 |
| 8 / 1,024 | integrated | 0.460 µs | 0.250 | 0.250 | 0.250 |
| 32 / 1,024 | baseline | 0.593 µs | 1.031 | 1.031 | 0.125 |
| 32 / 1,024 | integrated | 0.415 µs | 0.094 | 0.094 | 0.125 |

The final 36 trials validate 223,014,085 responses, with zero transport/HTTP
failures, server rejections, aborts, protocol errors, timeouts, or I/O errors.
Every run accepts and closes exactly 64 measured client connections, exits
cleanly, and ends with no public request or rejection permits held. The default
64-buffer pool has no observed exhaustion in these trials.

CPU and operation ratios use server completion deltas spanning measured-client
connection setup and drain, while throughput uses the client's measured window.
TCP OutSegs is a whole-host diagnostic including requests, responses, ACKs, and
background traffic. It is not a count of server response packets alone. Profiling
permission is currently `perf_event_paranoid=2`, so this pass records userspace
PMU events only and makes no new kernel instruction or cache-miss claim.

These are closed-loop, one-worker, loopback results. Pipeline tail latency,
physical-NIC aggregation, multiple workers, and access-log throughput were not
measured in this pass. Functional tests do exercise access logging and custom
application lifetimes. The earlier NIC-placement results remain a separate
experiment.

[Final raw trials and summary](runs/response-aggregation-integrated.json "Summary of docs/response-aggregation-integrated/pipeline/summary.json; raw artifact retired"),
[commands and binary hashes](runs/response-aggregation-integrated.json "Summary of docs/response-aggregation-integrated/pipeline/manifest.json; raw artifact retired").
The first integration screen is preserved in
[pipeline-before-rate-fix](runs/response-aggregation-integrated.json "Summary of docs/response-aggregation-integrated/pipeline-before-rate-fix/summary.json; raw artifact retired")
and is excluded from the final comparison; a short regression reproduction
ran during that screen. Source snapshots
preserve the baseline, pre-fix integration, and final integration separately.

## Validation and reproduction

Both Debug and ReleaseSafe pass 87 component tests, 18 compile-failure declaration
checks, the separate embedded-library consumer, 58 existing wire tests, five
previous pipeline boundary tests, five new aggregation wire tests, three worker
placement tests, and five NIC topology tests.
Debug,
ReleaseSafe.

New coverage includes owned log metadata across parser/body-buffer reuse,
streaming completion accounting, pool disablement, concurrent reuse of a
one-buffer pool, and rate-limit closure after an admitted response. Lower-level
checks exercise partial sends, exact first-byte/log/completion accounting,
pool exhaustion, the oldest write deadline, and both cancellation-completion
orders. The earlier `MSG_MORE` regression is now in the main worker tests; its
only structural adaptation replaces the prototype's nested batch type with the
new module. The embedded consumer checks that all post-initialization allocations
can fail while aggregation still works, every pool initialization allocation
failure unwinds, and custom cleanup cannot poison transmitted bodies or logs.

```sh
zig build test test-library test-wire -Doptimize=Debug
zig build test test-library test-wire -Doptimize=ReleaseSafe
python3 bench/aggregation_revisit.py --output /tmp/aggregation-integration \
  --variant baseline=/path/to/baseline/zhtps \
  --variant integrated=/path/to/integrated/zhtps --user-perf
```

The benchmark requires the validated `bench/pipeline/main.go` client at
`/tmp/zhtps-pipeline`; see [the benchmark guide](../bench/README.md). No NIC queue,
IRQ, offload, or sysctl settings were changed.
