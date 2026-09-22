# ZHTPS

An embeddable HTTP server and standalone executable for Zig 0.16.0, built on Linux
io_uring. Requires Linux 6.0+ and an x86-64-v4 CPU (including AVX-512). Builds pinned
OpenSSL 3.5 LTS and libnghttp2 sources with Zig by default.

[Build and run](docs/getting-started.md) · [Documentation](docs/README.md) ·
[Benchmarks](docs/benchmarks.html)

## Features

- **HTTP/1.1 and HTTP/1.0:** Persistent connections, ordered pipelining, and HTTP/1.0
  keep-alive interoperability.
- **HTTP/2 over TLS:** Multiplexed requests, HPACK header compression, SETTINGS,
  PING, stream cancellation, and connection/stream flow control through nghttp2.
- **Request bodies:** Content-Length and chunked decoding, chunk extensions, and
  separate request trailers, with buffered or incremental application consumption.
- **Streaming responses:** Known or unknown lengths, chunked HTTP/1.1 output, and
  HTTP/2 DATA frames; generated endpoints expose a writer with flush and cancellation
  for large responses and server-sent events.
- **100 Continue:** Admission and head checks run before accepting an upload.
- **Methods:** Custom endpoints support GET, HEAD, POST, PUT, PATCH, DELETE, and
  OPTIONS; bundled resources implement GET, HEAD, POST, and OPTIONS.
- **HEAD and OPTIONS:** Automatic HEAD for GET routes, resource and server-wide
  OPTIONS, and accurate Allow headers on method errors.
- **Conditional requests:** Bundled GET resources have ETags; applications can
  evaluate entity-tag and modification-date preconditions with the public helper.
- **Routing:** Normalized paths, named parameters, nested route groups, middleware,
  query/header access, and typed JSON request parsing.
- **Static sites:** Directory mounts with index pages, content types, streaming,
  HEAD and cache revalidation. See [static files](docs/endpoints.md#static-files).
- **Response helpers:** Text, JSON, redirects, custom headers/statuses, and automatic
  Date and framing headers.
- **TLS 1.3:** OpenSSL provides AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305,
  PEM certificate chains, cross-worker session resumption, and TLS close notifications;
  ALPN prefers HTTP/2, then HTTP/1.1, with HTTP/1.1 when ALPN is absent.
- **IPv4 and IPv6:** Separate public/admin bind addresses and optional ephemeral ports.
- **Graceful shutdown:** Drains active work, gives established HTTP/1 keepalives a
  final-request window, and sends HTTP/2 GOAWAY.
- **Observability:** Prometheus and JSON metrics, structured application/access logs,
  health checks, and worker/connection inspection on a separate admin listener.

See [HTTP semantics and scope](docs/conformance.md), [HTTP/2](docs/http2.md),
[TLS](docs/tls.md), and the [endpoint API](docs/endpoints.md) for contracts and limits.
There is no h2c, HTTP/3, WebSocket/Upgrade, CONNECT tunnel, server push, automatic
compression, or range serving; TLS uses one certificate chain without SNI-based
selection or client-certificate authentication.

## Security

- **Strict request framing:** Rejects ambiguous lengths, Transfer-Encoding plus
  Content-Length, duplicate Host fields, malformed line endings, and folded headers.
- **Consistent routing:** Normalizes paths before dispatch while preserving original
  bytes, rejects transport/scheme mismatches, and does not trust forwarded identity.
- **Trailer separation:** Rejects framing, authentication, and other sensitive fields
  in trailers so late metadata cannot replace the request head.
- **Bounded input:** Limits headers, field counts, paths, bodies, trailers, and total
  chunk framing; checked size arithmetic and bounded SIMD reads protect storage.
- **Bounded application storage:** Request scratch and JSON nesting have explicit
  limits, including scratch bounds in ReleaseFast.
- **Compile-time contracts:** Rejects invalid or ambiguous routes, unknown declaration
  options, and invalid metric definitions before serving.
- **Response validation:** Checks header syntax, reserves framing fields, verifies
  stream lengths, and suppresses bodies where HTTP forbids them.
- **Admission and rejection budgets:** Bounds active work, optional request rates,
  and rejection traffic; exhausted budgets shed work before further parsing.
- **Deadlines and backpressure:** Monotonic deadlines bound handshake, header, body,
  write, idle, and close phases, while bounded buffers regulate producers and consumers.
- **HTTP/2 abuse limits:** Caps streams, protocol memory, continuation frames,
  queued acknowledgments, and reset rates.
- **Application isolation:** Bounded lane queues keep user hooks off transport
  threads and let route groups reserve separate executor threads.
- **Safe cancellation and reuse:** Retains borrowed storage until hooks and all I/O
  completions finish, with exactly-once application cleanup and startup rollback.
- **Resource exhaustion handling:** Allocation failures release affected resources,
  and descriptor exhaustion triggers accept backoff to avoid a busy loop.
- **Admin separation:** Loopback defaults, exclusive admin binding, reserved storage,
  no-store responses, and owner-captured inspection avoid accidental public sharing.
- **Bounded, private diagnostics:** Escaped JSON, fixed log queues, sampled rejections,
  fixed metric cardinality, and input-free error bodies limit disclosure and log floods.
- **TLS policy:** Requires TLS 1.3 and OpenSSL security level 2, validates credentials
  at startup, and disables early data, record compression, and renegotiation.
- **Executable hardening:** The standalone server uses PIE for address randomization;
  ReleaseSafe retains runtime safety checks.
- **Deployment input safety:** Configuration generators validate addresses and create
  files exclusively to reject injection, accidental overwrites, and symlink targets.

Admin has no authentication and remains HTTP; keep it private. Applications own
authentication, authorization, and shared-service synchronization, and running hooks
must cooperate with cancellation. Details and evidence: [security review](docs/security.md),
[runtime limits](docs/runtime.md), and [endpoint lifetimes](docs/endpoints.md).

## Performance

- **Worker ownership:** Each thread owns an io_uring ring, sockets, and admission
  counters; SO_REUSEPORT distributes connections without a shared request-permit lock.
- **CPU placement:** Explicit worker affinity and a NIC/topology helper can keep
  networking and application work on suitable cores.
- **Bounded I/O batches:** Processes completions and submits ready work in batches
  without waiting for a batch to fill.
- **SIMD parsing:** AVX-512 scans long headers and field values, with narrower paths
  for short inputs and tails.
- **Compile-time routing:** Route declarations specialize the application, and heads
  without user middleware avoid an executor round trip.
- **Shared application lanes:** Threads consume server-wide bounded queues so spare
  lane threads can serve requests from any transport worker.
- **Reusable storage:** Worker-local connection, request, large-buffer, and HTTP/2
  stream caches reduce allocations; idle HTTP/1 sockets release request storage.
- **Cache-aware layout:** Padded buffer placement reduces cache-set conflicts.
- **Fewer copies and sends:** Borrowed bodies, vectored header/body sends, and gathered
  stream fragments reduce copying and syscall overhead.
- **Pipeline aggregation:** The built-in application can combine up to 16 small
  responses, flushing promptly and preserving admission headroom.
- **Efficient HTTP/2 output:** Submits response headers directly to nghttp2 and batches
  frames into TLS records while allowing reads and writes to progress independently.
- **Bounded streaming:** Upload consumers and response producers process large bodies
  incrementally without retaining the whole payload.
- **TLS reuse:** Shared credentials and session resumption reduce repeated handshake
  work; HTTP/1 socket I/O uses BIO storage directly.
- **Cheap bookkeeping:** Caches formatted Date headers, skips full token-bucket refill
  work, and collects metrics without heap allocation or locks.
- **Asynchronous logging:** Batched writes and drop-on-full queues keep slow log
  consumers from blocking HTTP; access logging can be disabled.
- **Connection turnover:** Optional idle reclamation frees slots under pressure, and
  thin-stream TCP retries can recover short responses sooner after packet loss.

See [runtime details](docs/runtime.md), [SIMD measurements](docs/simd.md),
[architecture measurements](docs/architecture-implementation.md), and
[HTTP/2 experiments](docs/bun-http2-implementation.md).

## Knobs

Start with `-Doptimize=ReleaseSafe` (the build default is `Debug`) and measure
successful throughput, p99 latency, errors, queueing, and memory under your actual
workload. The standalone executable accepts all of the flags below.

### Listeners and TLS

- `--address IP` (default: `127.0.0.1`): Public listener address, IPv4 or IPv6.
- `--port PORT` (default: `8080`): Public listener port; `0` chooses a free port.
- `--admin-address IP` (default: `127.0.0.1`): Separate HTTP admin listener address.
- `--admin-port PORT` (default: `9090`): Admin listener port; `0` chooses a free port.
- `--tls-certificate PATH` (default: unset; TLS disabled): PEM certificate chain;
  requires `--tls-key` to enable HTTPS on the public listener.
- `--tls-key PATH` (default: unset): Unencrypted PEM private key matching
  `--tls-certificate`; both paths are required for TLS.
- `--http-redirect` (default: disabled): Enable an HTTP listener that sends 308
  redirects to HTTPS. Requires both TLS credentials; otherwise startup fails.
- `--http-redirect-port PORT` (default: `80`): Redirect listener port on `--address`;
  `0` chooses a free port. Used only with `--http-redirect`; must differ from the
  HTTPS `--port`. Redirects preserve the hostname, raw path, and query string.
- `--tls-handshake-timeout-ms N` (default: `5000`): TLS handshake deadline in
  milliseconds; requires the certificate and key options.

### Workers and resource budgets

Automatic sizing is enabled by default. Explicit numbers override individual
choices; cgroup service limits take precedence over host capacity. Inspect the
effective limits and sizing sources at `/debug/config`. See
[automatic defaults](docs/configuration.md#automatic-defaults) for the policy.

- `--workers N` (default: `auto`): Event-loop threads and io_uring rings, sized
  within CPU, cgroup, memory, and descriptor limits, accounting for lane threads.
- `--worker-cpus LIST` (default: automatic NIC placement when supported): Ordered logical CPU
  IDs or ranges, such as `9,10-12`, with one distinct CPU per worker.
- `--max-connections N` (default: `auto`): Public connection slots per worker.
- `--memory-budget-bytes N` (default: 1/4 of detected available memory): Process
  sizing allowance, constrained by remaining host and cgroup memory.
- `--admin-connections N` (default: `8`): Reserved admin slots on worker zero;
  `0` disables the admin listener.
- `--completion-budget N` (default: `64`): Maximum completions processed per
  event-loop iteration.
- `--response-batches N` (default: `64`): Aggregate response buffers per worker for
  the built-in application; `0` disables aggregation.
- `--large-buffer-bytes N` (default: `auto`, up to 64 MiB): Leased large-buffer bytes
  per worker; cached and small buffers are additional.
- `--http2-max-streams N` (default: `100`): Concurrent HTTP/2 streams per connection.
- `--http2-worker-streams N` (default: `auto`): Active or retained HTTP/2 streams per
  worker, including reset streams whose application hooks have not returned.
- `--http2-memory-bytes N` (default: `auto`, up to 64 MiB): HTTP/2 protocol, transport,
  stream, and cached allocation budget per worker.

### Admission

These budgets apply **per worker**. Divide a process budget across workers and
leave headroom for uneven connection distribution. Derived counts use public
connection slots, excluding the admin reserve.

- `--max-active N` (default: `max(1, floor(max-connections * 3 / 4))`): Maximum
  active public requests per worker.
- `--max-rejecting N` (default: `max(1, floor(max-connections / 8))`): Concurrent
  rejection responses per worker; `0` closes excess requests without sending 503
  responses.
- `--rate N` (default: `0`, disabled): Admitted requests per second per worker.
- `--burst N` (default: effective `--max-active`): Request
  token-bucket capacity per worker when rate limiting is enabled.
- `--rejection-rate N` (default: `1000`): Rejection responses per second per worker.

### Timeouts and connection reuse

All timeout and age values below are in milliseconds.

- `--header-timeout-ms N` (default: `5000`): Request header deadline.
- `--body-timeout-ms N` (default: `30000`): Request body deadline.
- `--write-timeout-ms N` (default: `5000`): Response write deadline.
- `--idle-timeout-ms N` (default: `15000`): Keepalive idle deadline.
- `--tcp-retries MODE` (default: `thin-linear`): TCP retry policy for public sockets;
  accepts `thin-linear` or `system`.
- `--idle-reclaim-ms N` (default: `0`, disabled): Minimum completed keepalive idle
  age before reclaiming a slot under pressure; must be below `--idle-timeout-ms`
  when enabled.
- `--close-timeout-ms N` (default: `100`): Bounded response drain deadline.
- `--shutdown-keepalive-ms N` (default: `100`): Final-request window for established
  public keepalives during shutdown, capped by `--shutdown-timeout-ms`; `0` closes
  idle keepalives immediately.
- `--shutdown-timeout-ms N` (default: `5000`): Graceful shutdown drain deadline.
- `--max-requests N` (default: `1000`): Maximum requests per connection.

### Request limits

- `--max-body-bytes N` (default: `67108864`, 64 MiB): Server request body limit;
  generated routes default to 64 KiB and may impose a smaller limit.
- `--max-chunk-framing-bytes N` (default: `65536`, 64 KiB): Cumulative chunk framing
  overhead limit per request.

### Logging and help

- `--log-slots N` (default: `256`): Buffered JSON log records per worker.
- `--no-access-log` (default: off; access logging enabled): Omit per-response logs
  while retaining metrics and other events.
- `--verbose` (default: off): Include JSON debug events.
- `--help` (default: off): Print usage and exit; pass this flag alone.

Embedded applications also configure lanes and buffer sizes through the Zig API.
Each lane defaults to `threads = 1`, `queue = 64`, and `timeout_ms = 100`; thread
and queue counts are multiplied by workers and shared across the server. Keep
CPU-heavy concurrency within available CPU capacity, size blocking lanes to
downstream capacity, and give long-lived streams their own lane. The default
`application_bytes` is 65536 (64 KiB) per live exchange; buffered bodies share it
with parsing and response scratch, while streaming avoids retaining the whole body.

The [configuration guide](docs/configuration.md) covers library settings, sizing
examples, and workload tradeoffs; [observability](docs/observability.md) explains
what to measure.

## Example

After [adding zhtps to your Zig project](docs/embedding.md), this `main.zig`
serves a custom endpoint at `http://127.0.0.1:8080/hello/Ada`:

```zig
const std = @import("std");
const zhtps = @import("zhtps");

const api = struct {
    fn hello(call: *zhtps.Call(@This())) zhtps.EndpointError!zhtps.http.Response {
        return call.json(.ok, .{ .hello = call.param("name").? });
    }

    pub const routes = .{zhtps.get("/hello/:name", hello)};
};

pub fn main(init: std.process.Init) !void {
    const App = zhtps.Application(api);
    var server: App.Server = undefined;
    try server.init(init.gpa, init.io, .{
        .port = 8080,
        .admin_connections = 0,
    }, .{});
    defer server.deinit();
    try server.serve();
}
```

Run `zig build`, start your executable, and `curl http://127.0.0.1:8080/hello/Ada`
to receive `{"hello":"Ada"}`. The embedding host owns signal handling; see
[lifecycle and graceful shutdown](docs/embedding.md) and [more endpoint examples](docs/endpoints.md).

To serve a static site, replace `api` with:

```zig
const api = struct {
    pub const lanes = .{ .files = .{ .timeout_ms = 30_000 } };
    pub const routes = .{
        zhtps.staticFiles(@This(), "/", .{ .root = "public" }),
    };
};
```

Put your site's files in `public/`; `/` serves `public/index.html`. Use a prefix
such as `/assets` to mount a directory alongside your API endpoints.
