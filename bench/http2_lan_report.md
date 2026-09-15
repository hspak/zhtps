# HTTP/2 comparison with a remote load host

Measured on September 14, 2026, with the load generated on
`client.example` (reported hostname `benchmark-client`, `192.0.2.20`) and all servers
on `benchmark-server` (`192.0.2.10`). This is a two-host wired LAN benchmark. The
[earlier loopback comparison](http2-comparison.md) remains separate.

The client hardware and client HTTP/2 implementation also differ from the
loopback experiment, which used the Go standard-library transport. Differences
between those reports cannot be attributed solely to the network path.

The matrix contains @@TRIALS@@ trials and @@SUCCESSES@@ verified measured responses.
All @@FAILURE_RECORDS@@ failed operations are retained as individual records,
including setup, connection holding, warmup, and measurement. A trial with
request failures stays in the results. Rates and latency below are medians
of three trials; failure counts are totals across those three trials.

@@FINDINGS@@

**Client placement sensitivity:** @@CALIBRATION_NOTE@@

## One constrained worker

Each server process and all its threads are restricted to one physical CPU.
Node and Bun run only in this comparison, using the same `node:http2` fixture.
Cells show **verified responses/s**, then **successful-response p99**.
Every connection uses **four concurrent stream slots**.

@@SINGLE@@

**† Partial connection population in at least one trial.** The rate is the
observed result at the requested target; it must not be presented as a
comparison in which both servers maintained that many connections.
The actual populations and failures appear below.

## Multiple workers

ZHTPS uses the stated number of workers. Go uses the same CPU affinity and
`GOMAXPROCS` equal to that CPU count. Node and Bun are excluded.
Cells again show verified responses/s and successful-response p99.

@@MULTI@@

These are end-to-end rates over this LAN and load host, rather than isolated
HTTP/2 engine limits. At high concurrency, packet delivery, client scheduling,
and queueing can limit throughput or produce timeouts even when the server
process has spare CPU. Process CPU does not include all host interrupt and
packet-processing work. The recorded network counters cover the whole host
and cannot attribute loss to one server on their own.

The remote NIC's `rx_missed_errors` counter decreased in some captured
intervals. Its raw values are retained; a simple difference is not treated as
a reliable packet-loss count.

## Failures and actual connections

[ZHTPS failure diagnosis](http2-diagnosis.md): 18 separate follow-up trials localize
substantial receive loss to the NIC path, predominantly on the remote client.
The report includes paired TCP snapshots, rapidly sampled wrapping NIC counters,
CPU-placement controls and zero-failure loopback controls using the same binaries.

ZHTPS permits at most **8,176 connections per worker**, so one worker cannot
hold either 8,192 or 16,384 connections. Two workers permit at most 16,352,
just below 16,384; distribution between worker accept queues can lower the
achievable population further. The benchmark uses the existing implementation
and records the resulting limits.

Requested populations of 64, 1,024, 8,192, and 16,384 correspond to maxima of
256, 4,096, 32,768, and 65,536 concurrent requests when all connections are
available. Four stream slots per established connection repeatedly issue
requests in a closed loop. Failed connections are not replaced and failed
requests are not transparently retried. Actual outstanding work can be lower
because of failures, flow control, and client scheduling.

The population columns are **minimum–maximum across three trials**. Ready is
sampled immediately before measurement; successful means the connection
returned at least one verified response during measurement; alive is sampled
at the end. Full population requires every requested connection to be ready
and participate. It does not promise that all connections survive the trial.

@@POPULATIONS@@

Setup includes TCP connection establishment, TLS negotiation, and one
validated HTTP/2 GET. Holding GETs keep already-opened connections alive while
other clients finish setup. Warmup and measurement use all four stream slots.
Every failure category and original error string is preserved; these totals
are not sampled. Unattempted connections, if any, are reported separately and
are not counted as failed requests. Measured failure percentage uses all
attempts made during measurement, including attempts that finish after the
eight-second issuing window.

@@FAILURES@@

The following totals cover each server's entire matrix. Node and Bun have
fewer trials because they run only with one CPU; these totals are accounting
records, not normalized reliability rankings.

@@TOTALS@@

Successful-response latency excludes failed operations. A low p99 alongside
many failed requests must therefore be read with the failure table. Failure
latency histograms and separate failure p99 values are retained in the raw
results. Each per-client gzip JSONL file identifies the phase, local connection
index, stream slot, start timestamp, elapsed time, failure category, and full
error string. The containing trial directory and client filename identify the
server, CPU budget, connection target, repeat, and client shard.

## Method and environment

- Server: AMD Ryzen AI Max+ 395, 16 physical cores / 32 logical CPUs, Linux
  `7.2.4-arch1-2-strixhalo`. Server affinity is CPUs `0` through `workers−1`.
- Client: AMD Ryzen 7 8745HS, 8 physical cores / 16 logical CPUs, Linux
  `7.1.9-arch1-2`. Eight client processes each use one physical core plus its
  SMT sibling: `[0,8]` through `[7,15]`, with `GOMAXPROCS=2` per process.
- Wired path: server `server_eth0` to client `client_eth0`, both negotiated at
  2,500 Mb/s full duplex. Different kernel boot IDs are checked every trial.
  Affinity constrains benchmark threads; it does not reserve CPUs from other
  host activity.
- Every trial starts a fresh server on a fresh destination port. Runtime
  order rotates across repeats. Three trials per server, CPU budget, and
  connection target; two seconds of concurrent warmup and eight seconds of
  issuing measured requests.
- Connection setup allows 32 concurrent opens per client process, 256 in
  total, and a 180-second setup deadline. Each connection and each request
  has a two-second deadline. The setup budget is longer to let capped servers
  finish attempting the requested population.
- All client processes keep prepared connections alive until a shared
  warmup barrier. A second barrier schedules measurement on the remote host.
  Per-client start times and clock-offset uncertainty are retained. No
  benchmark request traffic travels through SSH; SSH carries control and
  retrieves the evidence.
- The load client uses explicit `golang.org/x/net/http2.ClientConn` objects
  (`x/net v0.47.0`, `x/text v0.31.0`), with no automatic HTTP request retry or
  connection replacement. Each GET verifies TLS 1.3, ALPN `h2`, HTTP/2, status 200, the exact
  six-byte `ZHTPS\n` body, content length, content type, ETag, and a valid Date.
  The temporary P-256 certificate is trusted explicitly; verification is on.
- ZHTPS uses **ReleaseSafe**, targeting `x86_64_v4`, with the same server
  executable and source as the earlier loopback run. Limits are 8,176
  connections and active admitted requests per worker, 65,535 HTTP/2 streams per
  worker, and 4,294,967,295 bytes of HTTP/2 memory budget per worker. The request
  cap is 4,294,967,295, the admin connection allocation is zero, and access
  logging is off. These are benchmark settings, not production defaults.
- Go's baseline is `net/http` with normal GC. Versions are Zig 0.16.0,
  Go 1.27.1-X:nodwarf5, Node 26.8.2, and Bun 1.4.0. Sharing the `node:http2`
  fixture does not establish that Node and Bun use identical internal
  implementations. Their recorded runtime versions are retained.
- File descriptor soft limits are raised only within existing hard limits:
  131,072 for the controller/server and 65,536 for each remote client process.
  No host-wide network or kernel settings are changed.

The controller checks server readiness with a local TCP connect and close,
before launching the remote clients. It sends no HTTP request. Go logs that
probe as a TLS handshake EOF; the retained server log includes it, but it is
not a failed request from the benchmark load.

Requests are issued until the eight-second deadline, then in-flight requests
are drained and their successes or failures counted. Throughput divides
verified successes by the elapsed time from the earliest client start to the
latest client finish, including that drain. Slow or timed-out final requests
therefore lengthen the denominator. This is a closed-loop capacity test, not
a fixed offered-rate test; latency excludes time before a stream slot begins
its request. CPU cost is measured server process CPU divided by verified
measured successes. Host network counters bracket the same measurement.

The p99 tables use merged, upward-rounded microsecond histograms: 1 µs buckets
through 1 ms, 10 µs through 10 ms, and successively wider decimal buckets.
The reported percentiles are bucket upper boundaries. Ranges below describe
the observed repeats; they are not confidence intervals.

The TCP column is the median increase in the server host's `Tcp.RetransSegs`
counter per elapsed measurement second. It covers all host traffic, not just
the benchmark sockets, and is an observation rather than proof of the cause of
latency or failures. TCP retransmissions are distinct from HTTP request retries.

@@RANGES@@

## Evidence, validation, and reproduction

The run started at `@@STARTED@@` and finished at `@@FINISHED@@`.

- [Summary JSON](http2-lan/summary.json) and [CSV](http2-lan/summary.csv)
  contain all 40 server/workload groups, ranges, populations, and phase counts.
- [Complete trial results](http2-lan/results.json.gz) retain client histograms,
  all counters, commands, host identities, CPU placement, versions, hashes,
  server process snapshots, and network counters.
- [Per-trial evidence archive](http2-lan/evidence.tar.gz) contains every
  client failure JSONL, client stderr, server log, controller event log, and
  per-trial result. Failed trials are not discarded. Paths have the form
  `w1-c16384-node-r1/client/client-0.failures.jsonl.gz`.
- [Audit receipt](http2-lan/audit.json), [build receipt](http2-lan/build.json),
  [measured source archive](http2-lan/source.tar.gz), and
  [validation records](http2-lan/validation.json) retain provenance and checks.
  The [artifact manifest](http2-lan/manifest.json) lists file sizes and SHA-256 hashes.
- [Preparation checks](http2-lan/preparation.tar.gz) retain the short remote
  checks used to validate the harness. Their results are excluded from the
  primary tables. Earlier checks exposed a missing shared setup barrier;
  a permanent [regression check](../bench/check_http2_lan_idle.py) reproduces
  the failure on the previous client and passes on the measured client.
- [Client placement calibration](http2-lan/calibration.md) checks the
  eight-worker, 64-connection case with alternative client process layouts
  that leave the remote NIC's physical core available for packet processing.
  Those supplemental trials are separate from the primary matrix.

The independent [audit](../bench/audit_http2_lan.py) verifies the exact trial
matrix, separate hosts, CPU placement, every phase's attempted/succeeded/failed
accounting, every individual failure category and log hash, histogram sample
counts, aggregate throughput, percentiles, and reported populations. Local
checks also verify all four server fixtures, deliberate wrong response bodies,
and a two-connection server capacity limit.

To audit the retained evidence without rerunning the load:

```sh
mkdir -p /tmp/http2-lan-audit
tar -xzf docs/http2-lan/evidence.tar.gz -C /tmp/http2-lan-audit
gzip -dc docs/http2-lan/results.json.gz > /tmp/http2-lan-audit/results.json
python3 bench/audit_http2_lan.py /tmp/http2-lan-audit
```

To rebuild and run a new comparison:

```sh
zig build -Doptimize=ReleaseSafe --prefix zig-out/http2-benchmark \
  --cache-dir /tmp/zhtps-http2-zig-cache \
  --global-cache-dir /tmp/zhtps-http2-zig-global-cache
GOCACHE=/tmp/zhtps-http2-go-cache go build \
  -o zig-out/http2-benchmark/go-server bench/go_server/main.go
(cd bench/http2_lan_client && CGO_ENABLED=0 GOCACHE=/tmp/zhtps-http2-go-cache \
  go build -o ../../zig-out/http2-benchmark/lan-client .)
python3 bench/compare_http2_lan.py \
  --client-host client.example --ssh-key /path/to/benchmark-key \
  --connections 64,1024,8192,16384 --streams 4 \
  --output /tmp/http2-lan-rerun
python3 bench/audit_http2_lan.py /tmp/http2-lan-rerun
python3 bench/summarize_http2_lan.py /tmp/http2-lan-rerun \
  --output /tmp/http2-lan-summary
python3 bench/check_http2_lan_idle.py
python3 bench/render_reports.py
```

The runner transfers only the compiled client, Python supervisor, and public
test certificate to a newly created temporary directory on the authorized
remote host. The TLS private key stays on the server host. All remote evidence
is copied back before that temporary directory is removed after a complete run.
