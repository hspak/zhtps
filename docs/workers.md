# Worker ownership and performance review

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

ZHTPS runs one thread and private io_uring per worker. `--workers` defaults to
one. Public connection capacity, active permits, token buckets, rejection budgets,
and log queues apply per worker; adding workers multiplies capacity. The shared
admin listener and its reserved connections belong to worker zero.

## Runtime ownership

The calling thread allocates and initializes every worker and listener, resolving
port zero once. It then starts the other N−1 threads. A readiness barrier ensures
all worker threads have entered before any loop processes I/O. The caller runs
worker zero. Allocator calls and final destruction stay on the calling thread;
application hooks and connection mutations stay on the owning worker. Unused
slots do not call application initialization on the setup thread; initialization
is deferred until the owner prepares a request. A permanent regression reproduces
the earlier eager initialization and passes after its removal.

Each public listener belongs to the same Linux `SO_REUSEPORT` group. Connections
remain on the worker that accepted them. The scheme preserves request ordering,
per-connection buffer lifetimes, and the existing cancellation rules. It does
not balance application permits or move hot keep-alive connections. Spare local
capacity can be stranded; connection headroom and per-worker inspection make
that visible.

Metrics remain separate from renderers. Each worker owns a `Metrics` instance;
admin handlers merge atomic snapshots into the existing `Metrics.Snapshot`
shape before selecting Prometheus or JSON output. Counters, occupancy and
histogram buckets/sums aggregate; `draining` is a flag indicating any worker is
draining. The snapshot is observational, without a cross-worker transaction.

`/debug/workers` reports thread IDs, actual ring sizes, occupancy and request
counts, with a 32-worker pagination limit. `/debug/connections?start=N` traverses
workers and returns at most 32 live entries per page. Remote inspection uses one
bounded request/response mailbox per worker. Release/acquire handoff protects
the page; only the owner examines mutable connections. A busy mailbox returns
503. Abandoned/recycled admin connections are distinguished by generation, and
pages complete on the existing timer tick without blocking another worker.
Connection and request IDs are local to a worker; logs and inspection carry
worker IDs to disambiguate them.

Every worker has its own bounded logging queue. One atomic owner serializes
asynchronous writes to stderr, retaining ownership across short writes. A worker
that cannot acquire ownership continues processing HTTP; its queue can drop
records when full. Cancellation releases ownership only after the kernel has
finished with the record. Access logs remain enabled by default;
`--no-access-log` suppresses completion records while retaining all metrics and
operational events.

Startup failure closes already initialized rings/listeners. Thread-spawn failure
releases the readiness wait and joins any started threads. A fatal loop error
sets a shared stop signal before canceling its own operations. Other workers
begin their existing bounded graceful drain. All threads join before any worker
storage or shared metrics can be freed. Kernel cancellation can still exceed
the graceful deadline if an operation cannot finish; memory ownership takes
precedence over returning early.

## Performance changes and evidence

The review covered ring allocations, connection allocation/recycling, the event
loop, parsing/response construction, metrics, logging, shutdown, and benchmark
resource placement. No HTTP validation, admission checks, or latency histograms
were removed.

1. **Bounded submission queues with independent completion sizing.** The first
   16-worker trial, at 2,048 public connections per worker, failed startup. A
   syscall trace showed five successful `io_uring_setup(16384)` calls followed by
   `ENOMEM` on the sixth (setup trace). The old setup also allocated 32,768 CQ entries per
   worker. Submission capacity does not have to equal outstanding I/O: the
   implementation now uses at most 256 SQ entries, flushing when full, and a
   CQ sized to `nextPowerOfTwo(4 × local_slots + 64)`. At this configuration SQE
   storage falls from 1 MiB to 16 KiB per worker, and CQE storage halves. The same
   16-worker startup test fails against the saved pre-fix executable and passes
   unchanged after the fix. No system resource limit was raised to achieve it.
   The existing per-worker connection cap is retained.
2. **Constant-time free slots.** Separate intrusive free lists for public/admin
   slots replace scans through the connection array on every accept attempt.
   Closing returns a slot only after all operation and cancellation CQEs have
   arrived. This removes work proportional to occupied capacity, especially
   when the pool is full.
3. **Single-writer metric recording.** A 16-worker user-space `perf` sample found
   30.79% of cycles in `processInput`, with annotated stalls following locked
   metric increments. `Metrics.recorder()` uses atomic loads/stores when all
   updates are serialized on the worker, preserving concurrent readers. The
   ordinary metrics methods retain their atomic read-modify-write behavior for
   concurrent producers. Fields, metric names, snapshots and both renderers
   remain compatible. See the profile.
4. **Explicit access-log opt-out.** The Go reference has no access logger.
   Discarding ZHTPS stderr still exercised logging, so the benchmark now records
   an explicit opt-out. In the four-worker baseline the bounded log queues were
   already dropping most records; disabling completion logging produced no
   clear throughput change. The option provides a clear operational choice.

Four-worker checks used 4,096 clients, 2,048 public slots and permits per worker,
15 client cores, three three-second measurements and one second of warmup.
Both default logging and the opt-out retain metrics. Rates count successful
responses completed within the fixed measurement window.

| Stage | Median successes/s | Success p99 ms | Median server CPU, one CPU = 100% |
|---|---:|---:|---:|
| Initial worker implementation | 743,336 | 10.355 | 255.1% |
| Smaller rings and free lists | 747,695 | 10.355 | 255.3% |
| Access logs disabled | 746,366 | 10.486 | 254.6% |
| Single-writer metric recorder | 758,504 | 10.027 | 252.4% |

The recorder check improved median goodput by about 1.6% relative to the preceding
stage. The earlier throughput differences are small enough to treat as noise;
the concrete ring-allocation and free-list benefits do not depend on those
small differences. These short shared-host checks do not prove portable speedups.
Raw measurements preserve each stage's source and binary hashes:
[initial](runs/standalone.json "Summary of docs/worker-performance-before.json; raw artifact retired"),
[ring/free-list changes](runs/standalone.json "Summary of docs/worker-performance-after.json; raw artifact retired"),
[logging opt-out](runs/standalone.json "Summary of docs/worker-performance-no-access-log.json; raw artifact retired"), and
[recorder](runs/standalone.json "Summary of docs/worker-performance-recorder.json; raw artifact retired").

The remaining sampled work includes request parsing, response construction,
writer operations, copying and clock reads. Clock reads already use Zig's vDSO
path. The parser retains its incremental framing/error checks. The 10 ms timer
still scans the worker's connection pool, and load distribution remains at the
connection level. More complex parsing shortcuts, timer structures, connection
migration, busy polling and kernel task-run flags were left out without stronger
evidence that their cost/complexity is justified for this workload.

## Verification

Debug and ReleaseSafe each pass 34 component tests and 40 raw TCP tests.
The Go load-client tests also pass.

The component suite covers metrics merging and concurrent snapshot readers,
worker budget validation, injected fatal worker errors, and io_uring cancellation.
The raw TCP suite covers all existing framing and application behavior plus:

- Multiple distinct threads serving persistent/pipelined requests and preserving
  echoed bodies across connections.
- More aggregate connections than one worker's capacity, aggregated admission
  counts/occupancy, remote connection pages, and complete JSON log records.
- Per-worker admission saturation, HTTP 503 responses, and permit recovery.
- Sixteen workers with 2,048 connection slots each starting successfully.
- Canceling more outstanding receives than the SQ can hold in one batch.
- Shutdown with active bodies and a blocked log sink; partial startup failure.
- Disabling access logs while retaining successful-request counters/histograms.

The fatal-completion regression's manually constructed worker fixture now
initializes the admin free-list head. Its injected error and all behavioral
assertions are preserved. The new large-worker startup regression was explicitly
run against the saved pre-fix binary and then unchanged against the fixed binary.

See the [multicore benchmark](go-comparison-workers.md) for the final comparison
at 4,096, 8,192 and 16,384 clients with unrestricted Go.

## Worker-count calibration

A short calibration compared eight workers with 4,096 slots each and sixteen
workers with 2,048 slots each, keeping total public slots and permits at 32,768.
Both used unrestricted process affinity, access logging disabled, the same
15-core client, one second of warmup and two two-second measurements per count.

| Workers | Clients | Median successes/s | Success p99 ms |
|---:|---:|---:|---:|
| 8 | 4,096 | 1,431,035 | 5.702 |
| 16 | 4,096 | 1,474,492 | 4.932 |
| 8 | 16,384 | 1,011,886 | 26.673 |
| 16 | 16,384 | 1,173,503 | 20.644 |

All trials had zero client failures. Sixteen workers were selected for the
longer comparison: the improvement was most visible at 16K clients. This is a
choice for this machine and workload, not a universal optimal worker count.
The calibration preceded the final removal of eager application initialization
for unused slots; the per-request path was unchanged by that review fix.
Raw data: [eight workers](runs/standalone.json "Summary of docs/worker-calibration-8.json; raw artifact retired"),
[sixteen workers](runs/standalone.json "Summary of docs/worker-calibration-16.json; raw artifact retired").
