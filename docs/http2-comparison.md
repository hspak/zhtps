# HTTP/2 runtime comparison

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Measured on 2026-09-14 using the current HTTP/2 worktree. ZHTPS, Go, Node,
and Bun each receive one physical server core in the constrained comparison.
Only ZHTPS and Go run with two, four, or eight server cores. Node and Bun use
one process and the exact same `node:http2` stream-handler fixture; there is
no clustering or worker-thread pool in that fixture.

## Results

All 84 trials completed, with 171,517,473 validated measured responses,
zero errors, and exactly the requested number of connections in every trial.

With one worker, Bun leads the serial case; ZHTPS and Bun are nearly tied
on one multiplexed connection. ZHTPS leads the two multi-connection cases.
Against Go, ZHTPS leads every measured worker/workload combination.

### One worker: requests per second

| Connections × streams | ZHTPS | Go | Node | Bun |
|---|---:|---:|---:|---:|
| 1 × 1 | 38,709 | 31,259 | 35,291 | 41,939 |
| 1 × 32 | 127,245 | 58,220 | 112,382 | 127,758 |
| 8 × 32 | 259,473 | 56,608 | 115,971 | 132,880 |
| 64 × 4 | 163,094 | 58,179 | 93,255 | 127,021 |

### One worker: p99 latency in milliseconds

| Connections × streams | ZHTPS | Go | Node | Bun |
|---|---:|---:|---:|---:|
| 1 × 1 | 0.037 | 0.047 | 0.036 | 0.032 |
| 1 × 32 | 0.607 | 0.814 | 3.250 | 0.585 |
| 8 × 32 | 1.330 | 8.410 | 11.700 | 2.300 |
| 64 × 4 | 2.150 | 7.640 | 3.590 | 2.210 |

### Multiple workers: ZHTPS versus Go

| Workers | Connections × streams | ZHTPS req/s | Go req/s | ZHTPS / Go | ZHTPS p99 ms | Go p99 ms |
|---:|---|---:|---:|---:|---:|---:|
| 2 | 8 × 32 | 505,798 | 104,218 | 4.85× | 0.918 | 8.220 |
| 2 | 64 × 4 | 324,794 | 113,519 | 2.86× | 1.330 | 6.560 |
| 4 | 8 × 32 | 721,647 | 220,348 | 3.28× | 0.893 | 4.020 |
| 4 | 64 × 4 | 643,218 | 223,818 | 2.87× | 0.905 | 4.230 |
| 8 | 8 × 32 | 894,003 | 470,284 | 1.90× | 0.911 | 1.550 |
| 8 | 64 × 4 | 975,368 | 400,293 | 2.44× | 0.808 | 3.520 |

For the 64 × 4 workload, scaling relative to one worker is:

| Workers | ZHTPS scaling | Go scaling | ZHTPS server CPU µs/req | Go server CPU µs/req | ZHTPS client CPU threads used | Go client CPU threads used |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1.00× | 1.00× | 4.89 | 13.79 | 2.49 | 1.24 |
| 2 | 1.99× | 1.95× | 4.93 | 13.11 | 4.70 | 2.27 |
| 4 | 3.94× | 3.85× | 4.97 | 13.39 | 9.18 | 4.23 |
| 8 | 5.98× | 6.88× | 5.85 | 15.17 | 13.29 | 6.76 |

Node's 64 × 4 p99 ranged from 3.34 to 12.70 ms across the three
trials. Eight-worker ZHTPS at 8 × 32 ranged from 810,382 to 907,071
requests/s. The [CSV summary](http2-comparison/summary.csv) retains throughput
and p99 ranges for all 28 groups. These are observed ranges from three trials,
not statistical confidence intervals.

## Workload and measurement

Every server receives HTTPS `GET /` and returns status 200, `ZHTPS\n` (six
bytes), `Content-Type: text/plain; charset=utf-8`, ETag `"zhtps-root-v1"`,
Content-Length 6, and a Date header. The Go standard-library client verifies
its temporary P-256 certificate, TLS 1.3, ALPN `h2`, HTTP/2 on every response,
status, response headers, and the entire body. It checks the Date format.
A trial fails on a response error or any extra connection attempt.

The four workloads are 1 connection × 1 in-flight stream, 1 × 32, 8 × 32,
and 64 × 4. The two multi-connection cases both hold at most 256 requests
in flight, separating stream multiplexing from distribution over connections.
The multi-worker comparison runs those two cases only. These are persistent,
closed-loop requests: every stream starts its next request after its prior
response completes. They measure neither TLS handshake capacity nor latency
at a fixed offered request rate.

Each trial starts a fresh server and client processes, establishes verified
connections, and performs two seconds of concurrent warmup per client process.
Clients then wait for a shared start timestamp. Measurement lasts eight
seconds; requests started before the deadline drain, and that drain time is
included in the throughput denominator. Server order rotates across three
repeats. Tables report median throughput and the median of the three run p99s.
They do not average per-client percentiles: each run's p99 comes from merging
request-count histograms, with 1 µs resolution below 1 ms and at most 1%
rounding above it. Raw per-client p99s retain nanosecond resolution.

ZHTPS uses ReleaseSafe, `x86_64_v4`, no access logging, a raised request-count
limit, and an explicit CPU per worker. For the benchmark it allows 2,048
connections, 2,048 active requests, 2,048 HTTP/2 streams, and 512 MiB HTTP/2
memory per worker. These are ceilings, not measured occupancy or default
production settings. Go uses the existing `net/http` baseline with `-http2`
and `GOMAXPROCS` equal to the server core count. All server threads inherit
the same bounded CPU affinity. Node and Bun use the low-level stream API,
without the HTTP/1 compatibility request/response wrappers.

## Host and limits

The machine is an AMD Ryzen AI Max+ 395: 16 physical cores, 32 SMT threads,
two L3 cache domains, one NUMA node. Server CPUs are 0 through workers−1;
the client pool is 8–15 and 24–31, the other eight physical cores and their
SMT siblings. Server and client never share a physical core. This places
them in separate L3 domains. Affinity controls placement; it does not reserve
cores against unrelated host activity.

Multi-connection runs use eight independent client processes, each pinned
to the two SMT threads of one client core, with `GOMAXPROCS=2`. Single-connection
runs use one client process on physical CPUs 8 and 9, also with `GOMAXPROCS=2`.
This allocation stays the same across server runtimes and worker counts.
The raw records preserve every process placement and server thread snapshot.

Toolchains: Linux 7.2.4, Zig 0.16.0, Go 1.27.1-X:nodwarf5, Node 26.8.2,
Bun 1.4.0, host OpenSSL 3.6.4, and nghttp2 1.70.0. Go uses its default
`GOAMD64=v1` target; the build receipt records the Go environment. Runtime version maps
are retained, including Node's nghttp2/OpenSSL and Bun's BoringSSL/lshpack
entries. Sharing the `node:http2` API does not establish that Node and Bun
use identical native protocol or TLS engines; Bun provides its own
[implementation of that API](https://bun.com/reference/node/http2).

The client calibration deliberately tested both process layout and CPU
capacity. With eight server workers and 64 × 4, a short ZHTPS trial rose
from 825,283 requests/s on eight client CPU threads to 994,100 requests/s
when their SMT siblings were added. Go measured 413,138 and 401,934 requests/s,
respectively. These single short trials are diagnostic, not confidence
intervals. At 64 × 32 the client also saturated; that workload is retained
in calibration records and excluded from the primary matrix.

The eight-worker ZHTPS results may still be limited by the generator. They
are achieved end-to-end loopback throughput, not a demonstrated server
capacity ceiling. CPU use and client scaling evidence must accompany the
throughput ratios. This experiment does not measure physical-network,
large-body, upload, streaming-handler, or general application performance.
Closed-loop p99 values describe these workloads and cannot establish equal
latency at equal offered load.

Server CPU cost is process user plus system time from `/proc`, sampled around
the synchronized measurement and drain. It excludes warmup and client
histogram sorting, but includes small phase-completion bookkeeping. The
10 ms accounting resolution makes CPU costs approximate. CPU cores means
CPU seconds divided by elapsed wall seconds; client core counts include
SMT threads. Asynchronous kernel-worker CPU is not included. Memory snapshots
are diagnostic RSS/high-water marks, not allocator ownership accounting.

## Reproduction and evidence

Run from the repository root with Linux, Zig, Go, Node, Bun, OpenSSL,
nghttp2 development files, and permission to create loopback sockets and
io_uring instances:

```sh
zig build -Doptimize=ReleaseSafe --prefix zig-out/http2-benchmark \
  --cache-dir /tmp/zhtps-http2-zig-cache \
  --global-cache-dir /tmp/zhtps-http2-zig-global-cache
GOCACHE=/tmp/zhtps-http2-go-cache go build \
  -o zig-out/http2-benchmark/go-server bench/go_server/main.go
GOCACHE=/tmp/zhtps-http2-go-cache go build \
  -o zig-out/http2-benchmark/client bench/http2_client/main.go
python3 bench/compare_http2.py \
  --zhtps zig-out/http2-benchmark/bin/zhtps \
  --go-server zig-out/http2-benchmark/go-server \
  --client zig-out/http2-benchmark/client \
  --output /tmp/http2-comparison.json
```

The defaults select one hardware thread from each physical server core,
and the other half of the physical cores with their siblings for the client.
On smaller hosts, set `--workers`, `--server-cpus`, and `--client-cpus` to
valid lists. The runner rejects shared server/client physical cores and
always excludes Node and Bun when workers exceeds one. `--cases`,
`--servers`, `--client-processes`, `--duration`, `--warmup`, and `--repeats`
allow focused repetitions. Output paths must be new; results are checkpointed
after every trial and marked complete only after the whole matrix succeeds
and source/binary hashes are rechecked.

- [All primary trials and medians](runs/http2-comparison.json "Summary of docs/http2-comparison/results.json; raw artifact retired"), including
  commands, runtime versions, hashes, errors, CPU use, connection
  counts, start skew, and thread placements.
- [Build receipt](runs/http2-comparison.json "Summary of docs/http2-comparison/build.json; raw artifact retired") and
  the now-retired measured source archive. That archive
  captured this uncommitted HTTP/2 implementation and benchmark fixtures;
  the base commit alone does not reproduce the measured tree. Zig's pinned
  `zeit` dependency is specified in the archived `build.zig.zon`.
- Calibration records: four client processes,
  eight client processes,
  64 × 4 on physical client threads,
  and client SMT comparison.
  These retired records used the earlier histogram format where applicable.

Validation included all 84 end-to-end trials, `go vet` for both Go programs,
Node syntax checking, Python compilation, and whitespace checking. The client
also rejected an HTTP/1.1 fallback and an HTTP/2 response with an incorrect body
in separate negative checks. The independent accounting audit verifies trial
coverage, CPU separation, thread affinity, connection counts, response totals,
measurement duration, histogram totals, merged percentiles, and every median.
The original command below requires the retired raw results:

```sh
python3 bench/audit_http2.py docs/http2-comparison/results.json
```

The maximum observed client start skew was
0.547 ms. Source and binary hashes were unchanged throughout the primary run.

