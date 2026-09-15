Follow-up: [paired server/client observations](server-timeout-correlation.md)
now capture all 17 ZHTPS failures in four additional diagnostic runs. Each
has a consumed request and a complete unacknowledged response. The earlier
client-only observations below remain preserved as a separate experiment.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The new diagnostic client captured all nine ZHTPS read timeouts in a separate
60-second, 300k-offered/s window at 16,384 connections. At each failure, the
request had been acknowledged by TCP, the client was waiting for response
headers, and no new TCP response data had arrived during the exchange. Client
wakeup lateness was below one millisecond. These observations narrow the
remaining investigation to request arrival timing, server processing, and
response delivery; they do not by themselves prove where packets were lost.
[Audited results and individual observations](runs/read-timeout-socket-info.json "Summary of docs/read-timeout-socket-info/results.json; raw artifact retired").

The first diagnostic pair used the original 20-second high-load window and
captured no ZHTPS failure. Go had 1,711 read timeouts and 35 dial timeouts.
The recorder kept the first 64 read timeouts and explicitly reported the
remaining 1,647 as omitted. Of those 64, 58 had fully acknowledged requests;
six still had unacknowledged segments. All 64 were waiting for headers and
had no recent incoming TCP data. This bounded prefix is not a random sample
and must not be extrapolated to all Go failures.

The longer ZHTPS run retained 300k offered requests/s, the same second host,
seven server workers, CPU placement, exact response validation, and the
two-second deadline for each exchange. Only observation duration increased.
It captured nine of nine read timeouts, with no probe errors or omitted
records. The initial pair and longer run passed the ordinary provenance and
failure-accounting audit. The instrumented client's timing differs from the
decision client, so none of its throughput or latency results are merged into
the 48-run performance comparison.
[Initial plan](runs/read-timeout-socket-info.json "Summary of docs/read-timeout-socket-info/plan.json; raw artifact retired"),
[longer observation](runs/read-timeout-socket-info.json "Summary of docs/read-timeout-socket-info/long-plan.json; raw artifact retired"),
[three-run audit](runs/read-timeout-socket-info.json "Summary of docs/read-timeout-socket-info/audit.json; raw artifact retired"),
[uninstrumented decision results](tcp-read-timeout-mitigation.md).

For the nine ZHTPS failures:

- Connections were 24.7–87.0 seconds old and had issued 199–1,132 requests.
  They were not first requests on newly opened connections.
- Each socket remained established, with zero unsent bytes and zero
  unacknowledged segments at capture. Acknowledged bytes covered all bytes
  written on that connection, including the acknowledged SYN.
- The last received data was 2,000–2,021 ms earlier. The reader had no
  buffered response bytes, and every timeout occurred while reading headers.
- Deadline wakeup lateness was 6.6–671.9 microseconds; capture began another
  8.1–24.5 microseconds later. This does not support a large client scheduling
  overrun as the cause of these nine failures.

Acknowledgement at the deadline does not establish that the request arrived
early. For example, the last incoming ACK in one record was only 306 ms before
the deadline. That timestamp does not identify the first acknowledgement of
the current request. TCP receipt also does not establish application dispatch,
response generation, or server transmission. Client-side retransmission totals
cover the connection's history and expose neither the server's current RTO nor
its response retransmissions. Server-side correlation is still required before
classifying each residual failure as delayed processing or lost output.

The diagnostic client uses a fixed 64-record limit and snapshots `TCP_INFO`
before closing a timed-out socket. It records the original failure timestamp
before probing and preserves failure accounting. Capture errors remain separate
from HTTP errors. It stores the returned raw bytes as well as decoded fields;
fields beyond the kernel's returned length are omitted. It does not query
socket information on every successful response. The installed Linux UAPI
layout was checked independently with a C compiler.

All 19 client tests passed, including real partial-response timeouts through
both offered and saturated workers, unchanged response/histogram tests,
closed-socket behavior, truncated socket information, and concurrent capture
limits. The four new tests also passed under the Go race detector. The
diagnostic sources and executable are frozen separately; the ordinary
performance client remains unchanged.
Build and source receipt,
tests,
race checks,
archived sources.

The next useful step is a bounded server-side snapshot correlated with a
failing client tuple, before the client closes that socket. It should establish
whether the worker received/dispatched/completed the request and whether TCP
still has an outstanding response, its RTO, and its retry history. That adds
evidence for testing aggregate response pacing or a server scheduling change.
These nine observations do not justify another blind minimum-RTO reduction,
nor do they establish that changing only the client's retry policy would fix
the remaining failures.
