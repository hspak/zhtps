# Verification and load measurement

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Run these commands from the repository root.

```sh
zig build test
zig build test-library
zig build test-wire
zig build test-resources
zig build test-deploy
zig build test-tls
zig build test-application test-upload test-response-streaming
zig build test -Dtest-filter='fuzz framing' -Derror-tracing=false --fuzz=100K
python3 tests/load.py --port 8080 --rate 1000 --duration 10 --connections 32
python3 tests/sweep.py zig-out/bin/zhtps --output docs/load-sweep.json
```

The load/sweep and HTTP/1 wire tools require Python 3.11 or later and use only its
standard library. TLS tests also invoke OpenSSL; the HTTP/2 suite requires the
packages in `tests/requirements-http2.txt`. See [HTTP/2 verification](http2.md#verification)
for environment setup and the `zig build test-http2` command.

Automatic sizing tests launch the real server with restricted CPU affinity and
descriptor limits, check the effective config, and serve HTTP requests. In-file
resource-discovery fixtures exercise cgroup v1/v2, inherited limits, namespace and
subtree mounts, malformed inputs, and NIC topology without changing host settings.
Existing wire and queue-expiry fixtures explicitly retain their original worker
and capacity settings so their saturation and scheduling coverage stays stable.
Wire and library integration tests start ephemeral local servers and exercise
real io_uring operations; they require an environment that permits those calls.
The ongoing [failure-mode comparison](failure-modes.md) records raw HTTP/1 and
HTTP/2 cases against Node and Go, retained policy differences, and regression fixes.
The fuzz target compares complete versus fragmented parsing, message boundaries,
decoded bodies, trailers, and errors. This host's Zig 0.16 fuzz test runner has an
error-return-trace type mismatch; `-Derror-tracing=false` works around that compiler
library issue while retaining Debug runtime safety checks. Tests use the LLVM
backend because the native backend did not generate usable fuzz coverage here.

## Load methodology

The load driver schedules offers independently of completed responses. Reported
latency starts at the intended offer time, so waiting for an available client
connection is included. Generator queue drops, transport errors, HTTP errors,
and rejection latency are reported separately. Scheduling lag identifies when
the Python generator cannot sustain the requested rate. This is a reproducible
load/overload probe, not a precision microsecond latency instrument.

For meaningful comparisons, pin server and generator to separate CPUs, use the
same kernel and CPU governor, warm up consistently, and sweep offered rate through
saturation and recovery. Compare successful response latency alongside errors,
rejections, queue drops, and goodput. A lower p99 obtained by rejecting most work
is a different outcome from preserving useful work at that latency.

## Reports and measurements

The checked-in [load sweep](runs/standalone.json "Summary of docs/load-sweep.json; raw artifact retired") used a 1,000 request/s admission
limit and 32-request burst, with two-second phases at 250, 1,500, 6,000, then 250
offers/s. It maintained about 1,015 successful responses/s in the overload
phases (including the initial burst), shed excess work with 503s or closed
connections, and returned to 500/500 successful requests in the recovery phase.
Generator scheduling lag was around a millisecond at p99, so these measurements
demonstrate admission and recovery rather than the server's latency floor or
maximum capacity.

The [sustained overload validation](overload.md) adds three-minute phases
at nominal 2×, 5×, and 10× calibrated baseline rates, separately exercising
connection reuse and churn. It records actual written traffic, unsent offers,
successful latency, rejection/failure latency, CPU, memory, and recovery, and
compares admission rate limits. The distinction between scheduled and delivered
load is essential when interpreting these results.

The [browser report](benchmarks.html) compiles these results and the earlier
comparisons into one offline HTML file with charts, a phase explorer, and embedded
run summary downloads.

The [remote HTTP/2 comparison](http2-lan.md) benchmarks ZHTPS, Go, Node,
and Bun using `client.example` as the client, with 64 through 16,384 connections
and four streams per connection. Node and Bun run only with one server CPU;
multiple-worker comparisons use Go. The report retains every failed operation
and marks workloads that cannot reach the requested connection population.

The [September 12 Go rerun](go-comparison-current.md) measures the current
worktree in both the original single-CPU setup and the 16-worker setup, with
fresh Debug, ReleaseSafe, and Go builds and comparisons to the historical results.

The earlier [multicore Go comparison](go-comparison-workers.md) measures 4,096,
8,192, and 16,384 connections. The [worker implementation and performance review](workers.md)
describes ownership, verification, profiling, and optimization measurements.

The [request critical-path review](request-critical-path.md) traces kernel
networking, request processing, and response completion. It gives measured and
estimated costs, prioritizes remaining improvements, and marks areas to stop optimizing.
The [local follow-up experiments](critical-path-experiments.md) record measured
changes, rejected variants, and the checks behind each decision.
The [remaining experiments and updated budget](request-path-remaining.md)
cover gather sends, streams, pipelines, receive alternatives, connection churn,
logging, timers, and local veth/kernel accounting, with retained and parked decisions.

The earlier [Go comparison](go-comparison.md) benchmarks Debug and `--release=safe`
builds against a minimal Go `net/http` server using persistent HTTP/1.1
connections. Its [runner and methodology](../bench/README.md) reproduce the builds,
CPU placement, warmup, repeated measurements, and response validation.
The [higher-connection results](go-comparison-high-connections.md) cover
512–8,192 connections with Go unrestricted across all available CPUs.
The [8,192-client overflow run](go-comparison-8192-overflow.md) starts ZHTPS
at valid capacity and reports useful responses alongside excess-client failures.
