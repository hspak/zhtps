The paired client/server observations locate all 17 captured residual ZHTPS
read timeouts on the response-delivery path. At the server snapshot, each
request had been consumed, the complete 145-byte HTTP response had been sent
into TCP, no response bytes remained unsent, and those 145 bytes were still
unacknowledged. The client had received only earlier responses. This supports
loss and retransmission recovery as the next mitigation target; it does not
identify the physical or software queue where a packet was lost.
[Paired audit and individual observations](runs/server-timeout-correlation.json "Summary of docs/server-timeout-correlation/paired-audit.json; raw artifact retired").

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

These are four diagnostic runs on September 13, 2026, using the retained
`tcp-retries-v1` server, seven workers on CPUs 9–15, the second load host on
CPUs 0–7, and Go with GOMAXPROCS=32 and normal GC. There are two workloads at
16,384 connections: an offered schedule ending in 60 seconds at 300k/s, and a
60-second saturated measurement after two seconds of warmup. The original
two-second exchange deadline and full response validation remain in force.
No server source or host network setting changed for this observation.
[Plan](runs/server-timeout-correlation.json "Summary of docs/server-timeout-correlation/plan.json; raw artifact retired"),
[four-run provenance and accounting audit](runs/server-timeout-correlation.json "Summary of docs/server-timeout-correlation/audit.json; raw artifact retired").

| Diagnostic run | Read failures eligible for capture | Captured | Request unread / response outstanding at every capture |
|---|---:|---:|---:|
| ZHTPS, offered | 14 | 14 | 0 / 145 bytes |
| ZHTPS, saturated | 3 | 3 | 0 / 145 bytes |
| Go, offered | 7,642 | 64 | 0 / 145 bytes |
| Go, saturated including warmup | 4,183 | 64 | 0 / 145 bytes |

The recorder keeps the first 64 read failures, not a random sample. All 64
captured Go saturated failures belong to warmup; the measurement itself has
3,788 read failures by request-origin accounting. The 4,183 eligible failures
include 395 warmup errors. These categories must not be combined with the
separate completion-window failure counts. All captured ZHTPS failures belong
to the intended high-load measurement. Go offered also has 189 dial timeouts;
Go saturated has 83 measured dial timeouts. ZHTPS has no other HTTP failures
in these runs. Diagnostic throughput and latency are excluded from performance
decisions because observation delays failed-socket cleanup.

The observations verify more than an empty receive queue. For each connection,
server TCP bytes received equal every request byte written by the client.
Server bytes sent minus retransmitted bytes equal the request count multiplied
by 145; acknowledged response bytes and client received bytes both equal the
previous request count multiplied by 145. `notsent_bytes` is zero. All 17
ZHTPS requests were also fully acknowledged at the client, and all failures
occurred while reading headers. No additional response data arrived during any
of their follow-up probes.

Linux reports a connected TCP socket's receive queue as received sequence
space not yet copied to userspace, and its write queue as written sequence
space not yet acknowledged. The observer rejects returned tuples that differ
from the requested established socket; an exact lookup can otherwise fall back
to a listener. The raw netlink reply, TCP_INFO bytes, socket inode, tuple, and
server executable hash are preserved alongside decoded fields.
[Linux diagnostic implementation](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp_diag.c),
frozen observer.

Fourteen of the 17 ZHTPS sockets have a current consecutive timeout-retry count
of seven or eight, with exponential backoff already active. The remaining
three have counts of four, five, and six. These counts are distinct from total
connection retransmissions and do not count every possible loss probe.
The retained thin-stream policy provides bounded linear retry intervals;
it eventually returns to exponential backoff. Residual failures show that
improved recovery does not eliminate the need to prevent loss.
[Linux retransmission timer](https://raw.githubusercontent.com/torvalds/linux/master/net/ipv4/tcp_timer.c),
[retained policy and decision measurements](tcp-read-timeout-mitigation.md).

The client records failure time and TCP_INFO before notifying a small UDP
observer on the server. It waits for an acknowledgment before closing the
failed TCP socket, with at most three 50 ms attempts. The observer queries only
that tuple and acknowledges after recording it. Every recorded notification
was matched successfully. One ZHTPS notification required three attempts;
its server snapshot was already obtained on the first notification. The
acknowledgment delay must not be confused with the time of the snapshot.

Estimated failure-to-server-query time is 0.063–2.545 ms for ZHTPS offered
and 0.265–1.292 ms saturated. The corresponding clock-offset uncertainties are
0.120 and 0.104 ms. Actual kernel query durations are 37–160 microseconds.
Client deadline lateness is at most 2.133 ms. These observations are close to,
but not simultaneous with, failure. They cannot prove there was no earlier
application delay or quantify time until the first response transmission.
They do establish that the response was already outstanding and undergoing
TCP recovery when inspected.

Validation includes 19 diagnostic client tests, four race checks, an
independent C check of the TCP_INFO layout, real-socket netlink tests, and two
complete notification-path tests. Those tests distinguish an intentionally
unread request from a partially sent response and verify the socket inode.
An initial test incorrectly expected ENOENT for a missing remote tuple; Linux
returned a listener, which the observer correctly rejected. The corrected
test preserves tuple rejection and separately exercises a genuinely missing
local socket. The initial failed log is retained.
Client build and tests,
netlink tests,
notification integration tests.

The next experiment is bounded pacing of send submissions across connections
within each worker. It targets short bursts without changing the client deadline
or HTTP success criteria. The prototype starts at 100,000 submissions/s per
worker, a burst of four, and a bounded FIFO with one queued send per connection;
admin output bypasses pacing. This is submission pacing, not a general wire-rate
limiter: a large send can represent multiple packets, and workers do not share
a global token bucket. Its performance decision is tracked separately.
[Pacing experiment](runs/send-pacing.json "Summary of docs/send-pacing/candidate.json; raw artifact retired").
