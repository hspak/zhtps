Two rotated diagnostic pairs per server preserve the current 8 MiB upload
workloads and add client TCP_INFO plus send/response timestamps. Tracing adds
client overhead, so these are explanatory controls, not replacements for the
three original untraced pairs. All eight trials have zero HTTP failures and
independently validated response lengths and IEEE CRCs. Those failure ties and
the 200 MiB/s paced-throughput ties remain open.

> Artifact retention: [Run summaries and setup records](../runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

In the paced controls, ZHTPS p99 is 30.540 and 30.570 ms; Go is 29.837 and
29.873 ms. A small number of requests account for the retransmissions:

| Server/trial | Requests with retransmissions / all | p99 without retransmissions |
|---|---:|---:|
| Go 1 | 5 / 750 | 29.825 ms |
| Go 2 | 5 / 750 | 29.842 ms |
| ZHTPS 1 | 7 / 750 | 29.810 ms |
| ZHTPS 2 | 8 / 750 | 29.777 ms |

The conditional figures explain sensitivity near the p99 boundary; they do
not remove failed transport delivery from the measured workload or establish
a causal server advantage. HTTP completes successfully after TCP recovery.
The original totals retain every request. Higher ZHTPS retransmission incidence
in these two trials remains a finding to investigate, not a justified exclusion.

There are roughly 2.5 MiB of unsent client bytes at median send-call return in
paced runs, and 2.1 MiB in saturated runs. Time between send return and response
therefore includes client queuing and wire transit, not just server execution.
Receiver-window-limited TCP time stays zero in the recorded request intervals.
The traces do not isolate application callback or completion-queue duration.

The saturated p99 ordering varies: Go is 915.504 / 925.819 ms and ZHTPS is
915.697 / 915.812 ms. Both retain roughly 912.4 ms median latency and the same
near-link-capacity throughput. This reinforces the need for rotated trials and
does not close the original large-upload tail gap.

The isolated runtime experiment drained already-published application
completions before ring submission. The current loop otherwise waits for its
eventfd completion before submitting a subsequent read or response. Collecting
ready work can remove that extra loop turn; the experiment preserves the eventfd
wakeup, worker ownership, callback isolation, request deadlines and paused reads
during each callback. The existing full ReleaseSafe test suite passes: 65/65
build steps and 94/94 component/CRC tests, plus the wire, embedded, executor and
streaming suites. Formatting also passes.

The experiment is discarded after three untraced rotated pairs per workload.
Uncapped median p99 improves from 927.917 to 915.863 ms, with lower p99 in all
three pairs. Its median CPU rises from 291.02 to 292.00 µs/MiB, with overlapping
ranges. Paced median CPU falls from 181.40 to 176.28 µs/MiB, also with overlapping
ranges, but paced p99 worsens in all three pairs (29.808 to 29.841 ms median).
Throughput ties at 281.333 MiB/s uncapped and 200 MiB/s paced. All HTTP failure
counts remain zero. The favorable results are retained in the record, but the
tail tradeoff does not justify retaining the runtime change. It was tested in
an isolated source snapshot and never replaced the root worker implementation.

[Exact traces and analysis](../runs/go-performance-followup.json "Summary of docs/go-performance-followup/upload-trace-analysis.json; raw artifact retired"),
[commands](../runs/go-performance-followup.json "Summary of docs/go-performance-followup/upload-trace-plan.json; raw artifact retired"),
[candidate and tests](../runs/go-performance-followup.json "Summary of docs/go-performance-followup/ready-completion-candidate.json; raw artifact retired").
