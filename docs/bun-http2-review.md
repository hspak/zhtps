# Bun HTTP/2 source review

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The [implementation follow-up](bun-http2-implementation.md) records sequential
experiments and their measured retain/revert decisions.

The most promising transfers are **bounded worker-local allocation reuse, direct
HTTP/2 response headers, and smaller stream storage that grows when needed**.
They preserve ZHTPS's independent transport workers and address concrete costs
in its current implementation. Bun's output batching is useful corroboration,
but ZHTPS already batches plaintext into 16 KiB TLS writes. Increasing batching
is a lower priority, especially after the observed LAN receive losses.

This source review was completed on September 14, 2026, before the linked
implementation experiments. It changed no server code and claimed no new
performance result. Its rankings and descriptions below refer to the frozen
reviewed source; the follow-up records subsequent code changes and measurements.

## Which Bun implementation was reviewed

The requested `../bun` directory is absent. The clean checkout at
`../bun`, commit `ae7179126de54c4cd9496f784168671bb520e92a`, was reviewed.
The comparison binary reports `1.4.0+34cbb9a40`, corresponding to the earlier
commit `34cbb9a40b4bd1bd767d134a7065e66c2432a676` dated August 19. ZHTPS source
references below are snapshots of the current working tree, including the
existing HTTP/2 work, rather than a claim that all changes are committed.
[Provenance and source hashes](runs/bun-http2-review.json "Summary of docs/bun-http2-review/provenance.json; raw artifact retired"),
complete reviewed source snapshots.

**Bun's `node:http2` does not use the same HTTP/2 library as Node.** The shared
JavaScript benchmark fixture uses `node:http2.createSecureServer`, but Bun routes
that API through its own Rust `H2FrameParser`, Rust connection engine and
ls-hpack. The measured revision already has this Rust binding. The newer
checkout also has a separate C++ HTTP/2 implementation under `Bun.serve`;
its addition postdates the measured binary. It supplies further design ideas
but cannot explain that binary's benchmark results.
Fixture, current API binding,
measured revision binding, Rust engine,
ls-hpack wrapper, native implementation.

The requested comparison remains appropriate: Node and Bun in the one-worker
case, ZHTPS versus Go in the multi-worker cases. Sharing an API or benchmark
fixture does not establish a shared implementation.

## Ranked opportunities

| Rank | Candidate | Main opportunity | Assessment for ZHTPS |
|---:|---|---|---|
| 1 | Bounded worker-local pools for HTTP/2 allocations | Reduce allocation/free traffic through a mutex shared by workers | Strong architectural fit; profile contention before choosing pool sizes |
| 2 | Submit structured response headers directly | Remove HTTP/1 serialization and reparsing on every response | Strong fit; share validation and origin semantics across protocols |
| 3 | Small stream storage with bounded growth | Lower active/cached stream memory and allocator traffic | Strong capacity opportunity; requires stable request/application storage |
| 4 | Reuse synchronous scratch within a transport worker | Reduce per-connection scratch at 8k/16k connections | Conditional fit; asynchronous I/O and TLS retries retain their own storage |
| 5 | Refine bounded TLS coalescing and flush scheduling | Reduce small writes when work arrives in separate completions | Already partly present; demonstrate a multi-worker benefit without worse latency/loss |
| 6 | Queue ready application work with fair service budgets | Avoid repeatedly scanning inactive streams | Conditional at high multiplexing; low priority for four streams per connection |

### 1. Amortize the shared allocator lock with worker-local reuse

Bun's Rust path lazily creates a **per-thread slab of 256 parser objects**, with
heap fallback, and reuses thread-local cork and batch storage. This is a pool of
connection/parser objects, not a claim that all streams or all allocations are
pooled. Other allocations still use its general allocator.
Pool and reusable buffers.

ZHTPS's HTTP/2 allocator has a separate budget per worker, but **each underlying
allocation and free locks the same `shared.allocator_mutex`**. The worker-local
budget therefore does not imply worker-local allocation execution. A pool in
front of that backing allocator could amortize lock acquisitions across slab
refills and returns. This is the candidate with the clearest connection to
multi-worker scalability, although source inspection alone cannot establish
how much time the lock currently costs.
Allocator, worker wiring.

Retain the arbitrary caller-supplied allocator contract: simply removing the
mutex would be unsafe for allocators requiring serialization. Allocate bounded
slabs under the existing lock, serve suitable allocations on the owning
transport worker, and charge retained slabs/free slots to the worker budget.
Keep large or unusual allocations on the existing path. Return storage only
after executor borrowers and transport operations finish; do not make shared
application lanes mutate an unsynchronized transport pool.

ZHTPS already caches 64 complete streams per worker, so another pool must reduce
remaining allocations, including engine allocations or churn beyond that cache.
Measure allocation counts, retained bytes, and lock wait/hold time at 1/2/4/8
workers. A larger cache that merely consumes more memory is insufficient.
Existing stream cache.

### 2. Remove the HTTP/1 header round trip

Bun's `respond()` passes field pairs to its Rust encoder, which feeds names and
values into ls-hpack. Its newer native implementation likewise stores field
bytes plus offsets and encodes those fields directly. Neither path needs an
intermediate HTTP/1 status line and CRLF-delimited header block.
Node-compatible response path, Rust field encoder,
native field encoding.

ZHTPS currently changes a copy of the request version to HTTP/1.1, calls
`response.begin()`, splits the resulting bytes at CRLF and colons, lowercases
the names, removes connection framing fields, then submits the remaining fields
to nghttp2. That is concrete repeated work on every response, including the
six-byte benchmark response.
Current response path.

Extract common response validation and body/framing decisions from
`http.Response.begin()`, then give HTTP/1 and HTTP/2 their own encoders. HTTP/2
can construct validated fields directly for the existing nghttp2 wrapper.
Preserve HEAD/bodyless statuses, Date, Content-Length, invalid-header rejection,
known/unknown body lengths, field limits, and origin behavior such as validators.
Keep nghttp2's current field-copy ownership unless a separate lifetime analysis
justifies changing it. This optimization needs no cross-worker shared cache or
protocol-engine replacement.
Shared response policy, nghttp2 submission.

### 3. Make stream limits bounds rather than eager reservations

Bun's Rust stream keeps protocol fields and a pending DATA queue rather than
reserving ZHTPS-sized application/header/output scratch in each stream. The
native response implementation starts with inline capacity for 256 header
bytes and 16 field references, growing for larger responses; queued body
storage is separate. These are storage strategies, **not directly comparable
total stream footprints**: Bun also has JS/runtime allocations.
Rust stream, native header/body storage.

ZHTPS allocates this storage block on a stream cache miss:

```text
2 × header_bytes + trailer_bytes + 8192 + application_bytes + response_bytes
```

With current defaults, that is **176 KiB per allocated stream**, before the
Stream object, optional body buffer and protocol allocations. A full 64-entry
worker cache retains 11 MiB of these blocks alone. This is reserved storage,
not a measurement of resident physical memory. The benchmark raises stream and
worker-memory limits but leaves these individual buffer defaults unchanged.
Allocation/layout, defaults, benchmark command.

Start with compact request metadata and bounded small header/path storage.
Allocate trailer storage only when trailers arrive, application scratch when
the application needs it, and producer output storage when a streaming response
starts. Grow outliers under the same worker budget. Header slices must remain
stable once exposed to an executor task; offsets or nonmoving storage can avoid
invalidating them. Do not replace one eager reservation with unlimited vectors.
Measure steady-state RSS, committed allocator bytes, and churn as well as RPS.

### 4. Share scratch only during synchronous worker operations

Bun reuses a lazily allocated 64 KiB HPACK scratch buffer per thread. Its native
server lends a context-owned output buffer to one connection during a socket
event, then copies an unsent remainder into connection-owned storage before
returning it. The Rust receive path processes supplied bytes directly when
there is no pending suffix, buffering incomplete or reentrant input as needed.
These designs distinguish temporary work space from bytes retained across
events. HPACK compression tables themselves remain per connection.
HPACK scratch, native buffer lease,
receive fast path.

ZHTPS embeds **68 KiB of transport scratch per HTTP/2 connection**: two 18 KiB
ciphertext buffers and two 16 KiB plaintext buffers. At 16,384 established
connections this component alone is 1,088 MiB; this arithmetic excludes BIO,
OpenSSL, nghttp2 and stream storage. The first candidate to investigate is the
synchronous plaintext receive scratch, potentially one buffer per worker.
The input handed to nghttp2 is already consumed synchronously, so there is no
reason to add another parser or reassembly layer just to copy Bun's fast path.
Connection buffers, worker pump.

The ciphertext buffers are borrowed by outstanding io_uring operations and
cannot be shared until completion. Plaintext output may also survive a pump
iteration or an SSL write retry, which requires unchanged bytes. Sharing it
would need an explicit lease or an owned fallback on suspension. Reuse worker
scratch only where the lifetime is proven; keep asynchronous storage pinned.
TLS copy/retry contract, borrowed engine output.

### 5. Refine batching only where the current path misses opportunities

Bun's Rust implementation accumulates writes in a 16 KiB per-thread cork buffer
and schedules a deferred flush. Switching the cork to another session flushes
the old session; it does **not** combine different connections into one TLS
record. Frame headers and payloads can fill the same record. It also merges
small queued DATA writes into a tail frame. The measured Bun revision already
has the 16 KiB cork size.
Cork ownership, record boundary handling,
small-write merging, measured revision constants.

ZHTPS already gathers up to 64 engine output chunks into a 16 KiB plaintext
buffer, then uses bounded duplex BIO/socket storage. The remaining hypothesis
is that several application completions for the same connection could be
collected within a bounded worker turn before flushing. Only attempt this if
profiles show many small TLS writes. Cap bytes/work per connection and per turn;
flush pending data when yielding even if the record is not full. Preserve
prompt control traffic and the application `flush()` publication contract.
Existing batching, pump work bound,
[streaming contract](http2.md).

Measure TLS writes/record sizes, socket sends, packet counts, tail latency and
NIC receive misses. Fewer calls do not establish better delivery: the remote
diagnosis found receive-side loss, and larger bursts may make it worse.
[Failure evidence](http2-diagnosis.md).

### 6. Queue runnable application work when stream counts justify it

The newer native Bun server maintains a writable-stream queue, grants a byte
slice per stream, and puts streams that did not get a turn ahead of streams
already served. Its Rust `node:http2` implementation instead scans a snapshot
of streams when flushing queued DATA. These are distinct strategies; the native
queue is the more relevant design reference here.
Native fair drain, Rust queue scan.

ZHTPS repeatedly walks its stream list in `drive()` to check deadlines,
application readiness and producer publications. A worker-owned ready queue
could avoid scanning inactive streams, with separate deadline tracking if
measurements justify its complexity. Keep event publication through the existing
executor completion mechanism and bound connection service time. Leave HTTP/2
DATA scheduling and flow-control legality to nghttp2.
Current stream walk.

At four streams per connection, a short scan may be cheaper than queue bookkeeping.
Evaluate this with mixed small/large responses and 32–100 streams per connection
before prioritizing it for the current high-connection workload.

## Existing strategies to retain

ZHTPS already has worker ownership of protocol/TLS state, bounded producer
handoffs, stream credit returned as the application consumes input, independent
connection credit for bounded received bytes, delayed cleanup while hooks run,
and bounded continuation/ACK/reset handling. Bun reinforces these principles;
they are not new missing features. Keep them when changing storage or flushing.
[Transport and lifecycle contract](http2.md), engine limits.

## How to decide whether a transfer pays off

Implement candidates separately so before/after results identify the cause.
Use 2/4/8-worker throughput, CPU per successful request, p99 latency, memory and
failure rates as the adoption criteria; one-worker results are a regression
check. Keep the same affinity, binaries/build mode, request semantics, resource
limits, and remote placement between paired runs.

Retain the requested remote matrix: **64, 1,024, 8,192 and 16,384 connections,
four streams per connection**, with every setup, warmup and measured failure
recorded separately. Do not interpret a smaller successfully connected
population as a speedup. Use a calibrated loopback control with separate client
cores to expose CPU changes when the remote NIC limits useful throughput;
retain NIC drops and TCP retransmissions in remote trials.
[Benchmark methodology](http2-lan.md), [diagnostic controls](http2-diagnosis.md).

Storage changes require allocation-failure and exhaustion/recovery coverage,
disconnect/reset while hooks retain borrows, and existing slow-reader tests.
Header changes require HTTP/1 and HTTP/2 semantic parity. Flush/queue changes
require event flushes before application waits, zero-window recovery, fair
small responses beside large streams, and cancellation during output. Run the
existing HTTP/2/TLS/application suites plus focused regressions for any new
failure; benchmark gains do not substitute for those contracts.

## Strategies that do not map well

- **Replacing nghttp2 with Bun's handwritten engines or ls-hpack.** The source
  shows different protocol engines, not evidence that nghttp2 is ZHTPS's
  bottleneck. Bun's Rust binding currently also bridges legacy outbound state
  into its newer receive engine. Copying that design would add substantial
  protocol/lifetime work. Try the surrounding allocation and response-path
  improvements first. State bridge.

- **A single event-loop cork or draining until the socket blocks.** Bun's
  thread-local buffers work within one event loop. ZHTPS should preserve
  independent worker ownership. Bun's native-writable Rust callback loops
  until backpressure or no progress; copying an uncapped drain policy could
  delay other connections on a busy ZHTPS worker. A bounded per-worker queue
  is the possible adaptation. Writable callback.

- **Plain-TCP borrowed `writev` as an optimization for these TLS results.**
  Bun's large DATA write path can gather caller payload slices for plain TCP,
  copying only an unwritten suffix. Its TLS path builds a contiguous batch.
  ZHTPS's benchmark is TLS 1.3, and asynchronous sends retain buffers until
  completion. The plain-TCP shortcut supplies no immediate equivalent here.
  Vectored flush, DATA path.

- **Copying Bun's buffer/window constants at 16k connections.** The native
  path permits 256 KiB of ordinary queued socket output, advertises a 16 MiB
  connection receive window, and grows a stream window from 64 KiB to 1 MiB
  when its reader asks for the body. Just 256 KiB per connection across 16,384
  connections is 4 GiB; 1 MiB of credit across 65,536 streams permits 64 GiB of
  outstanding stream DATA. Those are capacity/credit illustrations, not Bun
  RSS measurements. Consumer-driven window growth may help large uploads,
  but six-byte GET responses do not benefit, and ZHTPS must preserve its total
  worker memory bound. Native limits,
  window growth.

- **Pausing timeouts with application backpressure.** The native response
  `pause()` disables that response's timeout and recomputes the connection
  timeout. ZHTPS deliberately retains application/body/write deadlines for
  stalled work. Preserve those limits. Native pause.

- **JS-specific reentrancy and GC lifetime machinery.** Bun needs guards for
  synchronous JS socket callbacks, reference-counted cork ownership and deferred
  JS dispatch. The transferable rule is stable ownership across callbacks;
  those mechanisms do not replace ZHTPS's executor cancellation and io_uring
  completion rules. Reentrant receive,
  [ZHTPS lifetime contract](http2.md).

- **Assuming Bun's stream lookup always scales better.** Its Rust path has a
  stream map, but its native path searches a vector newest-first. Neither
  establishes a win over ZHTPS's short lists at four streams per connection.
  Avoid paying for a more elaborate index on every connection without evidence.
  Native lookup, Rust stream map.

## Historical source locations

The snapshots were removed; these locations record the original review citations.

| Reference | Original source location |
|---|---|
| fixture | `bun-http2-review/source/zhtps/bench/http2_lan_server.cjs:1` |
| bun-api | `bun-http2-review/source/bun/src/js/node/http2.ts:89` |
| bun-measured-api | `bun-http2-review/source/bun-measured/src/js/node/http2.ts:89` |
| bun-engine | `bun-http2-review/source/bun/src/runtime/api/bun/h2/connection.rs:435` |
| bun-hpack | `bun-http2-review/source/bun/src/http/lshpack.rs:1` |
| bun-native | `bun-http2-review/source/bun/packages/bun-uws/src/Http2Context.h:1` |
| bun-pool | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:845` |
| z-allocator | `bun-http2-review/source/zhtps/src/server/Http2Allocator.zig:21` |
| z-worker-allocator | `bun-http2-review/source/zhtps/src/server/worker.zig:755` |
| z-cache | `bun-http2-review/source/zhtps/src/server/http2.zig:698` |
| bun-respond | `bun-http2-review/source/bun/src/js/node/http2.ts:3645` |
| bun-encode | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:1972` |
| bun-native-encode | `bun-http2-review/source/bun/packages/bun-uws/src/Http2Context.h:1079` |
| z-respond | `bun-http2-review/source/zhtps/src/server/http2.zig:561` |
| z-response-policy | `bun-http2-review/source/zhtps/src/http/Response.zig:72` |
| z-submit | `bun-http2-review/source/zhtps/src/http2.zig:141` |
| bun-stream | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:1305` |
| bun-native-storage | `bun-http2-review/source/bun/packages/bun-uws/src/Http2ResponseData.h:43` |
| z-stream | `bun-http2-review/source/zhtps/src/server/http2.zig:169` |
| z-config | `bun-http2-review/source/zhtps/src/Config.zig:22` |
| z-command | `bun-http2-review/source/zhtps/bench/compare_http2_lan.py:109` |
| bun-hpack-scratch | `bun-http2-review/source/bun/src/jsc/bindings/c-bindings.cpp:405` |
| bun-native-lease | `bun-http2-review/source/bun/packages/bun-uws/src/Http2Context.h:1053` |
| bun-read | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:3629` |
| z-buffers | `bun-http2-review/source/zhtps/src/server/http2.zig:38` |
| z-pump | `bun-http2-review/source/zhtps/src/server/worker.zig:1757` |
| z-tls | `bun-http2-review/source/zhtps/src/Tls.zig:75` |
| z-output | `bun-http2-review/source/zhtps/src/http2.zig:98` |
| bun-cork | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:2484` |
| bun-write | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:3188` |
| bun-merge | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:1690` |
| bun-measured-pool | `bun-http2-review/source/bun-measured/src/runtime/api/bun/h2_frame_parser.rs:779` |
| z-batch | `bun-http2-review/source/zhtps/src/server/http2.zig:337` |
| bun-drain | `bun-http2-review/source/bun/packages/bun-uws/src/Http2Context.h:1168` |
| bun-scan | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:2639` |
| z-drive | `bun-http2-review/source/zhtps/src/server/http2.zig:365` |
| z-limits | `bun-http2-review/source/zhtps/src/http2.zig:62` |
| bun-bridge | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:1079` |
| bun-writable | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:7492` |
| bun-vectored | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:3101` |
| bun-data | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:5261` |
| bun-native-limits | `bun-http2-review/source/bun/packages/bun-uws/src/Http2Context.h:80` |
| bun-grow | `bun-http2-review/source/bun/packages/bun-uws/src/Http2Context.h:1960` |
| bun-pause | `bun-http2-review/source/bun/packages/bun-uws/src/Http2Context.h:1941` |
| bun-read-guard | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:3548` |
| bun-find | `bun-http2-review/source/bun/packages/bun-uws/src/Http2Context.h:445` |
| bun-map | `bun-http2-review/source/bun/src/runtime/api/bun/h2_frame_parser.rs:1130` |
