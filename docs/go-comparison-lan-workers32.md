# Thirty-two ZHTPS workers versus Go over the LAN

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

This repeats the 8,192- and 16,384-connection cases with **32 ZHTPS workers**.
Go ran again alongside the Zig variants and reported **`GOMAXPROCS=32`**, with no
override or affinity restriction. Both servers could use all 32 logical CPUs
of `benchmark-server` (16 physical cores). HTTP load came from `client.example` (`benchmark-client`)
over the same 2.5 Gb/s wired LAN, using eight physical client cores and
`GOMAXPROCS=8`.

## Configuration difference

The initial attempt with 2,048 slots per worker failed before serving requests:
the 29th io_uring creation returned `ENOMEM`, under an inherited 8 MiB
`RLIMIT_MEMLOCK` hard limit. Noninteractive sudo was unavailable to raise it.
The [startup diagnostics](go-comparison-lan/workers32-startup-notes.md) retain
the command, limits, error and syscall trace.

The completed run uses **1,024 public slots and active-request permits per
worker**, preserving the earlier run's **32,768 total public slots**, plus eight
admin slots on worker zero. Each of the 32 rings has **256 SQ / 8,192 CQ entries**;
the previous 16-worker run had 256 SQ / 16,384 CQ entries per ring. Source files
and all four binary hashes match the previous run exactly. This comparison
changes worker count, per-worker budgets and ring sizing together.

Each result is the median of three five-second measurement windows after two
seconds of shared warmup, with a fresh server per trial and rotating server
order. The workload remains HTTP/1.1 `GET /`, exact six-byte `ZHTPS\n` responses,
keep-alive, one outstanding request per connection, no TLS and no pipelining.
Access logging is disabled for ZHTPS; admission checks and metrics remain enabled.
The client retains errors and retries using `--allow-errors`.

## Results

Throughput counts validated responses completed inside the fixed measurement
window. Latencies are medians of per-trial successful-request quantiles, in
milliseconds. Timeouts are excluded from these successful-request percentiles.

| Connections | Server | Responses/s | Trial range | p50 ms | p95 ms | p99 ms |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 8,192 | ZHTPS Debug | 340,378 | 339,548–340,771 | 1.778 | 209.715 | 246.415 |
| 8,192 | ZHTPS ReleaseSafe | 339,436 | 339,307–368,274 | 1.933 | 210.764 | 249.561 |
| 8,192 | Go net/http | 359,778 | 359,579–360,174 | 4.391 | 212.861 | 221.250 |
| 16,384 | ZHTPS Debug | 315,119 | 303,825–331,773 | 4.047 | 240.124 | 486.539 |
| 16,384 | ZHTPS ReleaseSafe | 329,279 | 299,179–329,882 | 6.619 | 221.250 | 434.110 |
| 16,384 | Go net/http | 319,547 | 317,551–322,355 | 6.390 | 222.298 | 436.208 |

## ReleaseSafe compared with the preceding 16-worker run

| Connections | 16 workers, responses/s | 32 workers, responses/s | Change | Go rerun, responses/s | 32-worker ZHTPS / Go |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 8,192 | 335,895 | 339,436 | +1.1% | 359,778 | 0.94× |
| 16,384 | 335,254 | 329,279 | -1.8% | 319,547 | 1.03× |

The 16- and 32-worker batches were sequential, not interleaved. In the Go control, throughput changed by -0.1% at 8,192 connections, -0.1% at 16,384 connections. Along with the ring-sizing change, this limits attribution of differences solely to worker count.

## Failures, participation and resources

All **18 trials** completed with **30,078,784 validated window responses**. Every requested connection completed measured requests. All 32 ZHTPS workers completed requests and accumulated CPU time in every Zig trial.

Error counts below sum three repeats and classify requests by their start phase.

| Connections | Server | Setup errors | Warmup errors | Measured errors | Extra connection opens |
| ---: | --- | ---: | ---: | ---: | ---: |
| 8,192 | ZHTPS Debug | 0 | 22 | 55 | 69 |
| 8,192 | ZHTPS ReleaseSafe | 0 | 14 | 30 | 39 |
| 8,192 | Go net/http | 0 | 41 | 25 | 60 |
| 16,384 | ZHTPS Debug | 0 | 722 | 614 | 1,169 |
| 16,384 | ZHTPS ReleaseSafe | 0 | 522 | 590 | 993 |
| 16,384 | Go net/http | 0 | 960 | 630 | 1,491 |

CPU percentages include warmup; server CPU also includes preparation, drain and collector polling. 100% is one CPU. Network counters cover the server host and can include unrelated traffic.

| Connections | Server | Server CPU | Client CPU | TCP retransmitted / outgoing segments |
| ---: | --- | ---: | ---: | ---: |
| 8,192 | ZHTPS Debug | 268.3% | 263.2% | 6.04% |
| 8,192 | ZHTPS ReleaseSafe | 156.3% | 265.3% | 6.85% |
| 8,192 | Go net/http | 744.6% | 310.7% | 8.18% |
| 16,384 | ZHTPS Debug | 214.5% | 276.8% | 17.51% |
| 16,384 | ZHTPS ReleaseSafe | 115.2% | 294.4% | 17.73% |
| 16,384 | Go net/http | 579.1% | 285.0% | 17.93% |

TCP retransmissions and two-second client timeouts remain part of these results.
Closed-loop clients reduce offered load when responses slow down, so throughput
and successful-request quantiles do not establish a fixed-arrival-rate latency
guarantee. The measurements do not pinpoint where packets are lost or establish
server-only capacity.

## Reproduce and audit

```sh
python3 bench/compare.py --server-address 192.0.2.10 \
  --client-host client.example \
  --remote-client-binary /tmp/zhtps-go-comparison-load-20260912 \
  --ssh-config /path/to/benchmark-ssh.conf --client-cores 8 \
  --connections 8192 16384 --zig-workers 32 \
  --zig-max-connections 1024 --zig-max-active 1024 --no-zig-access-log \
  --go-cpu-mode unrestricted --allow-errors \
  --duration 5 --warmup 2 --repeats 3 \
  --output docs/go-comparison-lan-workers32.json

python3 bench/audit_go_lan.py docs/go-comparison-lan-workers32.json \
  --output docs/go-comparison-lan/audit-workers32.json
```

The unchanged binaries passed the verification suites recorded in the
[preceding report](go-comparison-lan.md). The new result audit verifies hashes,
all 18 expected trials, remote host identity, Go runtime settings, accounting,
summary recomputation and activity on all 32 workers. An audit pass does not mean
the workload was free of client errors.

[Raw results](runs/standalone.json "Summary of docs/go-comparison-lan-workers32.json; raw artifact retired"),
[audit and network deltas](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/audit-workers32.json; raw artifact retired"),
[server before](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/server-workers32-start.json; raw artifact retired"),
[client before](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/client-workers32-start.json; raw artifact retired"),
[server after](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/server-workers32-end.json; raw artifact retired"),
[client after](runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/client-workers32-end.json; raw artifact retired").
