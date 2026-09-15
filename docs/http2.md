# HTTP/2

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The TLS listener negotiates `h2` ahead of `http/1.1`. Cleartext listeners and
clients without ALPN continue to use HTTP/1. TLS remains restricted to TLS 1.3.
The built-in application and generated endpoints both work over HTTP/2.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zhtps --port 8443 \
  --tls-certificate /path/fullchain.pem --tls-key /path/key.pem
curl --http2 --cacert /path/ca.pem https://localhost:8443/
```

## Protocol and application behavior

nghttp2 owns framing, HPACK, SETTINGS, PING, stream validation and protocol flow
control. Workers own all engine calls and socket I/O. The implementation follows
the [nghttp2 callback and ownership rules](https://nghttp2.org/documentation/programmers-guide.html);
callbacks never recursively receive or serialize protocol output.

Each stream owns its exchange, stable headers, normalized path, trailers,
application storage, buffered upload fragments, and deadlines. Requests expose
`version = .http_2`, `scheme = "https"`, and the pseudo-header authority and target.
`Request.hasBody()` works across protocols; `body_follows` records an open HTTP/2
request body without claiming chunked transfer encoding. Split Cookie fields are
joined before application dispatch, following
[RFC 9113 section 8.2.3](https://www.rfc-editor.org/rfc/rfc9113.html#section-8.2.3).
Trailers remain separate and use the same forbidden-field policy as HTTP/1.

Generated hooks run on the existing bounded executor lanes. Different streams
can execute concurrently; a blocked hook does not suspend its connection's
parser or other lanes. Lane thread/queue counts still determine application
concurrency. Admission and rate limits apply to individual requests, including
requests on the same connection.

Reset, disconnect, and deadline expiry set a stream-owned cancellation flag.
Generated handlers can poll `call.isCanceled()`. Queued canceled tasks skip hooks;
running hooks retain their borrowed storage until they return. Cleanup runs once.
Noncooperative application code cannot be forcibly stopped safely, so server
shutdown still joins running hooks as it does for HTTP/1.

Responses preserve ordinary origin semantics, including HEAD, OPTIONS, validators,
bodyless statuses, known and unknown response lengths, and `100-continue`.
HTTP/1 connection headers and chunk framing are never emitted into HTTP/2.
Response metadata is validated through the same framing policy as HTTP/1, then
submitted directly to nghttp2 without serializing and reparsing an HTTP/1 head.
The field count and former serialized-head byte budget remain enforced.
An early final response ends the response and cancels unread input with
`RST_STREAM(NO_ERROR)`. Invalid application responses reset their stream.

Shutdown and the request-count limit send GOAWAY with the highest accepted stream
ID. Existing streams finish within the shutdown deadline. Once output drains,
the server sends TLS `close_notify`. Forced deadlines and protocol failures can
close immediately.

## Backpressure and resource limits

| Setting | Default | Scope |
|---|---:|---|
| `--http2-max-streams` / `Config.http2.max_streams` | 100 | Per connection, advertised in SETTINGS |
| `--http2-worker-streams` / `max_streams_per_worker` | Automatic, up to 256 | Live streams plus reset streams with running hooks, per worker |
| `--http2-memory-bytes` / `memory_bytes` | Automatic, up to 64 MiB | Protocol, transport, stream, and cached allocations, per worker |
| `Config.header_bytes` | 32 KiB | Decoded field-list charge, including HPACK's 32-byte field overhead |
| `Config.trailer_bytes` | 8 KiB | Retained trailer names and values |
| Receive window | 65,535 bytes | Buffered body bytes per stream |
| Engine allocation budget | 1 MiB | Per connection, within the worker budget |
| Stream cache | 64 entries | Per worker, still charged to the memory budget |

Streams start with small inline header, path and response-name storage. Larger
metadata grows within the configured limits before dispatch. Trailer storage is
separate, so receiving trailers cannot relocate headers borrowed by a running
hook. Application storage is allocated in full before exchange initialization;
producer storage is allocated in full before a streaming response starts. Owned
allocations can be reused by the bounded stream cache.

Header and trailer counts are capped at 128 each; final response fields are capped
at 63 including generated Date and Content-Length. Existing body-size,
application-storage, header/body/write/idle deadlines and request-count settings
also apply. The nghttp2 session bounds continuation frames, queued acknowledgments,
and reset rates. OpenSSL allocations and kernel socket memory are additional.
Admin gauges expose `http2_streams_active`, `http2_streams_cached`, and
`http2_bytes_allocated`. Access records identify the request and `http2` phase.

Connection receive credit returns when bytes enter bounded stream storage.
Stream credit returns only after its application consumes those bytes. A stalled
consumer therefore withholds its own window without exhausting all connection
credit. Generated response producers use `call.stream` and a standard
`std.Io.Writer` on their application lane. `flush()` publishes an event boundary;
the producer can wait for the next application event without blocking the
transport. One bounded handoff buffer backpressures the producer when peer
flow-control credit is exhausted. Reset, timeout and shutdown wake blocked
writers; other streams remain independently multiplexed. See the
[streaming API and lifetime contract](endpoints.md#streaming-responses) for lane sizing and ownership.
Low-level synchronous producers still run only as peer credit allows.

The worker copies ciphertext into independent 18 KiB buffers for asynchronous
receives and sends, while the BIO pair remains bounded to 18 KiB per direction.
It batches at most 64 frames into a 16 KiB plaintext buffer, and reserves space
before TLS writes. This keeps write retries stable while allowing inbound reset,
window-update, and request frames to make progress. Stream storage is reused only
after hooks finish and the engine has copied response bytes.

## Verification

The Python wire suite uses an independent HTTP/2 client and real verified TLS
sockets. Install its test dependency in an environment of your choice:

```sh
python3 -m venv /tmp/zhtps-h2-tests
/tmp/zhtps-h2-tests/bin/pip install -r tests/requirements-http2.txt
zig build test-http2 -Dhttp2-python=/tmp/zhtps-h2-tests/bin/python
zig build test -Dtest-filter=http2
zig build test-tls test-library test-application test-upload test-wire
```

Tests cover multiplexed responses, blocked handlers and consumers, cancellation
and deferred release, stream/connection flow control, 2 MiB streaming uploads,
8 MiB responses, generated events flushed before an application wait, blocked
writer cancellation, bounded production at zero/limited window credit,
producer errors and length mismatches, trailers, split cookies, header limits,
resource exhaustion/recovery, `100-continue`, and graceful GOAWAY with TLS closure.
Component tests inject every allocation failure through session initialization,
complete request/body/response exchanges and metadata growth. Wire tests cover
growing header/trailer arrays and byte buffers, cookie joining and long paths,
response-name growth, and a blocked consumer retaining its header borrow while
trailers arrive. A capacity regression verifies six concurrent small uploads
under a 1 MiB worker HTTP/2 budget. The forbidden-trailer regression
was demonstrated failing for Authorization, Cookie, If-Match and Content-Type
before sharing the existing HTTP/1 policy; the same test passes after the fix.

After the retained optimization candidates, ReleaseSafe verification on
2026-09-14 passed 108 Zig tests and all endpoint declaration and library-consumer
checks. All 34 HTTP/2 wire tests passed in Debug and ReleaseSafe; the 32 TLS tests
and executor/upload/response-streaming suites passed in ReleaseSafe. Earlier
HTTP/1 wire verification also passed. The implementation report retains test logs,
source snapshots and benchmark identities.

## Runtime comparison

The [Bun source review](bun-http2-review.md) ranks compatible optimization
strategies for ZHTPS's multi-worker architecture, distinguishes Bun's Rust
`node:http2` engine from its newer native server, and records poor fits at the end.
It includes source snapshots and is also available in the [HTML report](benchmarks.html#bun-http2-review).
The [implementation experiments](bun-http2-implementation.md) record each candidate's
paired measurements, capacity results, tradeoffs and retain/revert decision.

The [remote HTTP/2 benchmark](http2-lan.md) uses `client.example` as the load
host at 64, 1,024, 8,192, and 16,384 connections with four streams per connection.
It compares all four servers on one CPU and only ZHTPS and Go at two, four, and
eight CPUs. Actual connection populations and every setup, warmup, and measured
failure are retained, with the results included in the [HTML report](benchmarks.html).

The earlier [loopback HTTP/2 benchmark](http2-comparison.md) compares ZHTPS, Go, Node,
and Bun on one server core, then ZHTPS and Go with two, four, and eight workers.
It includes client-capacity calibration, synchronized warmup/measurement,
per-trial CPU use, and reproducible source and binary records.

### Initial Go comparison

The repeatable benchmark uses Go's `net/http` client, verifies the certificate,
requires HTTP/2 on every response, and checks the complete `ZHTPS\n` body. Both
servers use TLS 1.3 and one CPU; the client uses two separate CPUs. Connections
are warmed before three alternating-order, three-second runs per scenario.
ZHTPS uses ReleaseSafe, disables access logging, and raises its request-count
limit for persistent-load measurements. Go uses `GOMAXPROCS=1` and the existing
baseline's new `-http2` option. The old HTTP/1 benchmark behavior remains its default.

On this host (Linux 7.2.4, Zig 0.16.0, Go 1.27.1, OpenSSL 3.6.4, nghttp2 1.70.0),
median results were:

| Connections × streams | zhtps requests/s | Go requests/s | Ratio | zhtps p99 | Go p99 |
|---|---:|---:|---:|---:|---:|
| 1 × 1 | 58,768 | 40,584 | 1.45× | 0.031 ms | 0.043 ms |
| 1 × 32 | 185,885 | 69,822 | 2.66× | 0.420 ms | 0.699 ms |
| 8 × 32 | 247,262 | 67,830 | 3.65× | 2.670 ms | 7.231 ms |

All measured responses succeeded. [Raw results](runs/standalone.json "Summary of docs/http2-benchmark.json; raw artifact retired") include CPU
costs and every run. These results establish parity for this small-response,
loopback workload; they do not establish parity for WAN uploads, all handlers,
connection counts, or the full Go HTTP API.

```sh
go build -o /tmp/go-h2-server bench/go_server/main.go
go build -o /tmp/go-h2-client bench/http2_client/main.go
python3 bench/compare_http2.py --go-server /tmp/go-h2-server \
  --client /tmp/go-h2-client --output /tmp/http2-results.json
```

Cleartext h2c, CONNECT tunnels, server push, arbitrary informational responses,
and a response-trailer API remain outside the current origin API. HTTP/2
integration and allocation tests are evidence of tested behavior, not a claim
of independent protocol certification.
