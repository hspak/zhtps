The retry policy improves recovery but does not identify or prevent the loss
behind every remaining read timeout. The next experiment should capture
connection evidence before changing another timer or adding response pacing.
The client capture described below is now implemented and validated in a
separate diagnostic binary. It captured nine residual ZHTPS timeouts; server
correlation and pacing remain proposals.
[Diagnostic results](../read-timeout-socket-info.md).

The GET client's two exchange paths close failed sockets immediately:
`worker` in `bench/load/main.go` and `offeredWorker` in
`bench/load/offered.go`. Capture a bounded `TCP_INFO` record immediately before
those closes, after recording the original failure and its finish timestamp.
Successful-request validation, deadlines, failure counts, and generator-miss
accounting must remain identical. Instrumented runs stay separate from decision
measurements because even failure-only observation can delay subsequent work.

Use a fixed process-wide record limit, such as 64. Claim storage only on read
timeouts, without a syscall, allocation, lock, or logging operation on every
successful response. After all workers finish, emit the records together with
the eligible and omitted counts. Preserve the raw returned socket-information
bytes and their actual length; absent fields on older kernels must remain
absent, not silently become zero. A failed probe must remain an observation
error and must not replace the original HTTP failure.

Each record should include:

- Local and remote addresses, connection request sequence, and cumulative
  bytes successfully written on that connection.
- Exchange start, original failure time, capture time, workload phase, and
  whether the client was reading response headers or body.
- TCP connection/congestion state, RTO, backoff, outstanding/unacknowledged
  packets, unsent bytes, total retransmissions, bytes acknowledged, bytes
  received, and time since the last received data and acknowledgement.
- Reader-buffered bytes and the original error, preserving partial-response
  evidence without changing response parsing.

Avoid taking `TCP_INFO` before and after every successful request. Per-socket
cumulative written bytes plus the failure snapshot can establish whether the
request remains unacknowledged. An acknowledged request only establishes TCP
receipt, not application dispatch. Absence of recent received data is compatible
with both a missing server response and response loss; server-side correlation
is still needed. Cumulative retransmissions include earlier exchanges and are
not proof that the last exchange retransmitted.

Before remote use, a local TCP test should send a deliberately incomplete
response, reproduce the read timeout, and verify a record containing the real
tuple, body-read phase, nonempty raw TCP information, and received-byte evidence.
Additional checks should cover a closed socket, record-limit overflow, and
concurrent capture. Existing response and histogram tests remain unchanged.

Aggregate pacing remains the highest-impact architectural hypothesis for
preventing loss. `queueSend` and `queueBatch` prepare work, and the worker submits
it after processing a completion batch. `sent` and `sentBatch` release admission
after local completion. Changing `completion_budget` changes loop batches but
does not impose a packet/time budget across workers or await peer receipt.

nginx provides a compatible scheduling pattern in
`../nginx/src/http/ngx_http_write_filter_module.c`: a delayed write returns to
the event loop and a timer resumes it. Its `limit_rate` accounting is per
request, so directly copying that limit would not bound aggregate bursts across
16,384 connections. For zhtps, a pacing experiment would need a bounded queue
of connection references, preserved response-buffer ownership and write
deadlines, fair service, and cancellation of queued writes. Worker-local
budgets also need staggered release or aggregate coordination to avoid all
seven workers emitting their allowance simultaneously. Waiting for each TCP
acknowledgement would instead serialize on network RTT and needs a different
design and justification.

Record useful throughput, all failure categories, p50/p99, server CPU/RSS,
queue drops, and retransmissions. Rejecting excess requests does not solve the
zero-failure requirement. A hard rate cap also keeps capped-throughput ties
open. Acceptance requires better delivery under the same offered load, with
every cost retained in the comparison.

The r8169 source confirms that its legacy missed-packet counter is only 16
bits and that the ethtool path exports that raw counter. A pair of snapshots
cannot establish how many wraps occurred. Do not repair negative deltas into
an assumed exact loss count or equate this counter with a particular failed
HTTP request. The driver also fixes both descriptor counts at 256.
[Upstream driver](https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/r8169_main.c).
