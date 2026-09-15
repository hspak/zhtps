# Request footprint and cache experiments — 2026-09-12

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The retained change spreads connection buffers across cache sets. On this machine,
the small-GET comparison improved from **499k to 526k requests/s**, with **7.8% less
server CPU per response**. At equal offered rates, CPU fell **4.4% at 100k/s** and
**1.5% at 300k/s**. This adds **448 bytes per configured connection slot** and changes
only buffer allocation and placement during worker initialization.

The much larger parser/connection restructuring experiments are parked. They
reduced reported cache misses, but the high-connection throughput results did not
justify their complexity. **The retained change does not resolve the slowdown at
high connection counts.**

The baseline is commit `5e96c109e72853f157ae5be946d7b7bbcb5e7107`, with the exact
[source hashes](runs/request-footprint.json "Summary of docs/request-footprint/baseline-source.json; raw artifact retired") saved before the experiment.
It is the source used for the [Go benchmark rerun](go-comparison-current.md).
The retained working source exactly matches the measured `spread` variant:
[source hashes](runs/request-footprint.json "Summary of docs/request-footprint/retained-sources.json; raw artifact retired"),
patch,
[implementation](../src/server/worker.zig).

## What occupies memory, and what a request actually touches

Compiled ReleaseSafe layouts on x86-64-v4:

| Variant | Connection record | Separate storage per slot | Total allocation change per slot versus baseline |
|---|---:|---:|---:|
| Baseline | 13,096 B | — | — |
| `scratch`: borrow parser scratch arrays | 832 B | 12,288 B scratch | +24 B |
| `narrow`: scratch split plus bounded integers | 792 B | 12,288 B scratch | −22 B, including the smaller active-slot entry |
| `buffers`: scratch split plus nearby small buffers | 840 B | 12,288 B scratch + 2,112 B buffer object | +2,144 B |
| `spread`: retained buffer placement | 13,096 B | — | +448 B padding |

The model uses compiled offsets: declaration order would give the wrong layout
for these normal Zig structs. Narrowing is limited to bounded worker fields:
16-bit slot indices, 32-bit configured-buffer positions, and an 8-bit outstanding
operation count. Public request slices and arbitrary application response lengths
retain their existing representation.

Every variant retains the configured large buffers and protocol limits. At the
defaults, those buffers already total **160 KiB per slot**. A smaller Connection
record is therefore not the same thing as substantially less allocated memory.
For 32,776 slots, narrowing saves only about 704 KiB overall, despite reducing the
Connection array from 409.4 MiB to 24.8 MiB; the scratch array still occupies
384.1 MiB. The retained padding costs about 14 MiB at that capacity, roughly 0.25%
of the original Connection, active-slot, and buffer allocation.

The baseline Parser is 12,608 B. Its two 128-entry header tables occupy 4 KiB each,
and its chunk-line buffer occupies another 4 KiB. A Header is 32 B: two borrowed
slices. Request is 152 B, Response 48 B, and the default application Exchange 128 B.
The tiny GET used here has one Host field, no trailers, and no chunk framing.
Moving all 12 KiB out of line changes the record stride dramatically, but a normal
GET did not read those entire arrays in the first place.

The reset disassembly also shows that
ReleaseSafe reset skips the large undefined arrays; it does not copy or clear
12 KiB on every request. The selected request/parser fields in the
static access model cover an average of
12.75 cache lines in the baseline, 12.375 with separate scratch, and 10 with the
narrowed fields, across all eight possible 8-byte-aligned positions in a 64-byte
line. This is field coverage, **not a dynamic load trace**. It excludes external
buffers and the separately stored header entry in the borrowed variants.

Compiled layouts and offsets:
[baseline](runs/request-footprint.json "Summary of docs/request-footprint/baseline-layout.json; raw artifact retired"),
[scratch](runs/request-footprint.json "Summary of docs/request-footprint/scratch-layout.json; raw artifact retired"),
[narrow](runs/request-footprint.json "Summary of docs/request-footprint/narrow-layout.json; raw artifact retired"),
[small buffers](runs/request-footprint.json "Summary of docs/request-footprint/buffers-layout.json; raw artifact retired"),
[retained placement](runs/request-footprint.json "Summary of docs/request-footprint/spread-layout.json; raw artifact retired").

## Controlled comparisons

All cases use ReleaseSafe, x86-64-v4, Zig 0.16.0, and the same validated Go client.
The machine is a Ryzen AI Max+ 395 with 16 physical cores and 32 logical CPUs.
The server and generator use separate physical cores; each worker is explicitly
pinned after startup. Access logging is disabled, while parsing, admission,
metrics, and response validation remain enabled. Connection turnover is disabled
for the measurement, and every requested client must participate successfully.

| Case | Clients | Server CPUs / workers | Client CPUs | Public capacity per worker |
|---|---:|---|---|---:|
| Small | 64 | CPU 2 / 1 | 4–7 | 256 |
| Many | 4,096 | CPU 2 / 1 | 4–7 | 8,168 |
| Multicore | 16,384 | CPUs 0–7 / 8, one worker per CPU | 8–15 | 4,096 |

There are three rotated-order trials per variant and case, with two seconds of
warmup and five measured seconds. Values below are medians of trial values;
quantiles are not pooled. The multicore setup differs from the earlier Go rerun's
16 unrestricted workers and shared generator CPUs, so compare variants within
these blocks, not their absolute throughput against that report.

`perf stat` records `cycles:u`, `instructions:u`, `cache-misses:u`, and
`L1-dcache-load-misses:u` for server threads. All measured events ran 100% of their
enabled time. These counters cover **user space only**, including connection
setup, warmup, and drain. Counts and process CPU are normalized by the server's
completed-request delta over that broader interval. Goodput counts validated
responses completed inside the measurement window. Those are distinct cohorts.

The generic `cache-misses` event is reported by its perf name; it is not presented
as a measured L3 or TLB miss count. The attempted dTLB event did not count on this
machine, so these experiments do not establish a TLB-miss reduction. Kernel CPU
comes from process accounting, not the user-space PMU events, and does not include
all host softirq work.

The [audit](runs/request-footprint.json "Summary of docs/request-footprint/closed-loop-audit.json; raw artifact retired") covers **72 closed-loop trials
and 180,844,981 validated window completions**, with zero client errors,
reconnections, server rejections, aborts, protocol errors, I/O errors, or timeouts.
No builds or other test loads ran alongside the measured workloads.
[Environment](runs/request-footprint.json "Summary of docs/request-footprint/environment.json; raw artifact retired"),
[runner](../bench/compare_footprint.py).

## Smaller records: better counters, limited throughput benefit

These changes are relative to the matching baseline in the
[four-way comparison](runs/request-footprint.json "Summary of docs/request-footprint/variants-screen/summary.json; raw artifact retired"):

| Variant | Goodput, 64 clients | Goodput, 4,096 clients | Goodput, 16,384 clients | Generic cache misses/response, 16,384 clients |
|---|---:|---:|---:|---:|
| Baseline | 516,581/s | 193,799/s | 804,634/s | 32.94 |
| Separate scratch | −2.91% | +0.87% | +1.09% | 26.80 |
| Scratch + narrower integers | −1.28% | +2.30% | +0.15% | 26.88 |
| Scratch + nearby small buffers | +0.98% | +2.44% | +0.76% | 29.99 |

The initial independent [scratch comparison](runs/request-footprint.json "Summary of docs/request-footprint/scratch-screen/summary.json; raw artifact retired")
had essentially identical multicore throughput: 787,311 versus 787,115/s. Its
generic cache-miss count fell about 18%, consistent with the second block. Baseline
throughput moved between blocks; the evidence supports better cache counters,
not a repeatable large throughput improvement from this restructuring.

At 16,384 clients, the four-way baseline used about **5.34 µs CPU/response**, with
about **4.37 µs in the kernel**. Around 82% of measured process CPU was therefore
outside the user-space work these structural changes primarily target. Together
with the small change in actual fields touched, this explains why reducing the
record from 13 KiB to under 1 KiB did not transform throughput. It is not a complete
kernel profile or proof that caches no longer matter.

The small-buffer prototype uses four nearby 512-byte buffers and falls back to
full storage for larger traffic. It adds request-path selection and promotion
logic. Besides its small measured benefit, it twice failed the full wire suite's
slow-reader timeout test. The unchanged test passed three isolated repetitions
on both baseline and prototype, and a subsequent full diagnostic run passed.
The suite interaction remains unexplained. This prototype is **not retained**;
the failures are preserved in the first log
and the repeat, alongside
diagnostics.

## Retained change: buffer placement

The default buffer capacities place head, trailers, normalized path, receive,
output, and application storage at offsets that are all multiples of 4 KiB.
The slot stride is 160 KiB. On this machine's 64-set, 64-byte-line L1 data cache,
those starts have the same low-address set index, both within and between slots.
The cache has 12 ways; repeatedly mapping unrelated active buffers to a small
set of indices is an avoidable placement risk.

The change adds five 64-byte gaps between the six buffers and two trailing cache
lines. The resulting default slot stride is **160 KiB + 448 B**, an odd number of
cache lines. Buffer starts within a slot occupy different nominal sets, and
successive slots traverse all 64 sets. Capacities remain exact, including the
application buffer; padding is not exposed as usable application storage.
There are no new request-time branches, copies, or allocations.
[Placement arithmetic and cache geometry](runs/request-footprint.json "Summary of docs/request-footprint/buffer-placement.json; raw artifact retired").

This address model motivated the experiment. The following measurements establish
its workload effect, without claiming that the model alone identifies every
hardware cause:

| Clients | Baseline → retained goodput | Change | Baseline → retained CPU/response | Baseline → retained p99 |
|---|---:|---:|---:|---:|
| 64 | 499,026 → 526,225/s | +5.45% | 1.316 → 1.213 µs | 160 → 187 µs |
| 4,096 | 193,997 → 193,106/s | −0.46% | 3.527 → 3.506 µs | 22.41 → 23.07 ms |
| 16,384, eight workers | 804,851 → 811,690/s | +0.85% | 5.360 → 5.321 µs | 26.74 → 26.61 ms |

[Raw comparison](runs/request-footprint.json "Summary of docs/request-footprint/spread-screen/summary.json; raw artifact retired"). At 64 clients,
generic cache misses fell from 10.10 to 1.92 per response, user cycles from about
2,503 to 2,023, and L1 data-load misses from 48.62 to 47.37. Instructions were
essentially unchanged. The different counter movements are a reason to avoid
equating the generic cache-miss reduction with an L1 miss reduction.

The closed-loop p99 increase at 64 clients is real in this block. A separate
three-trial comparison at **equal offered rates** checked that tradeoff:

| Offered rate | Baseline → retained CPU/response | CPU change | Baseline → retained service p99 |
|---|---:|---:|---:|
| 100k/s | 1.500 → 1.433 µs | −4.4% | 127.5 → 122.4 µs |
| 300k/s | 1.523 → 1.500 µs | −1.5% | 131.1 → 126.5 µs |

[Fixed-rate trials](runs/request-footprint.json "Summary of docs/request-footprint/spread-offered-small/summary.json; raw artifact retired"). Every
sent response validated. Intended-offer p99 was essentially unchanged at these
rates: roughly 1.155 ms and 1.057 ms respectively, including generator scheduling
delay. This is a small local CPU improvement, not a universal latency claim.

One baseline/retained pair each also checked longer headers, 64 KiB echo, and
chunked streaming. All responses validated with no HTTP or transport failures.
At their highest offered rates, CPU/response was 2.550 → 2.467 µs for headers,
7.168 → 7.002 µs for echo, and 3.101 → 3.000 µs for streaming. These short pairs
are compatibility checks, not evidence of precise speedups. Low-rate CPU samples
are especially coarse: the 2k/s echo warmup reported 5 → 10 µs, while the later
10k/s phase was essentially equal. Do not interpret that short warmup as a measured
doubling of steady-state echo cost.
[Headers](runs/request-footprint.json "Summary of docs/request-footprint/spread-offered-headers/summary.json; raw artifact retired"),
[echo](runs/request-footprint.json "Summary of docs/request-footprint/spread-offered-echo/summary.json; raw artifact retired"),
[stream](runs/request-footprint.json "Summary of docs/request-footprint/spread-offered-stream/summary.json; raw artifact retired").

Pipelining was repeated three times in alternating order after the first pair
looked slower. At depth 8, median goodput was 1.362M → 1.355M/s (−0.53%), and at
depth 32 it was 1.501M → 1.490M/s (−0.72%). Individual paired results changed sign,
and the ranges overlap; a consistent regression was not demonstrated. These
checks validated another 85,741,248 responses with zero client failures.
[Pipeline summary and raw trials](runs/request-footprint.json "Summary of docs/request-footprint/pipeline-summary.json; raw artifact retired").

## Correctness and reproduction

The retained source passed **79 component tests, 18 compile-time endpoint
declaration checks, 58 raw TCP tests, and four additional storage-boundary tests
in each of ReleaseSafe and Debug**. The separate embedded consumer also passed
in ReleaseSafe. Formatting, diff whitespace, report links, archive restoration,
and equality of retained and measured source hashes were checked.
ReleaseSafe components,
Debug components,
ReleaseSafe wire,
Debug wire,
[wire commands and exits](runs/request-footprint.json "Summary of docs/request-footprint/retained-wire-checks.json; raw artifact retired"),
embedded consumer.

The borrowed-parser experiments preserved the existing assertions and required
only structural test changes: moving parser tests into a namespace, narrowing
synthetic slot arrays, and supplying backing storage to a synthetic connection.
Their component suite reports 80 rather than 79 tests because of one additional
test-collection block. No behavioral test was weakened to accept an optimization.

Four additional wire checks cover head and body sizes around 512 B, long targets,
large trailers and chunk extensions, pipelining, and connection reuse. Both
baseline and the small-buffer prototype passed them. An embedded application
test verifies large response headers and a response body borrowed from request
header storage. These are contract-preservation checks, not regression claims.
Boundary checks,
borrowed-storage application.

All four variants are archived as patches against a small source archive,
including the pinned local dependency. The restoration tool verifies archive
hashes and checks every restored source against the hashes of the measured build:

```sh
python3 docs/request-footprint/reproduce.py /tmp/zhtps-footprint-replay-new
python3 bench/build_request_variants.py baseline scratch narrow buffers spread \
  --workspace /tmp/zhtps-footprint-replay-new \
  --records /tmp/zhtps-footprint-replay-new/records \
  --global-cache-dir /tmp/zhtps-zig-global-cache
python3 bench/compare_footprint.py baseline spread \
  --workspace /tmp/zhtps-footprint-replay-new \
  --records /tmp/zhtps-footprint-replay-new/records \
  --cases small many multicore --repeats 3 --duration 5 --warmup 2 \
  --output /tmp/zhtps-footprint-replay-new/results
```

The runner expects the validated load binary at `zig-out/bench/load`, Linux perf
permissions for user-space events, and the CPU topology above. Adjust its explicit
case definitions for another machine. Build before measuring and keep other CPU
loads out of the measurement interval. Fresh absolute paths can change executable
hashes through debug metadata; each new build records its own provenance.

Restoration was exercised successfully, and the original transformation script
also recreated byte-identical sources for all four measured variants after
`zig fmt`: restoration,
[generator verification](runs/request-footprint.json "Summary of docs/request-footprint/generator-check.json; raw artifact retired").
