The adaptive send-pacing candidate is **discarded**. It reduced read timeout
counts and improved p99, but cut throughput by 20–30%, raised median latency
about tenfold, and nearly doubled sampled memory. The experiment and broader
performance investigation ended at the user's request on September 13, 2026.
The retained server remains `tcp-retries-v1`; unresolved comparisons and ties
are preserved rather than recorded as wins.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The decision uses 18 audited GET trials: retained ZHTPS, the isolated candidate,
and Go, with three rotated repetitions at each of two 16,384-connection loads.
The established second host generated traffic over the wired LAN. ZHTPS used
seven workers on CPUs 9–15; Go used GOMAXPROCS=32 with normal GC. Client CPUs,
the two-second deadline, response validation, and server HTTP deadlines were
unchanged. High-load phases lasted 20 seconds. No decision trial was excluded.
[Plan](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/plan.json; raw artifact retired"), [audit](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/audit.json; raw artifact retired"),
[complete comparisons](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/results.json; raw artifact retired").

Counts below total three trials; other entries are medians of trial metrics.

| Metric | Retained ZHTPS | Adaptive candidate | Go |
|---|---:|---:|---:|
| 300k offered/s: read timeouts | 21 | 3 | 5,518 |
| 300k offered/s: all HTTP failures | 21 | 3 | 5,645 |
| 300k offered/s: valid responses/s | 291,291 | 231,831 | 289,788 |
| 300k offered/s: p50 ms | 5.210 | 53.215 | 2.212 |
| 300k offered/s: p99 ms | 465.568 | 427.819 | 633.340 |
| 300k offered/s: process CPU µs/valid response | 3.726 | 7.917 | 24.865 |
| 300k offered/s: sampled RSS MiB | 456.47 | 885.03 | 502.82 |
| Saturated: read timeouts | 5 | 0 | 4,183 |
| Saturated: all HTTP failures | 5 | 0 | 4,279 |
| Saturated: valid responses/s | 322,097 | 225,590 | 308,158 |
| Saturated: p50 ms | 6.652 | 67.109 | 5.145 |
| Saturated: p99 ms | 434.110 | 270.533 | 478.151 |
| Saturated: process CPU µs/valid response | 3.414 | 8.028 | 24.080 |
| Saturated: sampled RSS MiB | 455.21 | 946.32 | 496.29 |

Offered read timeouts were 7/9/5 for retained ZHTPS and 0/2/1 for the candidate;
saturated counts were 1/2/2 and 0/0/0. The p99 gains have separated trial ranges,
as do the high-load throughput, p50, CPU and RSS regressions. Three observed
ranges are descriptive evidence, not formal confidence intervals. Zero
saturated failures does not establish a guarantee against future timeouts.

At 300k offered/s, generator misses rose from 474,134 to 4,073,230; Go recorded
548,505. Saturated setup errors were zero for all servers. Warmup errors were
3/0/1,146 for retained/candidate/Go, separate from measured failures. At 100k
and 200k offered/s both ZHTPS variants had zero HTTP failures. Lower-load
throughput and latency differences are small or overlapping; the full ledger
keeps the candidate's CPU/RSS costs, favorable 200k generator count, and all
ties. The discarded candidate does not replace the retained server's broader
[90-comparison ledger](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/comparisons.json; raw artifact retired").

The candidate shares a bounded send budget by destination IP across workers.
It starts at 500k application send submissions/s, floors at 100k, and permits
a burst of four. Sparse TCP_INFO samples drive reductions when retransmissions
exceed 1% of sampled data transmissions, with limited upward probes. This is
application submission pacing: large sends can produce multiple packets, and
kernel retransmissions are outside its scheduler. It does not enforce a
packet or byte rate at the NIC. Storage, fairness, cancellation and feedback
details are in the [design](adaptive-send-pacing/design.md).

The observed backlog explains why this policy is a poor fit in its current
form. Request storage stays owned through response completion, including time
spent queued for a pacing credit. At high offered load, the median sampled
active request-storage count rose from two to **12,037**; at saturation it rose
from one to **15,044.5**. Candidate sample peaks approached all 16,384 sockets.
Connection-buffer ownership stayed about 327 MiB in both variants and the
large-buffer gauge stayed zero. This supports retained request storage as the
main explanation for the RSS increase, rather than a large-body buffer issue.
[Storage and controller samples](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/feedback-results.json; raw artifact retired").

New request-storage allocations increased from about 115 to 6,278 per second
offered, and 67 to 3,756 per second saturated, in the interior sample windows.
The controller recorded 90 cuts and 110 increases in offered windows and
85 cuts and 129 increases in saturated windows. TCP_INFO sampling had zero
reported errors. Nearly every high-load candidate send was delayed. Counting
all retransmissions gives this controller a broader trigger than persistent
multi-retry delivery stalls; the measurements show that its resulting limit
is too restrictive for the desired tradeoff. Timer, shared-atomic and allocator
costs have not been separately profiled, so CPU cost is not attributed entirely
to any one of them.

Process CPU per valid response rose 112%/135% for offered/saturated traffic.
Whole-server busy cores fell slightly as less work crossed the network; its
estimated CPU per valid response nevertheless rose 21%/41%. Process CPU is
already part of whole-host CPU and must not be added to it. Server retransmission
rates fell about 70%/85%. These benefits accompany substantially less completed
work. Queue counters cover whole runs, including preparation and cleanup, and
cannot identify the packet behind an individual failure. Candidate offered
server qdisc drops were zero in all three runs, yet two runs still had read
timeouts. Every run recorded zero ECN marks.
[Host analysis](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/host-results.json; raw artifact retired").

Correctness validation passed 67 build steps, 106 Zig tests, 65 wire tests,
and the library/application/upload suites. New checks exercise the shared
worker limit, admin responsiveness, write-deadline cancellation, slot reuse,
and shutdown with queued output. The shared-worker wire test was subsequently
strengthened to use 32 connections and passed again; production source did
not change between those checks. The unchanged six-packet-loss regression
delivered a valid response in 1.248 seconds. An initial candidate-only activation
run was separately audited and is not one of the 18 decision trials.
Full validation,
strengthened control,
loss regression,
[immutable build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/adaptive-pacing-v1/build.json; raw artifact retired").

A read-only NIC check after the decision measurements confirmed that both
hosts configure Ethernet pause receive/transmit as disabled, with pause
autonegotiation enabled. This establishes a configuration to investigate,
not a fix or proof of switch participation. A controlled pause-flow-control
comparison would require actual negotiation and pause counters, plus checks
for throughput and delay effects on the shared link. No such configuration
change or test was performed before the user ended the investigation.
[Server NIC](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/server-nic.json; raw artifact retired"),
[client NIC](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/client-nic.json; raw artifact retired"),
[Linux pause settings and counters](https://docs.kernel.org/networking/ethtool-netlink.html#pause-get).

The named `rx_missed` counter is exported from a 16-bit field in both installed
NIC modules: disassembly loads two bytes at offset 28 and writes counter index
four. Their source-version identifiers match the loaded modules. This agrees
with the inspected upstream driver. The check establishes export width, not
reset behavior, exact missed-packet semantics for these chip revisions, or
loss totals in earlier long sampling intervals. No guessed wrap correction
has been applied. Short-interval sampling with reset checks, receiver ingress
correlation, and verified ECN participation remain untested follow-up ideas.
[Module evidence](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/nic-module-review.json; raw artifact retired"),
probe and checked ABI,
[upstream counter export](https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/r8169_main.c).
