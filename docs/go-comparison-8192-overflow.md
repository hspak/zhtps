# Successful responses with 8,192 offered clients

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

For the current multicore implementation, see the [worker comparison](go-comparison-workers.md).

The earlier `Unsupported` result came from asking ZHTPS to start with an invalid
8,192-slot configuration. This follow-up starts the same binaries with **8,168
public connection slots** and **8,168 request permits**, while **8,192 client
workers** attempt requests throughout the trial.

Go remains unrestricted on all 32 logical CPUs (`GOMAXPROCS=32`). ZHTPS uses
one event-loop CPU. All three variants use the same 15-core client, HTTP/1.1
keep-alive `GET /`, and six-byte `ZHTPS\n` response. Every successful response
must pass status, Content-Length, and body validation.

The table reports medians of three five-second measurements after a one-second
warmup. Successful responses/s counts validated responses completed within the
fixed window; error counts likewise refer to that window. Successful-request
p99 uses requests started during the measurement interval, including their drain.

| Server | Successful responses/s | Trial range, responses/s | Success p99 | Read timeouts per 5s | HTTP 503 per 5s |
| --- | ---: | ---: | ---: | ---: | ---: |
| ZHTPS Debug | 91,077 | 83,601–92,394 | 93.85 ms | 48 | 0 |
| ZHTPS ReleaseSafe | 113,773 | 109,451–117,427 | 77.59 ms | 48 | 0 |
| Go net/http | 840,961 | 838,475–857,509 | 19.66 ms | 0 | 0 |

All **8,192 workers attempted measured requests** in every trial. For both Zig
builds, **8,168 workers received successful measured responses** and the remaining
**24 kept retrying**. Go served successful responses to all 8,192 workers.
Across the nine measurement windows, the client validated **15,723,344 successful
responses**. The only failures completing within those windows were the listed
Zig read timeouts; there were no HTTP rejections, invalid responses, connection
resets, or refused connections in those windows.

The connection-capacity behavior is visible in
[`queueAccept`](../src/server/worker.zig): when no connection slot is free, it stops
submitting accepts. Excess connected clients can remain pending without an HTTP
response. Their client-side read deadline is two seconds. In these trials this
produced read timeouts rather than prompt HTTP 503s. The
[request-admission limiter](../src/Admission.zig) has a separate 503/close path.
The request-permit budget here equals the connection-slot budget, so this test
exercises connection-slot exhaustion rather than a tighter request-permit limit.

Preparation attempts one verified request per worker, with at most 64 concurrent
opens. Each Zig trial recorded 24 failed preparation requests. All workers then
entered the shared warmup; failed workers reconnected and continued attempting
work. There were 24 warmup-started failures per Zig trial and 48 failures among
measurement-started requests. These start-time cohorts differ from the window
completion counters: a warmup request can fail during the measurement window,
and a measurement request can fail after it. The raw fields retain both views.
Each Zig trial opened 8,264 TCP connections in total, including the excess
clients' retries. Go opened exactly 8,192.

Successful responses/s uses the fixed five-second denominator so a blocked
excess client cannot extend it after the other workers stop issuing requests.
The older cohort-throughput field, `requests_per_second`, is retained alongside
`window_successes_per_second`. Latency percentiles describe successful requests;
failed clients' two-second waits are reported separately and are not folded into
success latency. This remains a closed-loop test, not a fixed-arrival-rate SLO
measurement.

Run details:

| Setting | Value |
| --- | --- |
| Start time | 2026-09-11T05:42:22Z |
| CPU | AMD Ryzen AI Max+ 395, 16 physical / 32 logical CPUs |
| Kernel | Linux 7.2.4-arch1-2-strixhalo, x86_64 |
| Zig | 0.16.0, Debug and `--release=safe` |
| Go | `go version go1.27.0-X:nodwarf5 linux/amd64` |
| ZHTPS placement | CPU 0 |
| Go placement | CPUs 0–31, no affinity restriction or GOMAXPROCS override |
| Client placement | CPUs 1–15, GOMAXPROCS=15 |
| Zig limits | `--max-connections 8168 --max-active 8168 --max-requests 4294967295` |

The server binaries are unchanged from the previous higher-connection comparison.
The harness now supports failure-tolerant runs, independent server capacity and
client count, failure classification, and fixed-window success counters. Tests
verify that a 503 or corrupt 200 response cannot count as success, and that clients
keep working after a rejected request or failed preparation. The existing strict
benchmark mode remains available. Source/binary hashes and all individual trials
are retained in [the summarized results](runs/standalone.json "Summary of docs/go-comparison-8192-overflow.json; raw artifact retired").

Reproduce from the repository root:

```sh
python3 bench/compare.py --connections 8192 --zig-max-connections 8168 \
  --zig-max-active 8168 --allow-errors --go-cpu-mode unrestricted \
  --client-cores 15 --duration 5 --warmup 1 --repeats 3 \
  --output docs/go-comparison-8192-overflow.json
```

The runtime environment must permit io_uring and loopback sockets. The client
shares this host with the servers; placement and scheduling affect these rates.
See [the higher-connection report](go-comparison-high-connections.md) for the
earlier setup and client-capacity checks, and [the harness documentation](../bench/README.md)
for field definitions and options.
