# Custom endpoints

`Application(Api)` builds a routed application whose middleware and handlers run
on bounded executor lanes rather than on the transport event loop. Routes,
middleware, metric names, and lane names are all known at compile time.
Unknown endpoint, group and lane options are compile errors. In this example,
`Auth.authenticate` returns `error.InvalidCredentials` for rejected credentials;
other `Auth.Error` values describe service failures.

```zig
const Api = struct {
    const ApiCall = zhtps.Call(@This());

    pub const Services = struct {
        auth: *Auth,
    };

    pub const Local = struct {
        account_id: ?u64 = null,
    };

    pub const metrics = struct {
        pub const Counter = enum { widgets_created_total };
    };

    pub const HandlerError = zhtps.EndpointError || Auth.Error;

    pub const metrics_namespace = "example";
    pub const lanes = .{
        .api = .{ .threads = 4, .queue = 128, .timeout_ms = 100 },
    };

    fn authenticate(call: *ApiCall) !?zhtps.http.Response {
        const authorization = call.header("Authorization") orelse
            return unauthorized();
        call.local.account_id = call.services.auth.authenticate(authorization) catch |err| switch (err) {
            error.InvalidCredentials => return unauthorized(),
            else => return err,
        };
        call.access.put("account_id", call.local.account_id);
        return null;
    }

    fn unauthorized() zhtps.http.Response {
        return .{
            .status = 401,
            .headers = &.{.{ .name = "WWW-Authenticate", .value = "Bearer" }},
        };
    }

    fn createWidget(call: *ApiCall) !zhtps.http.Response {
        const widget_id = try call.paramInt(u64, "widget_id");
        const notify = try call.query("notify");
        const input = try call.bodyJson(struct { name: []const u8 });
        call.metrics.add(.widgets_created_total, 1);
        call.log(.info, "widget_created", .{
            .widget_id = widget_id,
            .notify = notify,
        });
        return try call.json(.created, .{
            .id = widget_id,
            .name = input.name,
        });
    }

    pub const routes = .{
        zhtps.group(.{
            .prefix = "/v1",
            .before = .{authenticate},
            .routes = .{
                zhtps.endpoint(.{
                    .name = "create_widget",
                    .method = .post,
                    .path = "/widgets/:widget_id",
                    .handler = createWidget,
                    .body = .json,
                    .max_body_bytes = 16 * 1024,
                    .lane = .api,
                }),
            },
        }),
    };
};

const App = zhtps.Application(Api);

var services: Api.Services = .{ .auth = &auth };
var server: App.Server = undefined;
try server.init(gpa, io, .{
    .port = 8080,
    .application_bytes = 128 * 1024,
}, .{ .services = &services });
defer server.deinit();
try server.serve();
```

## Routing and request inputs

Path parameters use `:name` with letters, digits and underscores, at most eight
per route. Group prefixes are literal paths and cannot contain parameters.
Declarations must already be normalized: unreserved percent escapes, lowercase
reserved escapes, dot segments, query strings and fragments are rejected at
compile time. Repeated and trailing slashes remain significant. Parameters
borrow the normalized path; reserved escapes such as `%2F` stay encoded.

Routing chooses the most specific matching path before choosing a method.
At the first differing segment, a literal wins over a parameter. A static
resource with no matching method returns 405, without falling back to a broader
parameter route. Equivalent patterns with the same method are compile errors
even when parameter names differ. GET answers HEAD unless an explicit HEAD
route exists for that resource.

`Call.param`, `paramInt`, `query`, `queryInt`, `header`, `bodyBytes`, and `bodyJson`
expose request inputs. Query names and values percent-decode, and `+` means space;
decoded results are byte slices. Duplicate query names and headers return the
first value. Empty query segments are ignored; an explicit `=value` can use an
empty name. `queryInt` returns null for an absent name and `InvalidInput` for an
invalid integer. Query decoding allocates only the selected value in scratch.

## Buffered bodies and scratch

Body policies are `.none`, `.bytes`, `.json`, and `.stream`; body endpoints have a
fixed per-route limit with a 64 KiB default, also capped by `Config.max_body_bytes`.
Buffered `.bytes` and `.json` bodies must fit available application storage.
`.json` checks `application/json` for nonempty
or chunked bodies; `bodyJson(T)` performs JSON syntax and schema validation.
Calling no parser does not validate JSON; calling `bodyJson` on empty input fails.
`bodyJson` checks nesting without recursion before parsing. More than
`zhtps.max_json_depth` (128) nested objects or arrays returns `InvalidInput` (400).

For buffered endpoints, size `Config.application_bytes` for the accepted body
**plus** parsing and response scratch. Its default is 64 KiB: accepting a 64 KiB
body leaves no scratch at all.
The example reserves 128 KiB. Required scratch depends on the schema and response;
allocation exhaustion becomes a logged 500. Early middleware instead has 1 KiB
of separate scratch; `Api.head_scratch_bytes` can set it up to 64 KiB.
Body and scratch occupy disjoint regions once ingestion finishes. Allocation,
alignment and resize requests are bounded by the remaining region capacity in
every optimization mode, including ReleaseFast.

## Streaming uploads

Streaming endpoints declare a consumer and a final handler:

```zig
pub const Local = struct { bytes: usize = 0 };
pub const routes = .{zhtps.endpoint(.{
    .method = .post,
    .path = "/upload",
    .body = .stream,
    .max_body_bytes = 8 * 1024 * 1024,
    .consume = consume,
    .handler = finish,
})};

fn consume(call: *zhtps.Call(@This()), bytes: []const u8) zhtps.EndpointError!void {
    call.local.bytes += bytes.len;
}

fn finish(call: *zhtps.Call(@This())) zhtps.EndpointError!zhtps.http.Response {
    return call.json(.ok, .{ .bytes = call.local.bytes });
}
```

The consumer runs on the selected application lane after head middleware accepts.
There is at most one consumer call in flight per connection. Each decoded chunk
borrows the receive buffer only until that call returns; copy bytes you need to
retain into explicitly bounded storage. Parsing and receiving pause during the
call, so a slow consumer backpressures the sender after socket buffers fill.
Blocking work occupies a lane thread; size or isolate that lane accordingly.
`Api.Local` and scratch allocations persist through consumers, the final handler,
and cleanup. `bodyBytes()` is empty on a streaming route. Its
`Config.application_bytes` budget covers scratch, independently of body size.

Consumers can run before the remaining body framing and trailers are validated.
The final handler runs only after the complete request passes those checks;
use it to commit work that requires a valid complete upload. Abort cleanup must
handle partially consumed bodies. Empty bodies run the final handler without a
consumer call. Consumer errors produce 400 for `InvalidInput` or 500 for other
handler errors and close the connection. Limits, middleware rejection and
`100 Continue` checks still apply. The original application deadline spans all
consumer calls; returning from a consumer does not restart it. The body-read
timeout resumes after each accepted chunk, bounded by that deadline.

## Middleware and errors

OPTIONS and 405 Allow metadata include every declared method for the selected
resource plus generated HEAD/OPTIONS. Explicit OPTIONS handlers can read
`call.allowed_methods`. Automatic resource OPTIONS and 405 execute the first
declared matching template's middleware, on its lane; put shared authentication
and CORS policy on the group, or declare an explicit OPTIONS handler when methods
need different policies. Middleware can return a response with CORS headers.
`OPTIONS *` reports server-wide methods without running resource middleware.
Unmatched paths and protocol/body-policy failures also respond before middleware.
Bodyless generated failures preserve keep-alive; unread bodies require closure.

Handlers, middleware and body consumers use `EndpointError` by default:
`InvalidInput` becomes 400. Set `Api.HandlerError` to a named union including
`EndpointError` for service errors. Other errors become 500 and emit a bounded
`application_error` record carrying the error name. Handle expected authentication
and business failures explicitly when they should produce another status.

Group middleware runs after routing but before request-body ingestion, so it can
reject authentication failures without accepting the body or sending
`100 Continue`. Outer groups run before inner groups. `Api.Local` is reset for
each request and shares typed request-local values with the handler. `Api.Services`
is borrowed through server deinitialization and may be used concurrently.

## Cleanup and lifetimes

If `Local` owns resources, declare `pub fn release(call: *ApiCall) void` on `Api`.
It runs once after middleware has started and after all running hooks and borrowed
response bytes are finished, on success, early response, timeout, or abort. It must
handle partially initialized locals. Cleanup runs on the transport thread and
must be bounded, nonblocking and infallible; use it for external resources such
as heap allocations or leases from a nonblocking pool. Request scratch needs no
cleanup hook: its allocations are automatically reclaimed after hooks, outstanding
I/O and cleanup finish. A timeout does not reclaim storage while a hook is still
running. A hook that never returns also prevents its cleanup.

The `*Call` itself is valid only during its hook. `call.scratch.allocator()` returns
a handle whose state has a stable, exchange-owned address. Handles, allocations
and managed containers using them may be retained in `Local` through cleanup.
Middleware handles continue using the separate head region in later hooks.
Scratch is not thread safe; do not move or reset it, or retain it past cleanup.
Cleanup shares the handler's allocation cursor and may itself run out of scratch.

## Response helpers

Use `try call.textCopy(status, bytes)` to copy ordinary text responses into request
scratch; handler-stack buffers are safe with this helper. `call.text(status, bytes)`
is the zero-copy alternative: it borrows bytes until response completion, so never
pass a handler-stack buffer. `call.json` serializes into connection-owned scratch;
excessive output nesting returns `JsonTooDeep` (500 by default) without consuming
scratch or sending a partial response. `zhtps.JsonError` covers this error and
`OutOfMemory`, and is included in `EndpointError`. Use `call.empty` for 204, 205 and 304;
JSON with these statuses is a compile error, and nonempty text is an assertion
violation. `call.redirect(status, location)` copies Location into scratch and
accepts 301, 302, 303, 307 and 308. Raw `http.Response` headers and bodies likewise
need storage that survives response completion; framing headers remain reserved.

## Static files

Mount a directory with one route declaration:

```zig
const Api = struct {
    pub const lanes = .{ .files = .{ .timeout_ms = 30_000 } };
    pub const routes = .{
        zhtps.staticFiles(@This(), "/", .{ .root = "public" }),
    };
};

const App = zhtps.Application(Api);
```

Run `App.Server` as shown above. `/` serves `public/index.html` and
`/css/site.css` serves `public/css/site.css`. Root paths are relative to the
process working directory, or may be absolute. The directory is opened on each
request, so replacements become visible without restarting. A missing or
inaccessible configured root produces a logged 500; a missing or inaccessible
file within it produces 404.

`staticFiles(Api, prefix, options)` supports these options:

| Option | Default | Meaning |
| --- | --- | --- |
| `root` | Required | Filesystem directory path |
| `index_file` | `"index.html"` | Single filename to serve for directories; `null` disables indexes |
| `cache_control` | `"no-cache"` | Cache-Control response field; permits storage with revalidation |
| `dotfiles` | `false` | Allow names starting with `.`, including `.well-known` |
| `name` | URL prefix | Route name used in logs and metrics |
| `before` | Empty | Middleware, after inherited group middleware |
| `lane` | First declared lane | Application lane for opening and streaming files |

The prefix must be a normalized literal URL path, without a trailing slash
unless it is `/`. A mount at `/assets` covers `/assets` and `/assets/...`, but
does not cover `/assets-other`. Group prefixes and middleware compose normally.
Explicit endpoints, including parameter routes, take precedence over directory
mounts. Among mounts, the longest prefix wins. Method errors on an explicit
endpoint remain 405. Mounted resources support GET, automatic HEAD and OPTIONS;
other supported HTTP methods return 405 with Allow.

Directories with an index redirect to a trailing slash using 308, preserving the
query string so relative links resolve correctly. Directories without an index
return 404; directory listings are never generated. Common web extensions select
Content-Type, with `application/octet-stream` for unknown extensions. Every file
response includes `X-Content-Type-Options: nosniff`, a weak ETag derived from file
metadata, and Last-Modified when the timestamp is representable. Conditional
requests can return 304 or 412. Range requests receive the full representation;
automatic compression and SPA fallback are not provided.

Static file responses add `fields.file_path` to access logs: the decoded path
relative to the serving directory, including the selected index filename.
For example, `/assets/guide/` logs `guide/index.html` for a mount at `/assets`.
The `route` field retains the configured mount name. HEAD and conditional
responses include the same file path; redirects and missing files omit it.
This metadata uses the existing bounded access-field storage described below.

URL escapes decode once for filenames (including spaces and UTF-8); encoded
separators, backslashes, control bytes, `.` and `..` segments are rejected.
The transport first normalizes URL dot segments, and all filesystem lookups stay
relative to the selected root. Symlinks within the root are never followed,
including intermediate directories and index files. Dotfiles are hidden by
default. Only regular files are served; devices, sockets and FIFOs return 404.

Files stream through a 16 KiB read buffer and the existing bounded transport
buffer, independently of file size and request scratch capacity. The opened file
is closed automatically on completion, HEAD, conditional responses, cancellation
and abort; no `Api.Local` or `release` hook is needed. Headers and decoded paths
use request scratch. File I/O and backpressure occupy a lane thread. Set a lane
deadline long enough for the entire download; the default 100 ms is usually too
short. Deploy replacements by renaming complete files: truncating an open file
during a response aborts that response if its advertised length cannot be read.

For a directory opened at startup or selected through application services, use
`call.serveDir` in your own handler:

```zig
fn assets(call: *zhtps.Call(@This())) zhtps.EndpointError!zhtps.http.Response {
    return call.serveDir(call.services.public_dir, .{
        .path = call.param("filename").?,
        .cache_control = "public, max-age=3600",
    });
}
```

The caller owns `public_dir` and keeps it open through the helper call. Options
are `path`, `index_file`, `cache_control` and `dotfiles`; `path` is URL-escaped and
relative to the directory, defaulting to the request path without leading slashes.
Register this handler as a GET endpoint. Response file descriptors belong to the
exchange and remain valid after the borrowed directory is closed.

## Streaming responses

Generated endpoints can return a streaming response with `call.stream(options,
producer)`. The producer runs once on the route's application lane after headers
are committed. It can generate a large export or wait for events between writes:

```zig
fn events(call: *C) zhtps.EndpointError!zhtps.http.Response {
    return call.stream(.{
        .headers = &.{.{ .name = "Content-Type", .value = "text/event-stream" }},
    }, produceEvents);
}

fn produceEvents(call: *C, stream: *zhtps.ResponseStream) zhtps.EndpointError!void {
    try stream.writer.writeAll("data: connected\n\n");
    try stream.flush();
    // Replace this interval with your service's cancellable event wait.
    while (!call.isCanceled()) {
        std.Io.sleep(call.io, .fromMilliseconds(1000), .awake) catch return;
        if (call.isCanceled()) return;
        try stream.writer.print("data: {d}\n\n", .{call.monotonicNow()});
        try stream.flush();
    }
}
```

Register `events` with `get` or `endpoint`, using a lane whose `timeout_ms` covers
the intended response lifetime. The default lane deadline is only 100 ms. Waiting
and backpressure occupy one lane thread; assign long-lived streams a separate
lane with enough threads for the intended concurrency. Transport workers and
other lanes continue serving requests, including other streams on the same
HTTP/2 connection. Hooks for one request never overlap.

`stream.writer` is a standard `std.Io.Writer`: `writeAll`, `print`, JSON
serialization, and writer-based encoders can generate output incrementally.
Writes copy their input, so stack buffers can be reused immediately. `flush()`
(or `writer.flush()`) publishes the buffered bytes promptly and waits for
transport capacity before returning. TLS, socket capacity, and HTTP/2 flow
control still apply; flush does not acknowledge receipt by the client. An empty
flush is legal. Returning from the producer flushes remaining bytes and ends the
response. Only this callback may use the writer; do not retain it or spawn work
that outlives the callback.

Output uses one bounded handoff buffer, independent of request scratch and total
response size. HTTP/1 allocates at most `response_bytes - 32` additional bytes per
streaming request, charged to `large_buffer_bytes`; HTTP/2 reuses the stream's
`response_bytes` buffer within its existing memory budget. The transport stops
accepting output when its capacity or flow-control credit is exhausted.
`Local`, request metadata, body bytes and scratch remain valid through the
producer and cleanup. Headers must use static or request storage, never a
handler-stack array. Application logs are bounded and forwarded after the
producer returns; metrics can update throughout production.

Stream options are `status` (default `.ok`), `headers`, `length` (default `null`),
and `close`. A known length is checked exactly. An unknown length uses chunked
HTTP/1.1, connection closure on HTTP/1.0, and DATA frames on HTTP/2. HEAD and
bodyless statuses skip the producer; use `length = 0` for 204 or 205. The server
owns framing headers. Producer errors after commitment abort the HTTP/1
connection or reset the HTTP/2 stream, without sending a second status or a
successful end marker. Handle errors that need an HTTP error status in the
handler before returning the stream.

`call.isCanceled()` observes deadlines, shutdown cancellation and detected
disconnects or HTTP/2 resets. Cancellation wakes a producer blocked in flush;
`flush()` returns `Canceled`, while writer operations report `WriteFailed` with
details in `stream.write_error`. External waits must cooperate with cancellation
themselves. The server retains storage and joins producers until they return,
even after the shutdown grace period. The lane deadline spans routing, request
ingestion and the entire streaming response; write deadlines also bound stalled
transport output. The API starts response production after request ingestion;
it does not provide simultaneous request-body consumption and response writing.

## Application logs and metrics

`call.log` emits bounded structured records through the existing JSON log queue.
`call.access.put` adds copied metadata to the request's `request_complete` record.
Both accept strings, integers through 64 bits, finite floats, booleans, nulls,
optionals, typed enums and enum literals; unsupported or oversized fields are
dropped and counted. `access.put` replaces an existing name, reclaims its string
storage, and preserves the previous value if the update cannot fit. Access
metadata has eight fields and 512 bytes of string storage. Each middleware,
body-consumer or handler stage buffers up to four log records, with 128-byte event
names and the same per-record field limits, before forwarding them to the server log queue.
Application counters, gauges, and histograms use compile-time enums, per-worker
fixed storage, atomic updates, snapshot aggregation, and the existing `/metrics`
and `/debug/metrics` endpoints. Declare the enums in the API's `metrics` namespace;
the former `Metrics` spelling remains supported for existing applications.
Enums must be exhaustive and numbered from zero
without gaps. Names and namespaces use ASCII letters, digits and underscores,
starting with a letter or underscore. Names must be unique across metric kinds
and generated histogram `_bucket`, `_count`, and `_sum` names. `zhtps` and namespaces
starting with `zhtps_` are reserved. Histograms observe nanoseconds and expose
seconds in Prometheus. Gauges sum across workers, so set worker-local values;
do not duplicate process-wide totals. Dynamic metric labels are intentionally absent.

## Lanes and deadlines

Each lane has a server-wide queue and thread pool. The configured thread count
and queue capacity are multiplied by the worker count, preserving the total
budgets while allowing idle threads to serve any worker. A full lane queue returns
503 before response commitment; if it rejects a streaming producer after headers
are committed, that response is aborted. Hooks may run concurrently for sockets
owned by the same transport worker.
Generated routing without middleware runs inline; user hooks use the lane pool.
`timeout_ms` is one absolute deadline from admitted routing through
middleware, body ingestion, queue waits and handler completion, extended through
response completion for generated streams. Buffered responses have their separate
transport deadline. It disconnects an overdue request, but Zig code cannot be terminated
safely in-process: the lane slot and request storage remain occupied until that
call returns. Separate lanes prevent a blocked route group from consuming the
threads reserved for another group. Connection slots, admission permits, CPU,
and caller-owned services remain shared, so this is thread isolation rather than
a capacity reservation. Use separate server instances with separate connection
budgets when routes need independent admission capacity. `serve` and shutdown
wait for running hooks, even beyond `shutdown_timeout_ms`. Process isolation remains necessary to
contain panics, memory corruption, or permanently noncooperative code.

## Verification

Run `zig build test-library` for endpoint wire regressions and
`zig build test-endpoint-declarations` for invalid-declaration checks.
`zig build test-upload` checks incremental consumption, framing, backpressure,
borrowed-buffer lifetime and deadlines. `zig build test-response-streaming` checks
generated response streaming over HTTP/1 and TLS; `zig build test-http2` covers
streaming, multiplexing, flow control and resets over HTTP/2. These accept
`-Doptimize=ReleaseSafe` as well as the default Debug build. Unfiltered
`zig build test` also includes the declaration checks.
