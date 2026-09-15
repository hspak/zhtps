# Go comparison

Keep raw output in the ignored `zig-out/bench/` directory or another scratch
location. Commit only useful [run summaries and descriptions](../docs/runs/README.md).
Historical commands in the recorded reports may reference artifacts that have
since been removed.

From the repository root:

```sh
python3 bench/compare.py --duration 5 --warmup 1 --repeats 3 \
  --output zig-out/bench/go-comparison-current.json
```

The runner builds the current worktree's Debug binary, its `--release=safe`
binary, the Go `net/http` baseline, and the Go load generator. It uses only the
Python and Go standard libraries. Linux, Zig, Go, `taskset`, five available
physical cores, and permission to use io_uring and loopback sockets are required.
Binaries go under `zig-out/bench`; compiler caches go under `/tmp/zhtps-*-cache`.

With `--zig-workers 1`, ZHTPS gets one logical CPU. With multiple workers,
ZHTPS runs without an affinity restriction. Go runs without
an affinity mask or a `GOMAXPROCS` override by default. `--go-cpu-mode single`
reproduces the earlier single-CPU policy. The client uses four other physical
cores by default, configurable with `--client-cores`. It avoids ZHTPS's SMT
sibling, and its `GOMAXPROCS` matches its allocated core count. Unrestricted Go
shares the host with the client and may run on the client's CPUs.
CPU affinity limits placement but does not reserve cores against other host work.

The request is HTTP/1.1 `GET /` over loopback. Every response must be 200, have a
six-byte `Content-Length`, contain exactly `ZHTPS\n`, and preserve the connection.
Both servers send the same content type and ETag. Each connection has one request
outstanding; there is no pipelining or reconnect workload. TLS is opt-in. By default,
concurrency is 1, 16, and 128. Pass `--connections` to select counts up to 16,384.
The runner raises its inherited soft file-descriptor limit as needed, within the
existing hard limit. `--variants` selects a subset of the three servers.

To compare OpenSSL in ZHTPS with Go's `crypto/tls`, generate a disposable
certificate and pass it to both servers:

```sh
mkdir -p zig-out/bench/tls
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout zig-out/bench/tls/key.pem -out zig-out/bench/tls/cert.pem \
  -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1
python3 bench/compare.py --variants zig_release_safe go --go-cpu-mode single \
  --no-zig-access-log --tls-certificate zig-out/bench/tls/cert.pem \
  --tls-key zig-out/bench/tls/key.pem --duration 5 --warmup 1 --repeats 3 \
  --output docs/go-comparison-tls.json
```

Both sides use TLS 1.3 and HTTP/1.1. The benchmark client and readiness probe
skip certificate verification for these disposable certificates. Do not use
this client for security validation. Handshakes complete before warmup; results
measure encrypted keepalive requests, not handshake capacity or bulk encryption.
The load generator rejects combining `-tls` with open-loop `-schedule`.

Each trial starts a fresh server. The client establishes and verifies every
connection, with at most 64 concurrent opens, before a shared warmup begins.
The default warmup is one second and measurement lasts five seconds. Requests started during warmup are
excluded. Requests started before the measurement deadline are drained and their
drain time is included in the throughput denominator. Server order rotates across
three repeats. The summary contains median throughput, its min/max across runs,
and the median of each run's latency quantiles; it does not pool the quantiles.
Raw results, errors, connection counts, CPU usage, commands, toolchain versions,
and source/binary hashes are retained in JSON. Partial runs have no `summary`.

For a separate load-generator host, build once, copy `zig-out/bench/load` to that
host, and pass its SSH name and installed binary path:

```sh
python3 -c 'import sys; sys.path.insert(0, "bench"); import compare; compare.build()'
scp zig-out/bench/load load-host:/tmp/zhtps-comparison-load
python3 bench/compare.py --server-address SERVER_LAN_IP --client-host load-host \
  --remote-client-binary /tmp/zhtps-comparison-load --client-cores 8 \
  --connections 4096 8192 16384 --zig-workers 16 \
  --zig-max-connections 2048 --zig-max-active 2048 --no-zig-access-log \
  --duration 5 --warmup 2 --repeats 3 --output docs/go-comparison-lan.json
```

Use `--ssh-config PATH` when the host needs a dedicated SSH configuration.
The host key must already be trusted. The remote host needs Python 3 and Linux;
the installed client must be executable and match the freshly rebuilt local
client's SHA-256. The runner rejects clients sharing the server's kernel and
records the remote identity, affinity, binary hash, clock estimate, and resource
samples. Remote `--client-cores N` selects logical CPUs `0..N-1`; verify these
are distinct physical cores on the chosen host. The client's `GOMAXPROCS` is N.
The collector cancels load on parent disconnect, heartbeat expiry, or timeout.
Server NIC and TCP counters are retained around each trial. The public listener
binds to `--server-address`; the admin listener retains its loopback default.

See [the September 12 LAN comparison](../docs/go-comparison-lan.md) for the
recorded two-host setup and its comparison with the earlier loopback results.
The [32-worker follow-up](../docs/go-comparison-lan-workers32.md) uses 1,024 slots
per worker to preserve total capacity and fit the host's ring-memory budget.
The [comparison after the retained architecture changes](../docs/go-after-nginx.md)
uses seven NIC-local ZHTPS workers against Go with explicit `GOMAXPROCS=32`,
and includes streaming uploads with independently validated length and CRC32.
Its recorded commands use `bench/architecture.py --go-binary PATH` for GET and
`bench/upload_compare.py --go-binary PATH --candidate PATH` for uploads, keeping
the separately recorded Go and ZHTPS executables fixed across repeats.

ZHTPS keeps admission checks, metrics, and normal log generation. The runner sets
`--max-requests 4294967295` to avoid the default 1,000-request connection turnover.
It explicitly sets `--max-connections` and `--max-active` to at least 256,
or the requested count when larger, unless overridden. This preserves the
comparison's full-concurrency workload independently of automatic admission
headroom. Other budgets retain their defaults. Both servers' output goes to
`/dev/null`; Go has no access logger or metric collection. The baseline implements
only the workload and does not attempt feature parity.

Latency is measured by the client from immediately before sending to receipt and
validation of the complete response. Histogram quantiles round upward by less
than 0.8%. This is a closed-loop comparison: slower responses reduce offered
load. These percentiles therefore do not measure latency at a fixed arrival rate
or correct coordinated omission, and the benchmark does not test overload
shedding. CPU measurements include warmup; the server measurement also includes
connection preparation. 100% means one CPU. Client CPU usage
helps identify generator limits but alone cannot prove their absence.

The load generator's histogram boundary and merge checks can be run with:

```sh
GOCACHE=/tmp/zhtps-go-cache go test bench/load/main.go bench/load/offered.go bench/load/main_test.go bench/load/offered_test.go
```

See [the current rerun](../docs/go-comparison-current.md) for both CPU setups and
their historical comparisons, or [the original results](../docs/go-comparison.md).

The [request-footprint experiments](../docs/request-footprint.md) follow that rerun
with compiled field offsets, cache-counter measurements, fixed worker affinity,
and comparisons of parser storage, narrower fields, and buffer placement.

The [higher-connection comparison](../docs/go-comparison-high-connections.md)
uses unrestricted Go and a larger client:

```sh
python3 bench/compare.py --connections 512 1024 4096 8192 --go-cpu-mode unrestricted \
  --client-cores 15 --duration 5 --warmup 1 --repeats 3 \
  --output docs/go-comparison-high-connections.json
```

For the historical single-worker run, ZHTPS permitted 8,176 slots including admin, or
8,168 public connections with the eight default admin slots. At 8,192 the runner
records the actual `InvalidLimit` startup failure and reports that case as
unsupported. It does not lower the requested count or change the server's limit.
Supported trials require every requested connection to have completed measured
requests, with no connection turnover.

To offer more clients than the running server can admit, use overload mode:

```sh
python3 bench/compare.py --connections 8192 --zig-max-connections 8168 \
  --zig-max-active 8168 --allow-errors --go-cpu-mode unrestricted \
  --client-cores 15 --duration 5 --warmup 1 --repeats 3 \
  --output docs/go-comparison-8192-overflow.json
```

`--allow-errors` retains clients whose setup request failed and keeps retrying
after HTTP errors or transport failures. Successful responses must still have
status 200, length six, and the exact expected body. A successful response may
close its connection; the client then reconnects for the next request. Preparation
still attempts every client before warmup, but successful preparation is not a
requirement in this mode. The requested client count and actual successful
connection count are reported separately.

`--zig-max-connections` separates server capacity from offered concurrency, and
`--zig-max-active` sets the request permit budget. Both apply per Zig worker.
If no connection capacity is
specified, overload mode limits it to 8,168 while retaining every offered client.
The request permit budget defaults to the chosen server connection capacity.
Go's connection policy remains its own; these overrides apply only to ZHTPS.

In overload mode, the printed rate is `window_successes_per_second`: validated
responses completed during the fixed measurement window divided by its duration.
`window_failures` counts failures completing in that same interval, including
HTTP status categories, read/dial timeouts, resets, and invalid responses. Thus a
late failed request cannot lengthen the throughput denominator after other
clients have stopped generating work. The older `requests_per_second` field
still reports the request-start cohort's throughput including drain.

Latency remains the distribution of successful requests started in the
measurement window, including their drain. `attempts = successes + errors`
accounts for this cohort, while `failures` classifies its errors. Setup and warmup
failures have separate counts. Failure latency is not part of successful-response
percentiles. See [the 8,192-client overflow results](../docs/go-comparison-8192-overflow.md).

After a comparison, `python3 bench/check_client.py` checks the fastest case with
four versus eight client cores, alternating order across three repeats. It reuses
the built binaries, requires nine available physical cores, and records results
in `docs/go-comparison-client-check.json`.

## Multicore comparison

```sh
python3 bench/compare.py --connections 4096 8192 16384 --zig-workers 16 \
  --zig-max-connections 2048 --zig-max-active 2048 --no-zig-access-log \
  --go-cpu-mode unrestricted --client-cores 15 --allow-errors \
  --duration 5 --warmup 1 --repeats 3 --output docs/go-comparison-workers.json
```

This configures 32,768 public connection slots, retaining headroom for
`SO_REUSEPORT` distribution. It does not divide 2,048 slots among workers.
Both servers may run on every allowed CPU. Go has no `GOMAXPROCS` override.
The client still uses the specified physical cores and competes for this host
with both servers. A separate load-generator host is needed to isolate server
capacity from generator and loopback contention.

The comparison disables ZHTPS access logs explicitly because the Go reference
has none. ZHTPS admission, parsing, response validation, counters, and latency
histograms remain enabled. Omitting `--no-zig-access-log` preserves the default
access logging. The raw report records this choice, worker counters and ring
sizes before/after each trial, and CPU time for each worker thread.
`--allow-errors` ensures rejection/transport failures remain measurable at every
offered count; healthy trials can still be audited for zero errors and exactly
one persistent connection per client. Use fixed-window goodput when comparing
these runs. See [the multicore results](../docs/go-comparison-workers.md).

## Sustained fixed-rate overload

Build the ReleaseSafe server and the fixed-rate-capable client:

```sh
zig build --release=safe --prefix zig-out/bench/overload \
  --cache-dir /tmp/zhtps-overload-cache --global-cache-dir /tmp/zhtps-zig-global
GOCACHE=/tmp/zhtps-go-cache go build -o zig-out/bench/load \
  bench/load/main.go bench/load/offered.go
```

`bench/overload.py` starts a fresh server on ephemeral loopback ports, places
server and generator on separate CPU lists, and samples process CPU, resident
memory, descriptor counts, admin metrics, and network-namespace TCP drop counters
once per second. It preserves source/binary hashes, effective server configuration,
commands, phase results, and resource samples. Its default workload disables access
logs and the normal 1,000-request connection turnover. Pass `--access-log` to retain
access logs. The server uses automatic admission counts unless explicitly overridden.

Use `--server-binary /path/to/zhtps` to compare prebuilt server variants; its
default remains `zig-out/bench/overload/bin/zhtps`.

After calibrating a sustainable offered rate, use phases such as:

```sh
python3 bench/overload.py --output docs/overload/example.json \
  --server-cpus 0 --client-cpus 1-14 --connections 512 --max-connections 512 \
  --schedule 10000:10s,100000:30s,200000:180s,100000:30s \
  --labels warmup,baseline,overload,recovery
```

These example rates are illustrative. Repeat at 2x, 5x, and 10x the measured
baseline, and pass `--churn` for one new TCP connection per request. Use
`--rate-limit`, `--burst`, and `--rejection-rate` for admission experiments.
For high connection rates, `--source-ips 16` distributes client ports across
127.0.0.2 through 127.0.0.17. The client uses Linux `IP_BIND_ADDRESS_NO_PORT`
to defer port selection until connect; this avoids early-bind port scanning
under TIME_WAIT pressure. No host TCP sysctls are changed.
The schedule runs through one server process and one client pool, so recovery
does not get a fresh process or discard the existing connection population.

The Go client's `-schedule rate:duration,...` mode distributes uniformly scheduled
offers across independent shards. Scheduling never waits for network completion.
Each shard has a bounded queue; offers that cannot be enqueued, or exceed
`-max-lag` before I/O starts, are recorded as generator drops/expirations. Each
network worker has at most one outstanding request, reuses healthy connections,
and reconnects after server closure or errors. This mode does not pipeline.

Successful response bodies and lengths are validated. Success, HTTP rejection,
and transport-failure latency distributions start at the intended offer time;
successful service latency separately starts immediately before I/O. Histograms
have less than 0.8% upward quantile rounding. `sent` means a complete request was
handed to the local socket, not that the server processed it. Compare it with
server admission/rejection counters. Queue drops and expiration never count as
server rejections. Every scheduled offer must appear in exactly one outcome.

`window_successes_per_second` counts successful requests scheduled in that phase
and completed before its end, divided by the fixed phase duration. Cohort latency
includes requests finishing during subsequent phases or final drain. The report
retains both counts. Scheduler lag and client CPU identify when nominal offered
load exceeds the generator's ability to put requests on the wire; a nominal 10x
schedule alone is not evidence that the server received 10x baseline traffic.

CPU affinity separates execution placement, but this remains a shared-host
loopback test: kernel networking, memory bandwidth, caches, and thermal limits
are shared. TCP drop counters cover the network namespace, not just ZHTPS.

For representative workloads, use `--method`, `--path`, `--request-body`,
`--expect-body`, and `--content-type`. The request and expected-response files
are bounded to 64 MiB each and their hashes are retained. `--allow-chunked`
accepts chunked response framing while still checking every expected byte and
the response boundary. `--client-max-requests`, `--server-max-requests`,
`--access-log`, and `--timeout` make connection lifetime, logging, and failure
deadlines explicit. Latency reports include p99.9, p99.99, and maximum; missing
tail percentiles in historical reports remain missing, not reconstructed.

`--client-host` and `--remote-client-binary` run the generator over SSH and
collect its actual CPU/RSS, binary hash, payload hashes, clock alignment, and
kernel identity. `--target-address` routes through an ingress while the harness
owns the local origin process. Shared-kernel runs are rejected unless explicitly
marked as functional checks. See [upstream admission and distributed validation](../docs/ingress.md)
for deployment, independent connection budgets, and the sustained evidence audit.

Summarize completed reports and export a figure (plotting requires matplotlib):

```sh
python3 bench/summarize_overload.py docs/overload/sustained-persistent.json \
  docs/overload/sustained-churn.json --output docs/overload/sustained-summary.json
python3 bench/plot_overload.py docs/overload/sustained-persistent.json \
  docs/overload/sustained-churn.json --output docs/overload/sustained.svg
```

The summarizer checks offer accounting and clean server exit. Its baseline
criterion is 99.9% successful scheduled offers and successful p99 below 10 ms;
intentional overload must instead be assessed by preserved goodput, latency,
resource use, failure behavior, and recovery. See the
[sustained overload validation](../docs/overload.md) for results and limitations.

## Admission and SIMD components

Build the component benchmark with the same optimization and CPU target as the server:

```sh
zig build install-hot-paths --release=safe -Dcpu=x86_64_v4 --prefix /tmp/zhtps-after
taskset -c 2 /tmp/zhtps-after/bin/hot-paths 100000000
```

It emits JSON lines on stderr for admission acquire/release cycles, metric
observations, and complete HTTP parsing. The argument sets admission and histogram
iterations; parser cases run one twentieth as many iterations. The clock is read
only around each loop. Admission options remain runtime inputs, with a compiler
barrier preventing the loop from collapsing into a closed-form calculation.
Functions and storage use fixed alignment to reduce code-layout noise.
There are no sockets or clock reads per admission decision in this benchmark.

Use identical copies of `bench/hot_paths.zig` and the build steps in both trees,
and install the pre-change tree into a different prefix. Compare the binaries:

```sh
python3 bench/compare_hot_paths.py --before /tmp/zhtps-before/bin/hot-paths \
  --after /tmp/zhtps-after/bin/hot-paths --cpu 2 --repeats 5 \
  --output docs/simd/components.json
```

The comparison alternates order, verifies identical decision counts and metric
sums, and records raw timings, binary hashes, and min/median/max costs. CPU
affinity does not reserve the core. See [the recorded results](../docs/simd.md),
including the separate server CPU measurements under offered-rate load.

## Browser report

Open [docs/benchmarks.html](../docs/benchmarks.html) directly in a browser. It
includes the remote HTTP/2 comparison with Go, Node and Bun at 64 through 16,384
connections, throughput/p99/failure charts, and the earlier loopback comparison,
plus the complete performance investigation: retained HTTP/1 GET/upload
comparisons, Go and nginx architectural reviews, retained and rejected changes,
upload CRC/queue/cache attribution, timeout diagnostics and pacing experiments,
and the original loopback, admission, worker and kernel reports.

The overview summarizes decisions and acceptance, including higher p50 accepted
for lower p99. A metric chart and filterable 90-comparison ledger expose the final
retained measurements, individual trial values, unresolved results and ties.
Searchable, expandable reports preserve the full technical text. The original
overload phase explorer remains available separately. HTTP/2 LAN results identify
the remote client host and show actual connection populations and every failure
count. Earlier loopback measurements remain explicitly labeled. Node and Bun
appear only at one worker; the multi-worker charts compare ZHTPS and Go.

The HTML works offline and can be copied as one file. It embeds the reports,
compact run catalogs, and summary CSVs and charts. Downloads restore those retained
files using the browser's DecompressionStream; older browsers receive a `.gz`
file to decompress. SHA-256 hashes accompany each download. Source links require
the repository checkout. The print button expands all reports and trial details,
including filtered results. Full report text and tables are readable without
JavaScript.

See [recorded runs and artifact retention](../docs/runs/README.md) for the catalog
format and retained evidence. Raw measurements, logs, binaries, profiles, and
source snapshots have been removed. Historical commands below may reference
retired artifacts. Write new raw runs to `zig-out/bench/` or another scratch
location; commit only the useful summaries and run descriptions.

To rebuild after updating the source reports (requires Python-Markdown):

```sh
python3 bench/render_reports.py
```

The builder reads the Markdown reports and `docs/runs/` catalogs; it does not
rerun benchmarks or require raw measurements. The generated document embeds its
CSS, JavaScript, charts, reports, and summaries without browser-side libraries.


The [critical-path experiments](../docs/critical-path-experiments.md) describe
historical source variants with recorded compiler roots and hashes. Recreate
variants from the descriptions before using the following tools; their original
snapshots are no longer included. Use `build_request_variants.py`
with one Zig local cache per source tree, `compare_request_path.py` for offered-rate
comparisons, and `compare_request_latency.py` for fixed concurrency. The component
runner and `inspect_request_path.py` cover parser costs, idle pools, syscall counts,
and bounded CPU profiling. Run CPU experiments sequentially; the report includes
exact source restoration commands and identifies the invalidated early cache results.

The [remaining request-path experiments](../docs/request-path-remaining.md) extend
that comparison to large bodies, streams, pipelines, churn, and local veth traffic.
For already restored variant trees, use a separate records directory:

```sh
python3 bench/build_request_variants.py baseline retained_candidate \
  --workspace /tmp/zhtps-remaining --records /tmp/zhtps-rebuilt-records
python3 bench/compare_request_path.py baseline retained_candidate \
  --workspace /tmp/zhtps-remaining --records /tmp/zhtps-rebuilt-records \
  --case echo --schedule 1000:2s,5000:6s,20000:6s \
  --output /tmp/zhtps-echo-comparison
```

The comparison verifies source and executable hashes against the build records.
`--churn --isolated-loopback` gives each churn trial a fresh network namespace
and uses 64 local source addresses. `--observed-cpus` can include a dedicated
SQ polling core in CPU accounting. Offered-rate, pipeline, and kernel probes use
different measurement boundaries; compare variants within a harness.

The pipeline client validates every response at the requested depth. Its optional
fragment size controls client writes, not TCP packet boundaries. This harness
reports throughput and CPU per response, without latency quantiles:

```sh
GOCACHE=/tmp/zhtps-go-cache go build -o /tmp/zhtps-pipeline bench/pipeline/main.go
python3 bench/pipeline_request_path.py --binary zig-out/bin/zhtps \
  --depth 8 --fragment 0 --output /tmp/zhtps-pipeline.json
```

Local packet-path tests create disposable user/network namespaces and a veth pair.
They require `unshare`, `nsenter`, `ip`, `ethtool`, and permission to create those
namespaces. GRO changes apply only to the temporary links; host interfaces and
sysctls are untouched. The namespaces still share one kernel:

```sh
python3 bench/local_packet_path.py --binary zig-out/bin/zhtps \
  --server-cpus 2 --client-cpus 4-7 --gro on \
  --output /tmp/zhtps-veth.json
```

The optional C probe requires liburing development files (tested with 2.15).
It validates TCP exchanges but excludes HTTP and server concurrency/lifetime
policies. `recv`, `multishot`, `zc`, `busy`, `accept`, and `direct` select mechanisms.
The probe pins server/client to CPUs 2/4; the pipeline harness uses 2/4–7. Adjust
these experiment-specific constants for another machine before comparing results.

```sh
cc -O2 -Wall -Wextra bench/kernel_path.c -luring -o /tmp/zhtps-kernel-path
python3 bench/local_packet_path.py --probe-binary /tmp/zhtps-kernel-path \
  --probe-mode multishot --probe-size 64 --probe-iterations 100000 \
  --output /tmp/zhtps-multishot-veth.json
```

Zero-copy usage notifications and incoming NAPI IDs are recorded. Local delivery
copy fallback and NAPI ID zero must not be presented as successful hardware
zero-copy or effective busy polling. `idle_request_path.py` measures idle worker
CPU; `/proc` CPU ticks are coarse, while recorded scheduler runtime provides
finer accounting. None of these helpers establishes physical-network capacity.

## Keepalive policy and shutdown

The [keepalive policy follow-up](../docs/keepalive-policy.md) records rotated
normal-load controls and a pressure workload in which every original client
returns after newcomers arrive. Reproduce the policy screen with:

```sh
python3 bench/keepalive_policy.py --binary /path/to/zhtps --mode normal \
  --output /tmp/keepalive-normal
python3 bench/keepalive_policy.py --binary /path/to/zhtps --mode pressure \
  --output /tmp/keepalive-returning
```

The runner defaults to the recorded LAN addresses, SSH configuration and worker
CPUs. Select the testbed before running it. `--ages`, `--repeats`, `--idle-ms`,
and `--schedule` control the comparison. Passing `--idle-reclaim-ms 0` to
`bench/architecture.py` explicitly disables the policy even if the binary enables
it by default; omitting that option preserves the binary's default.

## Kernel work and physical NIC placement

The [kernel-work report](../docs/kernel-work.md) records multishot HTTP receive,
response aggregation, vectorized SEND, receive bundles, and direct-LAN placement.
The runtime variants and compiler provenance are preserved under
`docs/kernel-work/snapshots/`; the live server keeps the baseline transport.

After restoring a variant tree and its local `zeit` dependency, rebuild with:

```sh
python3 bench/build_request_variants.py baseline multishot --workspace /tmp/zhtps-kernel-work --records docs/kernel-work --global-cache-dir /tmp/zhtps-zig-global-cache
python3 bench/compare_kernel.py baseline multishot --output /tmp/new-kernel-comparison
python3 bench/compare_kernel_echo.py baseline multishot --output /tmp/new-echo-comparison
python3 bench/audit_kernel_work.py
```

Choose fresh output paths. Kernel counters need per-process kernel profiling
permission. CPU/IRQ numbers and SSH settings in the physical runners describe
this recorded testbed; inspect topology before using them elsewhere. The offered
runner retains generator misses separately from HTTP and transport failures.

`pipeline_kernel.py` compares the actual worker with explicit admission budgets;
`pipeline_packets.py` additionally captures whole-host TCP segment counters.
`physical_offered.py` uses the existing offered-rate harness with the authorized
SSH transport and TCP/NIC snapshots from both hosts. `profile_physical.py`
captures server kernel stacks under gradually opened remote traffic.

The additional pipeline boundaries run with `zig build test-wire`. Collector
regressions can be checked separately:

```sh
python3 tests/remote_load.py
```

The [aggregation revisit](../docs/response-aggregation-v2.md) uses
`aggregation_revisit.py` to rotate baseline, coalescing, and adaptive candidates
across both admission budgets. It preserves CPU, whole-host TCP packet, response
validation, and PMU records for every trial. Use `--user-perf` when kernel PMU
profiling is unavailable; this selects only user-mode cycles and instructions.
The [NIC placement helper](../docs/nic-placement.md) produces an explicit
`--worker-cpus` mapping from the service's allowed CPUs and current IRQ topology.

## nginx-inspired changes

The [implementation report](../docs/nginx-implementation.md) records sequential
request-storage, idle-reclamation and request-body streaming comparisons.
`build_nginx_variant.py` archives source and builds in a fresh local cache, then
copies independent executable bytes with a receipt. `--source` selects a
restored earlier tree. Use a new variant name and output directory each time.

```sh
python3 bench/build_nginx_variant.py upload-new --step install-upload-bench \
  --zig-option=-Dbody-streaming=true --zig-option=-Dupload-observe=false
python3 bench/upload_compare.py \
  --before zig-out/nginx-implementation/upload-before-unobserved/upload-bench \
  --candidate zig-out/nginx-implementation/upload-new/upload-bench \
  --output /tmp/zhtps-upload-comparison --repeats 3 --duration 20
```

The upload fixture accepts up to 8 MiB and returns length plus CRC32. The prior
version buffers and hashes the complete body; streaming hashes decoded chunks.
`-Dupload-observe=false` removes correctness-fixture progress counters and gates
from both measured variants. Correctness tests use the default observation mode:
`zig build test-upload -Doptimize=ReleaseSafe`. `-Dbody-streaming=false` selects
the buffered benchmark fixture; it is not the incremental test mode.

`upload_compare.py` rotates 64 KiB and 8 MiB requests across 32 persistent remote
clients. Its default client is closed-loop and validates every response; warmup
is five seconds. `--body-bytes 8388608 --rate 25` caps aggregate starts at 25/s,
with staggered client starts and no accumulated catch-up bursts. This is a paced
closed-loop control, not the offered-load generator. The client retains one
shared payload and records completion-window goodput separately from all
attempted and validated requests.

`idle_pressure.py` fills a worker's slots with completed keepalive requests before
introducing new peers. It records expected baseline timeouts as failures, along
with candidate successes and old connections closed. These physical runners
use the recorded testbed's LAN address, CPU placement and SSH configuration;
adjust them before running on another machine. They verify independent host
boot IDs and the actual running server executable hash.

`python3 bench/audit_nginx_implementation.py` verifies the recorded build
receipts, raw measurement accounting and final source identity. It also emits
upload aggregate tables while retaining every individual trial and the earlier
instrumented diagnostic comparisons.

## HTTP/2 runtime comparison

[`compare_http2.py`](compare_http2.py) benchmarks ZHTPS, Go, Node, and Bun
with one server core, then compares only ZHTPS and Go with multiple workers.
Node and Bun run the same [`node:http2` fixture](http2_server.cjs). The TLS 1.3
client verifies every response, pins independent load processes to separate
physical cores, and synchronizes measurement after concurrent warmup.

See the [HTTP/2 comparison](../docs/http2-comparison.md) for build/run commands,
resource settings, client calibration, results, and raw evidence. Defaults are
three eight-second trials after two-second warmups, with worker counts 1, 2,
4, and 8. On smaller hosts pass suitable `--workers`, `--server-cpus`, and
`--client-cpus` lists. Node/Bun are automatically omitted above one worker.

### Remote HTTP/2 comparison

[`compare_http2_lan.py`](compare_http2_lan.py) runs the load client on
`client.example` over SSH using `/path/to/benchmark-key`, while servers listen on the local
LAN address. It transfers the compiled client, Python supervisor, and public
test certificate to a fresh remote temporary directory. Request traffic uses
the LAN directly. Defaults are 64, 1,024, 8,192, and 16,384 connections, four
streams per connection, three eight-second trials after two-second warmups,
and server CPU counts 1, 2, 4, and 8. Node/Bun run only with one CPU.

The explicit HTTP/2 client has no automatic retries or reconnections. Setup,
holding, warmup, and measured failures are all recorded individually as gzip
JSONL. Actual established, ready, participating, successful, and surviving
connection counts are retained, including workloads above ZHTPS's per-worker
connection capacity. Results with request failures remain in the comparison.

```sh
(cd bench/http2_lan_client && CGO_ENABLED=0 GOCACHE=/tmp/zhtps-http2-go-cache \
  go build -o ../../zig-out/http2-benchmark/lan-client .)
python3 bench/compare_http2_lan.py --output /tmp/http2-lan
python3 bench/audit_http2_lan.py /tmp/http2-lan
python3 bench/summarize_http2_lan.py /tmp/http2-lan --output /tmp/http2-lan-summary
python3 bench/check_http2_lan_idle.py
```

See the [remote report](../docs/http2-lan.md) for server build commands, exact
environment and settings, all results, individual failure logs, and audit
receipts. The report generator uses the summary JSON for its tables and charts;
`http2_lan_report.md` and `http2_lan_report.html` are its report templates.
