# SIMD and admission performance

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The current x86-64-v4 baseline adds a 64-byte AVX-512 header scan ahead of the
existing 16-byte path and validates long field values 64 bytes at a time, with a
32-byte tail path. Short lines retain the narrower scans. The measurements below
predate that baseline bump and remain as evidence for the earlier admission and
16-byte parser changes; they should not be read as v4-versus-v3 results. The v3
reproduction commands are retained only to document those archived runs; use the
default target or `-Dcpu=x86_64_v4` with the current tree.

Measured on 2026-09-11 with Zig 0.16.0, ReleaseSafe, `-Dcpu=x86_64_v3`,
on an AMD Ryzen AI MAX+ 395. These are local shared-host measurements,
not a capacity claim for other hardware or applications.

## Changes

Admission skips refill arithmetic when a bucket is already full. For elapsed
intervals up to one second, both multiplication inputs fit 32 bits and the
result plus the existing balance fits 64 bits. Longer intervals retain the
original saturating arithmetic. This preserves fractional tokens, full bursts,
zero rates, clock regressions, and overflow behavior without approximating time.
Both buckets still refill on every `acquire`; permits and rejection policy are
unchanged.

The incremental parser compares 16 header bytes at a time with CR and LF, extracts
a bit mask, and counts trailing zeroes to find the first line ending. The emitted
x86-64-v3 code uses `vpcmpeqb`, `vpor`, `vpmovmskb`, and `tzcnt`. The bounded copy
stops before line endings, leaving existing framing checks to handle them.
Request-line parsing and target limits retain their scalar path. Every vector
load and copy fits both the available input and remaining header storage.
The 16-byte width also works with short HTTP header lines; AVX2 availability
does not require filling a 32-byte register for each scan.

A baseline profile under rate-limited load attributed 24.4% of sampled server
userspace cycles to `processInput`, which includes incremental parsing,
and 18.7% to the vDSO clock. Admission is inlined into `processInput`;
the profile does not independently quantify its share. This motivated measuring
the refill separately and optimizing the parser before admission.

Two experiments were discarded: vectorizing both 64-bit token buckets was
slower than scalar arithmetic, and vectorized histogram classification improved
mixed durations but regressed a fixed 100-microsecond case. Metrics production
code is unchanged.

## Component measurements

See [raw runs and summaries](runs/simd.json "Summary of docs/simd/components.json; raw artifact retired"). Each of five alternating
before/after trials pins the benchmark to CPU 2, runs 100 million admission
cycles and histogram observations per case, and parses five million requests
per parser case. Admission times include acquisition, immediate permit release,
decision accounting, and a compiler barrier. Setup, printing, and reading the
clock are outside the timed loops. Histograms serve as unchanged controls.
Function and storage alignment is fixed to reduce code-layout noise.

| Workload | Before ns/op | After ns/op | Change |
|---|---:|---:|---:|
| Admission, rate limit disabled | 1.595 | 1.197 | -25.0% |
| Admission, allowed at 250k/s | 1.772 | 1.461 | -17.5% |
| Admission, 1M/s offered against 250k/s | 1.631 | 1.610 | -1.3% |
| Admission, draining | 1.437 | 1.427 | -0.7% |
| Admission, two-second idle intervals | 1.711 | 1.572 | -8.1% |
| Histogram, 5 μs (unchanged control) | 0.392 | 0.393 | +0.2% |
| Histogram, 100 μs (unchanged control) | 0.464 | 0.460 | -0.8% |
| Histogram, mixed (unchanged control) | 0.733 | 0.738 | +0.7% |
| Parse 40-byte request | 173.830 | 173.451 | -0.2% |
| Parse request with 256-byte cookie | 1163.359 | 949.101 | -18.4% |

The clearest reductions are 25.0% for unlimited admission, 17.5% for
rate-limited allowed requests, and 18.4% for the longer-header parser workload.
Small-request parsing, overload/draining decisions, and unchanged histogram
controls are essentially unchanged. These costs exclude clock lookup, kernel
I/O, application work, and logging, so their percentages cannot be applied to
total server CPU. Tight loops also reuse hot state and predictable inputs;
validate the deployment workload before making a capacity decision.

## Server measurements

Three alternating before/after pairs use the existing offered-rate driver with
one server worker pinned to CPU 2 and eight client CPUs (4–11), avoiding its SMT
sibling CPU 18. Each fresh server has 256 public slots, 64 client connections,
a 150,000 requests/s limit, a 1,024-token burst, and 1,000 rejection responses/s.
Access logging is disabled; normal admission, metrics, parsing, and response
validation remain enabled. The phases are 50k/s for 3 seconds, 100k/s for 10,
200k/s for 10, then 100k/s for 5. Server process CPU includes userspace and kernel
time; 100% means one logical CPU. Phase summaries use the interior resource
samples, excluding startup and phase transitions.

[Phase summaries](runs/simd.json "Summary of docs/simd/server-summary.json; raw artifact retired") retain every run. Values below are
medians across three trials, with min–max CPU ranges in parentheses.

| Phase | Before CPU | After CPU | Before goodput/s | After goodput/s |
|---|---:|---:|---:|---:|
| Allowed, 100k offered/s | 32.2% (17.4–33.2) | 30.3% (15.3–31.2) | 99,992 | 100,000 |
| Overload, 200k offered/s | 56.7% (47.6–56.8) | 55.9% (46.6–56.7) | 150,088 | 150,098 |
| Recovery, 100k offered/s | 32.0% (17.7–32.5) | 31.0% (17.5–31.3) | 99,998 | 99,991 |

The CPU medians are lower, but the ranges overlap substantially. Both binaries
showed runs with different request batching and much lower CPU use. These
measurements do **not establish a consistent whole-server CPU reduction**.
They do verify rate limiting at about 150k useful requests/s under overload,
recovery to about 100k/s, balanced offer accounting, and clean exit for all six
runs. The 1,024-token initial burst explains useful throughput slightly above
the steady rate over a ten-second overload phase.

Median successful service p99 was 0.213 → 0.221 ms when allowed and
0.717 → 0.692 ms during overload. Offered-time success p99 was
1.090 → 1.163 ms and 1.196 → 1.237 ms respectively. No latency improvement is
claimed. Generator drops/expiration stayed below 0.06% in measured allowed,
overload, and recovery phases. Rejections intentionally include connection
closures when the separate rejection-response budget is exhausted.

## Reproduction

The working environment did not expose Git history. The
baseline patch reverses only the two production changes,
so it can reconstruct the pre-change implementation in a separate copy of this
tree while keeping the new tests and benchmark. Do not apply it to the tree you
intend to keep optimized. [Source hashes](runs/simd.json "Summary of docs/simd/source-hashes.json; raw artifact retired") and binary
hashes in the raw reports identify the measured variants. The source hashes
inside overload reports describe the invoking tree, even when `--server-binary`
selects the separately built baseline; the binary hash identifies the executable.

Build each tree into its own prefix with identical flags:

```sh
zig build install install-hot-paths --release=safe -Dcpu=x86_64_v3 \
  --prefix /tmp/zhtps-after
```

Run the component comparison using the before and after prefixes as described
in [the benchmark guide](../bench/README.md#admission-and-simd-components).
The server runs can be reproduced with this command for each variant, alternating
order across three repeats:

```sh
python3 bench/overload.py --server-binary /tmp/zhtps-after/bin/zhtps \
  --output /tmp/after-1.json --server-cpus 2 --client-cpus 4-11 \
  --connections 64 --max-connections 256 --rate-limit 150000 --burst 1024 \
  --schedule 50000:3s,100000:10s,200000:10s,100000:5s \
  --labels warmup,allowed,overload,recovery
```

## Correctness checks

- ReleaseSafe x86-64-v3: all 45 component tests and all 41 raw TCP tests pass
  with io_uring enabled, including rate-limit exhaustion, recovery, and workers.
- Debug x86-64-v3 and ReleaseFast baseline x86-64: 39 pass, with the six
  io_uring component tests skipped under the restricted sandbox.
- Fragmentation fuzzing completed 101,738 executions with no failures using
  `zig build test -Dcpu=x86_64_v3 -Dtest-filter='fuzz framing'
  -Derror-tracing=false --fuzz=100K`.
- The four added tests also pass on the pre-change implementation. They specify
  preserved behavior: exact credit using a wider integer oracle; fractional
  admission/rejection transitions; CR/LF at every offset across fragmented
  headers and pipelines; and exact storage capacities with unaligned input.
  Component tests provide deterministic nanosecond and byte boundaries that
  socket timing cannot reliably exercise.
