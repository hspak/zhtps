# Performance strategy composition review

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

This review examines the live implementation, its ownership boundaries, and the
existing experiment reports together. It is a source and regression review,
not a new throughput benchmark. Percentages below belong to their original
controls and must not be added together. Historical snapshots under `docs/`
and downloaded packages are evidence, not additional production implementations.

The core architecture is worth retaining. Its largest additions buy substantial
memory savings or serve distinct workloads. There is no identified strategy
adding thousands of lines solely for a demonstrated one-percent improvement.
However, two interactions were broken, and several historical performance claims
no longer describe the current source. Both broken interactions are fixed here.

## Confirmed interactions and fixes

### Aggregation could discard earlier successes when rejection had no permit

With `--max-rejecting 0`, send three valid GETs followed by a malformed header in
one pipeline. Ordinary sends delivered the three successful responses. With
aggregation enabled, `reject` closed the socket and aborted the unsent aggregate;
the client received an empty EOF.

The earlier rate-limit regression covered the pre-head exhaustion shortcut, but
not this protocol-error path. Admission and aggregation were each bounded, yet
their combination changed externally visible response delivery.

The fix flushes the existing batch before closing. Its pending `.close` decision
prevents both `MSG_MORE` and resuming an invalid parser. After send completion the
existing bounded TCP drain handles closure. This uses the existing permit and
completion machinery; it adds no allocation, queue, flag, or new lifecycle type.
Success accounting remains at send completion, and the failed request's abort
accounting occurs when the drain finishes.

The permanent test compares aggregation enabled and disabled, checks response
order, and checks success/abort accounting. It fails unchanged against the
pre-fix worker and passes after the fix:
[response aggregation tests](../tests/response_aggregation.py).

### Rejected requests could consume body-buffer resources

`processInput` promoted trailer and receive buffers before acquiring admission.
A rejected chunked request therefore borrowed an 8 KiB trailer buffer and retained
it through connection drain. With no large-buffer budget, it instead took the
buffer-exhaustion path before the ordinary admission rejection was counted.
Larger configured receive buffers had the same ordering problem.

Body-buffer promotion now follows successful public admission. Admin storage
already has full capacity. Header parsing and normalization still precede
admission; those are separate bounded costs, not a claim that rejection is free.

The permanent wire test holds the only active permit with an accepted body, then
sends a chunked request with `Expect: 100-continue`. It checks a final 503, no body
allocation or buffer exhaustion, correct rejection accounting, and successful
completion of the accepted request. Both available-budget and zero-budget cases
fail on the pre-fix worker and pass unchanged after the fix:
[buffer pool tests](../tests/buffer_pools.py).

## Strategy inventory and decisions

| Strategy in current source | Interaction and implementation assessment | Evidence and decision |
|---|---|---|
| Worker-owned rings, sockets, permits, indexed completion tokens, free lists | Establishes the ownership used by every later optimization. Application lanes share work, but socket and permit ownership stay local. Moving sockets or globalizing permits would add a different synchronization problem. | Keep. The [architecture assessment](architecture-implementation.md) found no measured reason for a global transport redesign. |
| Small submission queue, conservative completion capacity, cooperative task work, completion budget 64 | Submission batching amortizes ring entry; completion capacity protects outstanding receive/send/cancel lifetimes. Queue sizes address different lifetimes and should not be collapsed to one limit. | Keep. [Architecture review](architecture-review.md) and [kernel experiments](kernel-work.md) do not justify multishot, SQ polling, or smaller cancellation bounds in this implementation. |
| NIC/cache-aware worker placement | Reduces interference with IRQ work. Executors start before transport pinning and retain the inherited mask; pinning the entire process externally can still constrain both. | Strong return for small transport changes. Matched placement saved 22.3% process CPU and 42% p99 at 200k/s. Keep the topology-aware launcher; results remain host-specific. [Evidence](architecture-review.md). |
| Large-buffer pools | Grow storage only when needed; return it after ownership ends. Receive storage survives unread pipeline bytes and pending I/O. Admission ordering needed the fix above. | Keep. Original RSS fell 4,864 to 946 MiB; CPU was essentially neutral. [Evidence](architecture-implementation.md). |
| Request leases separate from connection slots | Idle sockets release parser/exchange storage while retaining receive buffers. Running application hooks and response lifetimes prevent early reuse. | Keep. About 36% lower RSS and 6–12% less CPU in the original matched-rate tests. [Evidence](nginx-implementation.md). |
| Common buffers acquired on acceptance | Saves reservation for unused slots, with a bounded warm cache. Misses and eviction serialize allocator access across workers. This deliberately trades CPU for memory. | Keep for memory: roughly 60% lower RSS at 8k versus the prior layout, with a measured 3–5% GET CPU cost. Do not call it a CPU speedup. [Evidence](go-performance-followup.md). |
| Larger returned-buffer caches | Reduces allocation/page-fault churn independently of when live leases are released. Uses the existing `BufferPool`, also shared by common connection buffers. | Keep. Isolated small-upload CPU fell about 54%. Cached bytes are additional to the active large-buffer budget, per pool and per worker. [Evidence](upload-parity.md). |
| Buffer-start padding | Separates buffer starts within a common allocation. The old odd-stride argument across a contiguous array is weaker now that public sets are allocated separately. | Retain the small implementation provisionally; do not attribute the old 1.5–7.8% CPU gains to today's allocator layout. Original [padding trials](request-footprint.md); subsequent [layout change and rejected offset variant](go-performance-followup.md). |
| SIMD head scan and field validation | Framing scan stops at CR/LF and checks incremental boundaries; field validation checks a different grammar. Narrow tails handle short input without a second parser or divergent fallback semantics. | Keep the small implementation. The earlier narrow-path evidence is useful, but the 64-byte AVX-512 paths have no isolated v4-versus-v3 result in [the SIMD report](simd.md). The platform restriction needs stronger evidence than a parser microbenchmark alone. |
| Token-bucket arithmetic, owner-thread metric updates, cached Date, timestamp reuse | Small optimizations with shared arithmetic and explicit clock/ownership contracts. Application metrics remain concurrent; transport recording remains on its owner. No new clock approximation or metric flush queue. | Keep. These are tens-of-lines changes, not architectural complexity. Do not multiply component percentage gains into whole-server throughput. [Evidence](critical-path-experiments.md). |
| Tiny-body copy and vectored header/body sends | Small bodies share one serialized send; large borrowed bodies avoid a second body copy using stable iovecs. Partial completions advance the two regions independently. TLS instead feeds bounded plaintext slices to its session. | Keep. The original matched echo CPU reduction was about 17%; direct encoding contributed a smaller GET gain. [Evidence](request-path-remaining.md). |
| Bounded synchronous stream-fragment gathering | Combines producer fragments within one response; keeps a deferred fragment borrowed when it does not fit. Its 16-call bound also limits transport-thread work. | Keep. Original demo-stream CPU reduction was 41–50%. This does not measure arbitrary producers. [Evidence](request-path-remaining.md). |
| `MSG_MORE` pipeline coalescing | Reduces packet formation across responses. Explicit flush before receive waits avoids delaying previous output behind an incomplete next request. | Keep, with the recorded fragmented-input CPU cost. Original complete-pipeline throughput rose 2.36–2.55 times. [Evidence](request-path-remaining.md). |
| Owned response aggregation | Reduces sends/completions across distinct requests. Must compose with packet coalescing, retained permits, oldest deadlines, logs, and parser reset. The highest maintenance burden among the narrow transport optimizations. | Keep, scoped to the built-in exchange. About 34–43% higher throughput and 28–30% less CPU with ample permits; ordinary-budget results were near neutral. This is a few hundred lines of mechanism and substantial regression coverage, not thousands for 1%. [Evidence](response-aggregation-integrated.md). |
| Shared bounded application lanes and inline generated heads | Shared queues address scheduling skew while transport ownership remains local. Inline work is allowed only when there is no user middleware callback. User handlers/consumers remain on executor threads. | Keep. Original fast-handler CPU fell 20%; mixed-handler p99 fell 83%. Queueing, deadlines, and cleanup are necessary application isolation, not optional instruction shaving. [Evidence](architecture-implementation.md). |
| Streaming request bodies and final fixed-length task fusion | Streaming avoids retaining the entire body, and pauses receives while a consumer borrows input. Fusion removes one final queue round trip; it checks the absolute deadline between consumer and handler. Chunked framing still validates trailers before final dispatch. | Keep. Streaming bought 75–88% lower upload RSS. Fusion's isolated 2.7% CPU gain has weaker evidence, but adds only a small stage/dispatch branch and reuses existing machinery. [Streaming](nginx-implementation.md), [fusion](upload-parity.md). |
| Log writev batches and bounded queue | One formatter feeds a fixed queue; a partial write retains a fixed prefix and global sink ownership. Batch size limits one worker's hold on a shared log sink. | Keep batches of 16. Earlier tests found about one-third less logged CPU; increasing to 64 had no reliable benefit. The former specialized access formatter is absent from current `Logger.writeRecord`. [Earlier batching](critical-path-experiments.md), [64-record experiment](architecture-implementation.md). |
| Active-slot deadline scans, optional idle reclamation, final shutdown window | Scans visit live slots; the idle list tracks a narrower eligibility policy. Neither should release request/application/I/O storage prematurely. The shutdown window is a correctness/lifetime policy. | Keep simple scans and opt-in reclamation. A timer wheel is unjustified by the measured small idle CPU cost. Reclamation helped new peers but raised returning-client p99, so its default stays off. [Scan evidence](request-path-remaining.md), [keepalive evidence](keepalive-policy.md). |
| Thin-stream retries | A listener socket option affects loss recovery; it neither replaces request deadlines nor requires a userspace retransmission scheduler. | Keep the escape hatch to system policy. The unchanged six-packet-loss regression recovered within its two-second deadline. More retransmission traffic and residual failures remain. [Evidence](tcp-read-timeout-mitigation.md). |
| TLS BIO bounds, shared credentials and resumption cache | Reuses transport lifetimes, buffer pools, admission, and HTTP serialization. OpenSSL owns cryptographic buffers and resumption; no second homemade session/cache implementation is present. | Keep for feature correctness and bounded ownership. GET performance comparisons explicitly excluded TLS, so they establish no TLS performance advantage. [Design and tests](tls.md). |
| Hardware CRC and sparse client histograms | CRC belongs to the upload fixture; histograms belong to the load generator. Neither duplicates transport behavior or speeds ordinary GET parsing. | Keep them outside the core. CRC was about 66 times faster in its microbenchmark; sparse histograms fixed generator memory pressure. [CRC](upload-parity.md), [generator](go-performance-followup.md). |

## Where similar code is justified

- **Three output batching mechanisms have different units.** Stream gathering
  combines fragments of one response; owned aggregation combines complete
  responses and their permits; `MSG_MORE` affects TCP packet formation. Their
  original interaction did cause a packet-count regression, which the retained
  coalescing gate corrected. One generic batch object would mix incompatible
  ownership and completion rules.
- **Ordinary and aggregate completion accounting differs deliberately.** Ordinary
  completion still owns parser/exchange metadata and may invoke custom cleanup.
  Aggregate completion owns copied metadata and several independent permits.
  Sharing the lifecycle wholesale would erase that distinction. Shared metric
  primitives, logging serialization, and permit release already avoid duplicating
  the low-level implementation.
- **Byte pools already share an implementation.** Common connection buffers and
  large buffers both use `BufferPool`. Typed request leases additionally own
  parser/exchange initialization and admin reservation; aggregate objects own
  fixed completion records. A universal allocator/pool abstraction would add
  indirection and policy parameters without an identified memory or CPU win.
  Header and output pools with equal configured sizes remain separate caches;
  there is no measured benefit that justifies cross-role cache sharing yet.
- **Framing and syntax scans are not duplicate validation.** The incremental scan
  finds safe boundaries; `Request.parseHeader` validates field grammar and
  semantics. Preserve one semantic parser. The small repeated vector-width and
  lookahead expressions do not justify a scanning framework or persistent scan
  cache with additional invalidation rules.
- **Generated and built-in applications need different execution paths.** The
  built-in exchange has bounded synchronous hooks and can discard its request
  object after copying response metadata. Generated hooks can block and retain
  scratch through cleanup. Generalizing built-in batching to them needs an
  explicit ownership design and a demonstrated workload benefit.

## Complexity and remaining decisions

The worker is the main maintenance hotspot because many strategies change the
same request transitions. At review entry it contained roughly 3,000 lines before
its test section and another 950 lines of tests. Most of that is HTTP/TLS,
application execution, diagnostics, shutdown, and cancellation; it is not one
optimization. Formatting changes during this review increased physical line
counts without changing that assessment.

The best next complexity reduction is to keep future changes within these
ownership boundaries and add interaction regressions when a boundary changes.
Moving the bounded executor to a concern-specific module could improve navigation,
but is not a measured runtime improvement and is not required for these fixes.
Do not delete cancellation, slow-reader, or borrowed-buffer coverage to reduce
line counts.

Three measurement questions remain, in priority order:

1. **Measure the current padding and v4 restriction.** The padding's allocation
   topology changed, and the SIMD evidence predates AVX-512. These are the weakest
   current attributions. Any removal or target-policy change should compare the
   current tree with one change at a time, using short/long/fragmented heads and
   whole-server CPU and tails. The old percentages cannot settle that decision.
2. **Measure aggregation only where it can activate.** The final LAN GET matrix
   has one outstanding request per connection and does not demonstrate pipeline
   aggregation's benefit. Its strongest evidence remains one-worker loopback with
   ample permits. Multiworker physical pipelines, TLS, and logged aggregation are
   unmeasured combinations; correctness tests alone do not establish speedups.
3. **Treat cache limits as a combined memory budget.** The active large-buffer
   budget excludes returned caches, common buffers, request objects, batches,
   kernel sockets/rings, and OpenSSL. A pool can retain eight large blocks even
   beyond 4 MiB. Multiply by pool and worker counts when sizing deployments.
   Current metrics distinguish the principal application-owned pools. A global
   cache coordinator is unwarranted without evidence of unacceptable retained RSS.

No new pacing, polling, multishot, zero-copy, timer-wheel, or generic pooling
machinery was introduced. The previously rejected experiments remain rejected on
their recorded CPU/latency/ownership tradeoffs, not merely on source length.

## Documentation and verification

Historical reports are preserved as experiment records. In particular, old
“no per-request allocation” claims predate leased storage with cache misses;
old connection sizes predate request separation and on-accept buffers; the old
specialized log formatter is no longer in the current source. The performance
summary now points here to distinguish historical evidence from this inventory.
The README's obsolete denial of shared application queues is corrected.

The ReleaseSafe validation command is:

```sh
zig build test test-library test-wire test-application test-upload test-tls \
  test-crc test-deploy -Doptimize=ReleaseSafe --summary all
```

It passed all 72 build steps and 98 top-level Zig tests, as well as the embedded
consumer and all Python TCP, TLS, application, streaming, and deployment suites.
`git diff --check`, `zig fmt --check src/server/worker.zig`, and Python compilation
of the two changed test modules also passed.

The [validation receipt](runs/performance-strategies-review.json "Summary of docs/performance-strategies-review/validation.json; raw artifact retired"),
full suite log, and
[before/after regression logs](runs/performance-strategies-review.json "Summary of docs/performance-strategies-review; raw artifact retired") preserve the
commands and results. Concurrent workspace edits continued during verification,
so the final suite runs from a frozen source snapshot. Source hashes identify
that snapshot, which also contains unrelated user work; this review does not
claim those changes or validate later edits to the live workspace.
The sandbox blocks `io_uring`, so live-server checks require execution outside
that restriction. Tests were rerun after unrelated concurrent workspace edits
temporarily introduced syntax errors; those edits were preserved.
