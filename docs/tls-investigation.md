# TLS performance investigation and OpenSSL integration review

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

## ReleaseSafe is faster when server CPU limits throughput

The original 8k LAN medians differed by only 0.7% in Debug's favor, with overlapping
trial ranges. At 16k, ReleaseSafe's median was already 0.5% higher. Neither result
established that Debug generates faster code. Both binaries link the same installed
`libssl.so.3` and `libcrypto.so.3`; changing Zig optimization does not recompile those
libraries. The build file passes the requested optimization mode to both the
executable and library module.

A repeated single-server-CPU TLS control demonstrates the optimization benefit.
It uses loopback, four separate physical client cores, two seconds of warmup,
ten seconds of measurement, three rotated repeats, and the same certificate.
All 18 trials have zero setup, warmup, or measured failures and full participation.
Rates below count successful completions inside the fixed window.

| Connections | Debug responses/s | ReleaseSafe responses/s | Go responses/s | ReleaseSafe / Debug |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 155,507 | 300,715 | 181,904 | 1.93× |
| 128 | 96,789 | 304,962 | 170,375 | 3.15× |

Every ReleaseSafe trial beats every Debug and Go trial in this control. This
confirms a CPU-limited TLS advantage, not an unlimited advantage once another
resource limits throughput. [Raw CPU control](runs/standalone.json "Summary of docs/tls-investigation-cpu-control.json; raw artifact retired").

## The three strongest explanations

1. **Network/packet-processing stalls hide faster application processing.**
   The original high-concurrency runs have substantial retransmissions and
   successful p95 around 210 ms. ZHTPS records no admission rejections, refused
   connections, server request timeouts, or TLS protocol errors in those trials.
   NIC byte throughput is well below the nominal 2.5 Gb/s rate, so byte-rate
   saturation alone is not the explanation. Repeated optimized LAN trials still
   have roughly 18% retransmitted/outgoing TCP segments at 16k and p99 around
   438 ms. These host counters do not identify the location or cause of loss.
   The CPU control strongly supports a non-application-CPU limit; exact packet
   loss attribution remains unresolved.

2. **Worker/IRQ placement and traffic timing change the plateau.**
   At inspection, server NIC interrupts land on CPU 24, whose physical sibling
   is CPU 8 in L3 group 1. Client NIC interrupts land on CPU 7, included in the
   original client's 0–7 mask. No IRQ affinity or host sysctl was changed.
   Restricting both servers to CPUs 9–15, then restricting the client to 0–6,
   improves ZHTPS goodput and nearly eliminates its request failures. Go uses
   the same server CPU mask and reports GOMAXPROCS=7 in these controls.
   The first placement screen also lengthens the trial, so its improvement
   cannot be attributed entirely to placement. The client-placement screen
   holds duration and server placement fixed and improves all three servers
   by about 3%, despite removing a client core. That is useful evidence against
   simply assigning every available core to application work.

3. **Short-window variation plus common OpenSSL work reduces visible build differences.**
   Five-second saturated trials are sensitive to retransmission episodes and
   closed-loop traffic bursts. Fifteen-second confirmation still has close
   Debug/ReleaseSafe goodput but substantially different CPU use. Shared OpenSSL
   allocation/encryption costs do not benefit from Zig optimization. An isolated
   record-buffer-retention experiment improves the CPU control only 2.3% and
   does not materially improve LAN throughput. OpenSSL buffer churn is therefore
   a small cost, not a demonstrated cause of the high-concurrency ranking.

## Placement and longer trials improve reliability, not every latency metric

The first two screens retain 32 workers × 1,024 slots and run only 16k clients,
with three-second warmup and ten-second measurement. Confirmation uses eight
workers × 4,096 slots (same 32,768 total public slots), three-second warmup and
fifteen-second measurement, at both connection counts. All use rotated triples.
The eight-worker change also changes per-worker capacity/ring sizing; it is not
a pure worker-count experiment. Separate experiment batches are sequential,
not interleaved factorial comparisons.

| 16k experiment | Debug responses/s | ReleaseSafe responses/s | Go responses/s |
| --- | ---: | ---: | ---: |
| Original unrestricted, 5 s | 294,416 | 295,979 | 311,013 |
| Server CPUs 9–15, client 0–7, 10 s | 317,010 | 318,070 | 314,810 |
| Server CPUs 9–15, client 0–6, 10 s | 326,815 | 327,011 | 324,314 |
| Same placement, eight workers, 15 s | 325,485 | 327,423 | 324,014 |

Longer confirmation results (CPU is percent, 100% = one logical CPU):

| Connections | Server | Responses/s | Successful p50 ms | Successful p99 ms | Server CPU | Warmup / measured failures |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 8,192 | Debug | 359,750 | 4.784 | 219.152 | 312.0 | 0 / 0 |
| 8,192 | ReleaseSafe | 358,767 | 4.850 | 220.201 | 202.1 | 0 / 0 |
| 8,192 | Go | 366,368 | 3.932 | 219.152 | 318.6 | 37 / 93 |
| 16,384 | Debug | 325,485 | 8.520 | 438.305 | 334.8 | 1 / 0 |
| 16,384 | ReleaseSafe | 327,423 | 8.389 | 438.305 | 232.3 | 0 / 2 |
| 16,384 | Go | 324,014 | 8.028 | 438.305 | 326.8 | 693 / 2,023 |

Failure counts sum three trials and classify by request start phase, including
drain. Fixed-window failures remain separately recorded. All requested connections
participate in every placement/confirmation trial; setup errors are zero.
Latency percentiles exclude failures. The higher p50 versus the original run
is a real tradeoff, not hidden by the throughput improvement.

ReleaseSafe is 2.1% behind Go at 8k and 1.1% ahead at 16k by median goodput.
This is close throughput with much lower failure counts and CPU use, not a
definitive across-the-board throughput win. It also does not establish zero-error
capacity or an offered-rate latency guarantee.

Evidence: [server placement](runs/standalone.json "Summary of docs/tls-investigation-server-placement.json; raw artifact retired"),
[client placement](runs/standalone.json "Summary of docs/tls-investigation-client-placement.json; raw artifact retired"),
[confirmation](runs/standalone.json "Summary of docs/tls-investigation-worker-confirmation.json; raw artifact retired"),
[audit and network deltas](runs/standalone.json "Summary of docs/tls-investigation-lan-audit.json; raw artifact retired").

## OpenSSL fits the ownership model, with two performance tradeoffs

**The transport boundary is appropriate.** `Tls.Session` owns SSL and a BIO pair;
OpenSSL never owns the socket or performs blocking socket I/O. `advanceTls` turns
the next SSL requirement into an io_uring receive/send using borrowed BIO storage.
`receivedTls`/`sentTls` commit only completed bytes. `finishClose` waits for pending
operations before freeing session storage, including cancellation completions.
The existing application, admission, timeout and shutdown paths remain in use.
Output flushes on WANT_READ, avoiding the BIO-pair handshake deadlock.

Waiting for ciphertext send completion before reporting plaintext completion
preserves response-buffer and permit lifetimes. Simply completing the response
when SSL accepts plaintext would invalidate those contracts. Socket-boundary
BIO borrowing avoids extra staging copies, but OpenSSL still copies between
its record buffers and BIO rings; this is not end-to-end zero-copy TLS.

**Record-buffer release trades memory for allocation work.** The current
`SSL_MODE_RELEASE_BUFFERS` may free/reallocate record storage on each active
keepalive exchange. A candidate removing only this mode was built in an isolated
source tree, with a separate cache. Three rotated baseline/candidate pairs:

| Workload | Current responses/s | Retained-buffer responses/s | Change |
| --- | ---: | ---: | ---: |
| One server CPU, 128 loopback clients | 304,667 | 311,619 | +2.3% |
| NIC-local, eight workers, 16k remote clients | 326,425 | 326,680 | +0.08% |

All measured errors were zero; baseline LAN warmup errors sum to four and candidate
LAN warmup errors to one. OpenSSL documents about 34 KiB of idle record-buffer
savings per connection: retaining buffers can add roughly 544 MiB at 16,384
connections, separate from the already-owned 36 KiB BIO-pair capacity per session.
This is an allocation-size estimate, not measured RSS. The tiny LAN result does
not justify changing the default. The candidate was not applied to server source.

[Buffer experiment](runs/standalone.json "Summary of docs/tls-investigation-buffer-policy.json; raw artifact retired"),
one-line candidate patch,
source archive,
[build receipt/accounting](runs/standalone.json "Summary of docs/tls-investigation-retain-build.json; raw artifact retired").
OpenSSL references: [release-buffer mode](https://docs.openssl.org/3.6/man3/SSL_CTX_set_mode/),
[BIO pairs](https://docs.openssl.org/3.6/man3/BIO_s_bio/),
[SSL reads](https://docs.openssl.org/3.6/man3/SSL_read/).

**Record boundaries limit pipeline aggregation.** `queueBatch` supports TLS, but
`aggregate` sees only decrypted bytes in the connection receive buffer. With forty
GETs in one TLS record, a real-wire probe records three batches covering all forty
responses. With the same forty GETs in forty records, flushed together, it records
zero batches. All eighty responses validate. This is a concrete optimization gap
for pipelined TLS traffic, but the high-concurrency comparison has no pipelining,
so it cannot explain its Debug/ReleaseSafe result.
The right candidate is bounded coalescing of already-buffered plaintext records
before HTTP parsing, without waiting for another socket read, delaying responses,
or violating SSL/BIO in-flight ownership. It needs separate pipeline latency,
fairness, fragmentation, cancellation and deadline tests before adoption.
[Record-boundary probe](runs/standalone.json "Summary of docs/tls-investigation-record-batching.json; raw artifact retired").

The shared allocator lock encloses session creation, not steady-state reads/writes.
It is worth profiling for handshake/churn load, but the current benchmark completes
initial handshakes before measurement. It is not evidence of per-request serialization.

Both current Debug and ReleaseSafe builds pass all 27 TLS tests, including the
embedded application fixture. The isolated candidate passes the 23 standalone
tests; four fixture-dependent cases are skipped for that executable.
Debug tests,
ReleaseSafe tests,
candidate tests.
These checks support correctness; they do not prove globally optimal integration.

## Strategy and remaining goals

1. Keep the CPU-limited control as a separate acceptance test: it establishes
   ReleaseSafe's large advantage without a lossy LAN obscuring it. Do not weaken
   Debug or remove ReleaseSafe safety checks to force saturated-network rankings.
2. Prefer the tested NIC-local CPU placement for further LAN work. Reconfirm IRQ
   location each time. Use matched masks and client budgets for Go controls.
   Eight versus 32 workers has not established a compelling throughput difference.
3. Before speculative transport changes, extend the offered-rate client to TLS
   and ramp through below-saturation rates with all 8k/16k connections established.
   Capture per-host NIC drops, softnet counters, IRQ CPU, retransmission timing,
   and phase-aligned server CPU. This distinguishes packet loss, generator limits,
   and server service cost. Packet captures or kernel profiling may require an
   additional privilege grant; this investigation changed neither sysctls nor IRQs.
4. Test decrypted-record coalescing separately on pipelined workloads. Retain the
   current record-buffer memory policy unless a CPU-bound deployment explicitly
   values the small gain more than the additional idle memory.

Goal 1 is confirmed for CPU-limited throughput and LAN CPU efficiency, not for
strictly greater goodput at every saturated-network point. Goal 2 is close on LAN
throughput and better on observed failures/CPU, but a definitive throughput win
over Go at both 8k and 16k remains unproven. No production performance change is
retained from this investigation.

To reproduce the LAN confirmation, use the original TLS LAN command with
`taskset -c 9-15` before Python, `--client-cores 7 --zig-workers 8`,
`--zig-max-connections 4096 --zig-max-active 4096 --duration 15 --warmup 3`,
and a fresh output path. The screens use 32 workers/1,024 slots, ten seconds,
16,384 clients, and eight then seven client cores. Raw reports retain all server
and client commands, source/executable hashes, repetitions and individual outcomes.
