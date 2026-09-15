# Configuration and tuning

Set runtime options with the standalone CLI (`zhtps --help`) or an embedded
[`Config`](../src/Config.zig). Lane declarations belong to the application's
compile-time API. Start with `-Doptimize=ReleaseSafe`; use a representative workload
to choose budgets, then test saturation and recovery using the [load tools](testing.md).

## Automatic defaults

The CLI and `Config{}` automatically size workers, public connections, leased
large buffers, HTTP/2 memory, and HTTP/2 worker stream capacity before binding.
An explicit number overrides that field; `auto` on those five CLI options, or
`Config.automatic` in a library field, restores automatic sizing. Other protocol,
admission-rate, timeout, logging, and application-lane policies retain their defaults.

Startup reads the calling thread's affinity, physical-core topology, memory,
descriptor limit, and cgroup membership/mounts. **Service limits take precedence
over host capacity.** Both cgroup v1 and v2 are supported, including visible
parents, subtree mounts, and cgroup namespaces. CPU quotas and cpusets constrain
CPU sizing; `memory.max`, `memory.high`, or v1 memory limits constrain memory;
`pids.max` constrains additional threads. An unlimited child cannot override a
tighter parent. Limits above a namespace's visible mount root cannot be inspected.
Malformed or unreadable service-limit information fails startup instead of
silently using host totals. Missing CPU topology falls back to one physical core.

The default process sizing budget is one quarter of the smaller of host available
memory and remaining cgroup memory allowance. `--memory-budget-bytes N` overrides
this allowance, up to detected available memory. The estimate accounts for compiled
connection/request records, bounded caches, admin storage, log/batch queues, lane
queues, and allowances for stacks, sockets, and TLS. It is a sizing estimate rather
than an RSS limit: application allocations, actual kernel/TLS costs, and other
processes can consume additional memory. Discovery is a startup snapshot; limits
and occupancy can change afterward.

Automatic worker count starts from physical cores within the affinity mask and
CPU quota, divided by one transport thread plus the declared lane threads per
worker. Fractional quotas round down with a minimum of one worker. Memory, thread,
and descriptor constraints can reduce the result. Explicit worker counts remain
exact, including intentional CPU oversubscription; kernel CPU quotas still apply.
Explicit connection counts remain exact and can exceed descriptor capacity, while
automatic counts leave descriptor headroom for admin, listeners, rings, and other
application activity. Configurations exceeding the memory sizing allowance or
available thread allowance fail before listening.

Each automatic large-buffer allowance uses 1 MiB plus one quarter of the remaining
per-worker sizing allowance, capped at 64 MiB. TLS listeners allocate an automatic
HTTP/2 budget the same way; cleartext listeners retain a 1 MiB inactive allowance.
Automatic HTTP/2 worker streams use up to half that budget for estimated stream
storage, capped at 256 (one inactive slot without TLS). Executor completion queues
for these streams also count against the sizing allowance. Remaining memory and
file descriptors determine public slots, within the implementation's existing cap.
Admission counts and burst are then derived from the final connection capacity.

For non-loopback listeners, a single discoverable physical NIC permits automatic
IRQ/L3-aware placement. IRQ cores and their SMT siblings are excluded. Ambiguous
NICs, enabled RPS, or unavailable topology retain scheduler placement.
`--worker-cpus inherit` forces scheduler placement. An explicit CPU list determines
worker count when `--workers` is automatic and must fit the serving thread's affinity.

`/debug/config` reports concrete limits plus a `resources` object containing detected
limits, the sizing estimate, and the sources of worker/connection decisions.
The info-level `resources_resolved` startup event logs workers, connections,
large-buffer and HTTP/2 budgets, stream capacity, active/rejecting admission limits,
burst, threads per worker, and the process memory budget/estimate. It includes
sizing sources and whether buffer/HTTP/2 settings were automatic. Each worker's
`worker_resources_resolved` event logs its selected CPU (null for scheduler
placement) and actual submission/completion ring sizes. These events are enabled
without verbose or access logging. No sysctls, IRQ settings,
process limits, or cgroup settings are changed.

Linux interface references: [cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html),
[v1 CPU quotas](https://docs.kernel.org/scheduler/sched-bwc.html),
[v1 memory](https://docs.kernel.org/admin-guide/cgroup-v1/memory.html), and
[network CPU placement](https://docs.kernel.org/networking/scaling.html).

## Choose a starting configuration

1. **Allocate CPU time.** Start with automatic sizing and adjust while useful
   throughput improves without unacceptable tail latency. For a dedicated built-in
   server, test up to one worker per available physical core. Generated applications
   also need CPU for lane threads; reserve headroom for those threads, NIC interrupts,
   and other host services. SMT siblings are not equivalent to independent cores.
2. **Size connections and admitted work separately.** Divide the desired public
   connection capacity across workers, allowing for uneven SO_REUSEPORT distribution.
   Keep `max_active` below that connection budget to leave room for headers, idle
   keepalives, and drains. Derive `rate` from measured sustainable throughput per
   worker and choose `burst` for tolerable bursts; zero rate disables rate limiting.
   Size the process file-descriptor limit for every worker's sockets and ring.
3. **Size each application lane.** A lane has one server-wide queue and thread pool;
   declared `threads` and `queue` are each multiplied by `Config.workers`.
   For example, four workers and `.api = .{ .threads = 2, .queue = 32 }` produce
   eight API threads and 128 waiting task slots in total, shared across all workers.
   The default lane has one thread, 64 queue slots per worker, and a 100 ms deadline.
4. **Budget memory for the busiest case.** Buffered endpoints need
   `application_bytes` for the body plus parsing and response scratch. Streaming
   avoids retaining the whole body, but each live request still needs scratch and
   transport buffers. `large_buffer_bytes` bounds leased HTTP/1 large buffers;
   cached buffers have separate bounds. HTTP/2 has a separate worker memory budget
   that includes its caches. Kernel socket memory and OpenSSL allocations are extra.
5. **Measure the result.** Inspect per-worker occupancy and memory, application queue
   rejections, timeouts, completed/aborted requests, and dropped logs. Measure client
   success latency and useful throughput together: a lower p99 caused by rejecting
   more work is not increased capacity. See [observability](observability.md).

## Match lanes and limits to the workload

| Workload | Starting approach | What to watch |
| --- | --- | --- |
| Small CPU-bound handlers | Keep total runnable lane threads plus transport workers within the CPU allocation; use short queues. | CPU saturation, queue waits, and successful-response p99. |
| Blocking database or service calls | Put them in a separate lane; size total threads to the downstream concurrency limit and use cancellable, bounded calls. | Downstream latency, connection-pool waits, and lane rejections. |
| Large uploads | Use `.body = .stream`; raise route and server body limits deliberately and allow enough time for the slowest accepted upload. | Body timeouts, consumer throughput, and retained scratch. |
| Long-lived response streams | Give the routes a dedicated lane with at least one thread per concurrent producer and a deadline covering the stream lifetime. | Occupied lane threads, peer flow control, and cancellation. |
| Many idle clients or connection churn | Increase connection capacity only within memory/FD limits; consider opt-in idle reclamation when completed keepalives exhaust slots. | Worker skew, reclamation, reconnect failures, and returning-client p99. |
| Many HTTP/2 streams | Tune connection and worker stream limits together with active permits, lane capacity, and the HTTP/2 memory budget. | Active/retained streams, memory exhaustion, and flow-control stalls. |

Queue capacity counts waiting hook tasks, not reserved request capacity. Keep queues
small enough that their wait plus middleware, upload consumption, and handler work
fit the lane deadline; response streams must also finish within it. Increasing
queues does not add throughput. A timeout cancels the request but cannot forcibly
terminate Zig code: threads and storage remain occupied until the hook returns.
Lanes isolate executor threads, while connection slots, admission, CPU, and services
remain shared. Use separate servers when independent admission capacity is required.

## Useful defaults and controls

| Control | Default | Sizing notes |
| --- | --- | --- |
| `--workers` | Automatic | CPU allocation, lane threads, memory, and resource limits; includes the serving caller. |
| `--max-connections` | Automatic per worker | Public sockets; admin reserves eight slots once on worker zero. |
| `--max-active` / `--max-rejecting` | 3/4 and 1/8 of public slots, each at least 1 | Explicit counts cannot exceed the per-worker connection budget. |
| `--rate` / `--burst` | Disabled / effective max-active | Request rate and burst are per worker. |
| `--rejection-rate` | 1,000/s per worker | `--max-rejecting 0` closes excess requests without 503 responses. |
| `Config.application_bytes` | 64 KiB per live application exchange | Library setting; buffered bodies and scratch share this capacity. |
| `--max-body-bytes` | 64 MiB | Server limit; generated routes default to 64 KiB and may impose a smaller limit. |
| `--large-buffer-bytes` | Automatic, up to 64 MiB per worker | Leased large buffers; caches and small buffers are additional. |
| `--http2-max-streams` / `--http2-worker-streams` | 100 per connection / automatic per worker | Reset streams with running hooks still occupy worker capacity. |
| `--http2-memory-bytes` | Automatic, up to 64 MiB per worker | Protocol, transport, stream, and cached allocations; see [HTTP/2](http2.md). |
| Header / body / write / idle timeouts | 5 s / 30 s / 5 s / 15 s | Each has a `--*-timeout-ms` option; lane deadlines also apply to generated endpoints. |
| `--tls-handshake-timeout-ms` | 5 s | Separate from the first request's header deadline. |
| `--max-requests` | 1,000 per connection | Increase for long-running reuse workloads if connection turnover is unnecessary. |
| `--idle-reclaim-ms` | 0 (disabled) | A nonzero age must be less than the idle timeout. |
| `--completion-budget` | 64 | Start here; change only with evidence about fairness or event-loop overhead. |
| `--response-batches` | 64 per worker | Built-in application only; zero disables aggregation. |
| `--log-slots` | 256 per worker | Larger queues absorb log bursts but do not fix a slow sink. |

`--no-access-log` reduces per-response logging work when metrics and sampled events
are enough. `--tcp-retries thin-linear` is the default; compare with `system` on
your network if retransmission traffic or packet loss matters. Avoid changing
batching, buffer dimensions, and retry policy together: measure one change at a time.
The [runtime guide](runtime.md) describes overload and shutdown, and the
[endpoint guide](endpoints.md#lanes-and-deadlines) explains application ownership.

Most CLI names map to the same `Config` field with underscores. Exceptions include
`--max-requests` (`max_requests_per_connection`) and admission controls such as
`--rate` (`admission.requests_per_second`). `application_bytes`, header/trailer sizes,
and receive/response buffer sizes are library settings, not standalone CLI options.
Use [`Config`](../src/Config.zig) as the complete field reference and `/debug/config`
to inspect effective runtime limits.

## Workers and resource budgets

`--workers N` starts N event-loop threads, including the calling thread; the
default is automatic. For example, an explicit allocation is:

```sh
./zig-out/bin/zhtps --workers 16 --max-connections 2048 --max-active 512
```

Connection, active-request, rate, burst, rejection, and log-queue budgets apply
**per worker**. The example reserves 32,768 public connection slots and allows
up to 8,192 active public requests. The eight default admin slots are reserved
once, on worker zero. Increasing workers multiplies public capacity; there is
no shared request-permit counter. Generated applications share bounded executor
queues across transport workers.

Public listeners share the resolved address/port using Linux `SO_REUSEPORT`.
Each accepted connection stays on its worker for its entire lifetime. All
workers initialize before readiness is reported, including when port zero is
used. Startup errors unwind initialized workers; fatal loop errors signal the
other workers to drain. Threads join before storage is freed. Workers use the
process's allowed CPUs, with automatic NIC placement when supported. `--worker-cpus 9,10-12 --workers 4` pins
workers in that order; each worker needs a distinct logical CPU. IDs must be
between 0 and 1023 and within the serving thread's inherited allowed set.
Invalid or unavailable mappings fail startup before readiness. The library's
`Config.worker_cpus` accepts the same borrowed string. Application executor
threads retain the inherited mask, and `serve` restores its caller's original
affinity when it returns. `/debug/workers` includes the configured `cpu`, or
null when placement is inherited.

For a physical NIC, inspect a suggested mapping with:

```sh
python3 deploy/worker_cpus.py --interface server_eth0 --workers 1 --json
python3 deploy/worker_cpus.py --interface server_eth0 --workers 7 \
  --exec ./zig-out/bin/zhtps -- --address 192.0.2.10 --max-connections 2048
```

The helper reads current IRQ affinity and L3/SMT topology, excludes IRQ cores
and their siblings, and chooses one allowed logical CPU per remaining physical
core sharing an IRQ's L3. `--exec` replaces the launcher with the server using
the discovered mapping, so signals and the exit status belong to the server.
Set the worker count on the launcher and pass other server options after `--`.
The example interface, address, and seven-core allocation are specific to the
measured host; choose the service's interface and allocation on your machine.
The helper refuses insufficient cores, missing
topology, and enabled RPS. It changes no host settings. Run it in the same CPU
allocation as the service and recheck after IRQ placement changes. This policy
is supported by [single-worker measurements](kernel-work.md) and the
[seven-worker comparison](architecture-review.md); multiple NIC queues
still need workload-specific validation.

Admission is local: an overloaded worker may reject while another has spare
capacity. Reserve connection headroom for uneven distribution and inspect
`/debug/workers`. Per-worker public capacity remains at most 8,168 with the
default admin reserve. Completion queues accommodate outstanding I/O and
cancellation; submission queues have at most 256 entries and flush when full.
Ring and socket memory remain subject to kernel resource limits. Size the process
file-descriptor limit for total connections plus worker listeners/rings; the
benchmark runner raises its own soft limit within the inherited hard limit.

Public listeners default to `--tcp-retries thin-linear`. Linux uses bounded
linear retransmission intervals for qualifying thin streams before resuming
exponential backoff. This helps short HTTP responses recover from packet loss
within client deadlines. It does not change HTTP deadlines or the kernel's
minimum retransmission timeout, and it can increase retransmission traffic.
Use `--tcp-retries system` (or `Config.tcp_retries = .system`) to leave kernel
retry defaults unchanged, including any global thin-stream setting. Admin
listeners always use system defaults. The public socket option is set before
binding and inherited by accepted sockets; unavailable support fails startup
with `TcpThinRetriesUnavailable` instead of failing incoming connections.
The selected mode is visible at `/debug/config`.

`--idle-reclaim-ms N` optionally admits new connections by closing the oldest
completed public keepalive connection when that worker's slots are full. Zero
(the default) disables reclamation. A nonzero minimum idle age must be below
`--idle-timeout-ms`. Initial idle connections, active requests, responses,
application hooks and admin connections are excluded. Reclamation starts only
after a new peer is accepted; each worker can hold one extra accepted descriptor
for up to `--close-timeout-ms` while receive/cancel completions release a slot.
Allow that descriptor in the process limit. Eligibility is reconsidered on the
10 ms event tick. Clients must handle an idle connection closing as they reuse it.
Metrics expose `connections_reclaimed_total` and `connection_reclaim_timeouts_total`.
The [default-policy measurements](keepalive-policy.md) favor 50 ms when
reclamation is desired, but retain opt-in because returning-client p99 increased
about 14% in the confirmation despite essentially neutral normal-load cost.

Public slots reserve a connection record. Each accepted public socket borrows
up to 20 KiB of common-case buffers plus 448 bytes of placement padding, retaining
them until the socket's application work and I/O finish. Each worker caches up
to 64 returned sets and reserves up to 64 at startup. Cache misses allocate
during acceptance; failure closes that socket and increments `connection_buffer_exhaustions_total`. Admin buffer
sets remain reserved at startup. Metrics expose active/cached public bytes and
`connection_buffer_allocations_total`. Parser and application exchange storage is
leased when request bytes arrive and returned after cleanup when keepalive goes
idle. Each worker preallocates up to 64 public request objects and retains at
most 64 returned objects; live objects remain bounded by its connection slots.
Additional allocations can occur for active requests. Allocation failure closes
the affected connection and increments `request_storage_exhaustions_total`.
Admin slots have private request objects reserved at startup. Metrics expose
`request_storage_active`, `request_storage_cached`, and allocations on cache misses.
Larger headers, paths, trailers, responses, and application scratch borrow
buffers from worker-local pools.
The default receive buffer remains 16 KiB. Protocol size limits are unchanged.
`--large-buffer-bytes N` bounds leased large-buffer bytes per worker (automatic by
default, up to 64 MiB). Each size class also caches returned buffers: up to 64 blocks within
4 MiB, or up to eight blocks when that allowance exceeds 4 MiB. The cache grows
on demand and does not reserve this memory at startup.
Exhaustion returns 503 and closes the request connection. Admin slots reserve
their full buffers at startup and remain usable when the public budget is full.
`/debug/workers` and metrics expose leased/cached bytes and buffer failures.

Connection-buffer, request-storage, and large-buffer cache misses allocate during
serving; allocator access is serialized between workers. Custom exchanges initialize after admission
with their full configured scratch capacity, rather than when an idle connection
is accepted.
Buffers remain owned until application cleanup and all relevant I/O complete.
Application hooks can execute concurrently for connections owned by the same
worker. Application-global mutable resources must provide synchronization;
partitioning mutable services by transport worker alone does not serialize hooks.

The [architecture assessment](architecture-implementation.md) records the
measured memory and application-scheduling improvements, tested contracts, and
reasons for retaining the other designs. The subsequent
[nginx-inspired implementation](nginx-implementation.md) records request-storage,
idle-reclamation and upload measurements.
