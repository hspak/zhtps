The investigation ended at the user’s request on September 13, 2026.
See the [final wrap-up](go-performance-wrap-up.md) for retained changes,
discarded experiments and unresolved results. The work plans below are
historical; no further experiments are scheduled.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The remaining read timeouts justify focusing on response delivery after the
server hands bytes to TCP. Server NAPI polling did not help and is discarded.
Two sampled failures now have software transmit evidence: their response byte
ranges reached the driver nine and six times, respectively, beginning about
two seconds before the client reported failure. Neither had an acknowledgment
for that range at the server snapshot. This narrows those cases beyond the
driver's timestamp point; it does not identify the exact NIC, wire, switch or
receiver failure.
[Individual transmit observations](runs/transmit-timestamps.json "Summary of docs/transmit-timestamps/partial-observations.json; raw artifact retired"),
[NAPI decision report](napi-polling.md).

The two observations come from a diagnostic job that was later aborted by the
harness's fixed 180-second job deadline. They were captured 113 and 61 seconds
before the abort. Binary identity, diagnostic source hashes, socket tuples,
inode/cookie, TCP byte counts and timestamp IDs have been checked individually.
The final client result was not returned, so these records are kept separate
from completed-run accounting. Failure times and request counts come from the
known diagnostic client's UDP notifications. This is evidence about those
individual failures, not a completed benchmark or an adoption result.
Partial-record audit,
[preserved failed job](runs/transmit-timestamps.json "Summary of docs/transmit-timestamps/aborted-180s/timestamps-offered-16384/zig-1/run.json; raw artifact retired").

| Sample | Driver events for missing response | First driver event before reported failure | Scheduler-to-driver intervals | Outstanding / unsent bytes |
|---|---:|---:|---:|---:|
| Request 799 on sampled connection | 9 | 1,993.472 ms | 0.166–7.591 ms | 145 / 0 |
| Request 1,711 on sampled connection | 6 | 1,999.371 ms | 0.269–7.346 ms | 145 / 0 |

Cross-host clock uncertainty is 0.109 ms. All request bytes had been consumed;
acknowledged bytes cover exactly the previous responses. Each scheduler event
for the failing byte range has a corresponding driver event. These delays
do not explain a two-second wait. Software transmit events occur before NIC
ownership, so they establish neither physical transmission nor reception.
The diagnostic adds work and cannot prove every retained-server failure has
the same cause.
[Timestamp semantics, driver source and validation](transmit-timestamps/setup-review.md).

Two corrected diagnostic runs, with 120-second high-load phases, completed
and passed provenance/accounting audits. They captured all 33 offered read
failures and all five saturated read failures eligible for observation; the
latter comprise three measured and two warmup failures. None landed in the
deterministic one-in-sixteen descriptor sample. Their paired TCP snapshots
still show zero unread request bytes and 145 outstanding response bytes.
These runs therefore add TCP evidence but no sampled transmit evidence.
An additional LAN control verifies that actual netlink identities match the
collector, including inode and cookie, ruling out a general matching failure.
[Completed-run audit](runs/transmit-timestamps.json "Summary of docs/transmit-timestamps/audit.json; raw artifact retired"),
[paired observations](runs/transmit-timestamps.json "Summary of docs/transmit-timestamps/paired-audit.json; raw artifact retired"),
matching control.

The sampler is bounded to 2,048 duplicate sockets and 64 events per socket.
Both completed runs peaked at 1,024 duplicates and closed them all. The LAN
control validates every timestamp for 128 responses on each sampled socket.
A controlled receiver-side drop test independently demonstrates repeated
driver events with no ACK until delivery recovers. Full server correctness
checks passed before load. These checks validate the instrument, not a
performance improvement. Production source remains `tcp-retries-v1`.

The remaining mitigation priorities are:

| Priority | Strategy | Why it remains useful | Acceptance evidence needed |
|---|---|---|---|
| 1 | Pace aggregate responses to a destination using sampled delivery feedback | Many small TCP connections share a receiver but have independent congestion windows. The new driver observations make controlling their combined bursts a stronger hypothesis. This develops the earlier pacing idea with transport feedback; it is not a newly discovered category. | A bounded shared budget with sparse ACK/retransmission/RTT sampling; preserve fairness, cancellation and original deadlines. Measure failures, valid throughput, both latency quantiles, CPU and memory against retained ZHTPS and Go. A fixed-rate candidate already failed this tradeoff. |
| 2 | Localize receiver/NIC loss with sequence-level ingress or reliable short-interval hardware counters | This is a diagnostic prerequisite for choosing a deployment mitigation. The available evidence reaches the transmit driver but cannot distinguish its NIC from the path or receiver. | Correlate the same failed byte range at client ingress, or verify counter width, resets and sample intervals before deriving loss counts. Never guess a wrap correction. Receiver placement and RPS were already considered and are not new findings. |
| 3 | Negotiate ECN with participating clients and paths | It can replace eligible congestion drops with marking. Current trials have zero ECN marks; the existing accept-only endpoint configuration does not make clients request negotiation. | Verify negotiation and actual marks, then compare failure and latency results. It requires endpoint/deployment participation and cannot resolve every downstream loss mechanism. |

Adaptive pacing is still an untested hypothesis. Per-connection feedback also
has syscall and sampling costs, and its control loop must account for traffic
generated by TCP retransmissions outside application send scheduling. A shared
destination budget needs bounded storage and fair service across workers;
replacing timeouts with rejects would not satisfy the failure objective.

The retained thin-stream retry policy remains the only newly adopted timeout
mitigation from this investigation. Fixed-rate send pacing is discarded after
24 trials because its modest failure-count reduction came with CPU, memory and
median-latency costs. Ten-microsecond server NAPI polling is discarded after
18 trials: offered read timeouts tied at 14, saturated read timeouts tied at
one, and whole-server CPU rose 80–84%. Lowering the minimum RTO to 50 ms alone
was also discarded after increasing failures and queue drops.
[Retained retry policy](tcp-read-timeout-mitigation.md),
[pacing result](send-pacing.md), [NAPI result](napi-polling.md),
[minimum-RTO result](read-timeout-rto50.md).

Every tied and unfavorable comparison remains open. There is no claim of
zero remaining timeouts or completion of the broader Go performance goal.
