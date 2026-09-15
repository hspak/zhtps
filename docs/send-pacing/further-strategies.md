These follow-ups are ordered by relevance to the paired residual-timeout
observations. They are hypotheses for separate experiments, not measured gains.
The retained listener retry policy is already implemented and is excluded here.

1. **Pace output across connections, with a bounded queue.** The first isolated
   fixed-rate prototype was tested and discarded from adoption after 24 runs
   because its modest timeout benefit did not justify its costs. It limits each
   worker's send submissions over time. A further design could adjust that budget from a
   bounded sample of TCP delivery/retransmission feedback, rather than selecting
   one fixed rate for every deployment. The simple prototype provides no basis
   for assuming an adaptive design would win; it needs an independently
   justified experiment. It must preserve write deadlines and expose queued time;
   replacing read timeouts with rejected or indefinitely queued requests would
   not meet the goal. Neither a per-flow pacing setting nor the current
   completion-batch limit by itself coordinates output across thousands of
   independent connections. Linux's ordinary TCP pacing uses per-socket
   transmission timing.
   [TCP output implementation](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp_output.c).

2. **Test bounded io_uring NAPI busy polling.** This is an additional source-review
   finding beyond the existing IRQ-placement/RPS discussion. Kernel support can
   let a ring's worker service incoming packets without waiting for an interrupt.
   It fits the current worker/ring ownership model without changing the HTTP
   parser or response contract. Start with a small explicit polling interval,
   verify that the relevant NIC's NAPI ID is actually being polled, and account
   for total host CPU and idle cost. The server and client must be tested
   separately: the 17 observed failures involve response delivery, so server
   receive polling alone may miss the bottleneck. Multiple workers share a
   single hardware queue on these hosts, which may introduce contention.
   The source review establishes availability of an API, not benefit on these
   machines or support of every optional mode.
   [Kernel NAPI documentation](https://docs.kernel.org/networking/napi.html),
   [io_uring registration and polling](https://raw.githubusercontent.com/torvalds/linux/master/io_uring/napi.c).

3. **Test ECN with participating clients and queues.** Already considered, but
   not implemented or measured here. The recorded hosts accept incoming ECN
   negotiation but do not request it on outgoing connections. Marking can let
   congestion control react before some active-queue-management drops, when the
   actual connection negotiates it. It cannot recover packets already dropped
   by a full hardware ring, and ordinary server code cannot compel arbitrary
   clients to participate. Verify negotiated TCP flags and nonzero queue marks;
   run the same deployment configuration against Go. Host-wide configuration
   should remain an explicit deployment experiment.
   [Prior evidence and ECN review](../read-timeout-mitigations.md),
   [Kernel ECN settings](https://kernel.org/doc/html/latest/networking/ip-sysctl.html).

A maximum-RTO cap was also reviewed as a possible way to bound the tail after
thin retries are exhausted. The current Linux `TCP_RTO_MAX_MS` setter rejects
values below 1,000 ms. That rules out the proposed 200–400 ms cap through this
API. A one-second cap is not established as useful for the unchanged two-second
exchange deadline; no candidate was implemented from that hypothesis.
The earlier minimum-RTO reduction remains discarded because its measured
retransmission pressure and failures were worse.
[Linux socket validation](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp.c),
[negative minimum-RTO experiment](../read-timeout-rto50.md).

Before attributing individual residual failures to a particular queue, the
next diagnostic should correlate a bounded TCP-sequence/drop trace across the
server output and client input paths. Current paired socket observations prove
that responses were outstanding, but do not locate drops. Any tracing overhead
must stay in diagnostic runs and out of the performance decision ledger.
