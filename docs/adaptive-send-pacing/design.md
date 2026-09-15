This isolated candidate extends the discarded fixed-rate prototype with a
shared destination controller. The retained root was verified against all
56 source/build/test/documentation hashes before starting. The previous goal
turn made progress: it completed 18 NAPI decision trials and obtained new
transmit evidence. There is no current external blocker.

Each server has 128 exact address entries, with ports ignored and IPv6 scope
preserved. A final overflow entry shares a budget among excess addresses;
catalog exhaustion never rejects a connection or allocates unbounded storage.
All workers share the same entry for an address. Catalog locking occurs only
on connection attachment and final release. Entries are reused only after
their last reference is gone.

The initial/maximum budget is 500,000 send submissions/s per destination,
with a floor of 100,000 and a burst of four. This limits application send
submissions, not packets or bytes on the wire. A large send can produce many
packets; TCP also generates retransmissions independently. Those limitations
remain part of the experiment and will be evaluated in upload comparisons if
the initial decision supports adoption.

Workers reserve a destination's next credit atomically. Each worker queues
only one reservation per destination head, with further descriptions kept in
a local FIFO. A bitset rotates among ready destination queues, so a waiting
destination does not block another. A reservation cannot extend the shared
calendar more than 100 µs plus its current interval into the future. Failed
bookings do not change it. This bounds abandoned reservations after cancellation
and prevents a full connection queue from reserving seconds of future output.
Existing io_uring pacing wakeups remain part of the measured scheduling cost.

The worker maintains at most 32 sampled connections, chosen from available
slots at accept. It reads four positions on each existing 10 ms tick, so a
full sample set is revisited about every 80 ms. Samples are deterministic,
not random. The TCP_INFO prefix supplies data segments sent, total retransmitted
segments and delivered segments. TCP's data-segment counter includes repeated
transmissions. The controller evaluates retransmissions relative to all sampled
data transmissions, not as an estimated probability that a request failed.
[Kernel counters](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp.c),
[transmission accounting](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp_output.c).

Feedback accumulates for at least 100 ms and 64 sampled data transmissions.
If retransmissions exceed 1%, the controller lowers its rate to the smaller
of 98% of the old limit and 98% of observed application submission rate,
subject to the floor. It waits 500 ms between decreases so existing loss
recovery has time to progress. With no more than 1% retransmissions, at least
32 deliveries, and application submissions at 90% or more of the current
limit, it probes upward by 1% plus 1,000 submissions/s, up to the ceiling.
These constants define a hypothesis to test, not an established optimal policy.

Only the small feedback update uses a try-lock. On contention the worker
keeps its previous TCP baseline, allowing the next sample to include the
unconsumed delta. Counter subtraction tolerates 32-bit wrap. Stale worker
timestamps cannot underflow elapsed time after another worker's update.
Socket read failures increment an explicit error counter. The last rate
gauge refers to the destination most recently sampled by that worker, not
an aggregate rate across all destinations.

Queue descriptions borrow existing response buffers and generations. They
are canceled before buffer or connection reuse. Only submitted operations
increment the kernel pending count. Administrative responses bypass pacing;
HTTP write and client exchange deadlines are unchanged. Sample slots and
destination references are released on normal closure and error cleanup.

The old fixed-mode queue and its existing tests remain intact. An explicit
`--send-rate` selects that mode; zero disables pacing. `--send-feedback`
selects the new mode, which is this candidate's default. Neither experimental
mode has been added to the retained root. Full correctness, actual feedback
activation, and immutable source/binary receipts precede the decision trials.
Every failure, generator miss, latency/throughput/resource regression and tie
must be reported; favorable Go comparisons alone cannot justify a regression
against the retained server.
