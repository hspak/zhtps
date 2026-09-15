# HTTP/2 comparison with a remote load host

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Measured on September 14, 2026, with the load generated on
`client.example` (reported hostname `benchmark-client`, `192.0.2.20`) and all servers
on `benchmark-server` (`192.0.2.10`). This is a two-host wired LAN benchmark. The
[earlier loopback comparison](http2-comparison.md) remains separate.

The client hardware and client HTTP/2 implementation also differ from the
loopback experiment, which used the Go standard-library transport. Differences
between those reports cannot be attributed solely to the network path.

The matrix contains 120 trials and 170,005,710 verified measured responses.
All 839,068 failed operations are retained as individual records,
including setup, connection holding, warmup, and measurement. A trial with
request failures stays in the results. Rates and latency below are medians
of three trials; failure counts are totals across those three trials.

At one CPU and 64 connections, ZHTPS has the highest median verified throughput: 185,864 responses/s.

At one CPU and 1,024 connections, ZHTPS has the highest median verified throughput: 160,279 responses/s.

Among the 11 multi-worker workload pairs where both servers reached the full population in every trial, ZHTPS has higher median throughput in 11.

Its median successful-response p99 is higher than Go at 2 CPUs / 1,024 connections, 4 CPUs / 1,024 connections, 8 CPUs / 1,024 connections.

Throughput, latency, connection capacity, and failures must be considered together; partial-population trials are excluded from that count of full-population comparisons.

**Client placement sensitivity:** At eight server CPUs and 64 connections, the primary client layout gives ZHTPS 285,662 and Go 242,359 verified responses/s. Leaving the client NIC’s physical core free gives ZHTPS 339,973 and Go 370,399 with seven client processes, reversing the throughput ranking. Repeating the original layout gives 288,148 and 252,242, respectively. These are medians of three trials, all with zero failures; the primary matrix measures this client/LAN configuration rather than isolated server ceilings.

## One constrained worker

Each server process and all its threads are restricted to one physical CPU.
Node and Bun run only in this comparison, using the same `node:http2` fixture.
Cells show **verified responses/s**, then **successful-response p99**.
Every connection uses **four concurrent stream slots**.

| Requested connections | ZHTPS | Go | Node | Bun |
|---:|---:|---:|---:|---:|
| 64 | 185,864<br>1.830 ms | 76,832<br>6.050 ms | 95,402<br>3.680 ms | 170,034<br>2.930 ms |
| 1,024 | 160,279<br>39.800 ms | 63,416<br>109.000 ms | 46,417<br>146.000 ms | 144,297<br>41.200 ms |
| 8,192 | 93,557 †<br>474.000 ms | 54,049<br>800.000 ms | 36,584<br>1,410.000 ms | 115,787<br>288.000 ms |
| 16,384 | 85,835 †<br>509.000 ms | 51,527<br>1,600.000 ms | 24,593<br>1,980.000 ms | 116,295 †<br>681.000 ms |

**† Partial connection population in at least one trial.** The rate is the
observed result at the requested target; it must not be presented as a
comparison in which both servers maintained that many connections.
The actual populations and failures appear below.

## Multiple workers

ZHTPS uses the stated number of workers. Go uses the same CPU affinity and
`GOMAXPROCS` equal to that CPU count. Node and Bun are excluded.
Cells again show verified responses/s and successful-response p99.

| Server CPUs / workers | Requested connections | ZHTPS | Go |
|---:|---:|---:|---:|
| 2 | 64 | 321,494<br>1.560 ms | 151,530<br>4.170 ms |
| 2 | 1,024 | 281,000<br>223.000 ms | 121,875<br>52.700 ms |
| 2 | 8,192 | 182,144<br>254.000 ms | 105,403<br>388.000 ms |
| 2 | 16,384 | 173,814 †<br>511.000 ms | 103,834<br>715.000 ms |
| 4 | 64 | 283,364<br>1.970 ms | 253,760<br>2.470 ms |
| 4 | 1,024 | 257,760<br>234.000 ms | 229,033<br>218.000 ms |
| 4 | 8,192 | 227,637<br>846.000 ms | 167,221<br>1,490.000 ms |
| 4 | 16,384 | 186,694<br>1,290.000 ms | 158,355<br>1,640.000 ms |
| 8 | 64 | 285,662<br>1.990 ms | 242,359<br>2.230 ms |
| 8 | 1,024 | 268,859<br>223.000 ms | 255,890<br>218.000 ms |
| 8 | 8,192 | 220,885<br>860.000 ms | 195,501<br>1,480.000 ms |
| 8 | 16,384 | 206,262<br>1,310.000 ms | 181,329<br>1,560.000 ms |

These are end-to-end rates over this LAN and load host, rather than isolated
HTTP/2 engine limits. At high concurrency, packet delivery, client scheduling,
and queueing can limit throughput or produce timeouts even when the server
process has spare CPU. Process CPU does not include all host interrupt and
packet-processing work. The recorded network counters cover the whole host
and cannot attribute loss to one server on their own.

The remote NIC's `rx_missed_errors` counter decreased in some captured
intervals. Its raw values were recorded; a simple difference is not treated as
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

| CPUs | Requested | Server | Ready at measurement start | Successful connections | Alive at end | Full-population trials |
|---:|---:|---|---:|---:|---:|---:|
| 1 | 64 | ZHTPS | 64 | 64 | 64 | 3/3 |
| 1 | 64 | Go | 64 | 64 | 64 | 3/3 |
| 1 | 64 | Node | 64 | 64 | 64 | 3/3 |
| 1 | 64 | Bun | 64 | 64 | 64 | 3/3 |
| 1 | 1,024 | ZHTPS | 1,024 | 1,024 | 1,024 | 3/3 |
| 1 | 1,024 | Go | 1,024 | 1,024 | 1,024 | 3/3 |
| 1 | 1,024 | Node | 1,024 | 1,024 | 1,024 | 3/3 |
| 1 | 1,024 | Bun | 1,024 | 1,024 | 1,024 | 3/3 |
| 1 | 8,192 | ZHTPS | 8,136–8,176 | 8,136–8,176 | 8,136–8,176 | 0/3 |
| 1 | 8,192 | Go | 8,192 | 8,192 | 8,192 | 3/3 |
| 1 | 8,192 | Node | 8,192 | 8,192 | 8,192 | 3/3 |
| 1 | 8,192 | Bun | 8,192 | 8,192 | 8,192 | 3/3 |
| 1 | 16,384 | ZHTPS | 8,176 | 8,176 | 8,176 | 0/3 |
| 1 | 16,384 | Go | 16,384 | 16,384 | 16,384 | 3/3 |
| 1 | 16,384 | Node | 16,384 | 16,384 | 16,384 | 3/3 |
| 1 | 16,384 | Bun | 16,364–16,384 | 16,364–16,384 | 16,364–16,384 | 2/3 |
| 2 | 64 | ZHTPS | 64 | 64 | 64 | 3/3 |
| 2 | 64 | Go | 64 | 64 | 64 | 3/3 |
| 2 | 1,024 | ZHTPS | 1,024 | 1,024 | 1,024 | 3/3 |
| 2 | 1,024 | Go | 1,024 | 1,024 | 1,024 | 3/3 |
| 2 | 8,192 | ZHTPS | 8,192 | 8,192 | 8,192 | 3/3 |
| 2 | 8,192 | Go | 8,192 | 8,192 | 8,192 | 3/3 |
| 2 | 16,384 | ZHTPS | 16,276–16,300 | 16,276–16,300 | 16,276–16,300 | 0/3 |
| 2 | 16,384 | Go | 16,384 | 16,384 | 16,384 | 3/3 |
| 4 | 64 | ZHTPS | 64 | 64 | 64 | 3/3 |
| 4 | 64 | Go | 64 | 64 | 64 | 3/3 |
| 4 | 1,024 | ZHTPS | 1,024 | 1,024 | 1,024 | 3/3 |
| 4 | 1,024 | Go | 1,024 | 1,024 | 1,024 | 3/3 |
| 4 | 8,192 | ZHTPS | 8,192 | 8,190–8,192 | 8,192 | 3/3 |
| 4 | 8,192 | Go | 8,192 | 8,183–8,188 | 8,192 | 3/3 |
| 4 | 16,384 | ZHTPS | 16,384 | 16,363–16,381 | 16,384 | 3/3 |
| 4 | 16,384 | Go | 16,384 | 16,266–16,335 | 16,384 | 3/3 |
| 8 | 64 | ZHTPS | 64 | 64 | 64 | 3/3 |
| 8 | 64 | Go | 64 | 64 | 64 | 3/3 |
| 8 | 1,024 | ZHTPS | 1,024 | 1,024 | 1,024 | 3/3 |
| 8 | 1,024 | Go | 1,024 | 1,024 | 1,024 | 3/3 |
| 8 | 8,192 | ZHTPS | 8,192 | 8,190–8,192 | 8,192 | 3/3 |
| 8 | 8,192 | Go | 8,192 | 8,100–8,162 | 8,192 | 3/3 |
| 8 | 16,384 | ZHTPS | 16,384 | 16,348–16,371 | 16,384 | 3/3 |
| 8 | 16,384 | Go | 16,384 | 16,121–16,229 | 16,384 | 3/3 |

Setup includes TCP connection establishment, TLS negotiation, and one
validated HTTP/2 GET. Holding GETs keep already-opened connections alive while
other clients finish setup. Warmup and measurement use all four stream slots.
Every failure category and original error string is preserved; these totals
are not sampled. Unattempted connections, if any, are reported separately and
are not counted as failed requests. Measured failure percentage uses all
attempts made during measurement, including attempts that finish after the
eight-second issuing window.

| CPUs | Requested | Server | Setup failures | Holding failures | Warmup failures | Measured failures | Measured failure rate | Unattempted connections |
|---:|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | 64 | ZHTPS | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 64 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 64 | Node | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 64 | Bun | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 1,024 | ZHTPS | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 1,024 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 1,024 | Node | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 1,024 | Bun | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 8,192 | ZHTPS | 90 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 8,192 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 8,192 | Node | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 8,192 | Bun | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 16,384 | ZHTPS | 24,624 | 0 | 0 | 0 | 0.0000% | 0 |
| 1 | 16,384 | Go | 0 | 0 | 0 | 19 | 0.0013% | 0 |
| 1 | 16,384 | Node | 0 | 0 | 22,017 | 374,590 | 35.4683% | 0 |
| 1 | 16,384 | Bun | 20 | 0 | 0 | 0 | 0.0000% | 0 |
| 2 | 64 | ZHTPS | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 2 | 64 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 2 | 1,024 | ZHTPS | 0 | 0 | 8 | 16 | 0.0002% | 0 |
| 2 | 1,024 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 2 | 8,192 | ZHTPS | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 2 | 8,192 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 2 | 16,384 | ZHTPS | 293 | 0 | 2 | 0 | 0.0000% | 0 |
| 2 | 16,384 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 4 | 64 | ZHTPS | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 4 | 64 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 4 | 1,024 | ZHTPS | 0 | 0 | 28 | 28 | 0.0004% | 0 |
| 4 | 1,024 | Go | 0 | 0 | 32 | 84 | 0.0014% | 0 |
| 4 | 8,192 | ZHTPS | 0 | 0 | 176 | 646 | 0.0107% | 0 |
| 4 | 8,192 | Go | 0 | 0 | 1,817 | 23,018 | 0.4592% | 0 |
| 4 | 16,384 | ZHTPS | 0 | 0 | 931 | 11,070 | 0.2019% | 0 |
| 4 | 16,384 | Go | 0 | 0 | 7,711 | 108,329 | 2.2360% | 0 |
| 8 | 64 | ZHTPS | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 8 | 64 | Go | 0 | 0 | 0 | 0 | 0.0000% | 0 |
| 8 | 1,024 | ZHTPS | 0 | 0 | 116 | 20 | 0.0003% | 0 |
| 8 | 1,024 | Go | 0 | 0 | 96 | 1,342 | 0.0198% | 0 |
| 8 | 8,192 | ZHTPS | 0 | 0 | 239 | 1,785 | 0.0283% | 0 |
| 8 | 8,192 | Go | 0 | 0 | 5,858 | 47,777 | 0.8191% | 0 |
| 8 | 16,384 | ZHTPS | 0 | 0 | 1,873 | 20,337 | 0.3327% | 0 |
| 8 | 16,384 | Go | 0 | 0 | 19,653 | 164,423 | 2.9263% | 0 |

The following totals cover each server's entire matrix. Node and Bun have
fewer trials because they run only with one CPU; these totals are accounting
records, not normalized reliability rankings.

| Server | Trials | Verified measured responses | Setup failures | Holding failures | Warmup failures | Measured failures |
|---|---:|---:|---:|---:|---:|---:|
| ZHTPS | 48 | 87,722,138 | 25,007 | 0 | 3,373 | 33,902 |
| Go | 48 | 63,765,595 | 0 | 0 | 35,167 | 344,992 |
| Node | 12 | 5,057,062 | 0 | 0 | 22,017 | 374,590 |
| Bun | 12 | 13,460,915 | 20 | 0 | 0 | 0 |

Successful-response latency excludes failed operations. A low p99 alongside
many failed requests must therefore be read with the failure table. Failure
latency histograms and separate failure p99 values were recorded in the original raw
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

| CPUs | Requested | Server | Requests/s range | p99 range (ms) | Server CPU µs/success | Client CPU cores | Host TCP retransmits/s |
|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | 64 | ZHTPS | 183,856–186,978 | 1.770–1.860 | 5.279 | 3.73 | 0 |
| 1 | 64 | Go | 76,230–77,476 | 6.030–6.230 | 12.783 | 2.62 | 0 |
| 1 | 64 | Node | 94,304–97,128 | 3.620–4.030 | 10.362 | 2.54 | 0 |
| 1 | 64 | Bun | 169,219–171,551 | 2.910–2.940 | 5.762 | 3.66 | 0 |
| 1 | 1,024 | ZHTPS | 158,793–162,296 | 39.500–40.600 | 6.131 | 4.53 | 1 |
| 1 | 1,024 | Go | 63,067–63,738 | 109.000–111.000 | 15.537 | 2.55 | 19 |
| 1 | 1,024 | Node | 41,743–46,787 | 145.000–149.000 | 21.374 | 1.86 | 13 |
| 1 | 1,024 | Bun | 143,913–145,896 | 36.500–50.900 | 6.803 | 4.01 | 11 |
| 1 | 8,192 | ZHTPS | 91,148–93,937 | 474.000–476.000 | 10.551 | 3.09 | 184 |
| 1 | 8,192 | Go | 53,599–54,251 | 797.000–805.000 | 18.274 | 2.35 | 359 |
| 1 | 8,192 | Node | 36,414–38,091 | 1,400.000–1,430.000 | 27.140 | 1.45 | 106 |
| 1 | 8,192 | Bun | 115,667–117,810 | 285.000–293.000 | 8.525 | 3.60 | 449 |
| 1 | 16,384 | ZHTPS | 85,607–86,631 | 505.000–516.000 | 11.521 | 2.90 | 142 |
| 1 | 16,384 | Go | 51,508–51,993 | 1,590.000–1,640.000 | 19.169 | 2.31 | 580 |
| 1 | 16,384 | Node | 20,358–25,498 | 1,970.000–2,000.000 | 40.292 | 1.61 | 312 |
| 1 | 16,384 | Bun | 114,797–118,475 | 680.000–710.000 | 8.481 | 3.63 | 1,129 |
| 2 | 64 | ZHTPS | 312,566–321,770 | 1.550–1.560 | 6.081 | 7.09 | 39 |
| 2 | 64 | Go | 151,457–153,372 | 4.050–4.480 | 12.346 | 4.10 | 1 |
| 2 | 1,024 | ZHTPS | 265,235–291,333 | 219.000–223.000 | 6.150 | 6.94 | 22,582 |
| 2 | 1,024 | Go | 120,886–126,559 | 49.400–60.500 | 15.964 | 3.98 | 71 |
| 2 | 8,192 | ZHTPS | 177,438–182,497 | 252.000–273.000 | 10.661 | 5.57 | 1,845 |
| 2 | 8,192 | Go | 105,186–106,002 | 378.000–404.000 | 18.466 | 3.84 | 1,236 |
| 2 | 16,384 | ZHTPS | 173,474–176,540 | 509.000–514.000 | 11.313 | 5.40 | 1,965 |
| 2 | 16,384 | Go | 102,586–104,014 | 713.000–720.000 | 18.870 | 3.83 | 1,923 |
| 4 | 64 | ZHTPS | 283,029–286,523 | 1.950–2.000 | 7.241 | 6.41 | 1,921 |
| 4 | 64 | Go | 245,078–253,807 | 2.450–2.530 | 13.454 | 6.43 | 1,452 |
| 4 | 1,024 | ZHTPS | 223,889–262,593 | 220.000–234.000 | 6.820 | 6.30 | 24,182 |
| 4 | 1,024 | Go | 223,464–230,964 | 218.000–218.000 | 14.367 | 6.29 | 15,268 |
| 4 | 8,192 | ZHTPS | 215,794–234,917 | 846.000–849.000 | 10.803 | 6.20 | 65,564 |
| 4 | 8,192 | Go | 166,371–168,904 | 1,490.000–1,500.000 | 17.858 | 5.18 | 35,341 |
| 4 | 16,384 | ZHTPS | 182,363–187,355 | 1,280.000–1,290.000 | 17.901 | 5.43 | 88,952 |
| 4 | 16,384 | Go | 156,263–159,072 | 1,630.000–1,650.000 | 19.268 | 5.05 | 45,112 |
| 8 | 64 | ZHTPS | 284,595–288,255 | 1.950–2.000 | 7.580 | 6.44 | 1,960 |
| 8 | 64 | Go | 241,816–246,892 | 2.210–2.250 | 16.764 | 6.11 | 3,281 |
| 8 | 1,024 | ZHTPS | 262,787–274,500 | 223.000–225.000 | 7.107 | 6.61 | 24,489 |
| 8 | 1,024 | Go | 247,254–256,687 | 218.000–218.000 | 15.673 | 6.48 | 21,268 |
| 8 | 8,192 | ZHTPS | 219,525–221,457 | 852.000–869.000 | 11.091 | 5.97 | 58,096 |
| 8 | 8,192 | Go | 192,225–196,423 | 1,480.000–1,480.000 | 19.284 | 5.68 | 42,053 |
| 8 | 16,384 | ZHTPS | 205,703–208,627 | 1,310.000–1,320.000 | 18.242 | 5.84 | 87,029 |
| 8 | 16,384 | Go | 180,873–182,708 | 1,550.000–1,560.000 | 20.855 | 5.62 | 54,975 |

## Evidence, validation, and reproduction

The run started at `2026-09-14T19:35:01.247208+00:00` and finished at `2026-09-14T20:08:18.599090+00:00`.

- [Summary JSON](runs/http2-lan.json "Summary of docs/http2-lan/summary.json; raw artifact retired") and [CSV](http2-lan/summary.csv)
  contain all 40 server/workload groups, ranges, populations, and phase counts.
- The original complete trial results recorded client histograms,
  all counters, commands, host identities, CPU placement, versions, hashes,
  server process snapshots, and network counters.
- The retired per-trial evidence archive contained every
  client failure JSONL, client stderr, server log, controller event log, and
  per-trial result. Failed trials are not discarded. Paths have the form
  `w1-c16384-node-r1/client/client-0.failures.jsonl.gz`.
- [Audit receipt](runs/http2-lan.json "Summary of docs/http2-lan/audit.json; raw artifact retired"), [build receipt](runs/http2-lan.json "Summary of docs/http2-lan/build.json; raw artifact retired"),
  measured source archive, and
  [validation records](runs/http2-lan.json "Summary of docs/http2-lan/validation.json; raw artifact retired") retain provenance and checks.
  The [artifact manifest](runs/http2-lan.json "Summary of docs/http2-lan/manifest.json; raw artifact retired") lists file sizes and SHA-256 hashes.
- The retired preparation archive contained the short remote
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

The original audit used these commands, which require the retired raw artifacts:

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
