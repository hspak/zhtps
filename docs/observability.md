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

## Structured logging

Stderr contains newline-delimited JSON. Normal events include listener startup,
request completion, sampled rejection, and shutdown start. `--verbose` adds
connection/request events and operation completion results. Connection and
request IDs, together with the worker ID, correlate records with inspection
output. `--no-access-log` skips per-response records while retaining metrics,
startup, sampled rejection, shutdown, and explicitly requested debug events.
Logs never contain request bodies or arbitrary headers.

Each worker has a fixed queue (`--log-slots`, default 256). An atomic owner
allows one asynchronous log write in flight across that server's workers and retains
ownership across partial writes, preserving whole JSON records without blocking
other event loops. Queues drop events when full, exposing the loss in metrics. Normal
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
