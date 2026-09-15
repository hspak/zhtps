The investigation ended at the user’s request on September 13, 2026.
See the [final wrap-up](go-performance-wrap-up.md) for retained changes,
discarded experiments and unresolved results. The work plans below are
historical; no further experiments are scheduled.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Follow-up: the [production integration](tcp-read-timeout-mitigation.md) is now
retained after 48 fresh decision trials and full correctness checks. It sets
the public listener option before binding and exposes an explicit system mode.
The prototype measurements below remain preserved as their own experiment.

The [latest follow-up](read-timeout-followup.md) updates the remaining priorities
with paired TCP and sampled transmit evidence. Fixed-rate pacing and server
NAPI polling have now been tested and discarded; adaptive pacing remains a
hypothesis. Every tied result remains open.

The strongest new mitigation is `TCP_THIN_LINEAR_TIMEOUTS` on accepted public
sockets. An isolated candidate reduced read timeouts by **99.7–99.9%** in repeated
16,384-connection GET benchmarks with the original two-second client deadline.
It also passed a controlled packet-loss regression that fails on the retained
server. This is a recovery improvement with measurable costs, not elimination
of packet loss. The retained server source remains unchanged by this experiment.

The investigation and measurements were completed on September 13, 2026.
[Machine-readable findings](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/investigation-result.json; raw artifact retired"),
[audited run inventory](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/audit.json; raw artifact retired"),
isolated patch, and
[candidate build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/timeout-thin-linear-v1/build.json; raw artifact retired")
preserve the result independently of this report.

A [subsequent 18-run comparison](read-timeout-rto50.md) tested a 50 ms minimum
RTO separately and discarded it: read timeouts increased in every baseline pair,
with much higher queue drops. The strategy ranking below reflects that evidence.
A further [24-run comparison against Go](read-timeout-thin-go.md) validates the
thin-stream candidate at 8k and 16k, with zero measured 8k failures and large
16k failure reductions. High-load median latency and saturated p99 remain open.

The benchmark's `read_timeout` means that the client was reading when its
exchange deadline expired. It is not ZHTPS's request-body timeout. The deadline
includes earlier exchange work, including dialing on the saturated client's
reconnection path. It does not establish whether the server received the request.
See [client deadline](../bench/load/main.go#L178),
[failure classification](../bench/load/main.go#L108), and
[offered-load exchange](../bench/load/offered.go#L275).

ZHTPS records a completed response when its local send completes; that does
not establish peer receipt. Its request-duration histogram excludes time before
the first received input and subsequent response retransmission. Admission
capacity is also released without waiting for TCP acknowledgement. Consequently,
fast application histograms can coexist with slow or failed client exchanges.
The selected runs recorded no server-side timeout, rejection, abort, I/O error,
slot exhaustion, buffer exhaustion, or reclaim events, while both hosts recorded
large retransmission and TCP timer counts. That points toward transport recovery
as a major contributor; aggregate counters cannot attribute every failed request.
[Completion accounting](../src/server/worker.zig#L2522),
[admission contract](../src/Admission.zig#L38),
[existing-run evidence](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/existing-evidence.json; raw artifact retired").

Small serial request/response streams can have too few outstanding packets to
quickly reveal a lost response through subsequent acknowledgements. Linux's
ordinary retransmission timeout backs off exponentially. The tested option
allows bounded linear retry intervals on qualifying established thin streams,
then returns to exponential backoff. Current upstream eligibility requires fewer
than four outstanding packets and being outside initial slow start. The socket
option does not resend an HTTP operation at the application level.
[Linux retry implementation](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp_timer.c),
[thin-stream eligibility](https://raw.githubusercontent.com/torvalds/linux/master/include/net/tcp.h).

Both benchmark hosts support the option, but it was disabled. The candidate
sets it only on accepted public server sockets, leaving the client and host
configuration unchanged. Both hosts retain a 200 ms minimum RTO.
[Server inspection](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/server-transport.json; raw artifact retired"),
[client inspection](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/client-transport.json; raw artifact retired").

The new measurements use three rotated baseline/candidate pairs per load,
seven ZHTPS workers on CPUs 9–15, the second host with the retained sparse
histogram client on CPUs 0–7, and 16,384 connections. Each high-load measurement
lasts 20 seconds. Offered runs first measure 100k and 200k requests/s for ten
seconds each; saturated runs have a separate two-second warmup. These are twelve
new GET runs, audited separately from the previous 192-run comparison ledger.
There are no new Go, upload, or 8k measurements of this candidate.
[Plan](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/thin-linear-plan.json; raw artifact retired"),
[all trial results](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/get-trials.json; raw artifact retired").

| Measurement, three trials | Retained ZHTPS | Thin-retry candidate |
|---|---:|---:|
| 300k offered/s: read timeouts | 2,389 / 1,925 / 2,313 | 7 / 5 / 5 |
| 300k offered/s: read timeout total | 6,627 | 17 |
| 300k offered/s: all failures | 6,733 | 17 |
| 300k offered/s: median valid responses/s | 289,184 | 291,025 |
| 300k offered/s: median trial p99 | 637.53 ms | 444.60 ms |
| 300k offered/s: median trial p50 | 5.964 ms | 6.259 ms |
| Saturated: read timeouts | 1,099 / 933 / 606 | 2 / 0 / 0 |
| Saturated: read timeout total | 2,638 | 2 |
| Saturated: all failures | 2,702 | 2 |
| Saturated: median valid responses/s | 323,696 | 321,683 |
| Saturated: median trial p99 | 436.21 ms | 436.21 ms |
| Saturated: median trial p50 | 7.274 ms | 7.864 ms |

The timeout reduction appears in every pair. Offered-load p99 improves about
30%, but saturated goodput falls 0.62%, with all three pairs lower and overlapping
trial ranges. Median latency rises 4.9% offered and 8.1% saturated. Median server
CPU per valid response changes from 3.450 to 3.427 microseconds offered and
3.332 to 3.421 saturated; those trial ranges overlap. Median sampled server RSS
changes from 455.49 to 454.34 MiB offered and 456.07 to 454.60 MiB saturated.
These measurements do not establish an across-the-board performance win.
[Aggregates and trial ranges](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/get-aggregate.json; raw artifact retired").

Load-generator misses remain separate from HTTP failures: at 300k offered/s,
totals are 579,663 before and 465,285 after. Neither variant sustains the full
configured rate. Saturated warmup errors are 830 before and zero after; setup
errors are zero throughout. At 100k and 200k, both variants have zero measured
HTTP failures. Generator misses are 1 versus 2 at 100k and 321 versus 463 at
200k. The 100k median goodput, p50, and p99 are exact ties. Every tied result and
every residual failure remains open under the user's acceptance criterion.

Faster recovery costs additional server retransmissions. Median interior rates
rise from 60,723 to 65,042 retransmitted segments/s offered, and 64,204 to 66,637/s
saturated: approximately 7% and 4%. Client retransmission rates change from
41,436 to 40,952/s offered and 13,083 to 13,213/s saturated. These are host-wide
counter deltas over interior windows, not per-request loss probabilities.
Software receive-backlog drops and budget-exhaustion counters remain zero on
both hosts. The option shortens recovery; it does not resolve the source of loss.
[Network evidence](runs/read-timeout-investigation.json "Summary of docs/read-timeout-investigation/thin-linear-evidence.json; raw artifact retired").

The controlled regression establishes the mechanism independently of benchmark
correlation. In a disposable network namespace, it warms a keepalive connection,
then drops the first six server response packets at the receiver. The unchanged
server reaches the two-second deadline after five transmissions and fails with
`TimeoutError` at 2.001 seconds. The candidate retransmits through all six drops
and delivers the correct status and body in 1.249 seconds. The test script is
identical between runs, SHA-256
`80fa6d6f01b1247bd0588ac521ad73305ea0850c5a05eb193912e57052843045`.
The baseline's `loss_control_verified: false` reflects expiry before the sixth
transmission, not absence of injected loss. Earlier calibrations that did not
reproduce the failure remain recorded separately; they are not counted as
successful regressions. No host firewall rules or network settings were changed.
Permanent regression source,
baseline failure,
candidate success.

The candidate also passed the full ReleaseSafe component and integration checks:
65 build steps, 94 component/CRC tests, and the wire, embedded library,
application, and upload/streaming suites. Formatting passed. Builds and tests
finished before performance measurements.
Validation log.

The remaining strategies are ranked by expected usefulness against these
timeouts, combining evidence, potential impact, and implementation cost:

| Rank | Strategy | Evidence and compatibility | Remaining work or cost |
|---|---|---|---|
| 1 | Configurable thin-stream linear retries | Directly validated above; fits the accepted-socket setup with no HTTP scheduling change. | Residual errors, extra retransmissions, and latency/throughput costs remain. Validate 8k, uploads, longer loads, and fresh Go controls. |
| 2 | Bound and pace aggregate response traffic | Current admission tracks local work, not outstanding transport delivery. Many individually small flows can produce a collective burst. A bounded response queue and packet/time budget fit the worker architecture. | Highest architectural upside for preventing loss, but unmeasured and substantially more work. Preserve deadlines, cancellation, fairness, and bounded memory; avoid an unbounded delay queue. |
| 3 | Negotiate ECN with participating clients and paths | Both Ethernet qdiscs support ECN, but both hosts use `tcp_ecn=2`, which accepts incoming negotiation without requesting it on outgoing connections. | Requires client/deployment participation and measurement of actual negotiation. Helps congestion marking where supported, not NIC overruns or every queue overflow. |
| Discarded | Lower the socket minimum RTO to 50 ms alone | Subsequently tested against current ZHTPS and Go in 18 runs. | More read timeouts in every baseline pair, higher p50 and CPU, lower saturated throughput, and much higher server queue drops. P99 gains remain recorded. |

The minimum-RTO experiment uses a per-socket setting supported by the inspected
kernel interface. Its negative result on this LAN argues against adopting it
without stronger workload-specific evidence.
[Linux socket options](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp.c).
The ECN opportunity follows from the recorded endpoint configuration and Linux's
negotiation modes; collect per-trial qdisc drops and ECN marks before attributing
current losses to active queue management.
[Linux ECN configuration](https://docs.kernel.org/6.18/networking/ip-sysctl.html#tcp-ecn-integer).

Aggregate pacing is distinct from the previously tried completion-batch limits
and immediate-send scheduling. Those alter when work is submitted in a loop;
they do not impose an aggregate packet budget over time. Likewise, the existing
admission token bucket never waits: excess requests are rejected or closed.
Replacing read timeouts with rejects would not satisfy the zero-failure goal.
For cooperative closed-loop clients, modest pacing might avoid the loss/retry
cycle at higher useful throughput than a fixed conservative rate cap. That is
a hypothesis to test, not an established result.

Before another transport change, the most useful diagnostic is a bounded
`TCP_INFO` snapshot on each residual client timeout, captured before closing
the socket. Record the connection tuple, exchange phase, deadline elapsed,
bytes received/acknowledged, unacknowledged and unsent bytes, retransmissions,
and RTO; correlate selected failures with the server side. This would distinguish
lost requests, lost responses, and scheduling delay. Add sampled transport-stall
metrics without redefining existing local-send completion metrics. This is an
observability proposal, not itself a timeout mitigation.

Several tempting knobs are already considered or unsupported by this evidence.
RACK, tail-loss probing, SACK, and DSACK are enabled. The server NIC's receive and
transmit rings are already at their reported maximum of 256, and its coalescing
query is unsupported. No software-backlog drops or budget exhaustion were
observed, so increasing those limits lacks a measured justification. RPS and
NIC CPU placement remain conditional deployment experiments already discussed
in [the kernel review](../KERNEL_CONF.md); they are not new findings here.
Lifetime qdisc drop counts confirm historical drops but cannot locate loss in
these specific trials, and raw NIC missed-counter wraparound remains unresolved.

Longer HTTP deadlines would change the benchmark contract. TCP keepalive and
`TCP_USER_TIMEOUT` govern detection/cleanup rather than making lost responses
arrive sooner. The old `TCP_THIN_DUPACK` option is a no-op in current upstream
Linux and should not be added based on older thin-stream guides.
[TCP timeout semantics](https://man7.org/linux/man-pages/man7/tcp.7.html),
[current option implementation](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp.c).

The experimental patch fails an accepted connection if setting the option
fails, which made unsupported operation visible during testing. Any production
integration needs an explicit configuration and unsupported-kernel policy;
the measured prototype should not silently become a universal default.
The candidate remains frozen in its source archive, the controlled regression
is retained, and the broader Go comparison goal remains active.
