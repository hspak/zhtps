# Multicore ZHTPS comparison with unrestricted Go

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

ZHTPS uses **16 worker threads and 16 io_uring instances**. Each worker has
2,048 public connection slots and active-request permits: **32,768 public slots**
in total, plus eight admin slots on worker zero. Each ring has 256 SQ entries
and 16,384 CQ entries. All 16 workers handled requests and accumulated CPU time
in every ZHTPS trial.

Both servers could run on all **32 logical CPUs** of this 16-core machine.
Go ran with no affinity restriction or `GOMAXPROCS` override and reported
`GOMAXPROCS=32`. The same client used 15 physical cores on this host.
ZHTPS access logs were explicitly disabled; admission checks, counters and
latency histograms remained enabled. Go has no access logger or metrics.
This compares the implemented servers for this workload, without feature parity.

Medians of three five-second measurement windows after one second of warmup:

| Connections | Server | Successful responses/s | Trial range, responses/s | Success p50 ms | Success p95 ms | Success p99 ms |
|---:|---|---:|---:|---:|---:|---:|
| 4,096 | ZHTPS Debug | 1,403,309 | 1,400,352–1,410,398 | 2.834 | 3.654 | 5.767 |
| 4,096 | ZHTPS ReleaseSafe | 1,480,642 | 1,473,309–1,493,912 | 2.720 | 3.277 | 4.653 |
| 4,096 | Go net/http | 910,031 | 908,464–911,436 | 3.883 | 8.061 | 12.583 |
| 8,192 | ZHTPS Debug | 1,218,608 | 1,215,988–1,223,752 | 6.586 | 7.733 | 11.338 |
| 8,192 | ZHTPS ReleaseSafe | 1,281,464 | 1,267,535–1,285,064 | 6.324 | 6.980 | 9.896 |
| 8,192 | Go net/http | 866,721 | 859,134–867,004 | 8.585 | 14.287 | 20.054 |
| 16,384 | ZHTPS Debug | 1,101,577 | 1,099,391–1,102,549 | 14.615 | 16.712 | 22.020 |
| 16,384 | ZHTPS ReleaseSafe | 1,171,834 | 1,168,428–1,173,204 | 13.828 | 14.942 | 19.923 |
| 16,384 | Go net/http | 844,277 | 842,330–845,591 | 18.088 | 27.525 | 33.423 |

All **154,131,508 responses completed within the measurement windows** passed
status, length and exact-body validation. All 27 trials had **zero setup, warmup
and measured client errors**, zero HTTP rejections, and zero reconnects. Every
requested client completed measured requests at all three connection counts.
No trials were skipped as unsupported.

## CPU observations

CPU percentages include warmup; server CPU also includes client preparation.
One CPU is 100%. These observations are not normalized efficiency claims.

| Connections | Server | Median server CPU | Median client CPU |
|---:|---|---:|---:|
| 4,096 | ZHTPS Debug | 1179.1% | 1114.2% |
| 4,096 | ZHTPS ReleaseSafe | 687.0% | 1112.4% |
| 4,096 | Go net/http | 1583.5% | 798.3% |
| 8,192 | ZHTPS Debug | 1155.8% | 1126.6% |
| 8,192 | ZHTPS ReleaseSafe | 702.1% | 1126.8% |
| 8,192 | Go net/http | 1581.1% | 837.7% |
| 16,384 | ZHTPS Debug | 1047.9% | 1086.0% |
| 16,384 | ZHTPS ReleaseSafe | 663.0% | 1113.2% |
| 16,384 | Go net/http | 1497.2% | 858.3% |

## Method and limits

Each trial starts a fresh server. The client attempts all requested connections,
with at most 64 preparation requests at a time, before entering a shared warmup.
The workload is HTTP/1.1 `GET /` over loopback, with one outstanding request per
persistent connection and no pipelining. A successful response must be HTTP 200,
have `Content-Length: 6`, and contain exactly `ZHTPS\n`. Both servers send the
same Content-Type and ETag. Server order rotates between repetitions.

The table uses `window_successes_per_second`: validated responses completed
inside the fixed measurement window divided by five seconds. Failure counts
are retained separately. Latencies use successful requests started inside the
measurement window and include their final drain; displayed percentiles are
medians of trial percentiles. Histogram rounding is upward by less than 0.8%.
The older cohort-based `requests_per_second` field remains in the raw report.

The runner used `--allow-errors`, so failures would have been recorded rather
than preventing a high-concurrency result. This run had connection headroom and
no admission rejections. It measures closed-loop saturation, not overload at a
fixed arrival rate or a latency service-level guarantee. Slower responses reduce
offered load; these percentiles do not correct coordinated omission.

The server and client share CPUs, caches and loopback networking. Client CPU
consumption is substantial. These numbers characterize this host and generator;
a separate load-generator host is needed to isolate server capacity. Results
cannot be extrapolated linearly with worker count. The earlier single-worker
reports also used a different logging policy and ring/metric implementation.

Worker-count calibration and the source review are documented in
[the worker report](workers.md). Final Debug and ReleaseSafe binaries each
passed **34 component tests and 40 raw TCP tests**; the Go load-client tests
passed as well. No protocol checks were removed for the benchmark.

## Reproduce

```sh
python3 bench/compare.py --connections 4096 8192 16384 --zig-workers 16 \
  --zig-max-connections 2048 --zig-max-active 2048 --no-zig-access-log \
  --go-cpu-mode unrestricted --client-cores 15 --allow-errors \
  --duration 5 --warmup 1 --repeats 3 --output docs/go-comparison-workers.json
```

Recorded start: `2026-09-11T06:26:56Z`. Kernel: `7.2.4-arch1-2-strixhalo`;
Zig: `0.16.0`; Go: `go version go1.27.0-X:nodwarf5 linux/amd64`.
Commands, CPU affinities, runtime settings, resource limits, all trial outcomes,
worker counters/CPU time and source/binary SHA-256 hashes are retained in
[the raw report](runs/standalone.json "Summary of docs/go-comparison-workers.json; raw artifact retired"). The final audit verified that
all recorded source and binary hashes match the measured worktree artifacts.
