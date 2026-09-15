Follow-up: the [upload root-cause investigation and fixes](upload-parity.md)
explain the checksum cost, client queue collisions, and buffer-cache churn.
The final tuned upload configuration matches Go's throughput and practical
latency while using less process CPU and RSS. The measurements below preserve
the September 12 baseline.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The current ZHTPS narrowly leads Go's saturated GET throughput on the second-host
LAN benchmark, while using substantially less CPU at matched request rates.
At 200k requests/s, ZHTPS uses 4.6–5.4 times less process CPU per validated
response. Go still uses less memory. Streamed uploads match Go's throughput and
paced latency, but consume more CPU, largely because the fixture's Zig CRC32
implementation is much slower than Go's hardware-assisted implementation.

These September 12, 2026 results cover 42 HTTP trials, with three rotated trials
per server and scenario. Six subsequent checksum-only trials investigate the
upload CPU difference. The [audit](runs/go-after-nginx.json "Summary of docs/go-after-nginx/audit.json; raw artifact retired") passed; HTTP
timeouts remain counted as failures. No production source was changed for this
comparison. The earlier [sequential before/after tests](nginx-implementation.md)
remain the evidence for each retained change's individual effect.

**Configuration.** The server is `benchmark-server`, `192.0.2.10`, with a Ryzen AI Max+ 395
(16 physical cores, 32 logical CPUs). Load originates on `client.example`
(`benchmark-client`, `192.0.2.20`), a separate eight-core host, across the same 2.5 Gb/s
LAN. Client CPUs are 0–7; the GET generator uses `GOMAXPROCS=8`. Host identities,
clock estimates, CPU samples, and NIC/TCP counters are retained per trial.

Every Go HTTP server explicitly uses **`GOMAXPROCS=32`**, confirmed by startup
output, with unrestricted CPU placement and normal GC. The harness clears
inherited `GOGC`, `GOMEMLIMIT`, and `GODEBUG`. Go is
`go1.27.1-X:nodwarf5`, built with ordinary `go build`; ZHTPS uses Zig 0.16.0
ReleaseSafe. Both HTTP workloads use persistent HTTP/1.1, without TLS or access
logging. ZHTPS retains its admission checks and metrics. The minimal Go fixtures
implement the measured workload, without equivalent operational features.

GET uses seven ZHTPS workers pinned to CPUs 9–15. This is the previously selected
NIC-local placement, excluding IRQ CPU 24 and its SMT sibling 8; it was
[rechecked](runs/go-after-nginx.json "Summary of docs/go-after-nginx/placement.json; raw artifact retired") before the run. Each worker has 4,096
public connection slots and active permits: 28,672 public slots in total, plus
eight admin slots. `--max-requests 4294967295` avoids routine connection turnover,
the completion budget is 64, and `--idle-reclaim-ms 50` enables the opt-in
pressure policy. This measures the current tuned configuration against Go;
it is not a comparison with equal CPU placement or equal configured capacity.

**Fixed-rate GET.** Each fresh server receives a ten-second preparation phase
at 1k/s for 8,192 connections or 2k/s for 16,384 connections, then ten seconds
each at 100k, 200k, and 300k offered requests/s. Successful responses must contain
exactly the six-byte `ZHTPS\n` body. Values below are medians of three trials;
each cell lists **ZHTPS / Go**. Failures are totals across the three trials.

| Connections | Offered requests/s | Validated responses/s | CPU µs/response | Service p99, ms | Failures |
|---:|---:|---:|---:|---:|---:|
| 8,192 | 100,000 | 99,275 / 99,345 | 4.45 / 22.65 | 0.176 / 2.687 | 0 / 0 |
| 8,192 | 200,000 | 198,164 / 198,463 | 4.24 / 22.86 | 0.434 / 5.439 | 0 / 0 |
| 8,192 | 300,000 | 299,197 / 294,833 | 4.43 / 24.97 | 2.081 / 455.082 | 0 / 729 |
| 16,384 | 100,000 | 98,614 / 98,556 | 5.05 / 23.12 | 24.117 / 26.739 | 0 / 0 |
| 16,384 | 200,000 | 199,493 / 199,028 | 4.77 / 22.07 | 0.618 / 202.375 | 0 / 2 |
| 16,384 | 300,000 | 295,243 / 287,645 | 3.58 / 24.73 | 641.729 / 633.340 | 1,594 / 2,367 |

ZHTPS's CPU advantage is consistent across these rates. At 200k/s, measured
process CPU is approximately 0.84 versus 4.54 cores at 8k connections and 0.95
versus 4.39 cores at 16k. These figures exclude kernel work executed outside
the server process, such as interrupt and softirq work on other CPUs; they
measure process cost rather than total machine cost.

Tail latency is less stable. At 16k connections and 100k/s, ZHTPS's three p99s
were 0.196, 42.205, and 24.117 ms; Go's were 6.685, 26.739, and 41.943 ms.
At 200k/s, ZHTPS's p99s were 0.426–0.913 ms and Go's were 47.710–204.472 ms.
At 300k/s and 16k connections, both have substantial tails and timeouts. The
nonmonotonic latency and transport retransmissions prevent treating every p99
difference as an isolated server implementation effect. The 8k/300k Go failures
and 16k/200k Go failures are read timeouts; 16k/300k includes read and dial
timeouts. No invalid response is counted as goodput.

| Connections, at 200k offered/s | ZHTPS RSS, MiB | Go RSS, MiB |
|---:|---:|---:|
| 8,192 | 609.5 | 267.8 |
| 16,384 | 609.3 | 505.8 |

ZHTPS's request pooling retains the approximately 609 MiB footprint seen in its
own before/after tests, down from about 948 MiB before that change. Go remains
smaller. ZHTPS still provisions small connection buffers against all 28,672
configured slots, which are identical at both offered connection counts; Go's
footprint grows with the live workload. This is not a per-live-connection memory
comparison with equal capacity reservation.

**Saturated GET.** Each trial prepares and verifies every requested connection,
warms for two seconds, then measures a ten-second closed-loop completion window.
Each connection has one outstanding request. All 8,192 or 16,384 requested
connections completed measured requests in every trial. The generator retains
errors and reconnects rather than reducing the requested concurrency.

| Connections | ZHTPS responses/s | Go responses/s | ZHTPS lead | p99, ms, ZHTPS / Go | Measured failures, ZHTPS / Go |
|---:|---:|---:|---:|---:|---:|
| 8,192 | 364,384 | 358,609 | 1.6% | 221.2 / 221.2 | 38 / 44 |
| 16,384 | 331,926 | 318,872 | 4.1% | 432.0 / 436.2 | 1,283 / 1,345 |

The throughput ranges across repeats were 363,925–365,230 versus
356,422–359,012 responses/s at 8k, and 331,395–333,368 versus 317,545–319,076
at 16k. Setup errors were zero. Warmup error totals were 23 / 91 at 8k and
529 / 781 at 16k, in addition to the measured failures above. These are observed
throughputs with errors, not error-free capacity limits. Similar saturated
throughput therefore coexists with a substantial difference in process CPU at
matched load. This experiment does not locate the transport bottleneck or
establish the maximum capacity of either server on a faster network.

**Streamed uploads.** The ZHTPS generated endpoint consumes each decoded body
chunk through its bounded application lane and returns the byte count and IEEE
CRC32. The [Go fixture](../bench/go_upload/main.go) streams through
`io.CopyBuffer` into `crc32.NewIEEE`, using a pooled 64 KiB buffer. Both accept
8 MiB bodies. The client independently validates the complete length/checksum
response. ZHTPS's fixture observation counters and blocking gates are compiled
out (`-Dupload-observe=false`).

ZHTPS uses four network workers on CPUs 9–12, four shared application threads
for the default lane, 256 slots/active permits per network worker, a 64 KiB
receive buffer, and 64 KiB application scratch. The fixture also configures
separate control and short lanes, unused by these upload requests. Go retains
`GOMAXPROCS=32`. Thirty-two persistent clients run on the second host using the
Python upload generator. Trials have five seconds of warmup and a twenty-second
completion window. The paced case staggers starts at an aggregate 25 requests/s,
or 200 MiB/s. Each table cell lists **ZHTPS / Go**.

| Body and load | Validated MiB/s | Service p99, ms | RSS, MiB | CPU µs/MiB |
|---|---:|---:|---:|---:|
| 64 KiB, saturated | 279.31 / 279.37 | 8.00 / 8.43 | 43.34 / 23.38 | 2,159 / 568 |
| 8 MiB, saturated | 285.20 / 281.60 | 1,847.70 / 917.71 | 43.40 / 18.92 | 2,096 / 339 |
| 8 MiB, paced at 200 MiB/s | 200.00 / 200.00 | 29.97 / 29.80 | 39.93 / 14.02 | 2,001 / 180 |

All attempts succeeded across all 18 upload trials. Saturated transfer rates
approach the 2.5 Gb/s link's capacity. Counting completed 8 MiB requests in finite
windows also admits work carried across window boundaries, so the small
throughput difference is insufficient evidence for a server-capacity advantage.
ZHTPS had worse median saturated large-body p99 in this comparison; Go also
had one 1,900 ms trial. At the paced rate, both consistently deliver 200 MiB/s
with p99 near 30 ms. Go uses less memory in every upload scenario.

**Why Go's upload CPU is lower.** After all HTTP trials finished, a standalone
probe measured each fixture's standard-library CRC32 implementation on the
server, pinned to CPU 9. Both process the same 8 MiB pattern 64 times in 64 KiB
chunks, modifying the first byte between iterations and retaining every
checksum. Python's independent CRC32 validates the warmup result and the sum of
all results. Timing uses process CPU time. Three rotated pairs produced:

| Checksum implementation | Median CPU µs/MiB |
|---|---:|
| Zig `std.hash.Crc32`, ReleaseSafe | 1,706.58 |
| Go `hash/crc32`, `GOMAXPROCS=1` | 26.49 |

The approximately 64-fold checksum difference is consistent with much of the
HTTP upload CPU gap. The installed Zig implementation uses a dependent
byte-at-a-time table loop; the installed Go implementation dispatches IEEE CRC32
to carry-less multiplication instructions supported by this CPU. Exact library
sources and CPU capability flags are archived:
Zig update loop,
Go dispatch, and
Go assembly.
The probe results contain individual
timings, build commands, hashes, and validation results.

This is evidence that the upload CPU comparison includes a substantial checksum
implementation difference. It is not a transport-only comparison, and the probe
does not justify exactly subtracting its cost from HTTP measurements: caching,
CPU frequency, chunk sizes, and scheduling differ. No checksum or transport
implementation was changed during this comparison.

**Coverage and measurement limits.** Request storage pooling is exercised by
GET and upload traffic; streaming and the shared application lane are exercised
by uploads. Idle reclamation was enabled for GET, but reclaimed zero connections
in all twelve ZHTPS GET trials because slot pressure was absent. Its benefit
under pressure remains established by the earlier
[full-slot admission tests](nginx-implementation.md). The non-pipelined GET
workload also produced zero response batches. These measurements show the
combined current implementation on the selected workloads, without activating
every optional path or isolating every prior change.

Reported quantiles are medians of per-trial successful-request quantiles,
excluding failed requests. GET histogram quantiles have finite bucket precision.
Closed-loop latency includes draining requests started during measurement;
throughput counts completions in the fixed window. Closed-loop failure totals
use that request-start cohort and are not an exact complement of window
goodput. Setup and warmup errors are separate.

Fixed-rate accounting retains generator expirations and queue drops; not every
offered request reaches a socket. CPU estimates use interior server samples,
excluding the first 500 ms and final 200 ms of each phase, divided by window
goodput; RSS is the median of interior samples. CPU includes work handling
failures. Upload CPU and RSS likewise use samples within the completion window.
Host network counters can include unrelated traffic and do not locate packet
loss. Three short repeats characterize this testbed, rather than proving
long-duration capacity or production tail latency.

**Artifacts and validation.** [Aggregate medians and trial values](runs/go-after-nginx.json "Summary of docs/go-after-nginx/aggregate.json; raw artifact retired"),
[individual trial summaries](runs/go-after-nginx.json "Summary of docs/go-after-nginx/trials.json; raw artifact retired"), and the
[audit](runs/go-after-nginx.json "Summary of docs/go-after-nginx/audit.json; raw artifact retired") accompany raw `run.json`, server logs,
client output, samples, and clock/host records under
[go-after-nginx](runs/go-after-nginx.json "Summary of docs/go-after-nginx; raw artifact retired"). The preparatory `upload-smoke` pair is
excluded from the 42 decision trials.

The [build receipt](runs/go-after-nginx.json "Summary of docs/go-after-nginx/build.json; raw artifact retired") records fresh Go binaries and the
unchanged final ZHTPS binaries from the
[previous implementation receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/final/build.json; raw artifact retired").
Every server's running `/proc/PID/exe` hash matches its recorded binary; the
remote GET generator hash and uploaded request/expected-response hashes are
checked. The audit also checks separate host identities, Go's HTTP
`GOMAXPROCS=32`, complete closed-loop connection participation, request accounting,
upload checksums, and unchanged production source. All servers exited after
measurement: ZHTPS normally and Go through the harness's SIGTERM.

The [recorded plan](runs/go-after-nginx.json "Summary of docs/go-after-nginx/plan.json; raw artifact retired") contains all six series commands
and frozen harness hashes; [runner results](runs/go-after-nginx.json "Summary of docs/go-after-nginx/runner-results.json; raw artifact retired")
show every series completed successfully. For another measurement, use fresh
output paths with those commands so these results remain intact. To re-audit
the retained results from the repository root:

```sh
python3 bench/summarize_go_after_nginx.py docs/go-after-nginx
```
