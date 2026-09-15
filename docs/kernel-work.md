# Kernel work experiments

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Follow-up: [NIC-aware worker placement](nic-placement.md) is now implemented.
[The aggregation revisit](response-aggregation-v2.md) evaluates bounded packet
coalescing and a fallback for small admission budgets. The subsequent
[main-server integration](response-aggregation-integrated.md) adds a startup pool,
owned access-log records, and completion-lifetime tests. The measurements and
baseline descriptions below refer to the original experiment pass.

This pass tests bounded HTTP multishot receive, aggregation of pipelined HTTP
responses, worker placement relative to a physical NIC, and newer vectorized-send
and receive-bundle APIs. The baseline includes the previously retained buffer
placement padding. Runtime candidates remain isolated in `/tmp/zhtps-kernel-work`;
[source snapshots and build records](runs/kernel-work.json "Run summaries from docs/kernel-work/snapshots; raw artifacts retired") preserve each version.

The server is the Ryzen AI Max+ 395 host `benchmark-server`, running kernel
`7.2.4-arch1-2-strixhalo`. Builds use Zig 0.16.0, ReleaseSafe, and x86-64-v4.
The physical generator is `client.example` (`benchmark-client`, Ryzen 7 8745HS).
Traffic uses the direct LAN: `192.0.2.20` to `192.0.2.10`.
Both links negotiate 2.5 Gb/s. Server `server_eth0` uses r8169 and exposes one RX
queue and one TX queue; channel reconfiguration is unsupported. RPS is disabled.
IRQ 103 runs on logical CPU 24, the SMT sibling of physical CPU 8. CPUs 8–15
share its L3; CPUs 0–7 use the other L3. No IRQ affinities, offloads, queue settings,
or persistent sysctls were changed by the experiments.
[Server topology](runs/kernel-work.json "Summary of docs/kernel-work/server-host.json; raw artifact retired"),
[generator topology](runs/kernel-work.json "Summary of docs/kernel-work/client-host.json; raw artifact retired"),
[client provenance](runs/kernel-work.json "Summary of docs/kernel-work/client-provenance.json; raw artifact retired").

The user temporarily changed `kernel.perf_event_paranoid` from 2 to 1.
Kernel-mode PMU counters and stack sampling now work. Counter events are
`cycles:k`, `instructions:k`, `cycles:u`, `instructions:u`, context switches,
and migrations. The recorded event running percentages are checked against
multiplexing. Separate CPU-core and network snapshots capture work that moves
outside process CPU accounting.

A crucial accounting distinction: per-task PMU samples include synchronous
softirq execution while a server thread is current. `/proc/PID/stat` process CPU
and `/proc/stat` softirq CPU are separate accounting categories on this host.
For example, the initial 64-client baseline records 4.52 process CPU seconds,
while CPU 2 also spends 2.46 seconds in softirqs during that interval. PMU cycles
must not be divided by process CPU time to infer a clock frequency. The profiles
also omit work on a separate IRQ CPU or ksoftirqd thread when the server is not
current. Whole-host CPU includes the local load generator and unrelated activity.

Closed-loop comparisons use three rotated-order trials, two seconds of warmup,
and five measured seconds. The small case has 64 clients and one worker on CPU 2;
the many case has 4,096 clients and one worker on CPU 2; the multicore case has
16,384 clients and eight workers pinned individually to CPUs 0–7. Client CPUs
are 4–7 for one worker and 8–15 for eight workers. Each trial verifies responses,
connection participation, no reconnections, clean server shutdown, and zero
server rejections, aborts, protocol errors, timeouts, and I/O errors. Goodput is
measured-window completions; CPU and operation counts use the server completion
delta across setup, warmup, and drain. These are different cohorts.

The baseline profiles locate substantial kernel cost in socket locking, TCP
connection lookup, packet-buffer handling, timer locking, and wakeups. At 64
clients `_raw_spin_lock_irqsave` has 3.40% self samples; at 4,096 it has 9.26%,
and with eight workers 11.47%. This is time in that function, not proof that all
of it is lock contention. The caller stacks show response transmission executing
loopback receive softirqs, Go-client epoll wakeups, and TCP timer updates. Thus
some kernel time attributed to the server in the local benchmark serves the
client's side of the same loopback connection. Physical-LAN placement tests are
needed to separate those effects. Kernel instructions grow much less than cycles
between the small and many cases, consistent with greater cost per instruction;
these samples do not establish a particular L3- or TLB-miss rate.
Small profile,
many profile,
multicore profile,
lock caller stacks.

The multishot prototype retains private receive buffers for fallback and admin
traffic. A nonincremental, worker-owned ring supplies up to 1,024 buffers, each
16 KiB. A connection owns its current fragment and a bounded queue; excess
read-ahead triggers cancellation, and pool exhaustion falls back to ordinary
receive so a connection can make progress. Cancellation, EOF, parser input,
application borrows, shutdown, and pool recycling are integrated into the actual
HTTP worker. The bundle variant additionally tracks ring order and owns every
buffer described by a multi-buffer CQE. Bundles exposed a parser scheduling bug:
it could request kernel input while another fragment was already queued. The
existing oversized-header wire test reproduced the failure; consuming queued
fragments first fixes it. Both the initial failing artifact and corrected source
are retained. No existing test was weakened.

Compiled connection sizes are 13,096 B for baseline, 13,144 B for multishot and
bundles, 13,104 B for aggregation, and 13,040 B for vectorized SEND. Multishot
also adds a 16 MiB pool per worker in these cases. Aggregation adds a pointer;
its 4,648-byte batch allocation is lazy, reused until connection close, and only
needed by pipelined connections. Vectorized SEND removes the 56-byte `msghdr`
while retaining the two iovecs. Compiled offsets and a static field-coverage
model are available in the layout records.
The coverage model is not a dynamic trace and excludes additional accesses
introduced by each experiment.

The aggregation prototype copies up to 16 completed serializations into a 4 KiB
buffer and sends them together. It keeps each request's admission permit until
its bytes complete, accounts partial sends, flushes before waiting for more input,
and preserves order around interim responses, streams, large bodies, and close.
To bound this experiment, aggregation is enabled only for the built-in application
with access logging disabled. Custom application release hooks and borrowed log
metadata would require a fuller deferred-completion representation before a
general implementation could be considered. Admission pressure can force earlier
flushes, so both the ordinary 192-permit budget and a larger 1,024-permit budget
are compared against matching baselines.

Vectorized SEND uses `IORING_SEND_VECTORIZED` with persistent iovecs in place of
SENDMSG for a separate header and body. It does not change the tiny GET's existing
single-buffer SEND. Receive bundles combine multiple supplied buffers in a single
receive CQE. The 64 KiB echo workload verifies both request and expected-body
hashes and byte counts, and uses the offered-rate client; the older closed-loop
GET client does not apply its body flags. API semantics are documented by
[liburing's send manual](https://kernel.googlesource.com/pub/scm/linux/kernel/git/axboe/liburing/+/refs/heads/master/man/io_uring_prep_send.3)
and [receive manual](https://kernel.googlesource.com/pub/scm/linux/kernel/git/axboe/liburing/+/refs/heads/master/man/io_uring_prep_recv.3).
The prototypes exercise the installed kernel; they are not compatibility fallbacks
for older kernels.

Corrected receive results (medians):

| Clients / workers | Variant | Requests/s | Process CPU/response | p99 |
|---|---|---:|---:|---:|
| 64 / 1 | baseline | 517,966 | 1.245 µs | 0.207 ms |
| 64 / 1 | multishot | 519,402 | 1.244 µs | 0.231 ms |
| 64 / 1 | bundle | 519,889 | 1.245 µs | 0.228 ms |
| 4,096 / 1 | baseline | 159,887 | 4.325 µs | 27.656 ms |
| 4,096 / 1 | multishot | 169,425 | 4.048 µs | 38.273 ms |
| 4,096 / 1 | bundle | 148,575 | 4.551 µs | 44.564 ms |
| 16,384 / 8 | baseline | 752,430 | 5.661 µs | 28.967 ms |
| 16,384 / 8 | multishot | 752,867 | 5.380 µs | 28.705 ms |
| 16,384 / 8 | bundle | 747,670 | 5.462 µs | 29.098 ms |

[Receive comparison](runs/kernel-work.json "Summary of docs/kernel-work/receive-counters-v2/summary.json; raw artifact retired"). Multishot reduces submissions from approximately two to one per request at 64 clients and with eight workers, while CQEs remain near two. At 4,096 clients, fallback traffic brings submissions back near two and completions rise to about 2.5. The multicore process-CPU reduction is about 5%; worker-core busy time including softirqs falls about 3%, and total-host busy time about 1%. Throughput stays essentially flat. The many-client p99 regression prevents selecting this as the default.

For 64 KiB echoes at 20,000 offered requests/s (after 2,000/s warmup):

| Variant | Process CPU/response | Kernel instructions/response | Service p99 |
|---|---:|---:|---:|
| baseline | 8.462 µs | 48,867 | 352 µs |
| multishot | 9.521 µs | 47,119 | 436 µs |
| bundle | 9.713 µs | 45,059 | 463 µs |
| vector | 8.269 µs | 48,642 | 356 µs |

[Echo comparison](runs/kernel-work.json "Summary of docs/kernel-work/echo-offered-counters/summary.json; raw artifact retired"). Multishot cuts approximately six submissions to one per echo; bundles also cut approximately six CQEs to three. Nevertheless, process CPU increases by roughly 13% and 15%, respectively. Fewer entries are not sufficient evidence of less execution time. Vectorized SEND saves about 2.3% median CPU here, but trial results overlap and the third paired trial regresses; its small instruction reduction does not establish a repeatable material win.

Pipelined responses, with 64 connections (medians):

| Depth | Write fragment | Permits | Variant | Responses/s | Process CPU/response | SQEs/response |
|---:|---:|---:|---|---:|---:|---:|
| 8 | whole batch | 192 | baseline | 1,320,679 | 0.662 µs | 1.125 |
| 8 | whole batch | 192 | batch | 872,864 | 0.891 µs | 0.538 |
| 32 | whole batch | 192 | baseline | 1,469,266 | 0.611 µs | 1.031 |
| 32 | whole batch | 192 | batch | 819,929 | 0.931 µs | 0.507 |
| 8 | 8 | 192 | baseline | 526,571 | 1.443 µs | 1.489 |
| 8 | 8 | 192 | batch | 540,588 | 1.398 µs | 0.831 |
| 8 | whole batch | 1024 | baseline | 1,343,966 | 0.650 µs | 1.125 |
| 8 | whole batch | 1024 | batch | 1,628,667 | 0.527 µs | 0.250 |
| 32 | whole batch | 1024 | baseline | 1,472,865 | 0.610 µs | 1.031 |
| 32 | whole batch | 1024 | batch | 2,082,304 | 0.437 µs | 0.094 |

[Pipeline comparison](runs/kernel-work.json "Summary of docs/kernel-work/pipeline/summary.json; raw artifact retired"). Each budget has a matching baseline; the larger budget also requires a larger configured connection capacity. These are separate comparisons. The ordinary budget forces short aggregates, while the baseline already coalesces TCP output with MSG_MORE. The larger budget allows fuller aggregates and yields a useful gain for this workload. The implementation is not selected as a general default because it regresses the ordinary complete-pipeline workload and deliberately excludes custom applications and access logging.

A larger multishot pool tests the exhaustion explanation. Raising the cap from 1,024 to 8,192 buffers adds 128 MiB of pool storage per worker in the large-capacity cases. A short verbose diagnostic records ENOBUFS with the original pool; logged counts are lower bounds because verbose records are dropped under load. The larger pool has no observed ENOBUFS in that diagnostic, and its submission/completion ratios provide a separate check during the uninstrumented comparisons.

| Clients / workers | Variant | Requests/s | Process CPU/response | p99 | RSS |
|---|---|---:|---:|---:|---:|
| 4,096 / 1 | baseline | 166,755 | 4.115 µs | 27.001 ms | 1,385 MiB |
| 4,096 / 1 | multishot-large-pool | 177,366 | 3.694 µs | 24.510 ms | 1,514 MiB |
| 16,384 / 8 | baseline | 751,563 | 5.717 µs | 28.836 ms | 5,558 MiB |
| 16,384 / 8 | multishot-large-pool | 741,007 | 5.489 µs | 29.098 ms | 6,584 MiB |

[Larger-pool comparison](runs/kernel-work.json "Summary of docs/kernel-work/large-pool-counters/summary.json; raw artifact retired"), functional diagnostic. This corrects the many-client tail regression, but does not improve eight-worker throughput and increases its RSS by about 1 GiB. The 64-client echo case uses the same pool size as before, so its regression remains. This is a workload-dependent prototype, not a universal replacement for ordinary receive.

A separate packet-count check explains the aggregation result. These whole-host TCP counts include requests, responses, ACKs, and background traffic, and are a single diagnostic pair per budget, not an additional repeated throughput comparison.

| Permits | Variant | SQEs/response | TCP OutSegs/response | Kernel instructions/response |
|---:|---|---:|---:|---:|
| 192 | baseline | 1.125 | 0.250 | 3,401 |
| 192 | batch | 0.543 | 0.720 | 5,258 |
| 1024 | baseline | 1.125 | 0.250 | 3,401 |
| 1024 | batch | 0.250 | 0.250 | 1,787 |

Packet evidence. Short aggregates cut ring entries but nearly triple TCP segments and increase kernel instructions. Full aggregates retain the existing packet coalescing and approximately halve kernel instructions. Reducing kernel-facing operations helps when it also preserves efficient packet formation.

The physical-LAN placement result is the strongest operational finding. The saturation screen ran four placements: IRQ CPU 24, its sibling CPU 8, another physical core in the same L3 (CPU 9), and CPU 2 across the L3 boundary. The first two clean trials per placement measured approximately 262k, 381k, 388k, and 217k requests/s respectively. The faster two placements had roughly 215–217 ms p99. A repeated same-L3 saturation run subsequently records two read timeouts and two reconnections near 390k requests/s. This is not reliable zero-error capacity.

For the controlled comparison, 4,096 connections open gradually at 1,000 requests/s for five seconds, followed by five seconds each at 50k and 100k offered requests/s. Three trials rotate placement order. All nine runs have zero HTTP/transport failures, no reconnections, and at least 99.9% successful offers in every phase. Small numbers of generator-expired or queue-dropped offers remain explicitly counted. CPU below uses matched first/last in-phase server samples and completed-request deltas; worker/IRQ time sums busy ticks on the selected worker CPU and CPU 24, without double-counting when they are the same CPU. It includes other activity on those cores and excludes the separate generator host.

| Offered rate | Placement | Goodput | Process CPU/response | Worker + IRQ core time/response | Service p99 | Offer-to-completion p99 |
|---:|---|---:|---:|---:|---:|---:|
| 50k | irq | 49,993/s | 2.200 µs | 7.600 µs | 0.262 ms | 0.416 ms |
| 100k | irq | 99,986/s | 1.800 µs | 4.950 µs | 0.291 ms | 0.362 ms |
| 50k | same_l3 | 49,976/s | 3.800 µs | 5.350 µs | 0.305 ms | 0.651 ms |
| 100k | same_l3 | 99,946/s | 3.250 µs | 4.400 µs | 0.152 ms | 0.194 ms |
| 50k | other_l3 | 49,977/s | 6.800 µs | 11.600 µs | 0.264 ms | 0.424 ms |
| 100k | other_l3 | 99,955/s | 5.625 µs | 9.275 µs | 0.219 ms | 0.244 ms |

[Fixed-rate results](runs/kernel-work.json "Summary of docs/kernel-work/physical-offered-gradual/summary.json; raw artifact retired"), matched CPU intervals, saturation timeout evidence. At 100k/s, the separate core in the NIC’s L3 uses about 42% less process CPU and 53% less combined worker/IRQ core time than the other-L3 placement. Service p99 falls about 31%. Putting the worker directly on the IRQ CPU minimizes process CPU accounting, but spends more combined core time and has worse service p99 than CPU 9. Process CPU alone would choose the wrong placement.

The physical profiles use the same gradual setup and 100k/s rate: same L3, other L3. They retain kernel stacks and raw samples, but do not cover the separate IRQ CPU completely. The one-queue NIC cannot support a measured multi-queue RSS/IRQ distribution comparison here. The useful tested setting is a separate physical worker core in the IRQ’s L3; verify actual IRQ placement again before applying that choice to another run or machine.

The initial high-rate warmup caused connection-setup timeouts and is retained as a diagnostic screen, not mixed into the gradual-setup comparison. One remote collector run also failed while sampling `/proc/PID/fd` as the client exited. The collector now preserves failed-client JSON and tolerates the observed exit-sampling race only when the child has actually exited. Two unchanged regression tests fail against the prior collector and pass after the fix.

The retained changes are the benchmark tools, evidence, remote collector fixes, and four pipeline boundary tests integrated into `zig build test-wire`. Runtime transport defaults remain the tested baseline, including the earlier buffer padding. Both Debug and ReleaseSafe pass component/declaration tests, the embedded consumer, 58 existing wire tests, and four added boundary tests. All four transport prototypes and the larger pool pass the ReleaseSafe suites; all initial four prototypes also pass the added boundaries. The remote collector suite passes all seven tests. Debug validation, ReleaseSafe validation, collector validation, regression before fix, [audit](runs/kernel-work.json "Summary of docs/kernel-work/audit.json; raw artifact retired").

The evidence supports same-L3 NIC/worker placement, a sufficiently provisioned multishot pool for selected many-connection workloads, and complete response aggregates when admission budgets allow them. It does not support an unconditional transport default change: multishot still hurts the echo workload, short response aggregates increase packet work, and vectorized SEND has only a small inconsistent timing benefit. The source snapshots make those candidates concrete for future workload-specific work.

Profiling is finished. The original paranoid value was 2; the current value remains 1 because noninteractive sudo requires a password. Restore the prior value with `sudo sysctl -w kernel.perf_event_paranoid=2`. [Cleanup record](runs/kernel-work.json "Summary of docs/kernel-work/profiling-permission.json; raw artifact retired").
