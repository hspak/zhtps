The first three opportunities from the [nginx source review](nginx-review.md)
were implemented sequentially, each compared with the preceding retained
version. All three are retained for measurable benefits in their intended
workloads. Request-body streaming remains opt-in: it reduces upload memory
substantially, with a measured 8–9% large-body CPU cost rather than a throughput
increase. No change was reverted for lack of a measurable benefit.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

These are ZHTPS before/after comparisons. nginx was the architectural reference,
not a benchmark participant. The earlier Go-inspired work remains in the
baseline. The [decision ledger](runs/nginx-implementation.json "Summary of docs/nginx-implementation/decisions.json; raw artifact retired"), build receipts, summarized client results, and run setup are in
[nginx-implementation](runs/nginx-implementation.json "Summary of docs/nginx-implementation; raw artifact retired").

**1. Lease request storage separately from connection slots — retained.**
The parser and application exchange now occupy a worker-owned request object.
Public connections acquire one when input arrives and release it after cleanup
when keepalive goes idle. Each worker preallocates up to 64 and caches at most
64 returned objects. Additional live objects are bounded by the worker's slots;
allocation failure closes the affected connection. Admin slots have private
request objects reserved at startup. Pipelined input and outstanding application
or kernel work retain the storage they still reference.

The 16 KiB default receive buffer and other small connection buffers remain in
place. A pending io_uring receive still owns its buffer. This change removes
idle request structures, without relaxing receive or cancellation ownership.
The request-cache metrics expose active objects, cached objects, allocations
and exhaustion. [Implementation](../src/server/worker.zig),
[wire tests](../tests/request_storage.py).

Twelve rotated two-host trials used seven workers pinned to CPUs 9–15, 4,096
public slots per worker, and 8,192 or 16,384 persistent connections. After a
10-second warmup, each run offered 100k requests/s for eight seconds and then
200k/s for eight seconds. Every sent request succeeded and validated the
six-byte response. Figures below are medians of three trials per variant.

| Connections | Offered requests/s | RSS before → after, MiB | CPU µs/success before → after | Service p99 before → after, µs |
|---:|---:|---:|---:|---:|
| 8,192 | 100,000 | 947.8 → 608.5 | 5.151 → 4.614 | 391 → 166 |
| 8,192 | 200,000 | 947.8 → 608.5 | 4.813 → 4.225 | 463 → 406 |
| 16,384 | 100,000 | 947.6 → 608.8 | 5.207 → 4.846 | 176 → 179 |
| 16,384 | 200,000 | 947.6 → 608.8 | 5.068 → 4.781 | 569 → 422 |

The approximately 36% RSS reduction is repeatable; measured median CPU cost
falls 6–12%. Configured slot capacity is identical at both connection counts,
which explains the similar RSS. These are matched-rate observations, not a
maximum-throughput claim. Generator expirations/drops remain in the accounting,
and a few TCP retransmissions occurred; successful HTTP validation does not
imply lossless transport. Results,
request accounting,
[source/build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/request-storage/build.json; raw artifact retired").

**2. Reclaim completed idle keepalive slots under pressure — retained, opt-in.**
This was the original opt-in decision. The later [keepalive policy
follow-up](keepalive-policy.md) measures returning clients and retains opt-in:
the 50 ms candidate has essentially neutral normal-load cost, but returning-client
p99 rises about 14% in the confirmation.

`--idle-reclaim-ms N` enables reclamation after a minimum idle age; zero remains
the default in these original trials. The worker selects its oldest eligible completed public keepalive
connection only when a newly accepted peer needs a full slot. Initial idle
connections, active requests, application hooks, responses and admin connections
are protected. A worker holds at most one extra accepted descriptor while the
victim's receive/cancel completions retire. It never reuses the victim's storage
merely because cancellation was submitted. The hold is bounded by
`close_timeout_ms`; eligibility is reconsidered on the 10 ms tick.
[Configuration](../src/Config.zig), [wire tests](../tests/idle_reclamation.py).

The reason for the initial opt-in policy is the admission tradeoff: new peers can displace
existing completed keepalives before the ordinary idle timeout. With the tested
50 ms age, a connection becomes eligible after 50 ms idle, but is closed only
under slot pressure when an accepted peer needs it. Displaced clients must
reconnect if they return. Reuse can also race with the server's close, requiring
client recovery subject to HTTP's retry rules.
[HTTP connection closure and retries](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.3.1).
Keeping the default off was a conservative policy choice given the original coverage
below; the measurements do not establish a repeatable CPU penalty from enabling
it or show that enabling it by default would be worse overall.

Three rotated pairs filled a single worker's 1,024 slots with validated idle
keepalive connections, then attempted 128 new requests through 32 client
threads. The baseline kept its 60-second idle timeout; the candidate also
enabled a 50 ms reclaim age. New requests had a 500 ms client timeout.

| Result | Previous version | Reclamation enabled |
|---|---:|---:|
| Successful new requests, each trial | 0/128 | 128/128 |
| Successful-request p99, three trials | No successes | 4.48 / 5.85 / 6.27 ms |
| Old idle connections reclaimed | 0 | 19 / 19 / 18 |
| Reclamation timeouts | 0 | 0 |

This is an admission/availability gain under full-slot pressure. It does not
measure maximum request throughput. The complete
[pressure results](runs/nginx-implementation.json "Run summaries from docs/nginx-implementation/idle-pressure-v3; raw artifacts retired") include the expected
baseline timeouts.

The [pressure client](../bench/idle_pressure_client.py) leaves the original
clients idle after setup and counts their closed sockets; it never has them
return with more requests. These trials therefore do not measure displaced
clients' reconnect latency, retry failures, or repeated connection churn under
sustained mixed traffic. They also do not establish 50 ms as a general default.

Six ordinary 8k-connection trials found essentially neutral median CPU cost
(+0.24% at 100k/s, −0.45% at 200k/s). Their short-run p99 values were noisy and
included millisecond spikes, more often in the candidate. A further six
same-binary policy-off/on trials used a 20-second 100k/s window. Those did not
reproduce the spikes: off/on CPU medians were 4.960/4.896 µs per success; p99
medians were 174/187 µs, with overlapping trial ranges. This supports retaining
an optional pressure policy; it does not establish a normal-load latency win.
Initial control,
longer policy control,
[source/build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/idle-reclaim/build.json; raw artifact retired").

Enabling the policy does add a timestamp read and constant-time idle-list
updates as connections enter and leave completed keepalive idle. Reclaiming a
connection adds receive cancellation and close work, plus the bounded extra
accepted descriptor described above. These are implementation costs; the
ordinary-load controls did not resolve a consistent CPU regression, and the
pressure trials did not isolate their cost from the admission benefit.

**3. Consume request bodies incrementally with backpressure — retained, opt-in.**
Generated endpoints can opt into `.body = .stream` with a `.consume` callback.
It runs on the endpoint's existing bounded application lane, with at most one
callback in flight per connection. The callback borrows one decoded receive
span; parsing and receiving pause until it returns. Local values and scratch
persist through successive callbacks, the final handler and cleanup. Body
limits and the original absolute application deadline still apply.

The final handler runs only after complete framing and trailers validate.
Consumers may already have processed a prefix when later input fails, so
application cleanup must support partial work. Empty bodies need no callback.
Buffered endpoints retain their existing behavior. The API does not add disk
spilling, a second receive buffer, or asynchronous retention of a callback's
borrowed span. [API](../src/endpoint.zig), [usage and ownership](endpoints.md#streaming-uploads),
[streaming wire tests](../tests/body_streaming.py).

The [upload fixture](../bench/upload.zig) computes CRC32 over every request byte
and returns both the length and checksum. The status-quo executable uses the
core source from immediately before streaming, buffers the full body and then
computes that checksum. The candidate computes the same checksum incrementally.
The remote client independently verifies both using Python's CRC32. Both
variants accept 8 MiB bodies; a baseline 413 or a missing response is a failure,
never counted as a streaming improvement.

Both measured variants compile with `-Dupload-observe=false`. This removes the
correctness fixture's progress counters and blocking gates. Earlier instrumented
trials incremented a progress counter once per chunk versus once per buffered
body; they remain as supplemental diagnostics in
[uploads](runs/nginx-implementation.json "Run summaries from docs/nginx-implementation/uploads; raw artifacts retired") and
[uploads-paced](runs/nginx-implementation.json "Run summaries from docs/nginx-implementation/uploads-paced; raw artifacts retired"), and are excluded from the
final comparison below. All 18 upload comparisons were repeated without that
unequal observation overhead. The buffered rebuild preserves every pre-streaming
core source byte.

Both use four workers on CPUs 9–12, 32 persistent clients, a 64 KiB receive
buffer, identical lane budgets and an 8 MiB endpoint limit. Buffered application
storage is 8 MiB; streaming scratch is 64 KiB. This deliberately measures a
service configured to accept large uploads. The status quo reserves its full
configured application buffer even for a smaller request, so the 64 KiB result
does not imply that every small-body service needs an 8 MiB buffer.

Each saturated trial has five seconds of warmup and a 20-second completion
window. Three rotated pairs per body size produced these medians:

| Body | Validated MiB/s before → stream | RSS before → stream, MiB | CPU µs/MiB before → stream | Service p99 before → stream, ms |
|---:|---:|---:|---:|---:|
| 64 KiB | 279.22 → 279.23 | 360.9 → 43.4 | 2,685 → 2,219 | 8.39 → 13.89 |
| 8 MiB | 281.6 → 281.6 | 360.9 → 43.6 | 1,962 → 2,135 | 923 → 920 |

RSS falls approximately 88%. Throughput reaches essentially the same LAN limit.
The large-body path incurs approximately 9% additional CPU per byte. Its
per-chunk application handoffs are a likely contributor, not a separately
profiled attribution. The 64 KiB p99 median is worse in this corrected set.
Saturated 8 MiB p99 is also unstable: baseline trials were 925/923/920 ms and
streaming trials 2,840/920/919 ms. Missed NIC receives occurred in both variants;
the raw counters and outliers remain in the evidence. Latency is measured by
the Python client and includes its scheduling and request/response transfer.
These results do not establish a saturated tail-latency improvement.
[Raw saturated trials](runs/nginx-implementation.json "Run summaries from docs/nginx-implementation/uploads-unobserved; raw artifacts retired"),
[buffered receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/upload-before-unobserved/build.json; raw artifact retired"),
[streaming receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/upload-streaming-unobserved/build.json; raw artifact retired").

Six additional rotated trials paced the 8 MiB uploads at an aggregate cap of
25 requests/s, with staggered starts and the same 32 persistent clients. Each
variant delivered exactly 200 MiB/s in every measurement window. Median RSS was
159.5 → 40.1 MiB (75% lower), CPU was 1,890 → 2,048 µs/MiB (8.3% higher), and
p99 was 44.9 → 30.1 ms (33% lower). Baseline p99 trials were 45.24/44.87/44.70 ms;
streaming trials were 30.14/30.11/30.23 ms. The lower tail latency is repeatable
in this paced workload, consistent with overlapping checksum work and body
arrival. The benchmark does not independently attribute the entire difference
to that overlap.
Paced results.

Streaming is retained for bounded memory and earlier consumption of large
bodies. Applications that prefer buffered access can keep `.bytes` or `.json`.
These measurements do not justify automatically converting existing endpoints,
claiming a small-GET speedup, or claiming uniformly better upload latency.

**Validation and reproducibility.** All comparisons use separate client and
server hosts: the server at 192.0.2.10 and the client reached through
`client.example` (reporting hostname `benchmark-client`). Results record independent boot
IDs, client placement on CPUs 0–7, source and executable hashes, actual running
`/proc/PID/exe` hashes, server exits, metrics and raw client accounting. Variants
were built from isolated source snapshots and copied into independent files.
The deliberately same-binary idle-policy control changes only configuration.

The standalone load generator uses scheduled offers; upload tests use validated
closed-loop completions. CPU-per-request/byte estimates use sampled process CPU
over the measurement interior. They include network and application threads,
not separate IRQ CPU. RSS includes reserved admin buffers and caches. Runs use
ReleaseSafe with access logging disabled. Host-wide network settings were not
changed; benchmark processes raised only their own descriptor limits.

Request storage passed its wire tests and allocator-exhaustion recovery test.
Reclamation passed repeated single-slot cancellation/reuse and protected-client
tests. Streaming tests exercise prefix consumption before body completion,
chunked fragmentation, trailers, limits, early rejection, empty bodies,
backpressure from a blocked consumer, borrowed-byte integrity, disconnect
cleanup and the original application deadline. A further malformed-trailer test
checks that consumed prefixes do not dispatch the final handler on invalid input.

The final ReleaseSafe run passed all 63 build steps and 90 component tests,
plus 20 declaration checks and the wire/embedded/application suites, including
all ten streaming tests. The complete Debug suite also passed; its final
streaming rerun includes the added malformed-trailer case.
ReleaseSafe log,
Debug suite,
final Debug streaming tests.
After separating benchmark observations, the ten streaming tests also passed
with the fixture's default observation mode in
ReleaseSafe and
Debug.
The [final build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/final/build.json; raw artifact retired") freezes the
retained source. The [audit](runs/nginx-implementation.json "Summary of docs/nginx-implementation/audit.json; raw artifact retired") verifies all 48
decision trials plus 18 supplemental instrumented upload trials, actual executable
hashes, source archives, host separation and
request accounting. Expected pressure-test baseline timeouts remain explicit.

Two failed pressure-harness attempts are preserved and excluded: the first hit
the benchmark process's inherited descriptor limit; the second had a blocking
remote socket probe and produced no complete result. The corrected harness uses
an adequate process limit and an explicitly nonblocking probe. Small pressure
and three-second upload smoke runs are diagnostic only. Earlier invalid
same-binary routing results from the review remain excluded.

Rebuild a recorded variant with `bench/build_nginx_variant.py`; receipts contain
the exact Zig command and source archive. Recheck measurement provenance and
accounting with `python3 bench/audit_nginx_implementation.py`.
