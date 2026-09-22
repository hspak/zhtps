# Observability

## Admin interface

```sh
curl http://127.0.0.1:9090/metrics
curl http://127.0.0.1:9090/debug/metrics
curl http://127.0.0.1:9090/debug/config
curl http://127.0.0.1:9090/debug/workers
curl http://127.0.0.1:9090/debug/connections
curl http://127.0.0.1:9090/healthz
```

The admin interface has no authentication and is intended for a trusted local
scraper/operator. `/metrics` uses Prometheus text format. `/debug/metrics` exports
the same counters/gauges as JSON, plus histogram bounds, noncumulative bucket
counts, and nanosecond sums. Both merge worker snapshots before formatting;
occupancy is summed and `draining` is true when any worker is draining.
`/debug/config` returns effective budgets (including automatic admission counts)
and resolved ports.
`/debug/workers` lists worker IDs, Linux thread IDs, ring sizes, occupancy and
request counts, in pages of at most 32 workers; follow `next` with `?start=N`.
`/debug/connections` reports at most 32 live connections, their phase, permit,
pending operations, elapsed time, and remaining deadline. Follow its `next`
cursor with `?start=N`; pages are observations, not a consistent snapshot across
requests. The cursor spans workers; `(worker, id)` identifies a connection.
Remote pages are captured by their owning worker through a bounded mailbox on
the timer tick; a busy mailbox returns 503. Admin requests never read another
worker's mutable connection structures. It omits request headers and bodies.

## Metrics and timing

Key metrics include:

- Admitted/rejected/completed/aborted requests, status classes, protocol errors,
  header/body/application/write timeouts, application queue rejections, and
  admission rejections that had to close without a response, including the subset
  closed before completing header parsing.
- Active connections, active request/rejection permits, pending I/O, and queued logs.
- Separate latency histograms for admitted, rejected, aborted, and admin requests.
- First-response-byte latency, header duration, and event-loop preparation time.
- Submitted/completed/failed I/O, bytes received/sent, dropped logs, and log write errors.

Request duration starts when the worker first processes request bytes and ends
when the final send completes. First-byte latency ends at the first final-response
send completion. These measure application/kernel handoff, not acknowledgement
or arrival at the client. They exclude earlier TCP/kernel queueing. Request
latency excludes admin traffic; the general counters include it. Event-loop
preparation time excludes CQ waiting and is not a full CPU utilization measure.
Responses are counted when queued; completion and abort counters distinguish
successful transmission to the local socket from abandoned work.

## Direct VictoriaMetrics push

```sh
zhtps --victoria-metrics http://127.0.0.1:8428
zhtps --victoria-metrics https://metrics.example.com --victoria-logs https://logs.example.com
```

The recommended push method for this server is batched Prometheus text over
HTTP(S), using `/api/v1/import/prometheus`. This is an engineering choice for our
small, fixed-cardinality snapshots, rather than a claim that text wins every
ingestion benchmark. It reuses the `/metrics` renderer, including application
metrics, without adding codecs or dependencies. VictoriaMetrics documents this
endpoint, request-wide labels, timestamps, and optional gzip in its
[Prometheus import guide](https://docs.victoriametrics.com/single-server-victoriametrics/#how-to-import-data-in-prometheus-exposition-format).

| Method | Fit for ZHTPS |
|---|---|
| Prometheus text | Existing representation; one batch per snapshot with preserved metric names and histogram buckets. Selected. |
| Remote write | Protobuf and Snappy require additional encoding and compression. Worth reconsidering for much higher cardinality or bandwidth pressure. |
| JSONL | Separate encoder; per-series arrays offer little benefit when each snapshot has one sample per series. |
| CSV | Separate schema and encoder, especially for labeled histogram buckets and application metrics. |
| Native binary | Intended for importing VictoriaMetrics exports; the documented format is unstable and discouraged for external encoders. |

The [remote-write specification](https://prometheus.io/docs/specs/prw/remote_write_spec/)
defines its protobuf/Snappy requirements. The [VictoriaMetrics import guide](https://docs.victoriametrics.com/single-server-victoriametrics/#how-to-import-time-series-data)
describes the other formats and native-format restriction.

A local startup snapshot measured 176 samples and 10,893 bytes including type
comments: approximately 1.1 kB/s at ten-second intervals, before HTTP/TLS overhead.
Gzip reduced that example to 1,119 bytes, but this implementation sends plain text
to keep encoding work and dependencies small at this rate. Counts and integer
widths grow with traffic; custom metrics add series. This is a payload measurement,
not a comparative ingestion-throughput benchmark. Collection reads each worker's
atomic metrics once per snapshot; no new per-request work is added. Connection
reuse amortizes TCP/TLS setup.

The sender starts with an immediate snapshot, waits ten seconds after each attempt,
and sends one final snapshot after producers stop. Every batch carries its capture
timestamp in Unix milliseconds, plus `job=zhtps`, the machine hostname (`host`),
and `[PUBLIC_ADDRESS]:BOUND_PORT` (`instance`). The host/instance pair distinguishes
servers across machines. All workers contribute to the same series; request paths,
client addresses and worker IDs do not become labels. Snapshots are atomic reads,
not transactions across all metric fields, as with `/metrics`.

Delivery uses a separate background task, one reusable 256 KiB body buffer, and
the same deadline-bound HTTP transport as VictoriaLogs. HTTP(S) origins may end
with `/`; credentials, paths, queries and fragments are rejected. HTTPS uses the
system trust store and verifies the hostname. Redirects are not followed.
Each POST has a two-second deadline; shutdown cancels the current attempt and
allows up to two additional seconds for the final POST. Logging options and the
admin listener do not control metric publishing.

Delivery is best effort, with no durable queue or retry of old snapshots. Network
errors, non-2xx responses, timeouts, concurrency failures and buffer overflow
increment `zhtps_metrics_push_errors_total`; successful HTTP deliveries increment
`zhtps_metrics_pushes_total`. Failed intervals lose gauge/history samples; subsequent
cumulative counters retain their totals. VictoriaMetrics' streaming import can
acknowledge malformed input, so HTTP success does not prove every sample was
stored; monitor the collector's `vm_rows_invalid_total` as well. Do not also scrape
these same series into the same database without arranging distinct labels or
deduplication.

## Structured logging

Stderr contains newline-delimited JSON. Normal events include listener startup,
request completion, sampled rejection, and shutdown start. `--verbose` adds
connection/request events and operation completion results. `--no-access-log`
skips per-response records while retaining metrics, startup, sampled rejection,
shutdown, and explicitly requested debug events. Logs never contain request
bodies or arbitrary headers.

The `worker` ID remains a separate integer field. Connection-related records also
include integer `conn_gen` and `conn_slot` fields, replacing the packed `connection`
field. For example, `"worker":0,"conn_gen":59,"conn_slot":3` identifies slot 3
on worker 0 at generation 59. The generation increments whenever a slot accepts
a new connection; requests on the same connection share all three fields.
Records without a connection omit `conn_gen` and `conn_slot`. Access records omit
the increasing `request` ID; application and diagnostic events may still include it.
To correlate with `/debug/connections`, match `worker` and reconstruct its `id`
as `(conn_gen << 32) | (conn_slot << 8)`.

Access records include `client_ip`, the socket peer's IPv4 or IPv6 address without
a port. The address is captured when the connection is accepted and accompanies
HTTP/1 and HTTP/2 responses, including batched responses and aborted HTTP/2 streams.
Behind a reverse proxy this is the proxy's IP; `Forwarded` and `X-Forwarded-For`
headers do not override it.

Access records also include `user_agent` when the request supplies a `User-Agent`
header. Header names are matched case-insensitively; the first value is used if
repeated. The value is JSON-escaped, and an explicitly empty header is logged as
an empty string. Each batched response retains its own value through parser reuse.
The existing fixed log-record size limit still applies; oversized records are
dropped and counted in `log_dropped_total`.

Built-in static file responses also include `fields.file_path`, the decoded file
path relative to the serving directory. Directory indexes include their filename,
such as `guide/index.html`; `route` continues to identify the configured mount.
HEAD and conditional responses include the file path as well.

Startup emits `resources_resolved` at info level with every resolved resource
budget, including derived admission counts and burst, plus the sizing sources.
`worker_resources_resolved` records each worker's selected CPU and actual io_uring
submission/completion queue sizes. Per-worker budgets use `_per_worker` field
names; `memory_budget_bytes` and `estimated_bytes` describe the process. CPU null
means scheduler placement. These events remain enabled with `--no-access-log` and
do not require `--verbose`. See [automatic defaults](configuration.md#automatic-defaults).

Each worker has a fixed queue (`--log-slots`, default 256). An atomic owner
allows one asynchronous log write in flight across that server's workers and retains
ownership across partial writes, preserving whole JSON records without blocking
other event loops. Each write selects up to 128 already-queued records without
waiting to fill the batch. See [access-log costs](access-log-performance.md) for
measurements and sink limitations. Queues drop events when full, exposing the loss in metrics. Normal
rejection events sample the first and every 1024th rejection; verbose mode logs
each. Logging may lose queued records during shutdown. An unread log pipe must
not stall HTTP processing or keep shutdown alive indefinitely; the TCP test
suite exercises that case.

## Metrics collection and rendering

`Metrics` owns atomic counters, gauges, and histogram observations. Collection
uses `add`, `set`, `observe`, and `response`; `snapshot()` copies the observations
into an allocation-free `Metrics.Snapshot`. Renderers consume that snapshot:

```zig
const snapshot = metrics.snapshot();
try zhtps.metrics_format.prometheus.write(&snapshot, prometheus_writer);
try zhtps.metrics_format.json.write(&snapshot, json_writer);
```

These replace the former `Metrics.writePrometheus` and `Metrics.writeJson` methods.
New formats can read `Snapshot.counter`, `Snapshot.gauge`, and `Snapshot.histogram`
using the metric enums, without changing collection or depending on atomic storage.
Histograms retain noncumulative buckets and nanosecond sums; the Prometheus
renderer applies cumulative buckets, seconds, and the `zhtps_` prefix. A snapshot
owns its observations and can be rendered repeatedly after collection continues.
Its atomic reads are independent, including histogram buckets and sums, so it is
not a transactional view across workers. Collection and rendering need no heap
allocation or locks.
