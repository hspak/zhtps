# Higher-connection comparison with unrestricted Go

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

For the current multicore implementation, see the [worker comparison](go-comparison-workers.md).

The [8,192-client overflow benchmark](go-comparison-8192-overflow.md) now measures
successful responses from a running ZHTPS server configured for 8,168 connection
slots while all 8,192 clients attempt work. The `Unsupported` rows below record
the earlier invalid-startup-configuration test.

Go was allowed all **32 logical CPUs**, with no affinity restriction and no
`GOMAXPROCS` environment override. The runtime reported `GOMAXPROCS=32`.
ZHTPS retained its single event-loop CPU. The same 15-core client drove each
server on this host; these results compare the resulting CPU configurations.

Each result is the median of three five-second measurements after one second
of warmup. Every connection was established and completed a verified response
before warmup started. Latency is measured by the client through receipt and
validation of the complete response. Quantiles are medians of per-trial
quantiles, in milliseconds.

| Connections | Server | Requests/s | Trial range, requests/s | p50 ms | p95 ms | p99 ms |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 512 | ZHTPS Debug | 128,556 | 126,596–140,463 | 3.965 | 4.522 | 4.948 |
| 512 | ZHTPS ReleaseSafe | 240,396 | 238,561–298,073 | 2.114 | 2.654 | 2.933 |
| 512 | Go net/http | 747,758 | 744,334–748,474 | 0.387 | 2.294 | 3.686 |
| 1,024 | ZHTPS Debug | 119,709 | 116,762–136,674 | 8.716 | 9.830 | 10.748 |
| 1,024 | ZHTPS ReleaseSafe | 187,796 | 183,616–219,586 | 5.472 | 6.226 | 8.913 |
| 1,024 | Go net/http | 833,096 | 825,065–846,250 | 0.807 | 3.588 | 6.488 |
| 4,096 | ZHTPS Debug | 76,161 | 73,551–76,182 | 53.477 | 55.050 | 55.837 |
| 4,096 | ZHTPS ReleaseSafe | 133,423 | 131,148–139,269 | 30.671 | 32.113 | 32.637 |
| 4,096 | Go net/http | 783,630 | 774,300–785,052 | 4.489 | 9.765 | 15.925 |
| 8,192 | ZHTPS Debug | Unsupported | `InvalidLimit` | — | — | — |
| 8,192 | ZHTPS ReleaseSafe | Unsupported | `InvalidLimit` | — | — | — |
| 8,192 | Go net/http | 746,443 | 736,453–746,794 | 10.093 | 16.515 | 22.282 |

All **60,543,597 measured requests** returned the expected status and body.
The 30 supported trials had **zero errors and zero reconnects**. Every requested
connection participated in the measured interval. The six remaining outcomes
are repeatable startup failures from the two Zig builds at 8,192 connections.

ZHTPS currently permits **8,176 total connection slots**, including its eight
default admin slots, leaving **8,168 public connections**. Configuring 8,192
public connections returns `InvalidLimit` before binding. The runner recorded
the actual exit code and error JSON for both builds on every repetition.
The [configuration limit](../src/Config.zig) follows the
[ring allocation budget](../src/server/worker.zig): the server rounds
`4 * total_connections + 64` up to a power of two and rejects sizes above 32,768.
The benchmark did not change that contract or substitute a lower connection count.

At the supported counts, ZHTPS was launched with `--max-connections N` and
`--max-active N`. Both Zig builds used `--max-requests 4294967295` to preserve
connections through the trial. Other runtime settings retained their defaults:
normal metrics and JSON log generation, default buffers, and no request-rate
limiter. Output was sent to `/dev/null`. The Go handler serves the same six-byte
`ZHTPS\n` body, content type, and ETag without metrics or access logging.
The request is HTTP/1.1 `GET /` over loopback, with no TLS or pipelining and one
outstanding request per connection.

Host and placement:

| Setting | Recorded configuration |
| --- | --- |
| Start time | 2026-09-11T05:27:30Z |
| CPU | AMD Ryzen AI Max+ 395, 16 physical cores / 32 logical CPUs |
| Kernel | Linux 7.2.4-arch1-2-strixhalo, x86_64 |
| Zig | 0.16.0; Debug and `--release=safe` |
| Go | `go version go1.27.0-X:nodwarf5 linux/amd64` |
| Go compiler settings | `GOAMD64=v1`, `GOEXPERIMENT=nodwarf5` |
| ZHTPS affinity | CPU 0 |
| Go affinity | CPUs 0–31, inherited without restriction |
| Client affinity | CPUs 1–15, one logical CPU from each other physical core |
| Client GOMAXPROCS | 15 |
| File descriptors | Soft limit raised to 8,448; hard limit 524,288 unchanged |

Go consumed about **13.4–14.9 CPU-seconds per wall-clock second** in these
trials; ZHTPS consumed about **0.60–0.75**. These are process CPU measurements
including connection preparation and warmup; separately accounted interrupt
work is excluded. CPU allowance and CPU consumption are both captured in the
[summarized results](runs/standalone.json "Summary of docs/go-comparison-high-connections.json; raw artifact retired"). Go shared the host and client
CPUs, so this measures a local server/client system rather than an isolated
server driven by another machine.

The original four-core client was insufficient for the unrestricted Go workload.
[Short client-capacity pilots](runs/standalone.json "Summary of docs/go-comparison-high-client-check.json; raw artifact retired") gave:

| Client cores | Go requests/s at 512 connections | Go requests/s at 8,192 connections |
| ---: | ---: | ---: |
| 4 | 520,628 | 307,043 |
| 8 | 695,112 | 589,987 |
| 12 | 760,809 | 715,395 |
| 15 | 757,024 | 734,934 |

These pilots used one-second measurements at four cores and two seconds at
larger allocations. They selected the final setup; they are separate from the
repeated five-second results above. Increasing from 12 to 15 client cores added
little throughput, while the earlier increases mattered substantially.

Client placement also affects ZHTPS. The short four-core pilot reached about
444k requests/s for ReleaseSafe at 512 connections, compared with a 240k median
using the 15-core client in the main comparison. The pilot does not isolate why
this changes; client scheduling, placement, and traffic timing remain influences.
The main table uses the same client allocation for every server. Its rates are
properties of this recorded setup, not portable capacity ceilings. The raw
pilot results retain the four-core Zig measurements as well.

This run changes both Go CPU allowance and client allocation relative to the
[original single-CPU comparison](go-comparison.md). The load generator now uses
a preparation barrier to ensure the requested connection population exists
before warmup; its barrier and histogram tests passed. All source and binary
hashes were verified against the measurement artifacts.

These are closed-loop measurements: a client waits for each response before
sending its next request. They do not establish latency at a fixed arrival
rate or during overload. Quantile rounding is less than 0.8%; host scheduling
and CPU placement can have larger effects. The wider Zig trial ranges at 512
and 1,024 connections are included rather than selecting the fastest run.

Reproduce from the repository root:

```sh
python3 bench/compare.py --connections 512 1024 4096 8192 --go-cpu-mode unrestricted \
  --client-cores 15 --duration 5 --warmup 1 --repeats 3 \
  --output docs/go-comparison-high-connections.json
```

The runner builds Debug, ReleaseSafe, the Go baseline, and the client. It raises
only its process file-descriptor soft limit, validates every response, rotates
server order across repetitions, and preserves individual outcomes. The host
must allow io_uring and loopback sockets; these runs executed outside the
workspace sandbox. See [the harness documentation](../bench/README.md) for options.
