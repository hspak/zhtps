# Recorded benchmark runs

The written performance reports retain the run descriptions, measured results,
decisions, and limitations. This directory holds their machine-readable setup
and result summaries. Start with the [browser report](../benchmarks.html) or
[investigation conclusions](../performance-summary.md).

## What is retained

Each experiment has a JSON catalog. Its `records` object uses the original
artifact path as an identifier, for example
`docs/http2-lan/summary.json` in [http2-lan.json](http2-lan.json).
These identifiers are historical references, not paths to existing files.

Each entry contains:

- `record`: the retained configuration, provenance, outcomes, or summary.
- `original_sha256`: the hash of the original JSON artifact before compaction.
- `omitted_fields`: names and occurrence counts of fields removed from that
  artifact, including nested fields. An empty object means the JSON values were
  retained completely, although whitespace and formatting may differ.

The catalogs preserve top-level result and setup records, along with per-run
`run`, `summary`, `manifest`, `build`, and `variants` records. Reported aggregates,
quantiles, trial values, failures, decisions, and recorded environment metadata
remain where present. Raw sampling series, latency distributions, individual
connection traces, process/network snapshots, and embedded source were removed.
Some diagnostic detail is consequently available only in the written findings.

[standalone.json](standalone.json) collects records formerly at the root of
`docs/`. [overload-phases.json](overload-phases.json) contains the browser phase
explorer's precomputed summaries, including CPU intervals, actual successes,
and unsent offers; it is an array of experiments rather than a catalog.
Summary CSVs and SVG charts remain beside the relevant reports.

## What was removed

Raw measurements, logs, executables, profiles, patches, source snapshots, and
duplicate benchmark scripts are no longer stored under `docs/`. Links to
retained JSON now open the corresponding catalog. References to removed source
or traces are plain text. Historical commands and paths in reports describe
the original experiment and may require artifacts that are no longer present.

The summaries cannot support a fresh audit of the deleted raw measurements or
reconstruct every historical source variant. Recorded hashes identify those
versions; they do not replace the deleted bytes. The cleanup changes the working
tree and does not rewrite Git history.

## Adding a run

Write raw output to `zig-out/bench/<run>/` (ignored by Git) or another scratch
directory. Keep the maintained harnesses in `bench/`. For a result worth keeping,
commit a short report containing:

- The question, date, source revision or hashes, and the candidate variants.
- Commands, tool versions, hosts, CPU placement, workload, and duration.
- Repetitions, summarized results, failures, controls, and limitations.
- The decision and its reason, including inconclusive or rejected outcomes.

Retain compact JSON or CSV summaries alongside the description. Do not commit
raw traces, binaries, profiles, or copies of source trees. Raw-data auditors
and summarizers in `bench/` require fresh run output; the browser report builds
directly from retained catalogs with `python3 bench/render_reports.py`.

## Catalogs

- [adaptive-send-pacing](adaptive-send-pacing.json)
- [architecture-implementation](architecture-implementation.json)
- [architecture](architecture.json)
- [bun-http2-implementation](bun-http2-implementation.json)
- [bun-http2-review](bun-http2-review.json)
- [critical-path-experiments](critical-path-experiments.json)
- [go-after-nginx](go-after-nginx.json)
- [go-comparison-lan](go-comparison-lan.json)
- [go-performance-followup](go-performance-followup.json)
- [http2-comparison](http2-comparison.json)
- [http2-diagnosis](http2-diagnosis.json)
- [http2-lan](http2-lan.json)
- [ingress](ingress.json)
- [keepalive-policy](keepalive-policy.json)
- [kernel-work](kernel-work.json)
- [napi-polling](napi-polling.json)
- [native-admission](native-admission.json)
- [nginx-implementation](nginx-implementation.json)
- [nginx-review](nginx-review.json)
- [nic-placement](nic-placement.json)
- [overload-phases](overload-phases.json)
- [overload](overload.json)
- [performance-strategies-review](performance-strategies-review.json)
- [read-timeout-investigation](read-timeout-investigation.json)
- [read-timeout-rto50](read-timeout-rto50.json)
- [read-timeout-socket-info](read-timeout-socket-info.json)
- [read-timeout-thin-go](read-timeout-thin-go.json)
- [request-critical-path](request-critical-path.json)
- [request-footprint](request-footprint.json)
- [request-path-remaining](request-path-remaining.json)
- [response-aggregation-integrated](response-aggregation-integrated.json)
- [response-aggregation-v2](response-aggregation-v2.json)
- [send-pacing-confirmation](send-pacing-confirmation.json)
- [send-pacing](send-pacing.json)
- [server-timeout-correlation](server-timeout-correlation.json)
- [simd](simd.json)
- [standalone](standalone.json)
- [thin-retry-integration](thin-retry-integration.json)
- [thin-retry-upload](thin-retry-upload.json)
- [transmit-timestamps](transmit-timestamps.json)
- [upload-parity](upload-parity.json)
