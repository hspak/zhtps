# Initial 32-worker startup failure

> Artifact retention: [Run summaries and setup records](../runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Keeping the previous per-worker budget of 2,048 public slots and active permits
made the 32-worker server exit before becoming ready with `IoUringResources`.
The [diagnostic report](../runs/go-comparison-lan.json "Summary of docs/go-comparison-lan/workers32-startup-diagnostic.json; raw artifact retired") records the command,
exit status, error and process limits. Both soft and hard `RLIMIT_MEMLOCK` were
8 MiB. The descriptor soft limit was already raised to 16,640.

A startup-only syscall trace shows 28 successful
`io_uring_setup` calls with 256 SQ / 16,384 CQ entries, followed by `ENOMEM`
on the 29th call. No requests were benchmarked in these failed startups.
Noninteractive sudo was unavailable, so the hard limit could not be raised.

The completed comparison uses 1,024 public slots and active permits per worker,
giving the same 32,768 total public capacity as the previous 16-worker run.
The server derives 8,192 CQ entries per ring from that budget, with 256 SQ
entries. Thus worker count, per-worker capacity, and CQ sizing differ from the
previous run; it is not an isolated worker-count experiment. The application
source, binaries, total public capacity, client workload, logging policy and
Go CPU policy remain the same.
