The objective is to rerun the Go HTTP comparison and investigate every result
that is not strictly better for ZHTPS, then implement and benchmark improvements
until the requested advantage is verified. Preserve the complete comparison:
GET at 8,192 and 16,384 connections, offered 100k/200k/300k and saturated load;
64 KiB and 8 MiB uploads, including saturated and paced 200 MiB/s bodies.
Track validated throughput, latency, process CPU, RSS, and failures. Ties and
inconclusive differences remain open; fixed offered rates and network ceilings
must be identified explicitly rather than counted as wins.

Starting source is verified against the preceding frozen final receipt in
starting-source.json. All prior worktree changes are preserved. Go HTTP keeps
GOMAXPROCS=32 and normal GC; load comes from the established second host.
Keep exact source/executable/client identities, raw records, repeated rotated
trials, independent response validation, and complete failure accounting.

First rerun the established full workload matrix. Then address observed gaps
one change at a time, with immutable before/after builds and focused correctness
coverage. Revert unsuccessful experiments. After retained changes, repeat all
affected comparisons and audit the current source and final full matrix.
Do not compile, profile, test, or run competing benchmarks during decision
measurements. Keep client/network diagnostic controls separate and retain all
measured samples, including slow and failed requests.

User clarification: keep every tied result open, including throughput fixed by
the offered-rate cap and zero failures. Do not count either as a win or silently
exclude it from the completion audit.
