The goal is to identify the upload performance causes and bring ZHTPS to at
least Go's measured performance, preserving body validation, bounded streaming,
backpressure, deadlines, and application isolation. Comparisons use the existing
second host and Go HTTP GOMAXPROCS=32 with normal GC.

The starting implementation and executables are frozen in
`../nginx-implementation/final/build.json`; the Go comparison is recorded in
`../go-after-nginx/`. Existing worktree changes predate this goal and are retained.

Required evidence before completion:

- Identify the saturated upload tail cause with connection-level evidence and
  controlled experiments; distinguish generator/network effects from server work.
- Match the checksum work using a validated hardware-assisted IEEE CRC32 port
  if needed. Preserve exact length and independently verified checksums.
- Measure remaining server overhead, implement justified improvements one at a
  time, and discard changes without measurable benefit.
- Compare the final current implementation with Go on 64 KiB and 8 MiB uploads,
  including paced 200 MiB/s and saturated persistent connections, with repeated
  runs, failure accounting, actual running binary hashes, and resource samples.
- Verify correctness with checksum boundary/fragmentation tests and the affected
  streaming, executor, wire, and component suites. Run appropriate GET controls
  for any production runtime changes.
- Report throughput, latency distributions, CPU, memory, tradeoffs, and exact
  workload coverage. Treat unresolved parity dimensions as incomplete rather
  than silently redefining parity around a favorable metric.

Initial evidence at the start of the investigation: the standalone CRC cost is 1,706.6 versus 26.5 CPU µs/MiB.
Saturated large-upload outliers affect two of 32 connections in both servers;
the other 30 connections maintain similar progress. No causal attribution of
those outliers has yet been established.

Completion evidence (September 13, 2026):

- Queue collisions were observed per connection and reproduced deliberately in
  both servers; distinct-queue controls remove the doubled upload tail.
- The hardware IEEE CRC32 port matches independent checksums and Go's measured
  checksum CPU cost. Portable and hardware boundary/fragmentation tests pass.
- Buffer-cache churn was isolated with allocation/page-fault counters and a
  permanent wire regression that failed before the fix and passed unchanged
  afterward. Controlled repeated comparisons show a 54% small-upload CPU gain.
- Final fixed-length callback/handler fusion has a smaller measured CPU gain;
  five other runtime experiments were reverted. See `decisions.json`.
- All 34 HTTP trials in `final-plan.json` completed. Final uploads match
  throughput, use less CPU and RSS, and have practical latency parity. The
  paced p99 median is 0.20 ms higher with overlapping observed per-run ranges.
  Natural client queue variation and mixed-size preparation are reported.
- ReleaseSafe and Debug checks passed, including 93 component/CRC tests,
  streaming/executor coverage, and the relevant wire/library suites.
- `audit.json` passed for 159 measured upload runs and four GET controls, with
  two failed setup attempts explicitly retained. Source and executable hashes,
  independent payload validation, failure accounting, and samples are checked.
- `../upload-parity.md` reports exact configuration, all final measurements,
  tradeoffs, GET generator drops, and the limits of the parity conclusion.
