# Direct-server admission

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

ZHTPS can serve clients directly. NGINX is optional and is not part of the
single-host admission path. Request admission runs in each ZHTPS worker; an
optional kernel SYN policy can protect the same public listener without adding
another HTTP process.

```text
client -> optional nftables SYN policy -> ZHTPS listener -> worker admission -> application
```

## Native request handling

The worker checks whether both useful work and HTTP rejection are unavailable
before feeding incoming request-head bytes to the parser. When both budgets are
exhausted, it refills the token buckets and checks again before closing the
connection. This avoids parsing a head solely to discover that no response can
be sent. Partial heads can be shed on a subsequent receive too. Idle sockets do
not consume request permits, and admitted bodies and responses continue normally.

When a rejection permit and token remain, the bounded parser validates the head
and the server sends an empty 503 before body processing or `100 Continue`.
Requests without a body can retain their connection after the 503. Their complete
head is also their request boundary, so the next pipelined request stays intact
and runs only after the previous response completes. Requests with unread bodies
or chunked framing still close. Explicit `Connection: close`, HTTP/1.0 defaults,
configured connection lifetimes, and shutdown also require closure. These rules
follow [HTTP/1.1 persistence requirements](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.3).

The 1,000/s rejection budget remains unchanged. Keeping eligible 503 connections
alive does not create an unlimited response loop: exhaustion still closes the
connection. `requests_closed_before_head_total` counts the subset of rejected
requests closed before head parsing completes. It appears in the existing JSON
and Prometheus metrics; it does not count SYNs or unaccepted connections.

Concurrency defaults remain relative to public slots: a 512-slot worker resolves
to 384 active requests, 64 concurrent rejections, and burst 384. `--rate` remains
zero by default. A measured request rate is per worker and must reflect that
application's cost; neither the slot count nor worker count establishes it.

## Optional connection protection on the same host

[deploy/connections.py](../deploy/connections.py) generates only a scoped nftables
policy, its removal file, and a JSON budget record. It requires no proxy, origin
address, HTTP request limit, or background process. Supply the public ZHTPS
listener's actual address/interface and calibrated budgets:

```sh
python3 deploy/connections.py --output /tmp/zhtps-connections \
  --listen-address 192.0.2.20 --listen-port 8080 --interface eth0 \
  --connection-rate 60000 --connection-burst 384 \
  --reset-rate 1000 --reset-burst 32
sudo nft --check --file /tmp/zhtps-connections/connections.nft
```

The example's numbers are workload-specific starting points from the earlier
[overload report](overload.md), not universal defaults. The SYN budget is aggregate
for the selected listener across all workers, while ZHTPS's request and rejection
budgets are per worker. Rates and bursts must be supplied explicitly.

To apply or remove the reviewed table on that host:

```sh
sudo nft --file /tmp/zhtps-connections/connections.nft
sudo nft list counters table inet zhtps_connections
sudo nft --file /tmp/zhtps-connections/remove-connections.nft
```

The policy matches only the selected destination address, port, and incoming
interface. SYNs, including retransmissions, are counted before connection tracking
and TCP listener work. Excess SYNs receive TCP resets within a separate reset
budget; further excess SYNs are dropped. Established connections and other ports,
including a separate admin listener, are unaffected by these rules. See the
[nftables limit and hook documentation](https://netfilter.org/projects/nftables/manpage.html).
No host firewall was modified during validation; kernel checks use disposable
network namespaces.

## Verification

The new raw TCP regressions failed against the preceding binary: an incomplete
head timed out with admission/rejection exhausted, and a bodyless 503 advertised
`Connection: close`. They pass against the updated server without changing the
tests. Additional cases cover pipelined GET/HEAD rejection, recovery on the same
connection, rate refill, rejection-token exhaustion, connection lifetime limits,
unread bodies, chunked framing, and explicit close semantics.

The standalone kernel tests preserve the original IPv4/IPv6 reset/drop, existing
connection, unrelated-listener, and recovery coverage. They now use the extracted
connection-policy module and exercise its direct CLI without any proxy options.

```sh
zig build test
zig build test-wire --release=safe
python3 tests/ingress_kernel.py -v
```

## Local before/after measurements

The confirmed baseline calibration target for the built-in `GET /` workload is
at least 99.9% successful scheduled offers and successful-request p99 at most
10 ms. Unsent offers count against the success target. The summary and sustained
evidence audit already use these thresholds.

Both binaries were built from the same current tree with ReleaseSafe, with the
native admission changes applied only to the second binary. The Go client was
unchanged. Each run pins one server worker to CPU 0 and the generator to CPUs
1–7 on the same host, uses 512 public slots and a six-byte `GET /` response, and
disables access logging. There is no NGINX process. These short comparisons
measure the specific behavior change; they are not the sustained distributed
validation or a representative application capacity result.

The first case schedules 500/s for five seconds, 2,000/s for 30 seconds, and 500/s
for five seconds, with 64 independent client connections, `--rate 1000`, automatic
burst 384, and the unchanged 1,000/s rejection budget:

| Overload phase | Before | After |
| --- | ---: | ---: |
| Requests written/s | 1,999.97 | 1,999.93 |
| Successful responses/s | 1,012.73 | 1,012.73 |
| New dial attempts during overload | 29,584 | 0 |
| HTTP 503 responses | 29,617 | 29,616 |
| Success p99 | 1.06 ms | 1.04 ms |
| HTTP failure p99.9 | 1.12 ms | 1.13 ms |

The after run uses its original 64 connections throughout all phases. Neither
run records a transport failure; each recovery succeeds completely. One before
offer and two after offers were unsent. This demonstrates removal of avoidable
reconnects when excess requests fit within the bounded HTTP rejection budget.
It does not establish a CPU improvement: measured core busy was about 1.9% before
and 2.0% after, at a load where background work matters. Raw records:
[before](runs/native-admission.json "Summary of docs/native-admission/before-reuse.json; raw artifact retired"), [after](runs/native-admission.json "Summary of docs/native-admission/after-reuse.json; raw artifact retired").

The second case uses 512 independent client connections and `--rate 250000`,
with ten seconds at 250,000/s, 30 seconds at 500,000/s, and ten seconds at
250,000/s:

| Overload phase | Before | After |
| --- | ---: | ---: |
| Requests written/s | 376,794 | 375,655 |
| Successful responses/s | 249,797 | 249,851 |
| Success p99 | 4.92 ms | 5.11 ms |
| Server core busy | 99.76% | 99.79% |
| Transport failure p99.9 | 1,002 ms | 1,007 ms |
| Unsent offers | 24.57% | 24.79% |

The after run closes 3,744,167 requests before completing their heads across all
phases, but connection churn and kernel work still saturate the core. Most
excess traffic is above the 1,000/s response budget and therefore cannot benefit
from keeping a 503 connection alive. Memory stays flat within both trials, at
about 85.4 MiB. Recovery success was 99.931% before and 99.838% after; the latter
misses the 99.9% target. Raw records: [before](runs/native-admission.json "Summary of docs/native-admission/before-pressure.json; raw artifact retired"),
[after](runs/native-admission.json "Summary of docs/native-admission/after-pressure.json; raw artifact retired"). The [summary](runs/native-admission.json "Summary of docs/native-admission/summary.json; raw artifact retired")
retains additional percentiles and failure counts.

## Same-host kernel policy comparison

Three further runs use the updated server in fresh, disposable network
namespaces, with the same 250,000/s request cap, 512 clients, CPU placement, and
10/30/10-second schedule. The control uses a nonbinding SYN rate of one billion/s
and records zero over-limit SYNs. The two limited runs use 60,000 and 10,000
SYNs/s. All three use burst 384 and the same bounded reset budget of 1,000/s with
burst 32. No proxy is involved, and no rules are installed in the host namespace.

| Overload phase | Namespace control | 60k SYNs/s | 10k SYNs/s |
| --- | ---: | ---: | ---: |
| Requests written/s | 427,882 | 243,030 | 174,783 |
| Successful responses/s | 249,877 | 224,704 | 172,393 |
| Success p99 | 3.96 ms | 1.17 ms | 1.07 ms |
| Server core busy | 99.72% | 69.57% | 51.75% |
| Transport failure p99.9 | 1,002 ms | 1,002 ms | 1,007 ms |
| Unsent offers | 14.35% | 51.27% | 64.92% |
| Subsequent recovery success | 99.987% | 99.391% | 99.191% |

Across all phases, the 60k policy counts 539,815 SYNs, of which 14,137 exceed its
budget: 3,290 receive a reset and 10,847 are dropped. The 10k policy counts 60,975
SYNs, with 14,955 over limit: 3,355 resets and 11,600 drops. The counter includes
retransmissions and can differ from client dial attempts. Short arrival bursts
can exceed burst 384 even when the long-run average is below the configured rate.

The policy reduces work reaching the server, but these values do not preserve
peak goodput or satisfy the failure-latency and recovery targets. The client's
bounded population becomes occupied by failed connection attempts, causing more
offers to expire unsent. Lower core usage and successful-request p99 therefore
cannot establish the stronger resilience goal. The 10k policy retains only about
69% of control goodput, and both limited runs miss the 99.9% recovery target.
Neither value is selected as a new default.

The namespace control matters: its baseline core usage is about 72%, versus 79%
in the earlier host-namespace pair. Compare each trial with its matching control;
do not attribute that setup difference to admission changes. These runs still
share a machine and do not establish a physical-host isolation result.

Raw records retain the applied policy, namespace identities, the exact local
runner source, and SYN counters sampled with server resources:
[control](runs/native-admission.json "Summary of docs/native-admission/kernel-1000000000.json; raw artifact retired"),
[60k SYNs/s](runs/native-admission.json "Summary of docs/native-admission/kernel-60000.json; raw artifact retired"),
[10k SYNs/s](runs/native-admission.json "Summary of docs/native-admission/kernel-10000.json; raw artifact retired").

## Limits of the result

The native changes reduce avoidable parsing and reconnect work. They do not
guarantee CPU headroom at arbitrary offered load. Established-socket traffic still
costs kernel and worker time, including when the request is rejected, and the SYN
policy cannot classify HTTP requests on persistent connections. Dropped connection
attempts fail according to the client's deadline. A prompt failure for every
excess arrival is therefore still unproven.

Distributed validation can use a separate generator sending directly to ZHTPS;
it does not require an ingress host. Use `bench/overload.py --client-host ...`
with a reachable `--server-address`, and omit `--target-address` for a direct run.
The [distributed collector and evidence audit](ingress.md#distributed-benchmark-support)
remain available for the required sustained workload matrix.

No remote hosts are currently available, so that validation is deferred. Local
runs continue to use separate server/generator CPU sets and retain actual written
traffic, unsent offers, failure tails, memory, and recovery. CPU affinity does not
remove their shared kernel, memory, and thermal constraints; it does not qualify
those runs as separate-host capacity evidence.
