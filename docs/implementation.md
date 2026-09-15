# ZHTPS implementation and verification

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Objective: a Linux x86-64-v4 io_uring HTTP/1.1 origin server with predictable
latency, bounded load shedding, structured JSON logging, optional verbose
diagnostics, and built-in operational metrics. RFC conformance must be verified
against applicable requirements in RFC 9110 and RFC 9112, not inferred from a
successful browser request.

## Work sequence

- [x] Strict incremental request parser and body framing, including trailers.
- [x] Response framing and HTTP semantics, including HEAD, informational
      responses, conditional requests where applicable, and connection reuse.
- [x] io_uring connection lifecycle, partial I/O, operation ownership,
      cancellation, deadlines, and graceful shutdown.
- [x] Admission limits, bounded rejection, fairness, and recovery after overload.
- [x] JSON events, verbose diagnostics, bounded logging, counters, gauges,
      histograms, and independent introspection capacity.
- [x] Runnable configurable server and reusable library interfaces.
- [x] In-file unit/integration tests and raw TCP end-to-end conformance tests.
- [x] Load/overload/slow-client tests, RFC requirement audit, and operator docs.

## Design decisions

- Pin Zig 0.16.0 and target Linux 6.0+ x86-64-v4. Use `std.os.linux.IoUring` directly.
- One owning worker per connection; never recycle operation storage before all
  its completions have been collected. Keep send ordering explicit.
- Parsing is independent of transport and exposes incremental events. Request
  boundaries are determined by framing headers regardless of method.
- Enforce explicit limits with protocol responses; never silently truncate
  headers, request targets, bodies, or response metadata.
- Admission occurs before expensive body processing. Rejection has separate
  bounded resources, and cannot require allocation or unbounded body draining.
- Metrics describe admitted/rejected traffic separately and remain available
  during overload. Logging cannot block the network worker indefinitely.
- Full conformance applies to the origin-server role. Optional protocol features
  may be declined using their specified HTTP behavior. TLS termination and
  forward-proxy behavior are separate roles, not prerequisites for HTTP/1.1.

## Verification policy

The generated starter demonstration APIs/tests were removed when the HTTP
modules replaced that contract. New tests assert externally meaningful behavior.
Conformance and runtime coverage remain permanent. Passing a small suite is not
evidence of full RFC conformance; the final audit must enumerate applicable
requirements, chosen optional behaviors, and their tests.

## Current evidence

- Repository initially contained the unmodified Zig 0.16 project scaffold;
  demonstration APIs/tests were removed when replacing it with the HTTP library.
- Compiler: Zig 0.16.0; execution host: Linux x86_64.
- RFC sources: https://www.rfc-editor.org/rfc/rfc9110.html and
  https://www.rfc-editor.org/rfc/rfc9112.html.
- Protocol and component tests pass via `zig build test`.
- The expanded raw TCP suite covers basic/pipelined GET and HEAD, chunked input
  and output, conditional requests, 100 Continue and Expect lists, body framing,
  malformed input, deadlines, JSON/Prometheus/config/connection introspection,
  admission before 100 Continue, and rejection-budget exhaustion/recovery.
- Slow/unread and closed logging pipes, disconnect churn, peer half-close,
  fragmented 64 KiB responses, stalled response readers, public slot exhaustion,
  descriptor exhaustion, and shutdown with slow bodies have been exercised.
- Both Debug and ReleaseSafe passed 26 component tests and 33 raw TCP tests.
  The component tests include actual io_uring fault injection and cancellation.
- Debug fragmentation fuzz campaigns passed 101,658 cases initially and 101,027
  cases after the final grammar fix. Tests require LLVM for coverage and disabled
  error-return tracing to work around this host's Zig 0.16 fuzz-runner defects.
- Execution host: Linux 7.2.4-arch1-2-strixhalo x86_64; Python 3.14.7.
- io_uring creation is blocked by the workspace sandbox but succeeds outside it.
  Run the local integration harness in that execution environment.

## Completed audit work

The requirements/evidence ledger is [conformance.md](conformance.md). It records
wire grammar, message boundaries, response framing, preconditions, optional
protocol behaviors, application responsibilities, and operational limits.

Fatal errors now synchronously cancel and drain before buffers are freed;
regressions cover a pending receive, abandoned accept completions, unsubmitted
entries, and late cancellation during response drain. Admission and rejection
budgets remain independent. Normal idle/drain closure is distinguished from
header, body, and write timeouts in metrics.

[Operator documentation](README.md) covers build/run settings, embedding,
JSON diagnostics, Prometheus/JSON metrics, introspection, and testing. The
[recorded load sweep](runs/standalone.json "Summary of docs/load-sweep.json; raw artifact retired") preserves the configured admitted rate
through overload and recovers afterward. Generator scheduling limits preclude
using this result as a microsecond latency or maximum-capacity measurement.

This audit covers the built-in HTTP origin application. Custom application
semantics and uninterruptible kernel I/O constraints are explicit in the
conformance ledger; they are not hidden behind a claim of independent certification.
