# TLS comparison over the LAN at 8,192 and 16,384 connections

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

This repeats the configuration of [the earlier 32-worker LAN comparison](go-comparison-lan-workers32.md)
with TLS 1.3 and HTTP/1.1 enabled for ZHTPS/OpenSSL and Go `crypto/tls`.
The current worktree is measured; this is not a controlled TLS-on/off comparison
against the older source revision.

The server is `192.0.2.10`; the load generator is `client.example`
(`192.0.2.20`), reached through SSH. These are example addresses and hostnames;
use your own trusted SSH configuration.
The audit verifies distinct host boot IDs and the exact remote load executable hash.
ZHTPS uses 32 workers, each with 1,024 public connection slots and active-request
permits (32,768 public slots total). Go runs without affinity restrictions and
reports `GOMAXPROCS=32`. Both servers can use all 32 server logical CPUs.
The generator uses physical cores 0–7 with `GOMAXPROCS=8`.

Each of three repeats rotates server order and starts a fresh server. Connections
are prepared with at most 64 concurrent opens, followed by two seconds of warmup
and five seconds of measurement. Access logging is disabled for ZHTPS. Every
successful response must contain exactly the six-byte `ZHTPS\n` body with HTTP 200
and the expected content length. There is one outstanding request per connection,
no pipelining, and errors are retained while clients retry.

Both servers use the same disposable ECDSA P-256 certificate. Certificate
verification is disabled in the benchmark client and readiness probe. Initial
handshakes are outside the measurement window; reconnect handshakes after failures
can occur inside it. This is encrypted keepalive load, not a dedicated handshake
or bulk-encryption benchmark.

## Go leads throughput; ZHTPS uses less CPU

Throughput counts validated responses completed inside the fixed measurement
window. Latencies are medians of per-trial successful-request quantiles; failures
are excluded from these percentiles.

| Connections | Server | Responses/s | Trial range | p50 ms | p95 ms | p99 ms |
| ---: | --- | ---: | --- | ---: | ---: | ---: |
| 8,192 | ZHTPS Debug | 340,576 | 337,783–346,213 | 1.704 | 210.764 | 320.864 |
| 8,192 | ZHTPS ReleaseSafe | 338,158 | 336,214–365,388 | 1.606 | 210.764 | 283.116 |
| 8,192 | Go | 351,832 | 349,929–356,719 | 3.588 | 212.861 | 220.201 |
| 16,384 | ZHTPS Debug | 294,416 | 285,477–302,709 | 1.958 | 278.921 | 578.814 |
| 16,384 | ZHTPS ReleaseSafe | 295,979 | 295,914–297,395 | 1.851 | 285.213 | 578.814 |
| 16,384 | Go | 311,013 | 305,887–311,990 | 4.817 | 225.444 | 469.762 |

Go's median throughput exceeds ReleaseSafe by 4.0% at 8,192 connections and 5.1%
at 16,384. ReleaseSafe has lower successful-request p50 but higher p99.

## Failures and incomplete participation remain visible

Counts sum three repeats. Setup errors precede warmup; warmup and measured errors
are classified by request start time, including requests drained after the window.
The raw report separately retains failures completed inside the fixed window;
these are different populations and must not be added together.

| Connections | Server | Setup errors | Warmup errors | Measured errors | Extra opens |
| ---: | --- | ---: | ---: | ---: | ---: |
| 8,192 | ZHTPS Debug | 0 | 11 | 18 | 28 |
| 8,192 | ZHTPS ReleaseSafe | 0 | 26 | 18 | 42 |
| 8,192 | Go | 0 | 63 | 27 | 83 |
| 16,384 | ZHTPS Debug | 0 | 298 | 385 | 553 |
| 16,384 | ZHTPS ReleaseSafe | 0 | 172 | 494 | 491 |
| 16,384 | Go | 0 | 1,226 | 663 | 1,783 |

Measured error classifications:

| Connections | Server | Read timeout | Dial timeout | `invalid_response` bucket |
| ---: | --- | ---: | ---: | ---: |
| 8,192 | ZHTPS Debug | 18 | 0 | 0 |
| 8,192 | ZHTPS ReleaseSafe | 18 | 0 | 0 |
| 8,192 | Go | 26 | 1 | 0 |
| 16,384 | ZHTPS Debug | 342 | 20 | 23 |
| 16,384 | ZHTPS ReleaseSafe | 464 | 16 | 14 |
| 16,384 | Go | 632 | 29 | 2 |

The existing `invalid_response` classifier is a catch-all for errors not recognized
as HTTP status, network-operation errors, resets, refusals, or EOF. It can include
TLS errors; these counts do not by themselves demonstrate corrupt HTTP bodies.
The collector retains a first error per trial, not a diagnostic for every failure.

All requested connections completed measured requests at 8,192. At 16,384,
Debug participation was 16,383 / 16,384 / 16,383 across repeats; ReleaseSafe was
16,384 / 16,384 / 16,382; Go was 16,384 in every repeat. No trials were discarded.

## CPU and retransmissions constrain interpretation

CPU is the median across trials; 100% means one logical CPU. Client CPU includes
warmup; server CPU also includes setup, drain and collector polling. TCP ratios
aggregate per-trial whole-server-host counters and may include unrelated traffic.

| Connections | Server | Server CPU | Client CPU | TCP retransmitted / outgoing segments |
| ---: | --- | ---: | ---: | ---: |
| 8,192 | ZHTPS Debug | 364.2% | 298.2% | 6.88% |
| 8,192 | ZHTPS ReleaseSafe | 254.1% | 292.8% | 7.01% |
| 8,192 | Go | 701.3% | 336.0% | 8.49% |
| 16,384 | ZHTPS Debug | 319.6% | 250.7% | 15.51% |
| 16,384 | ZHTPS ReleaseSafe | 230.6% | 267.5% | 15.61% |
| 16,384 | Go | 558.3% | 316.6% | 17.58% |

This is a closed-loop workload with two-second client deadlines: slow responses
reduce offered load. Retransmissions and failures prevent interpreting successful
latency quantiles as a fixed-arrival-rate guarantee or these rates as server-only
capacity. The comparison does not isolate TLS library performance or locate packet loss.

## Reproduce and audit

Generate a disposable certificate using [the benchmark instructions](../bench/README.md),
build the current load client, and copy it to the second host:

```sh
GOCACHE=/tmp/zhtps-go-cache go build -o zig-out/bench/load bench/load/main.go bench/load/offered.go
scp -F /path/to/benchmark-ssh.conf zig-out/bench/load \
  client.example:/tmp/zhtps-tls-comparison-load-20260914
python3 bench/compare.py --server-address 192.0.2.10 \
  --client-host client.example \
  --remote-client-binary /tmp/zhtps-tls-comparison-load-20260914 \
  --ssh-config /path/to/benchmark-ssh.conf --client-cores 8 \
  --connections 8192 16384 --zig-workers 32 \
  --zig-max-connections 1024 --zig-max-active 1024 --no-zig-access-log \
  --go-cpu-mode unrestricted --allow-errors \
  --tls-certificate zig-out/bench/tls/cert.pem --tls-key zig-out/bench/tls/key.pem \
  --duration 5 --warmup 2 --repeats 3 \
  --output docs/go-comparison-tls-lan-workers32.json
python3 bench/audit_go_lan.py docs/go-comparison-tls-lan-workers32.json \
  --output docs/go-comparison-tls-lan-workers32-audit.json
```

The audit passed for all 18 trials and 29,117,961 validated window responses. It
verifies source and executable hashes, remote identity and client hash, accounting,
summary recomputation, Go runtime settings, and activity on all 32 ZHTPS workers.
It correctly reports that not all requested connections participated. TLS was
also checked as enabled in every trial's client result and command.

[Raw results](runs/standalone.json "Summary of docs/go-comparison-tls-lan-workers32.json; raw artifact retired") and
[audit with per-trial network deltas](runs/standalone.json "Summary of docs/go-comparison-tls-lan-workers32-audit.json; raw artifact retired").
