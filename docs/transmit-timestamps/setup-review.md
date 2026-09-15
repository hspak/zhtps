This diagnostic extends the earlier paired TCP observations to the transmit
path. It is an isolated build from retained `tcp-retries-v1`, with a socket
option set before the first receive on public accepted descriptors divisible
by sixteen. It records scheduler, driver and cumulative-ACK timestamps with
TCP byte IDs and empty notification payloads. The real-socket controls verify
the IDs and distinguish these events; the independent C program checks the
Python decoder's constants and layouts against installed Linux headers.
Patch, [build receipt](../runs/nginx-implementation.json "Summary of docs/nginx-implementation/tx-timestamps-v1/build.json; raw artifact retired"),
decoder tests, [UAPI values](../runs/transmit-timestamps.json "Summary of docs/transmit-timestamps/uapi.json; raw artifact retired").

> Artifact retention: [Run summaries and setup records](../runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The diagnostic uses SO_TIMESTAMPING_NEW, OPT_ID_TCP and OPT_TSONLY. Linux
exposes transmit notifications through MSG_ERRQUEUE; reading that queue leaves
normal request bytes intact. A software driver timestamp precedes handing the
packet to the NIC, and does not establish physical delivery. Byte IDs allow
matching events even if their collection order differs. Stream coalescing and
notification loss can leave gaps; an absent event alone cannot establish the
packet's fate.
[Kernel timestamp API](https://docs.kernel.org/networking/timestamping.html),
[flag definitions](https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/net_tstamp.h),
[notification layout](https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/errqueue.h).

The inspected upstream r8169 transmit path calls skb_tx_timestamp after DMA
mapping and before releasing descriptor ownership to the NIC. That is the
source-level boundary used in the interpretation. The actual LAN control
independently verifies that the running driver produces these events.
[Driver implementation](https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/r8169_main.c).

The parent uses pidfd_getfd only on its own child server. It keeps at most
2,048 duplicate sockets and 64 events per socket, scans every 250 ms for
descriptor reuse, and closes duplicates on peer shutdown or when the child
descriptor disappears. A duplicate extends the kernel socket's lifetime;
this is a diagnostic cost. MSG_DONTWAIT avoids changing shared descriptor
flags. Exact local/remote tuple, inode and cookie must match before records
are attached to a timeout query. No host network configuration changes.
Collector, wrapper.

The LAN control uses 64 connections from the second host and validates 8,192
responses. Four sockets were sampled, each with exactly 128 scheduler, driver
and ACK events, the expected final byte ID, and no ID gaps or reordering.
Each per-socket history stopped at its 64-record bound. All seven workers
completed requests, incorrect inode/cookie lookups were rejected, and every
duplicate was closed after the peer closed. The server and remote process
both exited successfully. Earlier setup events can remain in the kernel
queue until the first collector scan; collection time is kept separately
from event time.
LAN observations.

A subsequent control also queries those live sockets through netlink and
successfully matches their returned tuple, inode and cookie to the collector.
Netlink matching control.

A separate disposable network namespace deliberately drops response packets
at the receiver. The warmed TCP connection generates four scheduler and
four driver events for the same missing 145-byte range, while the receiver
gets no bytes and there is no ACK event. The firewall counter independently
confirms four drops. Removing the rule allows recovery and an ACK for that
same byte range. Thus repeated IDs are valid retransmission evidence, and a
driver timestamp does not imply delivery. Namespace isolation is asserted;
the host firewall is untouched. The earlier permanent timeout regression
has not been modified.
Controlled loss observations,
control source.

The isolated server passed the complete ReleaseSafe suite: 65 build steps,
97 Zig tests, 59 wire tests, and the library, application and upload/streaming
checks. The two diagnostic workloads retain the original two-second deadline
and response validation. Timestamp collection consumes CPU and kernel queue
memory, and the existing timeout observer delays failed-socket cleanup by at
most 150 ms after the failure is counted. None of these runs can support a
performance adoption decision. The deterministic descriptor sample is not
a random sample of failures. Notification gaps, collector capacity limits,
uncaptured failures, and cross-host clock uncertainty must remain explicit.
Full test log, frozen diagnostic sources,
[diagnostic plan](../runs/transmit-timestamps.json "Summary of docs/transmit-timestamps/plan.json; raw artifact retired").
