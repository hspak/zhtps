# ZHTPS versus Go net/http

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

For the current multicore implementation, see the [worker comparison](go-comparison-workers.md).

For unrestricted Go and 512–8,192 connections, see the
[higher-connection comparison](go-comparison-high-connections.md). The results
below retain the original single-CPU setup.

On this Linux x86_64 host, ZHTPS ReleaseSafe delivered **463,365 requests/s** at
128 persistent connections: **2.60×** the minimal Go server and **2.28×** ZHTPS
Debug. Its client-observed p99 was **444 µs**, versus **1,630 µs** for Go and
**938 µs** for Debug. These results describe the small-response, single-CPU
workload below.

Each row is the median of three five-second trials after a one-second warmup.
The throughput range spans the three trials. Latency columns are the median of
the individual trials' quantiles, in microseconds.

| Connections | Server | Requests/s | Trial range, requests/s | p50 µs | p95 µs | p99 µs |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | ZHTPS Debug | 98,803 | 97,800–99,067 | 9.6 | 11.8 | 17.9 |
| 1 | ZHTPS ReleaseSafe | 139,065 | 138,605–139,080 | 6.8 | 8.7 | 13.1 |
| 1 | Go net/http | 90,578 | 90,549–92,335 | 9.9 | 13.7 | 25.6 |
| 16 | ZHTPS Debug | 187,678 | 187,533–189,236 | 82.9 | 101.9 | 140.3 |
| 16 | ZHTPS ReleaseSafe | 417,578 | 416,233–419,775 | 37.1 | 48.9 | 71.7 |
| 16 | Go net/http | 186,340 | 183,984–186,979 | 82.4 | 155.6 | 241.7 |
| 128 | ZHTPS Debug | 203,605 | 200,899–205,347 | 606.2 | 798.7 | 938.0 |
| 128 | ZHTPS ReleaseSafe | 463,365 | 457,657–464,083 | 268.3 | 362.5 | 444.4 |
| 128 | Go net/http | 178,304 | 175,587–181,997 | 720.9 | 1,359.9 | 1,630.2 |

Debug and Go have essentially the same throughput at 16 connections. Increasing
concurrency to 128 adds little throughput for either while increasing response
latency substantially. ReleaseSafe has higher throughput at every tested
concurrency, including the single-connection round-trip case.

All **29,462,107 measured requests** returned the expected status and body.
There were **zero errors**, including during warmup, and **zero reconnects**.
The [summarized results](runs/standalone.json "Summary of docs/go-comparison.json; raw artifact retired") contain every trial, maximum latencies,
CPU measurements, exact commands, toolchain versions, and source/binary SHA-256
hashes. The hashes were checked against the built binaries and source files.

The measurements started at **2026-09-11 05:02:15 UTC** (September 10 in
America/Los_Angeles), on:

| Setting | Configuration |
| --- | --- |
| CPU | AMD Ryzen AI Max+ 395, 16 physical cores / 32 logical CPUs |
| Kernel | Linux 7.2.4-arch1-2-strixhalo, x86_64 |
| CPU policy observed | `performance`, `amd-pstate-epp`, boost enabled |
| Zig | 0.16.0; Debug and `--release=safe` (ReleaseSafe), default native target |
| Go | `go1.27.0-X:nodwarf5 linux/amd64`; `GOAMD64=v1`, `GOEXPERIMENT=nodwarf5` |
| Server placement | CPU 0; Go `GOMAXPROCS=1` |
| Client placement | CPUs 1–4, separate physical cores; `GOMAXPROCS=4` |
| Request | HTTP/1.1 `GET /`, loopback TCP, no TLS |
| Response | 200, six bytes `ZHTPS\n`, matching Content-Type and ETag |
| Connection behavior | Keep-alive; one outstanding request per connection; no pipelining |

The Go baseline uses the standard `net/http.Server` with a small handler and
header/write/idle timeouts. ZHTPS runs its existing application, metrics,
admission checks, and normal JSON log generation. Both servers send output to
`/dev/null`; Go does not have an access logger or metrics subsystem. ZHTPS retains
its default resource budgets and disabled request-rate limiter. Its per-connection
request limit is raised from 1,000 to 4,294,967,295 to avoid forced turnover.

Each trial starts a fresh server. The client validates status, Content-Length,
body bytes, and persistent-connection behavior for every response. Warmup requests
are excluded; measured requests already in flight at the deadline are drained,
and that drain is included in elapsed time. Server order rotates across repeats
to reduce systematic order bias.

The client records time from immediately before a request through receipt and
validation of its full response. Its bounded histogram reports quantile upper
bounds with less than 0.8% rounding error. The histogram's boundary and merge
tests passed.

Client CPU consumption peaked at about 171% of one CPU in the main trials, within
the four-CPU allocation. A separate [client-capacity check](runs/standalone.json "Summary of docs/go-comparison-client-check.json; raw artifact retired")
repeated the fastest case with four and eight client cores, three times each.
Median throughput was 455,164 requests/s with four cores and 443,497 with eight.
Extra client cores produced no throughput gain, supporting the main setup;
this does not establish a universal server throughput ceiling. Process CPU
measurements include warmup and exclude separately accounted interrupt work.

This is a **closed-loop** benchmark: each client waits for its response before
sending another request. Slower responses reduce the offered rate. Its p99s do
not measure a fixed-arrival-rate latency SLO and are not corrected for coordinated
omission. The single-CPU allocation matches ZHTPS's current event loop; Go's
multicore scaling is outside this comparison. Larger bodies, connection churn,
real networks, TLS, and overload shedding also require separate workloads.
CPU affinity does not reserve cores, and host noise and boost can affect results.

Reproduce the full comparison from the repository root:

```sh
python3 bench/compare.py --duration 5 --warmup 1 --repeats 3 --go-cpu-mode single \
  --output docs/go-comparison.json
```

The runner builds both requested Zig configurations in separate directories:

```sh
zig build -Doptimize=Debug --prefix zig-out/bench/debug
zig build --release=safe --prefix zig-out/bench/release_safe
```

The optional client-capacity check reuses those binaries and requires nine
available physical cores:

```sh
python3 bench/check_client.py
```

See [the harness documentation](../bench/README.md),
[Go baseline](../bench/go_server/main.go), and [load generator](../bench/load/main.go)
for the complete setup. The runtime environment must allow io_uring and loopback
sockets; these trials ran outside the workspace sandbox because it blocks io_uring.
