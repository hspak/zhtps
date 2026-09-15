# Admission, I/O, and shutdown

## Admission and overload

The built-in application has no request queue; generated custom endpoints use
bounded executor queues shared by all workers. When admission and rejection budgets are
both exhausted, the server closes incoming request traffic before parsing more
head bytes. Otherwise admission runs after a bounded head has been parsed, before
body processing or `100 Continue`. A local permit limit bounds active requests;
a token bucket optionally limits request rate.

Admission counts default relative to each worker's `--max-connections`:

| Setting | Automatic default | With 256 public slots |
| --- | --- | ---: |
| `--max-active` | Three quarters of public slots, rounded down, minimum one | 192 |
| `--max-rejecting` | One eighth of public slots, rounded down, minimum one | 32 |
| `--burst` | Effective `--max-active`, including an explicit override | 192 |

For example, `--workers 16 --max-connections 2048` allows 1,536 active requests
and 256 concurrent rejections per worker: up to 24,576 active requests across
the server. Admin slots do not affect these defaults. Explicit admission options
take precedence regardless of CLI order. Active and rejection concurrency cannot
individually exceed the public connection budget; `--max-rejecting 0` disables
503 admission responses and closes excess requests immediately.

These defaults leave headroom for request headers, rejection, and closing drains.
They do not reserve public slots against idle clients or guarantee peak CPU
performance. With a single public slot, active and rejection requests necessarily
share that slot. Per-second rates cannot be inferred from connection counts:
`--rate` remains disabled by default and `--rejection-rate` defaults to 1,000 per
worker. Tune rates using the application's measured sustainable throughput.

[Direct-server admission](native-admission.md) requires no HTTP proxy. An
optional standalone nftables policy bounds new connection attempts on the same
host, with explicit calibration values. The [NGINX bundle](ingress.md) remains
available for deployments that want a proxy; it is not required for local or
distributed benchmark collection.

```sh
./zig-out/bin/zhtps --max-connections 512 --max-active 64 \
  --max-rejecting 16 --rate 10000 --burst 128 --rejection-rate 1000
```

Overload sends an empty 503 response when a rejection permit and rejection token
are available. If either is exhausted, the connection closes without an HTTP
response. Bodyless requests can keep their connection after a 503; unread
bodies, explicit close, and connection lifetime limits still require closure.
Admission rejection uses the already acquired request storage and connection
buffers without a further allocation. After sending
a closing response, the server half-closes its write side and drains at most 64 KiB for at most
`--close-timeout-ms` before closing. This reduces TCP reset loss of the response
without allowing an unbounded drain. The peer is not guaranteed to receive a
503 after the rejection budget is exhausted.

## Memory and chunk framing

Connection slots are allocated at startup; small public buffers follow accepted
sockets, while request objects and larger public buffers are leased on demand.
The larger buffers have a per-worker byte budget. Socket buffers, io_uring, request/connection structures
and logging consume additional memory. The default 256 public slots can lease
about 5.1 MiB of small buffers; up to 64 sets are reserved initially. Eight admin
slots reserve their full 160 KiB buffer sets.

Chunked requests have a cumulative framing budget of 64 KiB, independent of the
decoded body limit. `--max-chunk-framing-bytes N` changes it (minimum 3). The budget
counts size lines, extensions, and chunk delimiters; trailers have their own
storage limit. Exceeding it returns 413 and closes the connection. Clients sending
many tiny chunks may need a larger budget. The limit applies to admin requests
and resets for each request on a persistent connection.

## I/O and response aggregation

Each socket has at most one receive and one send in flight. Writes preserve
HTTP response order, including pipelined requests. The loop processes a bounded
completion batch and submits available work immediately; it never waits to fill
a batch. Small headers and bodies share a send; larger borrowed bodies use a
vectored header/body send. Low-level synchronous response streams gather up to
16 available producer fragments within the existing buffer. A fragment that does
not fit stays borrowed until the next fill. Those low-level calls must be bounded
and nonblocking. Generated streaming endpoints use an application-lane producer
and a bounded handoff buffer, with explicit flush and cancellation.

Small public pipeline responses may share TCP output when the next request head
is already buffered. The built-in application can also copy up to 16 complete
responses into a 4 KiB buffer and submit one send. It starts aggregates only when
the active-request budget is at least four times the worker's current connection
count, and flushes early to preserve admission headroom. Short aggregates retain
TCP coalescing, with a flush after at most 16 responses. Output is always flushed
before waiting for more input or sending an interim, streaming, large, or closing
response.

`--response-batches N` (`Config.response_batches`) reserves aggregate buffers
per worker at startup; the default is 64, capped at the public connection capacity.
Each buffer and its completion records occupy 4,648 bytes: 290.5 KiB per worker
at the default setting, plus an 8-byte pointer per built-in connection slot.
Zero disables aggregation. Aggregate-pool exhaustion falls back to ordinary
sends; aggregation itself performs no additional allocations. Custom applications retain ordinary
sends and allocate no aggregate pool, preserving their cleanup and borrowed
access-field contracts. Built-in access logging works with aggregation; each
record owns its metadata until completion.

`/debug/workers` reports `response_batch_capacity`. Metrics include
`response_batches_total` (initial batch submissions), `responses_batched_total`
(responses in those submissions), and `response_batch_fallbacks_total` (eligible
responses sent ordinarily because the pool was exhausted). Partial sends retain
storage and admission permits until the corresponding response completes;
cancellation retains storage until every outstanding operation completes.
See the [aggregation integration and measurements](response-aggregation-integrated.md).

These limits control admitted work and resource retention. They cannot make
arbitrarily high offered traffic free: TCP accepts, parsing, rejection, kernel
queues, and the shared CPU still cost work. A same-host kernel connection policy
can shed excess SYNs earlier; a proxy is optional. The admin listener reserves
slots and bypasses application
admission, but shares worker zero's event loop and CPU.

## Graceful shutdown and cancellation

SIGTERM/SIGINT shut down each worker's public and admin listening sockets, so
new TCP connections are refused and connections still queued in the listen
backlog are discarded. Active requests and responses can finish within
`--shutdown-timeout-ms` (default 5000), then outstanding operations are canceled.
Repeated signals leave the original deadline in place. The signal handler only
sets an atomic stop flag; workers observe it on their event loops, including the
10 ms timer when idle. Listener descriptors remain owned until cleanup so
pending accepts cannot reference reused descriptors. Storage is recycled only
after both operation and cancellation completions have arrived.
Established public keepalives get a final-request window of 100 ms from shutdown
start, controlled by `--shutdown-keepalive-ms` and capped by the overall shutdown
timeout. A request observed in that window can receive one final response with
`Connection: close`, subject to ordinary admission limits. Already-started
headers can finish after the window; their existing deadlines still apply.
Silent peers are half-closed and drained after the window. Initial idle and admin
connections are closed without that extension. Zero restores immediate idle
closure. This timer is independent of pressure reclamation; clients must still
handle closure when reusing a connection after the final cutoff.
Embedded endpoint applications also wait for running hooks to return; neither
the shutdown grace period nor a lane timeout can terminate Zig code safely.
Deadlines for active connection slots are checked on a 10 ms tick and are subject to event-loop and OS
scheduling delay; they are not hard real-time guarantees.
Fatal loop errors also cancel and drain before releasing buffers. An operation
stuck in uninterruptible kernel I/O can extend cancellation beyond the work-drain
deadline; memory safety requires waiting for its completion. A kernel failure
that makes both cancellation and completion collection unusable terminates the
process instead of freeing memory still referenced by I/O.
