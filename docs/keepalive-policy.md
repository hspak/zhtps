# Keepalive reclamation and shutdown

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

This follow-up retains **pressure reclamation as opt-in** and adds a
**100 ms final keepalive request window at shutdown**. The 50 ms reclamation
candidate has essentially neutral normal-load cost, but returning-client p99
rises **13.6%** in the confirmation. That does not satisfy the requested condition
to enable it by default only without a substantial negative result. The two timers serve different purposes:
reclamation measures completed keepalive idle age under connection-slot
pressure; shutdown protection starts when the worker begins shutting down.

## Shutdown choice

Three approaches were considered:

| Approach | Coverage and cost |
|---|---|
| Dispatch queued completions before closing idle sockets | Covers requests already in the completion queue, but misses requests arriving just afterward. |
| Immediately half-close and drain idle sockets | Makes EOF visible and reduces reset risk, but cannot respond to a concurrent request after the write half is closed. |
| Keep established public keepalives readable for a bounded final-request window | Handles queued receives and concurrent reuse, then sends a final response with `Connection: close`. Adds a short wait for silent peers. |

The implementation uses the third approach, with a **100 ms shutdown keepalive
window**, capped by the overall shutdown timeout. This allows ten ordinary event
ticks without retaining silent peers for the whole five-second work drain. It is a
bounded opportunity for a final request, not a guarantee about arbitrary network
delays. The window applies to established public keepalives regardless of how
long they were idle before shutdown. Initial idle and admin connections receive
no such extension. Existing request headers can finish after the window ends,
within their normal deadlines and the overall shutdown budget. Rate, active
request, rejection, body, and application limits still apply.

Responses begun during shutdown advertise `Connection: close`. A connection
cannot extend the shutdown deadline by issuing more keepalive requests. Silent
established connections receive a write half-close when their window expires;
the existing bounded receive drain then consumes late bytes before final close.
Outstanding I/O and cancellation completions still retire before storage reuse.
`--shutdown-keepalive-ms 0` retains immediate idle closure. The independent
`--shutdown-timeout-ms` continues to bound work draining; running application
hooks must return before their storage can be released.

The permanent [wire regressions](../tests/shutdown.py) reproduce two failures
against the unchanged executable: a TCP reset when an old idle client sends
after `shutdown_started`, and a 503 when an already-started header finishes
after shutdown begins. The same tests pass with the fix. Additional cases cover
one closing response for pipelined reuse, silent peers, the overall deadline,
initial idle connections, admission limits, and zero protection.
Before,
after.

HTTP/1.1 cannot prevent a client from sending after the final cutoff. Clients
still need to handle EOF and follow the protocol's retry rules. This change
addresses the immediate shutdown race and preserves orderly teardown; it does
not promise unlimited connection reuse while a server exits.
[HTTP connection failures](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.5).

## Benchmark method

The [runner](../bench/keepalive_policy.py) rotates off, 50 ms, 250 ms, and
1,000 ms policies on the same recorded executable. The server uses the physical
LAN and current NIC-local worker placement; the client runs on the separate
`client.example` host. Each run records executable hashes, process and host
counters, HTTP failures, and raw client results. The build receipt and complete
pre-change core source archive identify the executable independently of later
workspace edits. [Baseline build](runs/keepalive-policy.json "Summary of docs/keepalive-policy/before-build.json; raw artifact retired").

Normal-load trials use seven workers on CPUs 9–15, 4,096 slots per worker, and
8,192 persistent connections at 100k and 200k offered requests/s. The initial
screen has a short low-rate setup phase. Startup latency is variable, so the
confirmation uses a longer high-rate warmup before comparing measured phases.

The [returning-client workload](../bench/keepalive_returning_client.py) fills a
single worker's 1,024 slots with validated keepalives. Each of eight rounds waits
150 ms, attempts 128 newcomers using 32 threads, then issues another request on
**every original connection**. Clients retain their connections across rounds.
An original client retries its idempotent GET once after stale-connection failure;
its reported logical latency includes the failed attempt and reconnection.
Newcomer timeouts, resident retry errors, logical failures, and reconnections
remain separately counted. This explicitly measures the returning-client cost
missing from the original reclamation experiment. Python thread scheduling is
included in these latencies; they are not isolated server service times.

## Returning-client screen

Three rotated trials per policy each offered 1,024 newcomer requests and 8,192
returning-client requests. All **24,576 returning requests per policy** succeeded,
including retries. Latencies below are medians of trial p99 values and include
the complete logical request, including any reconnection.

| Minimum idle age | Newcomer successes / 3,072 | Newcomer p99 | Returning-client p99 | Returning reconnections / 24,576 |
|---|---:|---:|---:|---:|
| Off | 0 | No successes | 10.55 ms | 0 |
| 50 ms | 3,072 | 9.28 ms | 11.09 ms | 630 |
| 250 ms | 3,072 | 22.78 ms | 11.22 ms | 680 |
| 1,000 ms | 2,284 | 268.94 ms | 10.96 ms | 742 |

The **50 ms candidate** protects the short gap between ordinary requests for
five event ticks while making cold completed keepalives available quickly.
250 ms doubles newcomer p99 without reducing reconnections in this workload;
1,000 ms leaves newcomer requests waiting past their 500 ms client deadline.
The latter also records 20 reclamation-wait timeouts across three trials, versus
zero with 50 and 250 ms.

Reclamation is not free for returning clients. With 50 ms, 2.56% of their
requests first encounter a closed connection and reconnect. Their median trial
p99 rises by **0.54 ms (5.1%)**, while median trial p50 falls from 2.12 to 2.04 ms.
These results support an admission tradeoff, not a claim that every latency
metric improves. The benchmark uses retry-capable GET clients; it does not
establish equivalent behavior for clients that do not recover from closed
keepalives or for non-idempotent retries.

[Raw returning-client trials](runs/keepalive-policy.json "Run summaries from docs/keepalive-policy/returning-screen; raw artifacts retired"),
[aggregate](runs/keepalive-policy.json "Summary of docs/keepalive-policy/aggregate.json; raw artifact retired"),
[summarizer](../bench/summarize_keepalive_policy.py).

## Warmed normal-load confirmation

Four rotated off/on pairs use the same candidate executable, including the
shutdown fix. Each trial warms up for 10 seconds at 100k requests/s, then measures
20 seconds each at 100k and 200k/s. Each policy is explicitly configured, so the
off trials exercise `--idle-reclaim-ms 0` even with the candidate's provisional default.

| Offered rate | CPU µs/success, off → 50 ms | Goodput requests/s, off → 50 ms | Service p99, off → 50 ms |
|---|---:|---:|---:|
| 100k/s | 4.478 → 4.489 (+0.25%) | 99,754 → 99,765 | 155.6 → 155.1 µs |
| 200k/s | 4.387 → 4.373 (−0.32%) | 199,277 → 199,045 (−0.12%) | 154.1 → 112.6 ms |

All sent HTTP requests in the measured phases succeeded and validated the
response body. Connection setup during the separate warmup phase had **380 dial
timeouts off and 257 on**; these remain in the raw accounting and are not
included in the measured-phase latency table. No connections were reclaimed
in these normal-load trials because slot pressure was absent. Unsent
generator offers remain accounted separately in the raw trials; achieved goodput
is slightly below the offered rates. CPU and goodput trial ranges overlap.
The 200k/s p99 values are unstable: trial p99 ranges are **0.52–238.03 ms off**
and **0.58–231.74 ms on**. Both settings have large excursions, so the median
difference is not evidence of a reliable latency improvement. At 100k/s the
off/on p99 ranges are 148–161 / 145–162 µs.

The earlier 12-trial screen used only three seconds at 1k/s before increasing
the offered rate; opening the remaining connections contaminated its first
high-rate latency phase. Those records are retained, but the warmed same-binary
comparison above is the normal-load cost control. The 50 ms candidate retains
the measured admission gain with essentially neutral normal-load cost, but the
returning-client confirmation below determines whether that candidate can be
enabled by default under the requested condition.

[Confirmation trials](runs/keepalive-policy.json "Run summaries from docs/keepalive-policy/normal-confirm; raw artifacts retired"),
[initial screen](runs/keepalive-policy.json "Run summaries from docs/keepalive-policy/normal-screen; raw artifacts retired"),
[candidate build and source receipt](runs/keepalive-policy.json "Summary of docs/keepalive-policy/candidate-build.json; raw artifact retired").

## Returning-client confirmation and default decision

Three additional rotated off/50 ms pairs repeat the returning-client workload
using the candidate executable that includes the shutdown fix. All 24,576
returning-client requests succeed in each arm. The candidate admits all 3,072
newcomers; the off arm admits none before their deadlines.

Returning clients make **627 reconnections** with reclamation enabled, versus
none with it off. Their median trial p99 increases from **8.29 to 9.42 ms**,
or **13.6%**. The trial ranges do not overlap: **8.04–8.52 ms off** and
**9.20–9.60 ms on**. This includes client retry and scheduling cost; it is the
end-to-end effect for this client, not an isolated server CPU regression.

The original screen also showed a returning-client tail increase, but a smaller
one (5.1%). The confirmation makes the negative result substantial enough to
withhold a default change under the user's condition. **The final
`idle_reclaim_ms` default therefore remains zero.** 50 ms is the tested choice
for deployments that explicitly prefer admitting newcomers over retaining every
idle keepalive. No HTTP failure was hidden by the retry accounting, and no claim
is made that reclamation is universally worse: its admission benefit is large
under this full-slot workload.

The candidate archive records the provisional 50 ms default used during testing;
off and on were always passed explicitly. The final source restores the zero
default and retains the independently verified shutdown fix.
[Confirmation records](runs/keepalive-policy.json "Run summaries from docs/keepalive-policy/returning-confirm; raw artifacts retired").

## Compatibility and verification

The existing disabled-policy test now specifies zero explicitly, preserving its
original behavioral coverage. A new live test verifies that explicit 50 ms
reclamation admits a newcomer and lets the displaced original client reconnect
and reclaim the slot in turn. Existing timeout validation and tests are preserved.

`bench/architecture.py` now distinguishes an omitted policy from explicit zero,
so future same-binary off/on controls cannot accidentally run the default in
both arms. The new shutdown tests are part of `zig build test-wire`.

Full **Debug and ReleaseSafe** component, embedded-library, and wire suites pass:
59/59 build steps and 97/97 Zig tests in each mode, plus the Python wire suites
including seven shutdown cases. The two reported shutdown regressions were
unchanged between their failing baseline run and passing fixed run. During
Debug validation, the separate zero-window test exposed a harness assumption:
immediate exit can drop its buffered diagnostic log. That test now checks socket
EOF directly; it does not weaken the closure requirement.

Debug checks,
ReleaseSafe checks,
[final executable and source receipt](runs/keepalive-policy.json "Summary of docs/keepalive-policy/final-build.json; raw artifact retired"),
core changes,
[worker implementation](../src/server/worker.zig),
[configuration](../src/Config.zig).

Rebuildable source snapshots: baseline,
benchmark candidate,
final source.
The [evidence audit](runs/keepalive-policy.json "Summary of docs/keepalive-policy/audit.json; raw artifact retired") verifies 38 trials, policy
arguments, executable hashes, returning-client accounting, and final source
hashes, retaining warmup connection failures separately from measured phases.
