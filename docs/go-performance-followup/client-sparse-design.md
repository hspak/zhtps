The status-quo offered client retains four 64 KiB histograms per connection
per phase, reaching roughly 16.4 GiB RSS at 16k connections and four phases.
This allocation occurs during measured phases and can interfere with the
server comparison. Paired controls now isolate its effect at 100k and 200k/s.

> Artifact retention: [Run summaries and setup records](../runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The candidate preserves all quantile boundaries, counts, failures, scheduling,
request generation and reporting. Each histogram now reserves a pointer table
and allocates each 128-counter magnitude range on first use. Merge copies
counters into independently owned destination ranges. No samples are dropped
or approximated differently. The proposed benefit is client memory, allocation
work and measurement stability; benchmark effects require controlled trials.

A permanent integration regression drives four real HTTP phases with 256
connections and checks total allocations including the client and test server.
The identical test was run against status quo in
/tmp/zhtps-client-memory-before and the candidate in /tmp/zhtps-client-sparse.
Status quo allocated 290,724,616 bytes and failed the 96 MiB limit; the
candidate passes the unchanged test. Existing latency, failure accounting and cohort tests stay
unchanged. An ownership test checks that merging does not alias source buckets.

The candidate is retained in the worktree. All client tests pass and Go build
settings match the original executable. Three rotated pairs per server at 16k
connections reduce peak client RSS from approximately 17 GiB to 2 GiB. At
100k offered/s, generator drops total 43,216 / 43,255 for dense ZHTPS / Go,
versus 1 / 2 with sparse histograms. At 200k the totals change from
123,422 / 128,527 to 281 / 914. At 300k, transport losses remain and the
candidate does not establish a latency or failure advantage for ZHTPS.

This is a benchmark fixture correction used equally for both servers, not a
ZHTPS server optimization. Historical comparisons and every tie remain open.
See [all trials](../runs/go-performance-followup.json "Summary of docs/go-performance-followup/client-histogram-aggregate.json; raw artifact retired") and
build receipt.
