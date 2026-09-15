The thin-stream retry prototype completed all 36 upload trials with zero
failures and 1,531,432 validated responses. It retains substantially lower
server CPU and sampled RSS than Go, but this round does not establish an
upload throughput improvement. Every throughput or failure tie remains open.
[Audit](runs/thin-retry-upload.json "Summary of docs/thin-retry-upload/audit.json; raw artifact retired"), [results and all trial ranges](runs/thin-retry-upload.json "Summary of docs/thin-retry-upload/results.json; raw artifact retired").

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Three rotated trials compare retained ZHTPS V2, the accepted-socket retry
prototype, and Go in each of four existing workloads. Each response validates
the complete request-body length and CRC32. These measurements use the second
host, 32 upload connections, one ZHTPS network worker on CPU 9 with the process
pinned there, and Go with GOMAXPROCS=32 and normal GC. The client uses CPUs 0–7.
The 64 KiB trials last 20 seconds and the 8 MiB trials last 30 seconds, after
five seconds of warmup. The existing upload client has a 20-second socket
timeout; the GET benchmark has a two-second exchange deadline. Neither was
changed. The largest recorded upload latency was 1,125.919 ms.
[Plan](runs/thin-retry-upload.json "Summary of docs/thin-retry-upload/plan.json; raw artifact retired"),
[candidate build](runs/nginx-implementation.json "Summary of docs/nginx-implementation/timeout-thin-upload-v1/build.json; raw artifact retired").

Values below are medians across three trials. CPU is server process CPU per
validated MiB, excluding packet-processing work outside the process.

| Workload | V2 / retry / Go MiB/s | V2 / retry / Go p99 ms | V2 / retry / Go CPU µs/MiB |
|---|---:|---:|---:|
| 64 KiB, default queue mapping | 279.363 / 279.375 / 279.359 | 13.892 / 8.135 / 13.895 | 318.789 / 315.052 / 548.718 |
| 64 KiB, distinct client queues | 246.788 / 246.434 / 246.722 | 12.904 / 12.906 / 12.856 | 270.983 / 268.408 / 515.586 |
| 8 MiB, distinct client queues | 281.600 / 281.600 / 281.333 | 916.198 / 916.067 / 916.226 | 290.732 / 291.928 / 337.309 |
| 8 MiB, paced at 200 MiB/s | 200 / 200 / 200 | 29.805 / 29.886 / 30.402 | 174.626 / 174.626 / 178.294 |

Relative to retained V2, large-body CPU rises 0.41%, with separated trial
ranges. This small cost remains recorded. All other V2 metric comparisons
have overlapping trial ranges, including the favorable and unfavorable
medians. Calibrated-small throughput is 0.14% lower. Default-queue small-body
p50 is 3.10% higher, while p99 is 41.44% lower; the substantial p99 variation
does not support declaring a reliable gain from three trials. Large-body RSS
medians are 11.52 versus 13.38 MiB, but both trial ranges span approximately
11.52–13.50 MiB. The unfavorable median is not discarded as noise.

Relative to Go, retry-candidate CPU is 42.6%, 47.9%, 13.5%, and 2.1% lower
across the table's four rows, with separated trial ranges. RSS is 45.5%,
48.6%, 37.0%, and 32.4% lower, also with separated ranges. Paced p50 is lower
with separated ranges; the remaining latency and uncapped-throughput
comparisons overlap. The candidate's calibrated-small throughput, p50 and
p99, and default-queue small-body p50 have unfavorable medians against Go.
No trial was excluded. The Go comparison ledger has nine separated leads,
four unfavorable medians, six favorable overlapping comparisons, and five
ties. Three ranges are descriptive evidence, not confidence intervals.

The harness now accepts both a retained ZHTPS binary and Go alongside the
candidate, rotates all three across repetitions, and records repetition
identity. The auditor validates the exact planned variant/body/repetition
set. The original harness rejects this invocation; the expanded harness still
rejects a missing baseline. The 192-run legacy audit passed before these
measurements. Request validation and timeout rules are unchanged.
[Harness change evidence](runs/thin-retry-upload.json "Summary of docs/thin-retry-upload/harness-change.json; raw artifact retired"),
legacy audit.

The substantial GET timeout reduction justifies proceeding to production
integration despite the recorded upload CPU cost. The integration applies
the option to public listeners before accepting connections, provides an
explicit system-default mode, and must pass correctness, fixed-loss, and
fresh performance checks on its own exact binary. This report describes
the prototype, not that later integration's performance.
[GET comparison](read-timeout-thin-go.md),
[integration status](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/candidate.json; raw artifact retired").
