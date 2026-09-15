# ZHTPS HTTP/2 failure diagnosis

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The high-connection timeouts are strongly associated with **NIC receive loss, predominantly
on the remote client**. Fresh paired TCP observations show stalled delivery, and rapid NIC
sampling locates substantial receive loss. The same server and client binaries complete
three loopback controls without failures at more than twice the remote throughput.
This identifies a concrete transport bottleneck; it does not prove that every individual
failure had the same cause or that server response scheduling cannot contribute to bursts.

The investigation adds **18 trials: 15 remote and three loopback**, all with ZHTPS,
eight server workers, **16,384 established connections and four streams per connection**.
The issuing window is eight seconds after two seconds of warmup, with the same two-second
request deadline. All connections remained alive through measurement. All trials and
failed requests are retained. These diagnostics are separate from the
[original 120-trial comparison](http2-lan.md).
[Audited summary and individual decoded observations](runs/http2-diagnosis.json "Summary of docs/http2-diagnosis/summary.json; raw artifact retired"),
complete raw trials, failures, TCP snapshots and NIC samples.

## Where packets were being lost

| NIC-sampling trial | Client receive misses | Server receive misses | Measured request timeouts |
|---|---:|---:|---:|
| Original client placement | 1,710,225 | 0 | 5,242 |
| Client NIC physical core left free | ≥1,504,888 | 222,048 | 3,446 |

These counts cover approximately 9.74 and 9.92 seconds inside the measurement-plus-drain
interval. They are missed **packets**, which include retransmissions; they are not counts
of distinct HTTP requests. The counters cover the host NIC, so they cannot match a particular
lost packet to a particular HTTP stream. The dedicated benchmark load and simultaneous TCP
observations support it as the dominant source of the observed loss.

Both machines use the `r8169` driver with one receive queue and **256 receive descriptors**,
already the maximum reported by the driver. Software receive-packet steering is disabled.
The remote NIC is a Realtek RTL8125, with IRQ 115 on CPU 7; the server uses RTL8126,
with IRQ 103 on CPU 24. RX and TX Ethernet pause are disabled on both.
This configuration makes receive-ring service and packet-processing capacity the next
specific tuning targets. The evidence does not distinguish descriptor starvation from
every other possible driver or NIC receive-resource limit.
[Client NIC settings](runs/http2-diagnosis.json "Summary of docs/http2-diagnosis/client-nic.json; raw artifact retired"),
[server NIC settings](runs/http2-diagnosis.json "Summary of docs/http2-diagnosis/server-nic.json; raw artifact retired").

The earlier negative `rx_missed_errors` deltas were a counter-width problem, not evidence
of no loss. The driver exposes a **16-bit hardware missed-packet counter** through this
statistic. Sampling roughly every five milliseconds captured 26 wraps on the client in
the original-placement run and 23 in the NIC-core-free run.
[Upstream r8169 counter layout and statistics implementation](https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/r8169_main.c).

The analyzer sums consecutive differences modulo 65,536, assuming no counter reset.
It conservatively checks whether 65,536 minimum 64-byte packets could fit between samples
at 2.5 Gb/s, ignoring Ethernet framing overhead. Every interval passes in the first run
(maximum gap 6.84 ms). One interval in the second run is too long for that conservative
bound (14.94 ms), so its client total is reported as a **lower bound**. Server intervals
pass in both runs. Raw samples, timestamps and ambiguous-interval counts remain available;
the original benchmark's sparse counter readings have not been reinterpreted as exact totals.

## What happened at failed requests

In the two original-placement instrumented runs, **480 of 512 sampled timeout connections
had output outstanding in server TCP**. All 512 sampled requests were waiting for response
headers. The client's request-write callbacks occurred promptly after each request began.
The median delay was below nine microseconds; the largest observed delay was 39.4 ms.
At 269 server snapshots, TCP already reported seven or eight consecutive timeout retries.
Some sockets also had later output waiting unsent behind the outstanding bytes.
These observations support loss and TCP recovery as the immediate source of long waits.
With four streams sharing a TCP connection, missing TCP bytes can delay multiple HTTP/2 streams.

The NIC-core-free confirmation captured another 223 matched connections; 167 had server
output outstanding. That run also recorded receive loss on the server, consistent with
request delivery becoming part of the problem as the client sends faster. Snapshots cannot
attribute encrypted output to an exact HTTP/2 response or prove the time of its first send.
A few sockets had no outstanding server output when queried; they remain unresolved
individually rather than being forced into the response-loss classification.

The recorder keeps the first timeout on up to 32 distinct connections per client process,
from measurement only. This is a bounded prefix, not a random sample. There are 736 client
captures, 735 matching server snapshots, and no TCP_INFO query errors in those matched
observations. UDP observation acknowledgments timed out for 152 captures; server-side
records independently establish 151 of them. One notification never produced a server
snapshot and remains explicitly unpaired. The capture/acknowledgment delay is outside the
recorded HTTP failure duration, but can delay the next request in that slot. Instrumented
throughput is therefore diagnostic only. Query delays and clock uncertainty are retained.

## Controls and all trial groups

All setup and connection-holding failure counts were zero in these new trials. Failure
counts below total each group; rates and p99 are medians. Successful-response latency is
reported separately from failures. Every loopback request is validated identically.

| Diagnostic group | Trials | Valid responses/s | Successful p99, ms | Warmup failures | Measured failures |
|---|---:|---:|---:|---:|---:|
| Original client placement, 8 processes | 3 | 206,132 | 1,300 | 1,639 | 15,238 |
| First NIC-core-free screen, 7 processes | 3 | 233,745 | 1,180 | 455 | 7,249 |
| Paired TCP capture, original placement | 1 | 201,157 | 1,280 | 451 | 3,615 |
| Matched control: 7 processes, NIC core occupied | 3 | 201,947 | 1,300 | 1,412 | 12,754 |
| Matched control: 7 processes, NIC core free | 3 | 222,552 | 1,220 | 561 | 18,319 |
| Loopback, same binaries, separate physical CPU cores | 3 | 512,754 | 208 | 0 | 0 |
| Paired TCP + NIC sampling, original placement | 1 | 208,303 | 1,290 | 474 | 5,242 |
| Paired TCP + NIC sampling, NIC core free | 1 | 229,950 | 1,210 | 192 | 3,446 |

The loopback control completed **12,408,653 measured requests with zero failures in any
phase**. Rates were 504,904–512,773/s, with p99 of 205–217 ms. It used the exact original
server and client executables: server CPUs 0–7 and client CPUs 8–15,24–31, giving the load
client separate physical cores. Sharing a machine changes client hardware and scheduling,
so this is a diagnostic control, not a LAN performance comparison. It strongly argues
against a deterministic HTTP/2 stall at this connection/stream count.

Freeing the remote IRQ core is **not an established failure fix**. The first screen
improved both rate and failure count, but also changed the process count. With seven
processes and fourteen logical CPUs held constant, the NIC-core-free group improved
throughput while recording more measured failures. Groups ran sequentially rather than
as a randomized statistical experiment; the differing repeated results also demonstrate
load/run variability. All groups remain in the record.

The client also recorded about 38,000–47,000 transmit-queue drops in the queue-observed
original/matched-control trials, predominantly at the queue limit. Those are whole-trial
counts including setup and warmup, not packet attribution. The original-placement NIC
capture shows no server receive misses during its sampled interval, whereas the faster
client confirmation shows receive misses on both ends. The diagnosis therefore concerns
both receive capacity and offered packet bursts, with the remote client the dominant
observed receive-loss location.

## Scope and next step

The earlier **setup failures are a separate capacity limit**: ZHTPS permits 8,176 connections
per worker. One worker cannot hold 8,192 or 16,384, and two workers cannot hold 16,384.
The original setup failure records and partial-population flags remain unchanged.
The new eight-worker runs isolate in-flight failures without that limit.

No server implementation, IRQ affinity, NIC setting, qdisc or sysctl was changed.
The evidence justifies testing receive-packet distribution or a NIC/driver with greater
receive capacity, then repeating the unchanged remote workload. Simply increasing the
HTTP timeout would mask symptoms, and an HTTP/2 correctness patch is not justified by
these observations. Server-side response batching or pacing could still influence the
bursts; any such change needs a separate performance and correctness experiment.

The ordinary client executable was preserved. Optional tracing and bounded TCP capture
were added to a separately built diagnostic executable. Validation exercises real TCP
traffic, closed sockets, actual TLS HTTP/2 header/body timeouts, concurrent stream failures,
and exact failure accounting. The server observer separately checks exact tuples and
unread request bytes. All 15 remote trials pass the existing failure/provenance audit;
all three local controls pass their full-population and failure-log checks.
[Build hashes and unchanged production-source verification](runs/http2-diagnosis.json "Summary of docs/http2-diagnosis/build.json; raw artifact retired"),
[trial audits](runs/http2-diagnosis.json "Summary of docs/http2-diagnosis/audit.json; raw artifact retired"), validation,
race checks,
reproduction harness,
[artifact manifest](runs/http2-diagnosis.json "Summary of docs/http2-diagnosis/manifest.json; raw artifact retired").

For a paired diagnostic after building the diagnostic client:

```sh
python3 bench/diagnose_http2_lan.py --servers zhtps --workers 8 \
  --connections 16384 --repeats 1 --sample-missed \
  --client zig-out/http2-benchmark/diagnostic-client \
  --output /tmp/zhtps-http2-new-diagnostic
```

Use a fresh output directory. The runner transfers the approved compiled client,
Python supervisor and public test certificate, and retrieves the raw evidence before
removing its own temporary remote staging directory. The private certificate key stays
on the server host. Analyze a fresh run with `bench/summarize_http2_diagnosis.py`,
passing its output parent directory as `--input-root`. The historical raw evidence
archive has been removed; its summarized findings remain in this report.
