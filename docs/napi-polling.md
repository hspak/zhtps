The bounded NAPI polling candidate is discarded. Across 18 audited trials,
it did not reduce measured read timeouts and raised whole-server CPU use by
about 80% at high load. The retained `tcp-retries-v1` source stays in place.
All ties remain open, including the timeout ties in this experiment.
[Results and individual trials](runs/napi-polling.json "Summary of docs/napi-polling/results.json; raw artifact retired"),
[whole-host observations](runs/napi-polling.json "Summary of docs/napi-polling/host-results.json; raw artifact retired"),
[provenance audit](runs/napi-polling.json "Summary of docs/napi-polling/audit.json; raw artifact retired").

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The experiment ran on September 13, 2026, with 16,384 connections from the
second host, seven ZHTPS workers on CPUs 9–15, and Go with GOMAXPROCS=32 and
normal GC. Three trials per server and workload rotated their order. The
offered schedule ended with 20 seconds at 300k requests/s; saturated runs had
20 measured seconds after two seconds of warmup. The original two-second
deadline, sparse client executable and full HTTP response validation remained
unchanged. Builds, tests and association probes finished before measurements.
[Plan](runs/napi-polling.json "Summary of docs/napi-polling/plan.json; raw artifact retired"),
[candidate receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/napi-poll-v1/build.json; raw artifact retired").

| Measurement | Retained ZHTPS | NAPI candidate | Go |
|---|---:|---:|---:|
| Offered read timeouts, three trials | 5 / 4 / 5 | 8 / 5 / 1 | 2670 / 2429 / 2325 |
| Offered median valid responses/s | 295,160 | 293,935 | 289,656 |
| Offered median p50 / p99, ms | 5.276 / 446.693 | 5.439 / 450.888 | 3.719 / 633.340 |
| Offered process CPU, µs/valid response | 3.635 | 10.009 | 23.299 |
| Offered whole-server busy CPU, cores | 1.951 | 3.516 | 7.170 |
| Offered median RSS, MiB | 454.625 | 461.813 | 506.340 |
| Saturated read timeouts, three trials | 0 / 1 / 0 | 0 / 0 / 1 | 1247 / 1120 / 1368 |
| Saturated median valid responses/s | 319,394 | 320,290 | 314,182 |
| Saturated median p50 / p99, ms | 7.832 / 438.305 | 7.274 / 436.208 | 6.717 / 438.305 |
| Saturated process CPU, µs/valid response | 3.447 | 9.590 | 23.347 |
| Saturated whole-server busy CPU, cores | 1.943 | 3.572 | 7.620 |
| Saturated median RSS, MiB | 454.789 | 460.064 | 495.873 |

Failure counts use request-origin accounting. The candidate also had one
saturated dial timeout; retained ZHTPS had none. Saturated warmup had two
errors for retained ZHTPS and one for the candidate. These are preserved
separately from measured failures and completion-window counts. Go had 170
offered dial timeouts at 300k/s and 77 saturated dial timeouts. At 100k/s all
three servers had zero HTTP failures; at 200k/s ZHTPS and the candidate tied
at zero while Go had one read timeout. Offered generator misses at 300k/s
increased from 263,477 to 303,243 with the candidate.

The candidate's saturated goodput, p50 and p99 medians improved by 0.28%, 7.1%
and 0.48%, respectively, but their trial ranges overlap. At 200k/s p50 and
p99 improved from 0.127 / 0.410 ms to 0.112 / 0.261 ms. These favorable
observations remain recorded. They do not offset a timeout tie and the
repeatable resource cost for the proposed default. Process CPU per response
rose 175–178% at high load; whole-server CPU rose 80–84%. Whole-host CPU
already includes the process, so the two costs must not be added. Interior
host sampling also includes unrelated host work and is not a kernel profile.

Server IRQ CPU use fell while worker CPU use rose, consistent with moving
some receive processing into the workers. The extra total CPU shows that the
process increase was not merely accounting moving between contexts. Client
CPU and retransmission rates did not show a substantial corresponding
improvement. Server qdisc drops were not consistently reduced, and both
hosts recorded zero ECN marks. Queue counters cover entire runs, including
setup, warmup and cleanup; they cannot locate individual failed packets.

The candidate registers a ten-microsecond polling budget per io_uring ring,
using dynamic tracking with preferred polling disabled. Controlled LAN tests
verified the settings on all seven rings and valid NIC association on both
endpoints. Direct polling invocation was inferred from the effective settings
and kernel path, not traced: the kernel profiling attempt required an
unavailable sudo password. The full correctness suite passed 65 build steps,
98 Zig tests, 60 wire tests, and library, application and upload checks.
[Implementation, primary sources and probe limits](napi-polling/setup-review.md),
full validation log.

Because this policy failed its primary timeout objective with large CPU
regressions, no adoption tests at 8k or with uploads are justified. This
rejects the tested ten-microsecond server policy; it does not establish that
every polling budget, receiver configuration or NIC would behave identically.
The [paired TCP evidence](server-timeout-correlation.md) still points to
response delivery and repeated loss recovery. The next useful diagnostic is
to correlate a bounded sample of failed responses with software transmit
timestamps before the qdisc and at the driver, while keeping those diagnostic
timings out of performance decisions.
