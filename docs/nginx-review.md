The strongest lessons from nginx for ZHTPS concern the lifetime of request memory,
admission under connection pressure, and bounded streaming. The source review
does not establish that ZHTPS needs a different event backend or worker model.
Several nginx techniques already have equivalents in ZHTPS, including private
socket ownership, gather writes, bounded response batching, and application
work offload. The remaining opportunities depend substantially on the workload.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

This is a **review only** of the sibling nginx checkout, version **1.31.6**, commit
`f9c4264b6b48f4d9559dabd8ff2ff356e12d95fb`. Source references below identify that
local checkout. No nginx performance comparison was run. ZHTPS is assessed after
the [completed Go-inspired work](architecture-implementation.md), so that work's
improvements are not counted again as new opportunities. All experimental code,
build, harness, and test changes from this nginx pass have been removed; earlier
work is preserved. [Source provenance](runs/nginx-review.json "Summary of docs/nginx-review/provenance.json; raw artifact retired"),
[restoration verification](runs/nginx-review.json "Summary of docs/nginx-review/review-audit.json; raw artifact retired").

The ranking weighs possible impact on ZHTPS's present architecture, giving
priority to the original concern about high connection counts. “High” identifies
the affected dimension and workload; it is not a measured throughput multiplier.
Ranks 3 and 4 become priorities only for applications that need those features.

| Rank | nginx strategy / ZHTPS opportunity | Possible impact | Compatibility and assessment |
|---:|---|---|---|
| 1 | Separate request memory from idle connection storage | High memory/capacity impact at many configured or idle slots; modest demonstrated parser-only CPU upside | Strong fit for bounded worker pools. Large-buffer pooling is already adopted; embedded request scratch and fixed small storage remain. |
| 2 | Reclaim reusable connections under slot pressure | High availability impact when idle sockets occupy the local connection limit | Compatible with socket ownership, but reclamation must wait for pending I/O and cancellation completions. A policy proposal, not a validated implementation. |
| 3 | Stream request bodies with consumer backpressure | High memory and useful-throughput impact for large uploads and proxy-style consumers; no small-GET benefit | Requires a resumable body-consumer API and explicit buffer ownership. Generated endpoints currently buffer the complete body. |
| 4 | Represent file output as file ranges and bounded buffer chains | Potentially high CPU/copy savings for static files; no small-GET benefit | Requires file-response ownership and asynchronous file-work design. Existing byte/stream response types do not express this. |
| 5 | Precompute routing, method groups, and header dispatch | Potentially moderate to high CPU impact for large route tables; small for few routes | Excellent fit for Zig comptime. Whole-server benefit remains unmeasured; the preliminary comparison is invalid. |
| 6 | Borrow already canonical URI paths | Small overall CPU opportunity, potentially more for long ordinary paths | Compatible if ZHTPS's normalization and borrowing contracts remain exact. nginx's URI semantics cannot be copied wholesale. |
| 7 | Coalesce output while yielding between bounded units of work | Conditional pipeline/streaming throughput and tail-latency benefit | Mostly present. Further custom-response batching requires an explicit ownership contract. |
| 8 | Compile log formatting and buffer records by bytes | Conditional CPU/sink-efficiency benefit with logging enabled | Partly present. Larger drains have already failed to show a reliable benefit; actual sink behavior determines value. |
| 9 | Cache time and avoid unnecessary timer updates | Low measured upside at the tested idle population | Clock reuse is possible with precision constraints; nginx's timer slack is unsuitable for some ZHTPS deadlines. |
| 10 | Adapt accept handling to readiness, resource pressure, and listener sharing | Conditional churn/failure-recovery benefit; low for persistent traffic | ZHTPS already has reuseport listeners and accept retry handling. nginx does not support indiscriminately increasing accept batching. |
| 11 | Keep connection work local and offload selected blocking work | Largely an existing strength; no demonstrated gain from replacing worker threads with processes | Retain socket ownership and bounded shared application lanes. nginx reinforces this division of responsibilities. |

**1. Make idle connections carry less request storage.** nginx creates a separate
request pool and destroys it after request cleanup. Its configured initial pools
are 512 bytes per connection on a 64-bit build and 4 KiB per request; those are
initial pool sizes, not total connection/request footprints or hard memory caps.
The initial header buffer defaults to 1 KiB, with larger header buffers obtained
when needed. On the non-pipelined keepalive path nginx attempts to free header
storage and releases large header buffers. Pipelined bytes retain their storage
until consumed. [Pool defaults](../../nginx/src/http/ngx_http_core_module.c:3616),
[request allocation](../../nginx/src/http/ngx_http_request.c:573),
[keepalive cleanup](../../nginx/src/http/ngx_http_request.c:3464),
[pool cleanup ordering](../../nginx/src/core/ngx_palloc.c:47).

ZHTPS already cut matched-load RSS from approximately 4,864 to 946 MiB through
bounded large-buffer pools. It still embeds the parser and application exchange
in each configured Connection record, and reserves 20 KiB plus padding of small
public buffers per slot, including a 16 KiB receive buffer. Initializing an
exchange later avoids work but does not remove its inline storage. The further
compatible direction is a small connection record with request scratch leased
for the period it is needed, under an explicit active-memory budget.
[Connection layout and small capacities](../src/server/worker.zig:145),
[existing pool results](architecture-implementation.md).

The critical difference is that nginx can wait for socket readiness without a
pending receive owning an application buffer. A ZHTPS io_uring receive already
submitted against a buffer keeps that buffer live. Storage cannot be returned
just because the application considers the connection idle. Existing parser
outlining experiments yielded only about 0–2% throughput improvement, and the
earlier 4 KiB receive-buffer experiment failed an existing slow-reader test.
This recommendation is primarily about memory lifetime and capacity; it does
not justify shrinking the receive buffer or promising a comparable RPS gain.
[Parser-footprint evidence](request-footprint.md),
[receive-size constraint](architecture-implementation.md).

**2. Prevent idle clients from monopolizing all slots.** Before allocating a
connection, nginx drains reusable connections when free slots are at or below
one sixteenth of capacity. It chooses the oldest entries in its reusable queue
and processes between one and 32 per pass, depending on queue size. The handler
performs the actual close. nginx's reusable category can include connections
still waiting for their initial request, as well as completed keepalive
connections. [Allocation and drain](../../nginx/src/core/ngx_connection.c:1227),
[selection policy](../../nginx/src/core/ngx_connection.c:1409),
[initial wait handling](../../nginx/src/http/ngx_http_request.c:440).

ZHTPS stops submitting accepts when the worker has no free slot. An otherwise
idle population can therefore block new useful connections until clients close
or the idle timeout expires, even with spare CPU and application capacity.
The default idle timeout is 15 seconds. This is a concrete capacity-policy gap,
not evidence that active requests at 8k/16k connections execute inefficiently.
[Accept admission](../src/server/worker.zig:937),
[timeout defaults](../src/Config.zig:35).

A conservative future policy could reclaim the oldest **completed public
keepalive** connections after a minimum idle period. It should exclude active
requests, application callbacks, responses, and admin connections. Outstanding
receive/send and cancellation completions must retire before the slot is reused;
a close request alone does not release ownership. Reserved accept capacity or a
bounded pending accepted descriptor would be needed to bridge that interval.
Reclaim counts, rejection counts, reconnection churn, and new-client latency
would determine whether the policy helps. This review does not settle a default
or introduce a configuration option. There is no validated reclamation result.

**3. Let large bodies advance at the consumer's pace.** nginx's request-body
reader maintains reusable and busy buffer chains. In unbuffered mode, when
downstream still holds the buffers, it returns `NGX_AGAIN` and resumes later.
Buffered mode can write accumulated body buffers to a temporary file. These are
different storage/latency policies, not a claim that every nginx request streams
or that temporary-file writes are automatically nonblocking.
[Consumer backpressure](../../nginx/src/http/ngx_http_request_body.c:320),
[temporary-file path](../../nginx/src/http/ngx_http_request_body.c:550).

ZHTPS generated endpoints copy received body chunks into bounded application
storage and invoke the handler after ingestion. The default application buffer
is 64 KiB, independently of the parser's 64 MiB body limit. Raising the parser
limit does not create a streaming application interface. A resumable consumer
could process bodies larger than the memory budget by releasing chunks before
the next receive, while preserving timeout, cancellation, and rejection rules.
Disk spill would need separate storage limits and file-I/O handling. This is a
substantial API capability, justified by upload or proxy workloads rather than
the current bodyless benchmark.
[Generated body ingestion](../src/endpoint.zig:762),
[independent limits](../src/Config.zig:26).

**4. Preserve file ranges through the output pipeline.** nginx's static module
can put an open file and byte range into an output buffer. Its Linux sendfile
chain handles file ranges alongside memory headers, with TCP corking decisions
for that path. Configurable open-file caching can avoid repeated open/stat work;
it is a descriptor/metadata cache, not a cache of complete response bodies.
[Static file lookup](../../nginx/src/http/modules/ngx_http_static_module.c:92),
[file-range output](../../nginx/src/http/modules/ngx_http_static_module.c:261),
[Linux sendfile chain](../../nginx/src/os/unix/ngx_linux_sendfile_chain.c:50).

ZHTPS's response body describes bytes or a producer stream, so a file identity
and range are lost unless expressed by a new API. A file-body variant could
enable a suitable transfer path while retaining socket ownership. It would
need defined FD lifetime, partial-transfer offsets, file-change behavior, and
bounded work so cold file access cannot stall a network worker. Supporting the
representation is compatible with io_uring; directly copying nginx's syscall
loop is not required. There is no benefit to the six-byte response workload.
[Response body contract](../src/http/Response.zig:15).

**5. Move invariant dispatch work out of requests.** nginx builds balanced trees
for static locations during configuration and hashes known incoming header
handlers. Its parser accumulates the header-name hash while reading the name.
This avoids reconstructing lookup work after parsing.
[Static location construction](../../nginx/src/http/ngx_http.c:1164),
[header dispatch setup](../../nginx/src/http/ngx_http.c:414),
[header lookup](../../nginx/src/http/ngx_http_request.c:1518).

ZHTPS's generated routing currently scans all routes to select the most specific
resource, then scans them again to collect methods and select a handler. A
comptime literal index and pre-grouped methods could reduce work as route count
grows; parameter routes would need a matching index with ZHTPS's precedence.
Preserve automatic OPTIONS, 405 method reporting, HEAD fallback, parameter names,
and middleware ordering. nginx's exact/prefix/regex locations are not equivalent
to ZHTPS's parameter routes. Header indexing similarly needs evidence on realistic
header counts before adding extra work to tiny requests.
[Current two scans](../src/endpoint.zig:865),
[matching semantics](../src/endpoint/routing.zig).

**Evidence correction:** six preliminary routing runs were collected before the
review-only clarification. Audit found that both named variants and every run
record identify the same binary SHA-256, despite different archived sources.
They cannot establish any effect of the proposed index. All six are excluded
from architectural performance conclusions; neither their small timing
differences nor their successful HTTP responses validate the optimization. The
initial readiness-check failure is also excluded. The source changes are
removed, and no replacement experiment was run after the clarification.
Comparison audit.

**6. Avoid copying paths that need no normalization.** nginx uses a direct slice
of the request URI when its parser has not marked it complex, quoted, or empty;
only the other path allocates and normalizes. ZHTPS currently always normalizes
into separate path storage. A parser flag proving that a path is already
canonical could allow borrowing the original bytes for the request lifetime.
This reduces scans and copies, particularly for long ordinary paths.
[nginx URI fast path](../../nginx/src/http/ngx_http_request.c:1280),
[ZHTPS normalization call](../src/server/worker.zig:1298).

ZHTPS preserves repeated slashes and reserved separators, decodes unreserved
escapes before removing dot segments, and canonicalizes remaining escapes.
nginx's normalization has different semantics and configuration. Any bypass
must preserve those ZHTPS behaviors, including distinguishing a dot segment
from a name such as `.well-known`, and retain borrowed bytes through application
and response lifetimes. No benefit has been measured for this proposal.
[Normalization contract](../src/http/path.zig:9).

**7. Combine useful work without starving other connections.** nginx coalesces
adjacent memory into iovecs, advances buffer chains on partial writes, and waits
after an incomplete write. The HTTP write filter postpones small output only
when neither a final buffer nor an explicit flush requires sending. It also
limits send work; the configured default maximum chunk is 2 MiB. Posted events
provide continuation without recursive processing of all buffered requests.
The regular posted queue itself drains until empty, so it is not a universal
fixed-size fairness budget.
[Gather writes](../../nginx/src/os/unix/ngx_writev_chain.c:51),
[flush and send limits](../../nginx/src/http/ngx_http_write_filter_module.c:219),
[chunk default](../../nginx/src/http/ngx_http_core_module.c:3951),
[posted event processing](../../nginx/src/event/ngx_event_posted.c:12).

ZHTPS already gathers response headers/body, batches up to 16 built-in responses
into 4 KiB, and bounds completion/producer work. Generalizing aggregation to
custom responses requires ownership transfer or copies of every retained slice
and well-defined cleanup timing. Removing the custom-app exclusion would break
that contract. Further fairness work should target mixed large/small responses;
changing the existing completion count alone has not established a benefit.
[Batching contract](../src/server/ResponseBatch.zig),
[prior assessments](architecture-implementation.md).

**8. Treat logging as formatting plus a finite-capacity sink.** nginx compiles
format operations and optionally appends records into a contiguous byte buffer,
with configurable timed flush. Buffering is opt-in. Its file-write path executes
from the worker and explicitly handles failed or incomplete writes; it is not
an example of guaranteed lossless asynchronous logging.
[Record buffering](../../nginx/src/http/modules/ngx_http_log_module.c:327),
[file writes](../../nginx/src/http/modules/ngx_http_log_module.c:419),
[buffer/flush options](../../nginx/src/http/modules/ngx_http_log_module.c:1485).

ZHTPS already has compiled Zig formatting, bounded record queues, and a shared
sink with 16-record gather writes. Byte-oriented batching or cheaper optional
fields may help particular log formats, but the earlier 64-record experiment
showed no reliable improvement. Required delivery, sink speed, and drop policy
must remain part of the assessment. Copying synchronous file writes into the
network loop would introduce a blocking dependency.
[Logger](../src/Logger.zig),
[logging evidence](architecture-implementation.md).

**9. Reuse coarse time only where its precision is sufficient.** nginx updates
cached time through event-loop processing and caches formatted HTTP/log dates.
Its timer tree skips an existing timer update when the deadline moves by less
than 300 ms. This saves tree mutations by deliberately retaining the previous
expiration; it is a semantic tradeoff.
[Time cache](../../nginx/src/core/ngx_times.c:81),
[event loop time update](../../nginx/src/event/ngx_event.c:195),
[lazy timer update](../../nginx/src/event/ngx_event_timer.h:50).

ZHTPS already caches HTTP date formatting and scans active slots rather than
the entire capacity. Earlier measurements put its five request clock reads at
about 82 ns and maintenance of 4,096 idle sockets at about 0.1–0.2% of one core.
These bound the opportunity at that scale. A 300 ms tolerance is inappropriate
for short application deadlines or precise latency accounting. Revisit the
timer structure only if substantially larger idle populations make scans costly.
[Measured costs](architecture-implementation.md).

**10. Tune accept policy for its actual listener model.** nginx uses nonblocking
accept, configurable multi-accept, and timed retry after descriptor exhaustion.
Both multi-accept and the accept mutex default to off in this checkout. Its
EPOLLEXCLUSIVE listener reordering addresses distribution among workers sharing
a listener and explicitly skips reuseport listeners.
[Accept handling](../../nginx/src/event/ngx_event_accept.c:48),
[defaults](../../nginx/src/event/ngx_event.c:1368),
[listener reordering](../../nginx/src/event/ngx_event_accept.c:441).

ZHTPS already has per-worker reuseport listeners and resource retry deadlines.
Its prior multishot/larger-backlog experiments improved some churn counters but
worsened goodput or p99 under pressure. Persistent-connection tests do not make
accept the primary suspect. Idle-slot reclamation in rank 2 is the distinct new
policy opportunity; wholesale adoption of nginx's listener coordination is not.
[Existing accept assessment](architecture-implementation.md).

**11. Preserve local connection ownership and explicit offload.** nginx workers
own their event loops and connection pools, support CPU affinity, and can offload
selected work through bounded thread-pool queues with completion notification
back to the event loop. The pool still uses a mutex and condition signaling;
thread offload does not eliminate synchronization.
[Worker affinity](../../nginx/src/os/unix/ngx_process_cycle.c:881),
[bounded thread-pool submission](../../nginx/src/core/ngx_thread_pool.c:231).

ZHTPS's topology-aware placement, private network workers, and newly shared
bounded application lanes already capture the relevant separation. nginx's
process boundary provides different fault isolation and operational behavior,
but this review provides no performance basis for adopting it. Likewise, nginx's
readiness-driven I/O demonstrates another viable design, not a causal diagnosis
of the earlier Go parity. The previous ZHTPS immediate-send experiment already
failed to establish a repeatable whole-server benefit. Retaining the current
backend leaves all of the higher-ranked lifetime and API improvements available.
[Completed executor and I/O assessment](architecture-implementation.md).
