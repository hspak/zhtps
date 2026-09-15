ZHTPS now matches Go's upload throughput and practical latency on this testbed,
with lower process CPU and RSS in every final upload scenario. Three separate
causes explained the original results: a slow checksum in the benchmark
application, client FQ-CoDel queue collisions behind the doubled saturated tail,
and buffer caches that discarded reusable storage during concurrent bursts.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The retained changes are a benchmark-local hardware IEEE CRC32 port, larger
bounded buffer caches, and one fewer application round trip when a fixed-length
body ends. Five other runtime experiments were reverted after failing to show
material overall improvement. These September 13, 2026 results follow the
[original Go comparison](go-after-nginx.md).

**Final upload results.** Every cell lists **ZHTPS / Go**, using medians across
rotated pairs. All requests validate both body length and an independently
computed checksum; every measured upload succeeded. There are 32 persistent
connections, five seconds of warmup, and 20-second measurement windows for
64 KiB bodies or 30-second windows for 8 MiB bodies.

| Body and load | Repeats per server | Validated MiB/s | CPU µs/MiB | Service p99, ms | RSS, MiB |
|---|---:|---:|---:|---:|---:|
| 64 KiB, fresh connections, saturated | 5 | 279.37 / 279.36 | 315.21 / 547.05 | 8.83 / 13.90 | 16.85 / 23.79 |
| 64 KiB, calibrated distinct queues, diagnostic | 3 | 246.92 / 246.62 | 266.35 / 525.71 | 12.86 / 12.89 | 16.74 / 25.33 |
| 8 MiB, distinct queues, saturated | 3 | 281.60 / 281.60 | 289.72 / 334.46 | 916.40 / 916.14 | 15.00 / 21.27 |
| 8 MiB, fresh connections, paced at 200 MiB/s | 3 | 200.00 / 200.00 | 174.67 / 193.77 | 31.19 / 30.99 | 11.12 / 15.98 |

ZHTPS uses approximately **42%, 49%, 13%, and 10% less process CPU** in those
rows. Its fresh-connection 64 KiB p99 advantage cannot be attributed to the
server: natural queue collisions vary between runs. The controlled small-body
case has nearly identical p99s. Paced large-body p99 is 0.20 ms higher in the
ZHTPS median, with overlapping per-run ranges: 30.61–32.07 ms versus
30.98–31.54 ms. This supports practical latency parity on these short runs,
not a claim that ZHTPS wins every latency comparison.
[Aggregates and individual values](runs/upload-parity.json "Summary of docs/upload-parity/aggregate.json; raw artifact retired").

**Configuration.** The server is `benchmark-server`, `192.0.2.10`, with a Ryzen AI Max+ 395
(16 physical cores, 32 logical CPUs). Load originates on the second host,
`client.example` (`benchmark-client`, `192.0.2.20`, eight physical cores), using client
CPUs 0–7 over the 2.5 Gb/s LAN. Both fixtures use HTTP/1.1 keepalive, without TLS
or access logging. The server applications perform the same length and IEEE
CRC32 work while consuming the body incrementally.

Every Go HTTP run explicitly uses **`GOMAXPROCS=32`**, unrestricted CPU placement,
and normal GC; the harness clears inherited `GOGC`, `GOMEMLIMIT`, and `GODEBUG`.
Go is `go1.27.1-X:nodwarf5`, built with ordinary `go build`. The final ZHTPS
upload configuration uses **one network worker and the entire process pinned
to CPU 9**, including the application threads. It retains three application
lanes with one thread each; uploads use the default lane. There are 256 public
slots and active permits, eight admin slots, a 64 KiB receive buffer, 64 KiB
application scratch, and an 8 MiB body limit. Fixture observation gates are
compiled out. ZHTPS uses Zig 0.16.0 ReleaseSafe, native x86_64_v4.

This compares tuned configurations, without equalizing CPU placement or
reserved capacity. In particular, the original upload comparison used four
ZHTPS network workers and four default-lane application threads. Reducing that
configuration also contributes to the final CPU and memory results; those
gains must not all be credited to the source changes. The
[final commands](runs/upload-parity.json "Summary of docs/upload-parity/final-plan.json; raw artifact retired") and
[build receipt](runs/nginx-implementation.json "Summary of docs/nginx-implementation/upload-parity-final-v2/build.json; raw artifact retired") record
the exact settings, source snapshot, and executable hashes.

**Where CRC32 runs.** The stack is socket/io_uring → HTTP body parser → bounded
application executor → the upload fixture's `Api.consume` → CRC32 update.
The final handler returns the byte count and checksum. Buffered mode calls the
same consumer after buffering; streaming mode calls it as chunks arrive.
Neither the HTTP parser nor ZHTPS's transport computes CRC32. The Ethernet NIC's
frame CRC and TCP's checksum are separate mechanisms.
[Upload consumer](../bench/upload.zig), [application dispatch](../src/endpoint.zig).

The original standalone checksum cost was 1,706.6 CPU µs/MiB in Zig versus 26.5
in Go. The new Zig implementation measures **25.78 versus 25.95 CPU µs/MiB** in
three rotated pairs: approximately 66 times faster than the original Zig
checksum. Both probes process identical bytes in 64 KiB chunks, preserve their
results, and validate them independently with Python's zlib. They run on CPU 9;
the checksum-only Go probe uses `GOMAXPROCS=1`.
[Final microbenchmark records](runs/upload-parity.json "Summary of docs/upload-parity/crc-micro-final.json; raw artifact retired").

The benchmark-local [Zig port](../bench/Crc32.zig) follows Go's carry-less
multiplication folding and reduction, with the
[Go BSD license](../bench/licenses/go.txt). It supports incremental updates,
unaligned inputs, and arbitrary fragment boundaries. It detects PCLMUL support
at runtime; the wide path additionally requires an AVX512 build target and
VPCLMUL support. Portable CRC remains available, including for Zig's native
backend, which cannot encode these instructions in this toolchain. LLVM builds
enable the hardware paths. `-Dupload-fast-crc=false` retains the old benchmark
control. The x86 instruction named CRC32 computes CRC32C, so it cannot directly
replace this IEEE checksum.

**Why some uploads took almost twice as long.** Connection traces located the
extra time in sending the body, with retransmissions and without sustained
receive-window limitation. A serial setup upload allowed the load generator to
observe each socket's FQ-CoDel bucket through read-only `tc` statistics.
Per-socket transmit rehashing was disabled for these diagnostic connections so
the observed mapping remained stable.

In the natural 32-connection ZHTPS run, clients 0 and 18 shared bucket `:23c`.
Each completed only 11 measured uploads and had approximately 1.66–1.69 second
median latency. This run's p99 was 1,804 ms. The corresponding Go run had
32 distinct buckets and a 916 ms p99.
[ZHTPS trace](runs/upload-parity.json "Summary of docs/upload-parity/mapped-natural/n8388608-streaming-1/run.json; raw artifact retired"),
[Go trace](runs/upload-parity.json "Summary of docs/upload-parity/mapped-natural/n8388608-go-1/run.json; raw artifact retired").

A controlled four-connection experiment reproduced the effect in both servers:
four distinct queue priorities gave about 115 ms p99; assigning the first two
sockets to one queue raised p99 to about 200 ms in ZHTPS and 211 ms in Go.
No host qdisc setting was changed. FQ-CoDel hashes traffic into a finite set of
queues and schedules those queues; colliding connections share one queue's
allocation. This mechanism is visible in the
[Linux implementation](https://raw.githubusercontent.com/torvalds/linux/master/net/sched/sch_fq_codel.c)
and described in [RFC 8290](https://www.rfc-editor.org/rfc/rfc8290.html).
[Connection evidence](runs/upload-parity.json "Summary of docs/upload-parity/queue-evidence.json; raw artifact retired").

Controlled 32-connection trials select distinct observed buckets before
warmup. They do not filter measured requests or discard slow results. With that
control, saturated 8 MiB p99 is approximately 916 ms in both servers, consistent
with 32 × 8 MiB sharing roughly 280 MiB/s of payload bandwidth. The original
doubled tail therefore was not evidence that ZHTPS's streaming architecture
needed twice as long to process the body.

Queue observation requires an 8 MiB calibration body per connection. For the
64 KiB diagnostic this creates mixed-size preparation: subsequent goodput is
about 247 MiB/s in both servers, versus 279 MiB/s with homogeneous small bodies.
A factorial check isolates the large calibration upload as the trigger;
disabling transmit rehashing alone preserves 279 MiB/s. The final table keeps
this mixed preparation separate. Large-body queue calibration uses the same
body size as its measured workload.
[Preparation controls](runs/upload-parity.json "Summary of docs/upload-parity/aggregate.json; raw artifact retired").

**The remaining server bottleneck: buffer-cache churn.** After accelerating CRC,
natural 64 KiB runs still produced 64,738–107,104 fresh large-buffer allocations
and 1,036,495–1,714,584 minor page faults during approximately 85,000 completed
requests per sampled interval. Roughly 16 faults per allocation correspond to
touching a new 64 KiB buffer. The pool retained only eight returned blocks,
while 32 concurrent uploads can return and reacquire larger bursts.
[Interval evidence](runs/upload-parity.json "Summary of docs/upload-parity/buffer-cache-evidence-before.json; raw artifact retired").

The permanent wire regression holds 32 body leases using `Expect: 100-continue`,
finishes the burst, and repeats it on the same connections. Before the fix, the
second burst increased allocations from 64 to 112 and the test failed. After
the fix, the unchanged test passes with no new allocations.
Failure before the fix,
passing checks,
[wire regression](../tests/body_streaming.py).

The [cache](../src/server/BufferPool.zig) now retains up to 64 blocks within
4 MiB per size class, while preserving the existing eight-block allowance when
larger blocks exceed that byte limit. It grows on demand. Cached storage is
separate from the unchanged active lease budget, so this increases possible
idle retained memory for small classes. Medium and large size limits have unit
coverage. The tested non-libc ReleaseSafe build uses Zig's default debug
allocator; allocator selection was kept constant in the before/after trials.

Three rotated natural-connection pairs isolate the cache change: median CPU
falls from **688.10 to 317.05 µs/MiB, a 54% reduction**, with unchanged
approximately 279.4 MiB/s. A calibrated pair falls from 698.73 to 269.89 µs/MiB.
Every cache-candidate measurement window, and every final ZHTPS upload window,
has zero fresh buffer allocations and zero minor faults. This connects the CPU
improvement to the eliminated churn, independently of the checksum port.
[Trial counters](runs/upload-parity.json "Summary of docs/upload-parity/trials.json; raw artifact retired").

**Other retained and rejected work.** For a completed fixed-length body, the
executor now runs its last consumer callback and final handler in one task,
removing a worker/executor round trip. It rechecks the absolute deadline between
callbacks; chunked bodies still validate terminal framing and trailers before
dispatching the handler. Deadline coverage verifies that an expired last
consumer cannot run the final handler and that its resources are released.

The isolated confirmation pair, using the old cache in both binaries and the
same application CPU placement, reduces CPU from 684.59 to 665.83 µs/MiB,
approximately **2.7%**, at unchanged throughput and tail latency. Earlier three
pairs also favored the change but had noisier placement. The controlled pair
is a modest estimate, not a claim of the earlier 17% effect in every workload;
its incremental gain has not been isolated on top of the final cache. These
individual improvements are not additive.
[Finalization confirmation](runs/upload-parity.json "Run summaries from docs/upload-parity/final-v2-finalization-confirm; raw artifacts retired").

Opportunistic nonblocking body reads, coalesced completion notifications,
eventfd polling, combined ring submission/waiting, and signaling after unlocking
the application queue were each tested and reverted. Their measurements did
not establish material overall improvement. The
[decision record](runs/upload-parity.json "Summary of docs/upload-parity/decisions.json; raw artifact retired") retains candidate identities
and evidence. Bounded streaming, application isolation, backpressure, body
validation, and deadline checks remain in place.

**GET controls.** The final runtime was checked at 8,192 and 16,384 connections,
with one trial per server at each count. Each has ten seconds of preparation
at 1k or 2k requests/s, followed by ten seconds at 200k offered requests/s.
ZHTPS uses the earlier seven workers on CPUs 9–15, with 4,096 public slots per
worker and `--idle-reclaim-ms 50`; Go keeps `GOMAXPROCS=32`. Cells list
**ZHTPS / Go**.

| Connections | Validated responses/s | CPU µs/response | Service p99, ms | RSS, MiB | Generator drops/expirations |
|---:|---:|---:|---:|---:|---:|
| 8,192 | 197,919 / 197,903 | 4.11 / 22.52 | 0.69 / 5.83 | 609.78 / 268.44 | 20,781 / 20,854 |
| 16,384 | 195,733 / 195,656 | 4.66 / 22.32 | 15.47 / 207.62 | 608.84 / 494.03 | 42,656 / 43,076 |

There were zero HTTP failures. Generator drops and expirations are retained in
the accounting; these are not 200k/s successfully delivered loads. CPU cost is
consistent with the earlier comparison, and ZHTPS still reserves more GET
memory. These short controls do not establish maximum throughput or a durable
tail-latency improvement. In particular, the direct preparation-to-200k schedule
differs from the earlier multi-rate run, and its 16k ZHTPS p99 is higher.
[GET control records](runs/upload-parity.json "Summary of docs/upload-parity/get-controls.json; raw artifact retired").

**Validation and measurement limits.** The final ReleaseSafe check passed
65/65 build steps and 93/93 component/CRC tests, plus 58 base wire tests,
12 streaming tests, three executor tests, declaration compilation checks,
embedded-library checks, and the pool/storage/idle/placement/collector suites.
Debug passed 53/53 steps and 93/93 component/CRC tests, plus the streaming and
executor suites. Standalone CRC tests passed with native Debug, LLVM Debug,
and a generic target. The folding tests cover known vectors, alignment, tails,
wide-path boundaries, and fragmented incremental input.
ReleaseSafe log,
Debug log.

The [audit](runs/upload-parity.json "Summary of docs/upload-parity/audit.json; raw artifact retired") passed for **159 measured upload trials
and four GET controls** across the investigation, including all 34 HTTP trials
in the final plan. Two failed setup attempts are explicitly retained and
excluded, with their original errors; neither is a failed measured request.
The first final matrix was stopped after its active group finished when buffer
churn was identified. Its ten small-body and six large-body trials remain
intact as measurements of the preceding cache policy.
[Pause record](runs/upload-parity.json "Summary of docs/upload-parity/final-v1-pause.json; raw artifact retired").

The audit verifies running executable hashes against frozen receipts, remote
client source/binary identity, separate hosts, Go's HTTP `GOMAXPROCS=32`, exact
length and independent CRC expectations, request accounting, queue controls,
latency summaries, resource samples, final-plan completeness, and current
production/test source hashes. The final upload executable SHA-256 is
`800eace6fe7ab358b9d5238b912403900dcfe0689f1274c7e7b3ea71025260fe`.
Reproduction commands and raw trial paths are in the
[plan](runs/upload-parity.json "Summary of docs/upload-parity/final-plan.json; raw artifact retired"), [auditor](../bench/audit_upload_parity.py),
and [trial summaries](runs/upload-parity.json "Summary of docs/upload-parity/trials.json; raw artifact retired").

CPU is process user plus system time divided by validated payload throughput
over interior measurement samples; it excludes interrupt and softirq work
charged outside the process. RSS is the median of interior samples. Quantiles
are medians of per-trial successful-request quantiles, not pooled distributions.
Closed-loop throughput counts completed requests in a fixed window, while
latency includes draining requests started during measurement; large requests
can cross window boundaries. Transport retransmissions remain present and
recorded even with distinct client queues. Saturated throughput is constrained
by this LAN. These results establish the requested upload parity for these
body sizes and concurrency on this hardware, not general capacity or production
tail guarantees for every ZHTPS workload.
