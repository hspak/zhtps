The [follow-up implementation assessment](architecture-implementation.md) records
which of these baseline decisions were changed, their measured results, and why
the remaining proposals were skipped.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

ZHTPS's worker architecture is not fundamentally broken. The apparent parity
with Go at high connection counts conceals a large CPU-efficiency advantage:
at approximately 100,000 responses/s over 8,192 connections, ZHTPS uses **5.11 µs
of process CPU per response versus Go's 21.97 µs**. Both encounter retransmission
stalls as load rises. Go spends substantially more CPU to deliver similar
saturation throughput; its garbage collector has not somehow become free.

There are architectural costs worth addressing, especially memory provisioning,
I/O lifetimes, and application scheduling. Their impact must be separated from
the packet path limiting this particular benchmark. This review ranks the
findings below, including conditional production issues and the counterevidence
against tempting rewrites. It does not assign invented throughput percentages to
changes that have not been implemented and measured.

The comparison uses the existing ReleaseSafe binary, 16 workers, 2,048 public
slots and active permits per worker, default completion budget 64, access logging
off, and connection turnover disabled. Go uses its original optimized baseline
binary and **GOMAXPROCS=32**, confirmed by runtime output. The remote generator
runs on the second physical host with GOMAXPROCS=8 and CPUs 0–7. Both serve the
same validated six-byte HTTP/1.1 response with persistent, serial requests.
This is not a general application, large-body, TLS, HTTP/2, or connection-churn
comparison. The source hashes and exact commands accompany every measured run.

Each of three trials gradually opens all 8,192 connections during a ten-second
1,000/s phase, then offers 100k, 200k, and 300k requests/s for six seconds each.
Server order rotates. Entries below are medians of trial statistics; quantiles
are not pooled. Process CPU uses interior phase samples divided by full-phase
goodput and is an estimate. The longer whole-run accounting independently shows
5.10 versus 23.68 µs CPU per successful response.
[Raw trials and commands](runs/architecture.json "Summary of docs/architecture/rates-v2/manifest.json; raw artifact retired"),
[derived measurements](runs/architecture.json "Summary of docs/architecture/rates-v2/summary.json; raw artifact retired").

| Offered requests/s | ZHTPS goodput | Go goodput | ZHTPS CPU µs/response | Go CPU µs/response | ZHTPS service p99 | Go service p99 |
|---:|---:|---:|---:|---:|---:|---:|
| 100,000 | 99,886/s | 99,859/s | 5.11 | 21.97 | 0.158 ms | 1.425 ms |
| 200,000 | 199,238/s | 199,791/s | 5.18 | 22.70 | 0.313 ms | 4.751 ms |
| 300,000 | 299,358/s | 293,575/s | 5.04 | 25.16 | 220.201 ms | 448.791 ms |

At 100k/s neither server's interior sampling interval records retransmissions,
and there are no client failures. At 200k/s ZHTPS records none in those intervals;
Go records 482–810 retransmitted segments. ZHTPS's 200k/s p99 varies from 0.264
to 5.177 ms, so the median is not a guarantee. At 300k/s ZHTPS records
1,915–34,363 retransmitted segments and Go records 113,004–118,209. Go has
119–240 client read timeouts per trial in that phase. ZHTPS has no client
failures in these fixed-rate trials, but has a 220 ms p99 in two of three
300k/s trials. Zero counted retransmissions in an interior interval does not
mean no loss anywhere in the entire phase.

Unsent offers remain counted: median generator queue drops plus expired offers
are 676/833 for ZHTPS/Go at 100k, 4,541/1,227 at 200k, and 3,812/32,021 at 300k,
out of 600k, 1.2M, and 1.8M intended offers respectively. Successful-request
latency excludes failures; goodput counts validated completions inside the
window. These short experiments diagnose costs and failure modes, not sustained
zero-error capacity.

The first gate is outside the HTTP implementation: **the benchmark is sensitive
to packet loss and NIC/CPU topology**. The server exposes one receive queue and
one transmit queue, with 256 RX and TX descriptors, IRQ 103 on logical CPU 24,
RPS disabled, and negotiated Ethernet pause disabled. The link is 2.5 Gb/s,
full duplex, MTU 1500. Tiny requests can encounter packet-processing or burst
limits before a byte-throughput ceiling. The observed hundreds-of-milliseconds
tails coincide with TCP retransmissions and timeout counters. They are not
evidence that parsing or GC took hundreds of milliseconds.
[NIC evidence](runs/architecture.json "Summary of docs/architecture/nic.json; raw artifact retired"),
[two-host environment](go-comparison-lan.md).

This does **not** localize every lost packet to the server NIC: the client,
switch path, driver, and queueing remain possible contributors. Nor is the IRQ
CPU continuously at 100%: its average busy fraction is around 0.73 in several
lossy intervals. Brief overruns can coexist with average CPU headroom. A
different, independently characterized packet path and a paced offered-load
sweep are prerequisites for claiming a new server throughput ceiling. Simply
adding RSS queues or configuring XPS is not an available fix for this one-queue
device; Linux's documentation explicitly notes that XPS has no effect with a
single transmit queue.
[Linux network scaling documentation](https://docs.kernel.org/networking/scaling.html).

The following is the implementation/deployment priority ranking. “High” names
the affected dimension, rather than promising the same percentage increase in
requests/s. Rows marked conditional are architectural limitations under the
specified workload, not established causes of the built-in GET result.

| Rank | Decision | Possible impact and evidence | Direction |
|---:|---|---|---|
| 1 | Worker placement is unrestricted unless explicitly configured | **High, measured CPU/latency impact.** Sharing the NIC IRQ's L3 on separate physical cores saves about 22% process CPU and 42% p99 versus the other L3 at 200k/s. | Use the existing placement support in deployment and benchmark defaults; account for IRQs, cache domains, and SMT. |
| 2 | Worst-case connection buffers and ring capacity are reserved per worker | **Very high memory/capacity impact; throughput benefit unproven.** About 5.44 GiB RSS in ReleaseSafe versus Go's 0.26 GiB, with an important build-mode caveat below. Ring reservations also prevented the original 32-worker setup from starting. | Separate connection-count limits from active buffer and pending-operation budgets; use bounded lazy pools. |
| 3 | Every ordinary receive and send has its own completion-driven lifecycle | **Moderate CPU opportunity, uncertain throughput gain here.** About 2.018 SQEs and CQEs per completed request. Previous HTTP multishot experiments show modest, workload-dependent gains and regressions. | Prototype a bounded receive/write fast path or selective multishot with realistic ownership and pool limits. |
| 4 | Generated applications use fixed OS-thread executor lanes owned by each network worker | **Potentially high under blocking or mixed handlers; absent from this benchmark.** Separate head/response tasks cross mutex queues and eventfd notifications; one default thread per lane can cause head-of-line waiting. | Decouple application scheduling from socket ownership and benchmark mixed fast/slow routes. |
| 5 | Socket ownership, application queues, and admission capacity cannot share spare worker capacity | **Potentially high under skew; low evidence of harm in this uniform test.** Worker request counts are only about −13% to +11% from their mean. | Retain cheap socket ownership; balance new connections and make application capacity usable across workers where justified. |
| 6 | Custom-response lifetimes prevent the existing pipeline aggregation optimization | **Moderate to high for pipelined custom workloads; zero for these serial requests.** Built-in aggregation already improved earlier depth-8/32 tests by 34%/43%. | Define an explicit owned response/cleanup contract that permits safe batching for eligible custom applications. |
| 7 | Access logs drain through a shared sink with bounded worker queues | **Potentially high with logging enabled; zero here.** A prior one-core default-logging comparison dropped about 7.8 million ZHTPS records. | Measure required log completeness and sink capacity; consider a dedicated batched drain and cheaper record representation. |
| 8 | Completion processing uses a fixed count budget followed by submission | **Low demonstrated benefit from changing the knob.** Nine new trials with budgets 16/64/256 all remain lossy, with overlapping throughput ranges. | Change batching/fairness policy only after packet-path isolation and matched-rate evidence. |
| 9 | Every request pays fine-grained timing, metrics, normalization, and generic HTTP processing | **Small to moderate CPU opportunity, limited total headroom.** Clock sampling is about 15% of userspace samples, roughly 5% of process CPU; parsing is part of an inlined hot region. | Profile individual costs, reuse timestamps where semantics allow, and preserve protocol/security behavior. |
| 10 | A 10 ms tick scans active connections; accept uses one outstanding operation per listener and a small default backlog | **Conditional at very large idle populations or high churn; low here.** Prior 4,096-idle scans consumed only 11–14 ms CPU per ten seconds. Persistent-load results do not implicate accept throughput. | Test idle scale and churn separately before introducing timer wheels or multishot accept. |

Rank 1 has fresh causal evidence with matching worker counts and capacities.
Seven workers pinned to CPUs 9–15 share the IRQ's L3 while avoiding CPU 24 and
its SMT sibling 8. The comparison uses seven workers on CPUs 1–7, in the other
L3, with the same 4,096 slots per worker. Three trials per placement rotate
order, gradually connect 8,192 clients, and then offer 200k requests/s for ten
seconds. There are no client failures, no reconnections after setup, and no
server retransmissions in the interior measured intervals.

| Placement | Median CPU µs/response | Median service p99 | Median whole-server busy cores |
|---|---:|---:|---:|
| Other L3, CPUs 1–7 | 5.694 | 0.848 ms | 2.031 |
| NIC L3, CPUs 9–15 | 4.426 | 0.492 ms | 1.402 |

That is 22.3% less process CPU, 42.0% lower p99, and 31.0% less whole-host busy
CPU, including IRQ work and other host activity. These percentages compare
placements, **not seven workers against the unrestricted sixteen-worker
baseline**. Goodput is about 198k/s in both placements; this is an efficiency
and latency result at a matched offered rate. The earlier single-worker
experiment independently found a large locality benefit.
[Fresh placement trials](runs/architecture.json "Summary of docs/architecture/placement/summary.json; raw artifact retired"),
[existing deployment helper](../deploy/worker_cpus.py),
[placement support](nic-placement.md), [earlier experiments](kernel-work.md).

Rank 2 follows directly from resource lifetimes. Each configured slot reserves
32 KiB header storage, 8 KiB trailers, 8 KiB normalized path, 16 KiB receive,
32 KiB output, and 64 KiB application storage: **160 KiB plus 448 bytes padding**,
in addition to an approximately 13 KiB Connection record. The reservations are
made for all 32,776 configured slots, including unused slots, even though the
test has only 8,192 public connections. Go has no equivalent fixed reservation
for 32k slots in this fixture; that capacity-policy difference is part of the
memory comparison, not a claim about equal per-live-connection objects.
[Configuration](../src/Config.zig),
[allocation and slicing in Worker.initApplication](../src/server/worker.zig).

Build mode materially affects the RSS headline. Zig's allocator initializes
allocated bytes to `undefined`; safety-enabled compilation can materialize
poison writes. Two alternating-order diagnostic pairs at 100k/s rebuild the
same source as ReleaseFast and retain the exact buffer-capacity design.
ReleaseSafe RSS is 5,571 MiB before and after traffic. ReleaseFast starts at
437–439 MiB and reaches 1,728–1,732 MiB after exercising all 8,192 connections:
**about 1.69 GiB**, still about 6.5 times Go's 266 MiB in the original comparison.
That cross-build RSS check is distinct from the headline CPU trials; the two
ReleaseFast CPU estimates vary from 5.00 to 5.90 µs/response and establish no
throughput improvement. No client failures occur in these four diagnostics.
[Build-mode trials](runs/architecture.json "Summary of docs/architecture/build-mode/summary.json; raw artifact retired"),
[build receipt and allocator source hash](runs/architecture.json "Summary of docs/architecture/build-mode/build.json; raw artifact retired"). Consequently,
the entire ReleaseSafe-versus-Go RSS gap must not be attributed to live useful
HTTP state. ReleaseFast still reserves the same virtual buffer capacity; OS
demand paging does not provide an application-level pool or admission policy.

There are two separable changes here. First, allocate large scratch/output/body
storage on demand from bounded worker pools and release it when its borrowed
references and pending I/O permit. Keep protocol limits independently enforced:
a 32 KiB permitted header need not consume 32 KiB on every idle connection.
Second, size and validate ring resources against simultaneous operations rather
than multiplying a worst-case reservation at every worker-count change. The
current CQ is `nextPowerOfTwo(4 * slots + 64)`; 2,048 public slots select a
16,384-entry CQ, while 1,024 select 8,192. The earlier 32-worker attempt failed
on ring 29 under the 8 MiB memlock limit. Its successful retry reduced per-worker
capacity and CQ size, so it was not a pure worker-count experiment.
[32-worker evidence](go-comparison-lan-workers32.md).

This design deliberately buys predictable ownership and no general allocator
use while serving. A replacement must preserve bounded overload behavior,
handle pool exhaustion explicitly, and retain buffers through send/cancel
completion. It should not simply replace reservations with unlimited allocation.
Moving parser scratch out of the Connection alone is insufficient: that was
already tested, reduced cache misses, and improved high-connection throughput
by only about 0–2%. It retained the large buffers. ReleaseSafe reset also does
**not** clear all 12 KiB of parser scratch on every request.
[Footprint experiments and reset disassembly](request-footprint.md).

Rank 3 concerns the dependency chain, not the choice of language or the mere
presence of io_uring. A request normally follows receive CQE → parse/handler →
send SQE → send CQE → request cleanup/reset → receive rearm. Buffers and
application metadata remain owned until completion. Go's network FD code tries
the nonblocking read/write syscall immediately and parks a goroutine on poll
readiness only after EAGAIN; a successful write can advance without another
userspace completion-dispatch turn. However, a ZHTPS send CQE does not wait for
the peer's TCP acknowledgement, and Go has its own polling, locking, and
scheduling overhead. Serial request/response latency alone does not establish
that this dependency is expensive enough to warrant a new backend.
[Worker.queueReceive, queueSend, and sent](../src/server/worker.zig),
[Go FD implementation](https://go.dev/src/internal/poll/fd_unix.go).

The existing multishot HTTP prototype is important counterevidence. A sufficiently
large pool yielded about 6% throughput improvement and 10% less CPU at 4,096
connections on one worker, but no multicore throughput gain, added 128 MiB of
pool storage per worker, and regressed echo CPU in separate tests. Fewer SQEs
are not automatically less total work. Fixed files, SQPOLL, zero-copy send for
tiny responses, and vectorized send already failed to demonstrate a broadly
useful replacement. A selective fast path should first beat these results on
full HTTP and the request/body/cancellation workload matrix.
[Kernel-work measurements](kernel-work.md),
[remaining request-path experiments](request-path-remaining.md).

Ranks 4 and 5 matter most when this becomes a real application server. Generated
endpoints mark the application isolated. Each network worker owns its own
executor with default one-thread, 64-task lanes. Head and response are distinct
tasks, and completions notify the network loop through an eventfd. A slow call
occupies a lane thread; another worker's idle lane cannot help. Timeout checks
before and after execution do not preempt a currently blocked callback.
The built-in benchmark application bypasses this executor entirely, so these
costs cannot explain the measured parity.
[Endpoint lane defaults](../src/endpoint.zig),
[ApplicationExecutor](../src/server/worker.zig).

Go's useful inspiration is the separation of a logical connection task from an
OS thread: ordinary pollable network waits park its goroutine and the scheduler
can run or steal other runnable work. It is not one OS thread per connection.
For ZHTPS, a bounded application task pool shared across network workers, or an
explicit cooperative asynchronous application interface, could address uneven
or blocking work while preserving each socket's single owner. First measure a
small fraction of slow handlers mixed with fast handlers, uneven hot connections,
queue delay, rejection rates, and total thread count. A new global lock on every
tiny request would sacrifice a current strength without evidence.
[Go connection dispatch](https://go.dev/src/net/http/server.go),
[Go scheduler source](https://go.dev/src/runtime/proc.go).

Rank 6 is about ownership contracts. Built-in response aggregation already
copies complete responses into bounded 4 KiB batches, at most sixteen responses.
It operates only when requests are already buffered and admission permits it.
Custom exchanges can retain borrowed metadata and cleanup callbacks through
send completion, so `can_batch = App == application` deliberately excludes
them. Extending that optimization needs explicit transfer or copying of all
required response state and well-defined cleanup timing. It cannot combine
serial responses from different TCP connections into one TCP packet.
[Integrated batching and its measured gains](response-aggregation-integrated.md),
[ResponseBatch](../src/server/ResponseBatch.zig).

Rank 7 is an operational throughput/completeness tradeoff. A shared log descriptor
has a shared atomic owner and bounded per-worker record buffers; the sink still
has one physical drain rate. Full queues drop records. Increasing worker count
cannot make that sink arbitrarily faster. Access logging was disabled in all
new diagnostic runs and in the relevant multicore comparisons, while metrics
and admission remained enabled. Any logging redesign should benchmark actual
required record delivery, rather than report high HTTP throughput while silently
discarding the required output.
[Original comparison and logging drops](go-comparison-lan.md),
[Logger](../src/Logger.zig), [worker drain coordination](../src/server/worker.zig).

Rank 8 has a fresh negative screen: budgets 16, 64, and 256 produced median
goodput of 350,609, 361,130, and 365,001/s, respectively, in three rotated-order
five-second trials each at 8,192 connections. Trial ranges overlap; every run
has client failures and roughly 220–312 ms p99. The nominal 1.1% median advantage
of 256 over 64 is not evidence of a clean capacity improvement. Completion
batch size can alter submission bursts, fairness, and overhead, but that
requires a better isolated test before changing the default.
[Completion-budget trials](runs/architecture.json "Summary of docs/architecture/completion-budget/summary.json; raw artifact retired").

Ranks 9 and 10 are lower priorities because measured cost constrains their
upside. ZHTPS spends about 65% of process CPU in the kernel in the new mixed-rate
runs, before counting separate IRQ work. Eliminating all userspace cost would
therefore save only about 35% process CPU, for an idealized CPU-bound speedup of
about 1.5×; it does not remove the current lossy transport ceiling. The fresh
userspace profile attributes 35.6% of sampled cycles to `processInput`, which
includes inlined parser and request-path work, and 13.5% to the vDSO clock plus
1.9% to its wrapper. Those percentages are not percentages of end-to-end CPU,
and `processInput` is not a pure-parser measurement.
Userspace profile.

Metrics recording is already worker-owned load/store accumulation, not a global
atomic read-modify-write or histogram mutex on every request. Admission is also
worker local and was inexpensive in component measurements. Active-slot scans
replaced capacity-wide scans already. The default 1,000-request connection
turnover and listener backlog can matter in a churn workload, but turnover is
overridden in these runs and the fixed-rate intervals do not show listen drops.
Removing instrumentation, adding a timer wheel, increasing backlog, or replacing
the parser should not precede evidence for their intended workload.
[Metrics recorder](../src/Metrics.zig),
[measured remaining costs](request-path-remaining.md).

Go's strongest memory lesson is to make common-case storage small and reusable:
`net/http` pools a default 4 KiB buffered reader and 2/4 KiB buffered writers;
its configured maximum header size is a limit, not that much storage allocated
for every idle socket. It still allocates request/context/response/header objects,
flushes buffered responses, schedules goroutines, and performs background reads
for disconnect detection. The exact installed Go 1.27.1 source was inspected,
with [source hashes retained](runs/architecture.json "Summary of docs/architecture/go-source-manifest.json; raw artifact retired"); the official
online sources may track a different revision.
[Go HTTP source](https://go.dev/src/net/http/server.go).

The separate Go CPU profile at 200k/s confirms real runtime expense. Over about
3.0 million successful requests it allocated 6.84 GB cumulatively, completed
93 GC cycles, and reported 13.56 CPU-seconds of GC work. Aggregate stop-the-world
pause time was only 14.2 ms over the entire diagnostic run. Concurrent GC work
and allocation cost CPU without requiring long global pauses. `GCCPUFraction`
is normalized to available GOMAXPROCS capacity; its 0.0165 value must not be
misread as only 1.65% of the process's busy CPU. Runtime-class accounting and
pprof sampling have different boundaries and are not added together here.
Go profile,
runtime counters,
[Go's GC cost model](https://go.dev/doc/gc-guide).

The next implementation work should be a bounded storage-pool design with
separate connection, active-buffer, and ring-operation budgets, alongside using
the existing topology-aware placement in deployment. Benchmark that change on
a low-loss offered-load curve and compare CPU, resident/virtual memory, p99,
rejections, and validated goodput. Then investigate the I/O fast path. Before
optimizing generated applications, add the mixed-handler workload that can
expose their executor design. The current evidence supports retaining private
socket ownership and the io_uring backend while making these targeted changes.

All new server traffic was generated against the two authorized hosts; no
host-wide IRQ, NIC, sysctl, or GC settings were changed. Server runtime source
was not edited. Added files provide the diagnostic harness, optional Go profile
build, accounting audit, and this report. The profile build is separate from
the uninstrumented Go throughput baseline. Existing server tests were not
rewritten or weakened.

The [integrity audit](runs/architecture.json "Summary of docs/architecture/audit.json; raw artifact retired") checks source/binary provenance,
separate-host identity, runtime settings, connection counts, sample windows,
and request accounting. It deliberately preserves and reports client failures.
Two earlier diagnostic attempts remain excluded from aggregate comparisons:
the first rate collection lost its final client result during an FD-sampling
race, and the Zig profile harness initially treated the expected SIGINT exit of
`perf record` as a failed run. That profile's load result and readable perf file
were retained; `perf report` reports zero lost samples. The profile is used only
for approximate userspace attribution, not as another clean throughput trial.
The sampler and perf-exit handling were corrected, and the measured harness
versions are archived beside their manifests. All 26 completed diagnostic trials
pass the provenance/accounting audit; the two excluded attempts remain recorded.
Python syntax, Go formatting, and local report links were checked. Final host
snapshots confirm no benchmark server, load client, or profiler remains running:
[server cleanup](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/server-architecture-after.json; raw artifact retired"),
[client cleanup](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/client-architecture-after.json; raw artifact retired").

Fresh kernel call-stack profiling was unavailable under this host's current
perf restrictions. Process system CPU and both hosts' TCP/NIC/softirq counters
are available; older kernel profiles are supporting context, not fresh proof of
a particular kernel lock bottleneck. Nonmonotonic NIC missed-packet counters
are not used as exact loss totals. Upstream r8169 exposes a 16-bit missed-packet
counter, which can explain wrapping, but an exact loss total would additionally
require matching the installed driver and ruling out resets/multiple wraps.
[Driver source](https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/r8169_main.c).

Reproduction starts with the existing benchmark binaries and a working
second-host SSH configuration:

```sh
python3 bench/architecture.py --output /tmp/zhtps-architecture-rates \
  --schedule 1000:10s,100000:6s,200000:6s,300000:6s
python3 bench/summarize_architecture.py /tmp/zhtps-architecture-rates
```

Use `--worker-cpus 9-15 --workers 7 --capacity 4096` or `--worker-cpus 1-7`
for the placement comparison only after verifying the host's current topology.
Use `--profile` with the separately built optional Go profiling binary for
diagnostics. All exact invocations and source snapshots are retained in
`docs/architecture`; no benchmark result requires assuming the latest harness
is byte-identical to the one that recorded it.
