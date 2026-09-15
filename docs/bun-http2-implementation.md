# Three Bun-inspired HTTP/2 candidates

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

This follow-up implements the first three candidates from the
[Bun source review](bun-http2-review.md) **one at a time**, measuring each against
the preceding retained implementation. Multi-worker performance takes priority.
**Direct response headers and smaller stream storage are retained.** Allocation
pooling was rejected and reverted. The three stages include 192 throughput trials
and 24 fixed-population memory trials, with all failure records retained.

| Candidate | Decision | Evidence |
|---|---|---|
| 1. Bounded worker-local allocation pools | **Rejected and reverted** | 60 paired-trial runs: throughput changes −1.1% to +1.7%, CPU/request reductions 0.2% to 2.3%, RSS increased 0.8% to 3.1% |
| 2. Direct HTTP/2 response headers | **Retained** | 66 trials: two/four-worker loopback throughput +5.2% to +7.0%, multi-worker CPU/request −5.1% to −7.9%, memory unchanged |
| 3. Lazy stream storage | **Retained for memory/capacity** | Multi-worker RSS with 256 live uploads −26.8% to −33.6%; charged HTTP/2 memory −43.5%; timing provisional during reported CPU noise |

## Measurement and acceptance

The baseline is the working tree captured before these experiments, including
the existing HTTP/2 implementation. Both baseline and candidate executables use
Zig 0.16.0, ReleaseSafe and `x86_64_v4`; binary hashes and source snapshots are
retained. Each workload alternates baseline/candidate order between repetitions.
The loopback client uses physical cores separate from the server. Remote clients
run on `client.example`; SSH carries control and evidence, and requests use
the wired LAN directly.

The request remains TLS 1.3 `GET /`, with the complete six-byte `ZHTPS\n` response
verified, four streams per connection, two seconds of warmup and a two-second
request timeout. Rates include draining outstanding requests. Every failed
operation is retained by phase, including setup, holding, warmup and measurement.
The new runner also captures server memory after connection setup and after
measurement, server CPU per successful request, and client CPU use.

A working threshold is a repeatable improvement of roughly 5% in throughput or
CPU/request, or 10% in memory, while inspecting all other dimensions for material
regressions. This is a guide for judging the distributions, not an automatic
keep rule. A single favorable trial, a reduced connection population, or
unconfirmed changes in NIC-related timeouts do not establish an improvement.

The existing 8,176-connection limit per worker is unchanged. The runner explicitly
records workloads exceeding that limit as skipped, rather than timing known
setup failures again. The pool's remote trials all use eight workers and reach
all four requested populations: 64, 1,024, 8,192 and 16,384.

Baseline source,
[baseline build identity](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/baseline-build.json; raw artifact retired"),
[paired runner](../bench/compare_http2_variants.py),
[client supervisor](../bench/http2_remote.py),
[failure auditor](../bench/audit_http2_lan.py),
[summarizer](../bench/summarize_http2_variants.py).

## Candidate 1: worker-local allocation pools

The prototype put allocations of up to 4 KiB and alignment up to 16 bytes into
nine worker-owned size classes. Slabs grew lazily to at most 64 KiB, with smaller
slabs near the budget limit. Slab refills, returns, and larger/aligned allocations
used the existing shared allocator mutex. Freed slots were reused without that
lock. Each class retained at most one fully empty slab, evicted under budget
pressure; every backing byte, including cached capacity, remained charged.
Outstanding executor/transport borrowers retained their existing lifetimes.

Focused tests covered nonoverlapping live allocations, reuse with further backing
allocations disabled, alignment, budget exhaustion, cached-slab eviction, surplus
slab release and recovery after allocation failure. ReleaseSafe validation passed
110 Zig tests and 28 HTTP/2 wire tests. This established correctness of the
prototype; it did not establish a performance benefit.

There were 36 loopback runs, covering two/four/eight workers at 64 and 1,024
connections, and 24 remote runs covering eight workers at all four populations.
Each baseline/candidate workload has three repetitions. Loopback measurements
used five-second issuing windows; remote measurements used eight seconds.
All loopback requests succeeded. All trials reached their requested connection
population, and no server exited unexpectedly.

| Location | Workers | Connections | Throughput change | CPU/request change | RSS change | Failed operations: baseline → pool |
|---|---:|---:|---:|---:|---:|---:|
| Loopback | 2 | 64 | +1.3% | −2.0% | +1.4% | 0 → 0 |
| Loopback | 2 | 1,024 | +0.1% | −0.2% | +3.1% | 0 → 0 |
| Loopback | 4 | 64 | +1.3% | −0.8% | +1.1% | 0 → 0 |
| Loopback | 4 | 1,024 | +1.4% | −1.5% | +3.0% | 0 → 0 |
| Loopback | 8 | 64 | −0.1% | −2.3% | +1.0% | 0 → 0 |
| Loopback | 8 | 1,024 | +0.0% | −1.7% | +2.9% | 0 → 0 |
| Remote | 8 | 64 | +1.7% | −0.7% | +0.8% | 0 → 0 |
| Remote | 8 | 1,024 | −1.1% | −1.0% | +2.7% | 72 → 16 |
| Remote | 8 | 8,192 | +1.0% | −0.9% | +3.0% | 2,580 → 2,407 |
| Remote | 8 | 16,384 | +0.9% | −1.9% | +3.1% | 26,822 → 25,984 |

Changes compare workload medians. Failure counts total all phases across the
three runs; phase-specific counts, raw ranges and paired percentage changes
are included in the summary. At 16,384 connections, the pool's median RSS was
about 2,599 MiB versus 2,522 MiB. Remote failures varied between repetitions;
some pool trials had more failures than their paired baseline. The earlier
[NIC-loss diagnosis](http2-diagnosis.md) remains relevant. These results do not
establish that pooling fixes those failures.

**Decision: reject.** The CPU reduction is small, throughput is essentially
unchanged, and retained memory grows. That does not justify the allocator's
added code and lifetime/accounting obligations. Both changed production files
were restored, and every captured baseline source/test hash matched afterward.
The next candidate therefore compares against the original baseline.

[Summary JSON and per-phase failures](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/pool-summary.json; raw artifact retired"),
[summary CSV](bun-http2-implementation/pool-summary.csv),
all 60 trials and individual failures,
prototype patch,
prototype source,
[build identity](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/pool-build.json; raw artifact retired"),
correctness output.

## Candidate 2: direct HTTP/2 response headers

The old path serialized an HTTP/1 response head into a 32 KiB buffer and parsed
it back into fields for nghttp2. The retained path validates response metadata
through the same `Response.framing` contract as HTTP/1, then submits fields
directly. Only uppercase field names need copying and lowercasing. nghttp2 still
copies the submitted fields, so application and executor ownership is unchanged.

The 63-field limit and exact former 32 KiB serialized-head budget are preserved,
including generated fields, whitespace and filtered connection fields. Wire
tests verify duplicate cookie order, trimming, case conversion, invalid and
reserved headers, and both limit boundaries. The same compatibility tests pass
against the original implementation. Final validation passed 107 Zig tests,
30 HTTP/2 tests, 32 TLS tests and the HTTP/1 application/streaming suites. The
initial fixture build error in the saved test log was corrected before timing;
the separate final wire log records the passing run.

There were 42 loopback runs at one/two/four/eight workers and 64 connections,
plus two/four/eight workers and 1,024 connections. The 24 remote runs used eight
workers at all four populations. Each comparison has three repetitions, with
six-second loopback and eight-second remote issuing windows. Every trial reached
its requested population, every loopback request succeeded, and no server exited
unexpectedly.

| Location | Workers | Connections | Throughput change | CPU/request change | RSS change | Failed operations: baseline → headers |
|---|---:|---:|---:|---:|---:|---:|
| Loopback | 1 | 64 | +6.2% | -7.7% | -0.0% | 0 → 0 |
| Loopback | 2 | 64 | +7.0% | -7.9% | +0.2% | 0 → 0 |
| Loopback | 2 | 1,024 | +5.8% | -6.7% | +0.1% | 0 → 0 |
| Loopback | 4 | 64 | +5.7% | -6.3% | +0.1% | 0 → 0 |
| Loopback | 4 | 1,024 | +5.2% | -6.1% | +0.2% | 0 → 0 |
| Loopback | 8 | 64 | +1.1% | -5.1% | -0.2% | 0 → 0 |
| Loopback | 8 | 1,024 | +0.2% | -5.2% | -0.1% | 0 → 0 |
| Remote | 8 | 64 | +0.4% | -4.2% | +0.1% | 0 → 0 |
| Remote | 8 | 1,024 | +0.3% | -5.0% | -0.1% | 56 → 40 |
| Remote | 8 | 8,192 | -1.9% | -3.8% | +0.1% | 1,206 → 1,283 |
| Remote | 8 | 16,384 | -1.1% | -1.6% | +0.1% | 15,639 → 14,235 |

These are changes in workload medians; failed operations total all phases across
three runs. The JSON includes paired changes and ranges, including a slower
candidate repetition at two workers and 1,024 connections. The repeatable
four-worker improvement and the CPU reduction across multi-worker workloads
support retaining the change. At eight workers the loopback client becomes a
throughput constraint, while CPU/request still improves around 5%. Remote
throughput changes from −1.9% to +0.4%, with no material memory or latency
regression; its variable failures do not establish a network failure fix.

**Decision: retain.** The two/four-worker throughput improvement and lower
multi-worker CPU cost clear the acceptance guide without increasing memory.
This executable is the baseline for candidate 3.

[Summary JSON and per-phase failures](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/headers-summary.json; raw artifact retired"),
[summary CSV](bun-http2-implementation/headers-summary.csv),
all 66 trials and individual failures,
patch,
source snapshot,
[build identity](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/headers-build.json; raw artifact retired"),
initial test output,
final wire validation,
compatibility tests against the original.

## Candidate 3: smaller stream storage with bounded growth

This candidate keeps 1 KiB of request-head bytes, 256 bytes each of path and
response-name scratch, and 16 field references inline. Larger request metadata
and field arrays grow within the existing limits before application dispatch.
Trailer bytes and references have separate allocations, so a body consumer can
retain a request-header borrow while trailers arrive. Growth rebases existing
field and pseudo-header slices before they are exposed to application code.

The full configured application buffer is allocated before exchange initialization;
its API and lifetime are unchanged. The full response buffer is allocated when a
streaming response needs it. Upload storage keeps the existing 65,535-byte bound.
The same 64-entry worker cache retains owned allocations, all still charged to the
worker budget. TLS retry, io_uring and connection buffers are unchanged.

A permanent real-TLS regression opens six concurrent uploads under a 1 MiB worker
HTTP/2 budget, supplies each body and checks every response plus a neighboring
request. It fails against the retained header implementation with a TLS EOF
while opening streams and passes unchanged with this candidate. Wire tests also
exercise long paths, large/split cookies, header arrays, uppercase response-name
growth, and growing trailers while a blocked consumer retains a header borrow.
Allocation-failure injection checks metadata growth and cleanup through complete
protocol exchanges.

### Fixed-population memory measurements

The separate capacity probe holds 64 connections with four `POST /echo` streams
each, at one/two/four/eight workers, using three alternating-order repetitions.
It samples the admin allocation gauge and process RSS at four phases: connected,
heads pending, partial bodies consumed, and all responses completed. Each of the
24 trials completes and verifies all 256 one-byte uploads: **6,144 successes,
zero failed uploads, zero unexpected server exits**. This measures a fixed live
population and makes no throughput claim.

Before body data, charged HTTP/2 memory is **51.79 → 22.29 MiB (−57.0%)**.
With body buffers allocated it is **67.79 → 38.29 MiB (−43.5%)**. Those values
are identical at all worker counts. The connection-only charge is unchanged.
They include connection/protocol allocations; they are distinct from RSS and
exclude OpenSSL and kernel socket allocations.

| Workers | RSS with heads pending | RSS with body data | RSS after completion | Charged memory after completion |
|---:|---:|---:|---:|---:|
| 1 | -43.2% | -35.2% | +6.1% | -34.8% |
| 2 | -40.8% | -33.6% | -11.7% | -40.2% |
| 4 | -37.0% | -31.0% | -28.5% | -43.2% |
| 8 | -31.2% | -26.8% | -26.8% | -43.5% |

The one-worker post-burst tradeoff is explicit: median RSS is **52.98 → 56.19 MiB
(+6.1%)**, despite a smaller charged cache. The allocation gauge does not include pages retained by the backing allocator;
we have not attributed all of the post-burst RSS difference to one allocator path. Two/four/eight-worker
post-burst RSS improves, and all worker counts improve while uploads are live.
At four workers, connection distribution can leave different numbers of entries
in each bounded cache; the raw gauges and ranges are retained.

The first probe setup was rejected with `InvalidLimit` because its active-request
limit exceeded its configured connection limit. Correcting that harness option
produced the 24 complete trials above; the rejected setup is retained separately
and is not counted as a failed HTTP request or a measurement.

[Memory summary and ranges](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/storage-capacity-summary.json; raw artifact retired"),
[CSV](bun-http2-implementation/storage-capacity-summary.csv),
[all raw admin/process snapshots](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/storage-capacity-results.json; raw artifact retired"),
[rejected probe setup](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/storage-capacity-setup-error.json; raw artifact retired"),
[capacity probe](../bench/measure_http2_storage.py),
[independent capacity audit/summarizer](../bench/summarize_http2_storage.py),
regression before,
unchanged regression after,
wire and executor validation,
allocation-failure validation.

### Throughput and high-connection checks

The user reported approximately 30 minutes of CPU noise on the server at
22:22 UTC on September 14. Storage timing in this interval is **provisional**:
paired runs and CPU/request values remain useful regression screens, but small
changes cannot establish a speedup. The fixed-population memory comparison above
is the candidate's substantive improvement. All four remote connection counts
were checked before the retain decision.

There were 42 loopback and 24 remote timing trials, matching the header stage's
worker counts, populations and durations. Every trial reached its requested
population. All local requests succeeded, and no server exited unexpectedly.

| Location | Workers | Connections | Throughput change | CPU/request change | RSS change | Failed operations: headers → storage |
|---|---:|---:|---:|---:|---:|---:|
| Loopback | 1 | 64 | -1.9% | +1.0% | -0.3% | 0 → 0 |
| Loopback | 2 | 64 | -1.2% | +1.3% | -0.6% | 0 → 0 |
| Loopback | 2 | 1,024 | +1.4% | -1.3% | -0.1% | 0 → 0 |
| Loopback | 4 | 64 | -1.2% | +1.4% | -1.0% | 0 → 0 |
| Loopback | 4 | 1,024 | +0.3% | -0.4% | -0.3% | 0 → 0 |
| Loopback | 8 | 64 | +0.0% | +0.7% | -1.1% | 0 → 0 |
| Loopback | 8 | 1,024 | -2.5% | +2.3% | -0.5% | 0 → 0 |
| Remote | 8 | 64 | +0.2% | +0.3% | -1.3% | 0 → 0 |
| Remote | 8 | 1,024 | +0.5% | +1.3% | -0.5% | 76 → 60 |
| Remote | 8 | 8,192 | -0.4% | +3.1% | -0.1% | 1,398 → 1,246 |
| Remote | 8 | 16,384 | -0.4% | +2.7% | +0.0% | 11,962 → 13,575 |

Changes compare workload medians; failures total all phases over three runs.
All recorded remote failures in this stage are timeouts. Counts fluctuate in
both directions across paired trials, and the prior NIC-loss diagnosis remains
relevant. These measurements do not establish a failure fix.

At 16,384 connections, all three storage trials had more timeouts: measured
failures were **10,761 / 5,986,908 attempts (0.180%) → 12,351 / 5,965,529
(0.207%)**, a 0.027 percentage-point increase. This is an unresolved limitation
of the noisy comparison, not evidence that storage improves failure behavior.
The six-byte GET workload shows little RSS benefit; the upload probe deliberately measures the
live-stream storage that this candidate changes.

**Decision: retain for memory and capacity.** The repeatable multi-worker memory
reduction clears the acceptance guide, the small-budget regression now completes,
and throughput/latency differences are small. The higher 16k timeout rate and
one-worker post-burst RSS are the observed tradeoffs; neither erases the large
live-upload memory benefit, but neither is claimed resolved. Timing within the
reported CPU-noise window stays provisional: this decision does not
claim a storage-related throughput gain. The one-worker post-burst RSS increase
is retained in the report rather than hidden by the live-upload result. The
stages are separate comparisons; their percentage changes are not multiplied
and presented as a measured cumulative speedup.

[Timing summary and per-phase failures](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/storage-summary.json; raw artifact retired"),
[CSV](bun-http2-implementation/storage-summary.csv),
all 66 timing trials and individual failures,
patch against retained headers,
source snapshot,
[build identity](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation/storage-build.json; raw artifact retired"),
final validation,
[complete experiment artifacts](runs/bun-http2-implementation.json "Summary of docs/bun-http2-implementation; raw artifact retired").
