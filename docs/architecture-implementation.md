This work assesses the ten decisions in [the architecture review](architecture-review.md)
in ranked order, implements feasible improvements with demonstrated benefits,
and records a reason for each skipped change. The original source, test, benchmark,
and deployment files are preserved in
the baseline archive, with
[file hashes](runs/architecture-implementation.json "Summary of docs/architecture-implementation/baseline-sources.json; raw artifact retired"). Preexisting
worktree and staged changes are retained.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

| Rank | Decision | Assessment and implementation status |
|---:|---|---|
| 1 | NIC/cache placement | Retained: `deploy/worker_cpus.py --exec` launches with a freshly discovered mapping. Seven synthetic/launcher tests pass, and a live seven-worker check validates HTTP, actual per-thread affinity, and signal/exit behavior. Existing matched-rate evidence establishes the performance benefit. |
| 2 | Connection buffers and ring budgets | Buffer pools retained: both ReleaseSafe and Debug component, full wire, pool-boundary, and embedded tests pass; matched-rate RSS falls 80.6% with essentially unchanged CPU. Retain the CQ bound: timeout cancellation can produce receive, send, and both cancellation CQEs for every slot; shrinking without a separate outstanding-operation admission limit would invalidate that safety bound. |
| 3 | Receive/send lifecycle | Skipped after a working, tested prototype: fewer completions did not establish a repeatable CPU or latency benefit across small and large responses. |
| 4 | Application executors | Retained shared bounded lanes and inline generated heads with no middleware. Final rotated trials reduce all-fast CPU by 20% at 50k/s and mixed-handler p99 by 83% at 2.5k/s; existing embedded and new skew/lifetime tests pass. |
| 5 | Per-worker capacity under skew | Shared application queues/threads address demonstrated skew. Retain socket-local storage/admission: no measured uniform-load benefit justifies cross-thread socket transfer or global per-request permit contention. |
| 6 | Custom-response batching | Skip a general extension: custom responses retain scratch, metadata, and cleanup through send completion. Existing serial workloads offer no batching opportunity; a safe opt-in owned-response API needs its own workload evidence. |
| 7 | Shared logging drain | Retain 16-record bounded drains. A tested 64-record prototype shows no reliable CPU, latency or record-completeness gain in twelve rotated two-host trials, including one-worker pressure. |
| 8 | Completion budget | Retain 64: existing 16/64/256 rotated trials show overlapping, lossy results. The rejected direct-send prototype supplies no reason to change completion fairness. |
| 9 | Timing and request processing | Retain current semantics: prior component measurements put all five request clock reads at ~82 ns; one cached-Date clock removal would save ~16 ns, under 0.4% of measured CPU. Existing parser/security and observability guarantees outweigh an unproven gain. |
| 10 | Deadline scans and accepts | Retain active-slot scans and ordinary accept: idle maintenance is ~0.1–0.2% of one core at 4,096 idle sockets. Existing churn experiments show multishot/larger backlogs can reduce drops while worsening p99 and goodput under pressure. |

Each retained change needs relevant correctness coverage and a repeatable benefit
in its intended dimension. A new setting alone is not evidence of an improvement.
Measured packet-loss ceilings are kept distinct from CPU and memory changes.

The placement change has [live evidence](runs/architecture-implementation.json "Summary of docs/architecture-implementation/placement-live.json; raw artifact retired").
An initial verification script used the wrong admin JSON key (`worker` instead of
`id`); the server was cleaned up and the corrected verification passed.

The buffer prototype reserves small public buffers, borrows larger buffers on
demand, and reserves full admin buffers up front. A per-worker byte limit applies
to leases, with a cache of eight buffers per size class. Allocator use on misses
and eviction is serialized across workers. Its public serving contract now
permits these cold allocations; the existing small-pipeline/admin test that
disables allocation after init remains unchanged and passes.

Exchange initialization moves from connection/request reset to admitted head
dispatch. The existing initialization test was updated for that deliberate
contract change: it still proves no initialization for unused slots, additionally
proves none for an idle request, and proves one initialization at dispatch.

The first prototype failed the existing fragmented-echo test because receive
indices were not reset when shrinking a fully consumed receive buffer. The
original test was left unchanged and passed after correcting demotion. A
separate 4 KiB initial-receive experiment reproduced the historical small-buffer
prototype's full-suite slow-reader failure. Live socket evidence shows TCP
flow-control/retransmission stalls while the server awaits the next body, so a
write deadline is not yet applicable. The original 16 KiB initial receive size
restores the existing test; it is retained. This does not establish the precise
kernel mechanism, and the deadline test has not been weakened.
[4 KiB socket/connection evidence](runs/architecture-implementation.json "Summary of docs/architecture-implementation/slow-reader-pools-live.json; raw artifact retired"),
[16 KiB full-suite result](runs/architecture-implementation.json "Summary of docs/architecture-implementation/slow-reader-pools-receive16k.json; raw artifact retired"),
[baseline full-suite result](runs/architecture-implementation.json "Summary of docs/architecture-implementation/slow-reader-baseline-suite.json; raw artifact retired").

The corrected design passes all 50 ReleaseSafe build steps,
including 89 component tests, 18 declaration checks, the separate embedded
consumer, 58 existing wire tests, ten aggregation boundaries, three live placement
tests, seven topology/launcher checks, and four new pool tests. The component
runner prints informational server-startup stderr with a `failed command` label,
but reports 89/89 passing and the build exits zero; the earlier actual failures
remain in their separate logs.

Six alternating [two-host trials](runs/architecture-implementation.json "Summary of docs/architecture-implementation/memory-rates/summary.json; raw artifact retired")
compare the preserved baseline and pooled-buffer binaries at 8,192 connections,
seven workers on CPUs 9–15, and 4,096 public slots per worker. At the median,
RSS falls from 4,864.1 to 945.9 MiB (80.6%). Process CPU estimates change from
4.695 to 4.610 µs/response at 100k offered requests/s and 4.462 to 4.408 µs at
200k/s. These small CPU differences are not claimed as a precise speedup. Every
client request sent in these trials succeeds, and the interior server/client
sampling intervals record no retransmissions. The pooled GET trials allocate
zero large buffers while serving.

The generator discards roughly 1–2% of intended offers, and latency is variable
in this block, including on the baseline. The evidence establishes the memory
reduction and no material CPU regression in this workload, not sustained capacity
or a universal latency improvement. Binary/source provenance
identifies the baseline archive separately from the new source: running an old
binary with the latest measurement harness does not make it a build of the new
source.

The immediate-send prototype first tries `sendto`/`sendmsg` with `MSG_DONTWAIT`
and `MSG_NOSIGNAL`, and retains io_uring for reads and blocked sends. Each CQ
batch permits at most sixteen synchronous sends, bounding nested pipeline work.
Partial writes retain the existing byte-offset and buffer-ownership logic.
`--no-direct-send` supplies a diagnostic fallback. Successful sends mean bytes
were accepted locally, not acknowledged by the peer.
[Linux send semantics](https://man7.org/linux/man-pages/man2/send.2.html).


Six alternating [immediate-send GET trials](runs/architecture-implementation.json "Summary of docs/architecture-implementation/direct-rates/summary.json; raw artifact retired")
halved SQEs/CQEs per completion from about 2.018 to 1.019. At 200k offered/s,
CPU increased from median 4.762 to 4.879 µs/response, with all three immediate-send
trials worse; the 100k results overlapped. Median latency improved in this block,
but baseline latency varied considerably and did not establish a general benefit.
Nine rotated [64 KiB echo trials](runs/architecture-implementation.json "Summary of docs/architecture-implementation/echo-rates/summary.json; raw artifact retired")
likewise showed overlapping CPU and essentially unchanged p99. Every sent request
succeeded. The prototype passed the full ReleaseSafe suite and a 16,384-request
pipeline test, but correctness plus fewer completions is insufficient to retain
it. Its source and tests are archived; the runtime code and diagnostic flag were
removed. Buffer pools alone retain their memory benefit in both workloads.

The ring bound remains conservative for a reason: a connection awaiting a read
can enter timeout response handling, then need cancellation of both read and
write. Both original operations and both cancellation requests can complete.
The existing `4 * slots + 64` CQ reservation covers that case without relying on
kernel overflow allocation. Reducing it requires a separately admitted pending-I/O
budget or a different cancellation protocol, with potential stalls exactly under
overload. The demonstrated 32-worker startup limit is documented, and capacity
can already be configured independently of workers. No unsupported CQ-size knob
or silent reduction of overload guarantees was added.


The shared executor retains the existing total threads and queue slots per lane
(`workers * configured value`), but places those waiting slots and threads in one
server-wide lane pool. Tasks carry the socket owner; completions return to that
owner's existing bounded queue/eventfd. The server starts the pool before pinning
any transport thread and joins it after transport threads return, before freeing
any worker resources. Ordinary socket I/O, parser mutation, admission and cleanup
remain owned by one transport thread. Services can now see concurrent hooks from
connections with the same owner; this contract change is documented explicitly.
Custom metric updates already use atomics.

The permanent cross-worker wire regression identifies socket owners through the
admin endpoint, blocks one owner's handler, and requests a fast response on a
second socket with the same owner. The original executor fails with a read timeout;
the unchanged test passes with shared lanes. Another test disconnects the blocked
socket and verifies its cleanup does not run until the hook returns, then runs
exactly once. Before,
after.

Sharing application work is distinct from moving live sockets or globalizing
admission. The measured uniform benchmark's worker request distribution is only
about −13% to +11% from its mean. Live socket transfer would require routing pending
CQEs, cancellation, borrowed scratch and admin inspection to a new owner; global
admission would add synchronization and change rate/fairness guarantees on every
request. Neither has a demonstrated benefit here. The real same-owner application
head-of-line failure is reproduced and addressed without either change.

Custom pipeline aggregation is not safe by merely removing `App == application`.
The batch currently owns serialized bytes and a small method/status/timing record;
it owns neither custom access attributes nor an exchange and its release hook.
Resetting the one exchange after copying would invoke cleanup before the currently
promised send-completion lifetime, or lose the pending hook altogether. Preserving
that contract requires additional exchanges/owned metadata per queued response,
with admission and pool limits, or a deliberate opt-in early-cleanup API. No
measured custom pipelined workload establishes that those costs pay off. Existing
built-in batching and custom cleanup semantics are retained; this is a conditional
future extension, not a missing optimization for serial high-connection traffic.


Further clock/HTTP changes have a measured upper bound. The existing component
budget records about 82 ns for four monotonic reads plus one wall-clock read.
Refreshing the cached HTTP Date only on the 10 ms tick could eliminate one
~16.4 ns call, under 0.4% of a ~4.4 µs process-CPU response, while making freshness
depend on timely tick dispatch. Reusing monotonic timestamps more broadly would
change deadline, service-time or first-byte measurements. The larger sampled
clock share includes other loop/observability calls and cannot be assigned wholly
to this one call. No such semantic change is retained without a demonstrated
benefit; parsing and normalization security behavior is preserved.
[Existing measured cost budget](request-path-remaining.md).

Deadline scans and accepts already have targeted evidence. Active-slot idle
maintenance consumes 10.59/14.05 ms thread runtime per ten seconds at 4,096 sockets,
including other idle work. In three isolated churn comparisons, multishot accept
saves about 3.3% CPU at 30k new connections/s, but under pressure lowers delivered
goodput from about 164k to 155k/s and raises service p99 from 2.13 to 4.88 ms.
A 4,096 backlog eliminates listen drops in that pressure test while lowering
goodput to about 160k/s and raising p99 to 7.86 ms. Those are policy tradeoffs,
not a universally better accept architecture; no new packet-path/churn evidence
invalidates them. The timer wheel, multishot accept, and larger default backlog
are skipped. [Isolated churn evidence](runs/request-path-remaining.json "Summary of docs/request-path-remaining/churn-isolated/summary.json; raw artifact retired"),
[pressure/recovery evidence](runs/request-path-remaining.json "Summary of docs/request-path-remaining/churn-pressure/summary.json; raw artifact retired"),
idle evidence.


Twelve rotated final application trials
compare the original worker-owned executor with shared lanes plus inline generated
head work when there is no middleware. Four workers on CPUs 9–12 retain four lane
threads total, 256 queue slots total, 256 connection slots per worker, and 128
client connections. At 50k/s on the all-fast endpoint, median CPU falls from
9.31 to 7.45 µs/response (20.0%), with p99 about 0.131 versus 0.127 ms. On a mix
where every tenth handler blocks for 10 ms, at 2.5k/s median p99 falls from
59.245 to 10.289 ms (82.6%); CPU changes from 16.80 to 14.11 µs/response. All sent
requests succeed, and packet-counter integrity is checked separately.

The intermediate shared-queue-only implementation increased all-fast CPU by about
13%, so it was not retained alone. Generated heads previously queued a task even
with no middleware. The new capability permits only bounded generated head work
inline; user middleware and handlers still run on executor threads. The same
absolute application deadline begins before body ingestion, including this path.
Existing middleware/handler timeout and release tests are unchanged. These gains
apply to generated applications; the built-in GET benchmark bypasses executors.
[Intermediate trials](runs/architecture-implementation.json "Summary of docs/architecture-implementation/application-rates/summary.json; raw artifact retired"),
binary/source provenance.


The logging prototype increases only the fixed writev prefix from 16 to 64
records, preserving ownership across partial writes and bounded turn-taking.
It passes the full ReleaseSafe suite, including blocked sinks, concurrent JSON
records and cancellation. Twelve [rotated logging trials](runs/architecture-implementation.json "Summary of docs/architecture-implementation/log-rates/summary.json; raw artifact retired")
then compare the two binaries with a `/dev/null` sink, 512 connections, and full
HTTP/log accounting. With seven workers at 50k/100k offered requests/s, both drain
all ~902k records per trial with zero drops or write errors and nearly identical
CPU/latency. With one worker at 100k/200k, the 16-record version drops 72–1,390
records per ~1.802M events; the 64-record version drops 908–2,072. CPU and latency
ranges overlap. Every sent HTTP request succeeds.

These results establish no larger-batch benefit, so the change was reverted.
The sink is deliberately fast; this does not claim lossless durable file logging.
A dedicated log thread would require a new concurrent producer/consumer ownership
protocol and cannot exceed the destination's capacity. Current shared draining
already keeps up at the seven-worker tested rates, so that rewrite is not
justified by these results. Existing drop/error metrics and bounded best-effort
logging remain explicit. Prototype provenance.


Final validation passes in both ReleaseSafe
and Debug: 53/53 build steps,
89/89 component tests, 18 endpoint declaration checks, the separate embedded
consumer, all 58 existing wire tests, aggregation and placement suites, four
buffer-pool wire tests, and three application-executor wire tests. The new
body-ingestion test confirms that bypassing an empty head task does not extend
the application deadline; an overdue body disconnects under the application
budget and later requests still succeed.

The [final source/binary receipt](runs/architecture-implementation.json "Summary of docs/architecture-implementation/final-build.json; raw artifact retired")
preserves 109 source/test/deployment files. The [57-trial audit](runs/architecture-implementation.json "Summary of docs/architecture-implementation/audit.json; raw artifact retired")
passes binary preservation, archived-source availability, distinct host identity,
clock alignment bounds, and offer/outcome/latency accounting. There are no counted
client request failures in these experiments; generator drops and network counters
remain in the raw results. This is evidence for the stated memory, CPU and latency
changes, not a sustained zero-error capacity certification. Final read-only
[server](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/server-architecture-implementation-final.json; raw artifact retired") and
[client](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/client-architecture-implementation-final.json; raw artifact retired") captures
check process cleanup. No host-wide network policy was changed.

Two compatibility changes matter to embedders: cold large-buffer cache misses
can call the supplied allocator during serving (serialized across transport
workers), and shared lanes can execute different connections' hooks concurrently
even when they have the same transport owner. Mutable application services must
synchronize accordingly. Socket ownership, cleanup after borrowed I/O, absolute
application deadlines, and explicit bounded overload behavior are retained.
