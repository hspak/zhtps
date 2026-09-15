# ZHTPS versus Go over the physical LAN: September 12

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The [32-worker follow-up](go-comparison-lan-workers32.md) repeats the 8k and 16k
cases with the same binaries, preserving total public connection capacity.

The load generator ran on **`client.example` (`benchmark-client`, 192.0.2.20)** and sent
HTTP directly to **`benchmark-server` (192.0.2.10)** over wired Ethernet. Both links negotiated
**2.5 Gb/s full duplex**, MTU 1500. Distinct boot IDs were verified in every trial.

With one server CPU and 128 connections, ReleaseSafe delivered
**350,765 validated responses/s**, versus
**153,450 for Go**
(**2.29×**).
The multicore results below include substantial TCP retransmission and client
timeouts; throughput alone does not describe their quality of service.

## Testbed and method

The server is an AMD Ryzen AI Max+ 395 with 16 physical / 32 logical CPUs,
running `7.2.4-arch1-2-strixhalo`. The client is an AMD Ryzen 7 8745HS with
8 physical / 16 logical CPUs, running Linux 7.1.9-arch1-2. It used CPUs 0–7,
verified as eight distinct physical cores, with `GOMAXPROCS=8`.
Traffic used `server_eth0` on the server and `client_eth0` on the client. SSH carried
control and reports; HTTP went directly over the LAN.

All four binaries were built from the current working tree, including its
uncommitted changes: Zig `0.16.0` and `go version go1.27.1-X:nodwarf5 linux/amd64`. The remote
client's SHA-256 matched the freshly built local client in every trial.
The server source has changed since the preceding loopback report, so comparing
those historical numbers does **not** isolate the effect of moving the client.

Each reported row is the median of three five-second windows after two seconds
of shared warmup. Every trial starts a fresh server; server order rotates across
repeats. Up to 64 connections open concurrently during preparation. A successful
response must be HTTP 200 with `Content-Length: 6` and exactly `ZHTPS\n`.
There is one outstanding HTTP/1.1 `GET /` per connection, with keep-alive and no
pipelining, TLS, request body, or application/database work. Response Content-Type
and ETag match. Admission, counters and server latency histograms remain enabled;
the Go baseline does not implement feature parity.

Tables use validated completions **inside** the fixed measurement window divided
by five seconds. Latencies are medians of successful-request quantiles from each
trial, including drain; they are not pooled. Histogram rounding is upward by less
than 0.8%. The client is closed loop: response delay reduces offered load. These
are not fixed-arrival-rate latency guarantees, and timeout failures are excluded
from successful-request latency quantiles.

## One server CPU

Both servers were pinned to CPU 0; Go used `GOMAXPROCS=1`. ZHTPS used one worker,
256 public connection slots and active-request permits. Default access logging
was enabled, with output to `/dev/null`. Latencies below are **microseconds**.

| Connections | Server | Responses/s | Trial range | p50 | p95 | p99 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | ZHTPS Debug | 12,321 | 12,111–12,495 | 78.847 | 84.991 | 105.471 |
| 1 | ZHTPS ReleaseSafe | 13,035 | 12,686–13,064 | 75.775 | 81.407 | 94.207 |
| 1 | Go net/http | 12,380 | 12,283–12,489 | 78.847 | 86.527 | 111.615 |
| 16 | ZHTPS Debug | 122,019 | 120,617–122,596 | 132.095 | 160.767 | 186.367 |
| 16 | ZHTPS ReleaseSafe | 141,223 | 141,080–141,563 | 114.687 | 140.287 | 152.575 |
| 16 | Go net/http | 131,559 | 131,436–131,912 | 115.711 | 163.839 | 239.615 |
| 128 | ZHTPS Debug | 159,718 | 156,872–160,395 | 786.431 | 917.503 | 1130.495 |
| 128 | ZHTPS ReleaseSafe | 350,765 | 349,765–351,548 | 360.447 | 446.463 | 520.191 |
| 128 | Go net/http | 153,450 | 147,965–153,986 | 835.583 | 1466.367 | 1703.935 |

All 27 trials passed strict validation: **16,406,665**
validated window completions, zero setup/warmup/measured errors, zero connection
turnover, and participation by every requested connection. ZHTPS recorded no
request rejections, aborted requests, protocol errors, request timeouts, I/O
errors, or log write errors. Its bounded logger dropped
**7,840,538**
records across setup, warmup and measurement. This does not measure lossless
access logging. Server-wide TCP counters recorded no retransmitted segments
during these trial intervals.

## Sixteen workers

ZHTPS used 16 workers with 2,048 public connection slots and active-request permits
per worker: 32,768 public slots total, plus eight admin slots on worker zero.
Each ring used 256 SQ and 16,384 CQ entries. Both servers could use all 32 logical
CPUs, with scheduler placement; Go had no `GOMAXPROCS` override and reported 32.
ZHTPS access logging was disabled, matching the previous multicore policy.
Latencies below are **milliseconds**.

| Connections | Server | Responses/s | Trial range | p50 | p95 | p99 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 4,096 | ZHTPS Debug | 349,136 | 348,487–354,387 | 1.376 | 3.604 | 210.764 |
| 4,096 | ZHTPS ReleaseSafe | 348,104 | 344,894–387,834 | 1.401 | 3.375 | 210.764 |
| 4,096 | Go net/http | 382,826 | 382,642–384,357 | 3.654 | 8.782 | 214.958 |
| 8,192 | ZHTPS Debug | 361,389 | 343,098–370,602 | 2.769 | 211.812 | 248.513 |
| 8,192 | ZHTPS ReleaseSafe | 335,895 | 335,800–371,338 | 1.655 | 209.715 | 241.172 |
| 8,192 | Go net/http | 360,045 | 359,442–361,621 | 3.949 | 212.861 | 222.298 |
| 16,384 | ZHTPS Debug | 302,272 | 299,872–335,330 | 2.408 | 272.630 | 570.425 |
| 16,384 | ZHTPS ReleaseSafe | 335,254 | 333,922–335,891 | 5.931 | 220.201 | 429.916 |
| 16,384 | Go net/http | 319,973 | 317,921–320,009 | 5.112 | 224.395 | 463.471 |

ReleaseSafe / Go throughput ratios were **0.91×** at 4,096 connections, **0.93×** at 8,192 connections, **1.05×** at 16,384 connections.

The first strict multicore attempt aborted when its load client exited 1.
That invocation's detailed client result was not retained, so its cause and error
count are unknown. An identical diagnostic repeat passed. Both the
initial failure note and the
[successful diagnostic repeat](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/worker-strict-diagnostic.json; raw artifact retired")
are retained. Neither is included in the repeated-run medians.

The complete multicore series then used the existing `--allow-errors` mode so
errors and retries would be retained. Successful responses still undergo status,
length and exact-body validation. This mode permits reconnects and is not a
strict no-turnover workload. Error counts below sum all three repeats; they
classify requests by when they started (setup, warmup, or measurement).

| Connections | Server | Setup errors | Warmup errors | Measured errors | Extra connection opens |
| ---: | --- | ---: | ---: | ---: | ---: |
| 4,096 | ZHTPS Debug | 0 | 2 | 9 | 11 |
| 4,096 | ZHTPS ReleaseSafe | 0 | 0 | 1 | 1 |
| 4,096 | Go net/http | 0 | 1 | 0 | 1 |
| 8,192 | ZHTPS Debug | 0 | 39 | 46 | 59 |
| 8,192 | ZHTPS ReleaseSafe | 0 | 62 | 37 | 95 |
| 8,192 | Go net/http | 0 | 61 | 16 | 72 |
| 16,384 | ZHTPS Debug | 0 | 701 | 663 | 1,211 |
| 16,384 | ZHTPS ReleaseSafe | 0 | 708 | 580 | 1,175 |
| 16,384 | Go net/http | 0 | 731 | 448 | 1,080 |

The 27 completed multicore trials contain **46,911,702** validated completions inside measurement windows. Every requested connection completed measured requests. Every ZHTPS worker completed requests and accumulated CPU time in every trial.

## CPU and network observations

CPU percentages include warmup; server CPU also includes client preparation,
drain and collector polling. 100% is one CPU. They are process CPU observations,
not whole-host network cost or CPU time normalized per successful response.
The network columns use server-wide counters sampled around the complete client
run, including preparation, warmup and drain. They can include unrelated traffic.
Rates are medians of per-trial rates.

| Connections | Server | Server CPU | Client CPU | Server TX Mb/s | TCP retransmitted / outgoing segments |
| ---: | --- | ---: | ---: | ---: | ---: |
| 4,096 | ZHTPS Debug | 269.8% | 284.1% | 551 | 3.29% |
| 4,096 | ZHTPS ReleaseSafe | 155.2% | 280.2% | 562 | 3.36% |
| 4,096 | Go net/http | 826.9% | 326.8% | 584 | 3.29% |
| 8,192 | ZHTPS Debug | 251.7% | 299.3% | 556 | 8.10% |
| 8,192 | ZHTPS ReleaseSafe | 145.5% | 255.7% | 517 | 5.62% |
| 8,192 | Go net/http | 734.5% | 303.8% | 545 | 8.26% |
| 16,384 | ZHTPS Debug | 211.8% | 259.5% | 480 | 16.90% |
| 16,384 | ZHTPS ReleaseSafe | 114.0% | 296.4% | 545 | 17.68% |
| 16,384 | Go net/http | 606.7% | 270.1% | 502 | 17.76% |

The high-concurrency trials show material TCP retransmission and long successful
response tails on both servers. The recorded TX byte rate is below the negotiated
2.5 Gb/s rate; these results do not establish that raw link bandwidth is the
ceiling. They also do not isolate whether loss occurs at a host, NIC or switch.
The server's `rx_missed_errors` counter decreased in some intervals, so simple
deltas of that counter cannot serve as reliable packet-loss counts. Raw values
are retained. Client CPU use alone cannot prove the generator has sufficient
headroom. These numbers characterize the complete measured LAN path.

## Reproduce and verify

Build with `python3 -c 'import sys; sys.path.insert(0,"bench"); import compare; compare.build()'`
and copy `zig-out/bench/load` to the client as `/tmp/zhtps-go-comparison-load-20260912`.
The recorded runs used a dedicated SSH configuration with the existing
`/path/to/benchmark-key` identity and `/path/to/known_hosts` trusted host file.
Use an appropriate trusted configuration for your host.

```sh
python3 bench/compare.py --server-address 192.0.2.10 \
  --client-host client.example \
  --remote-client-binary /tmp/zhtps-go-comparison-load-20260912 \
  --ssh-config /path/to/benchmark-ssh.conf --client-cores 8 \
  --connections 1 16 128 --go-cpu-mode single \
  --duration 5 --warmup 2 --repeats 3 \
  --output docs/go-comparison-lan-single.json

python3 bench/compare.py --server-address 192.0.2.10 \
  --client-host client.example \
  --remote-client-binary /tmp/zhtps-go-comparison-load-20260912 \
  --ssh-config /path/to/benchmark-ssh.conf --client-cores 8 \
  --connections 4096 8192 16384 --zig-workers 16 \
  --zig-max-connections 2048 --zig-max-active 2048 --no-zig-access-log \
  --go-cpu-mode unrestricted --allow-errors \
  --duration 5 --warmup 2 --repeats 3 \
  --output docs/go-comparison-lan-workers.json

python3 bench/audit_go_lan.py docs/go-comparison-lan-single.json \
  docs/go-comparison-lan-workers.json --output docs/go-comparison-lan/audit.json
```

Before measurement, the Go load-client tests, seven remote-collector tests, and
`zig build test test-wire --release=safe` passed (including all 87 component tests
and the raw TCP, kernel, aggregation and placement suites). The post-run audit
checks source/binary hashes, remote identity and affinity, complete trial coverage,
summary recomputation, outcome accounting, connection participation and worker
activity. An audit pass verifies accounting; it does not mean a run had no errors.

[Raw single-CPU report](runs/standalone.json "Summary of docs/go-comparison-lan-single.json; raw artifact retired"),
[raw multicore report](runs/standalone.json "Summary of docs/go-comparison-lan-workers.json; raw artifact retired"),
[audit and network deltas](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/audit.json; raw artifact retired"),
[server metadata](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/server-start.json; raw artifact retired"),
[client metadata](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/client-start.json; raw artifact retired"),
[server final counters](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/server-end.json; raw artifact retired"),
[client final counters](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/client-end.json; raw artifact retired").
