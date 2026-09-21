# Connection lifecycle compared with Node and Go

This continues the [failure-mode audit](failure-modes.md) with 32 HTTP/1.1 cases
against ZHTPS, Node and Go. The production implementation is retained: these
comparisons do not justify changing its deadline, cancellation or shutdown policy.
Together with the request and response passes, the audit now covers 258 cases.

The [retained results](runs/failure-modes-lifecycle.json) include response status,
framing completion, body length/prefix, closure, elapsed time, fresh-connection
recovery, producer cleanup, ZHTPS counters and server diagnostics. The runner is
[lifecycle_comparison.py](../tests/lifecycle_comparison.py). It starts a fresh process
for each implementation and case. Measurements use Zig 0.16.0, Node v26.9.0 and
Go go1.27.1-X:nodwarf5 on Linux, dated 2026-09-17.

## Experiment boundaries

These are explicit short budgets, not the servers' defaults:

| Budget | ZHTPS | Node | Go |
| --- | --- | --- | --- |
| Request input | Separate 300 ms header and body deadlines | 300 ms `headersTimeout` and `requestTimeout`; 10 ms checking interval | 300 ms `ReadHeaderTimeout` and `ReadTimeout` |
| Writing | 600 ms write deadline | 600 ms socket inactivity timeout | 600 ms `WriteTimeout` |
| Idle keep-alive | 300 ms | 300 ms, with the extra timeout buffer disabled | 300 ms |
| Shutdown | 600 ms deadline and 100 ms keep-alive grace | `close()`, then `closeAllConnections()` after 600 ms | `Shutdown()` with a 600 ms context, then `Close()` on expiry |

Shutdown probes increase the input budgets to two seconds so normal read expiry
does not hide the shutdown decision. Node and Go's shutdown signal handling and
forced-close deadlines belong to the fixtures; their servers do not install this
process policy automatically. Native Go body-reader errors are explicitly mapped
to 400 by the fixture. The Node fixture leaves native parsing/expectation decisions
unchanged and attaches error listeners without replacing those responses.

The APIs have different scopes. Node's request budget and Go's read budget include
the whole request, while ZHTPS gives each input phase its configured budget. Node's
socket timeout measures inactivity; Go starts its response write budget after
reading the request headers. See the primary
[Node HTTP documentation](https://nodejs.org/api/http.html) and
[Go Server contract](https://pkg.go.dev/net/http#Server).

Each connection has a 1.4 second receive observation timeout. Producer cleanup is
polled for up to 900 ms, then checked again after connection closure. A producer
can therefore outlive the first cleanup observation without leaking. Elapsed times
include deliberate client sleeps and draining already-buffered response bytes;
they are not precise measurements of a server's timer firing.

The slow-reader probes request eight MiB with a receive buffer set to 4 KiB before
connecting, then refrain from reading for 850 or 1,800 ms. ZHTPS counters confirm
write timeout and request abort; body counts distinguish buffered prefixes from
complete responses. Reset probes use `SO_LINGER` to send TCP RST. Half-close probes
use `shutdown(SHUT_WR)` and continue reading.

The `/timeout` probe deliberately has an 80 ms ZHTPS application lane deadline
and a handler that sleeps 250 ms. Native reference handlers sleep the same amount
without an application watchdog. This demonstrates the separate application policy,
not equivalent timeout configuration or a claim that references cannot implement one.

## Decisions

| Concern | Decision and reason |
| --- | --- |
| Idle connections and incomplete input | Keep silent idle closure and 408 for incomplete requests that time out. Node's unsolicited 408 on a connection with no request bytes is unnecessary. Go's silent header closure/400 body mapping offers no benefit over identifying the timeout. |
| Trickling input | Keep deadlines that are not renewed by each incoming byte. All three bound these probes; an occasional byte must not occupy a connection indefinitely. |
| Per-phase input budgets | Keep independent header and body budgets. The split-phase probe takes 180 ms in each phase, completes under ZHTPS's configured contract, and exceeds the references' whole-request budget. Adopting their result would silently change the meaning of ZHTPS's options. |
| Partial pipelined requests | Keep the completed response and return 408 for the next incomplete request. Both references preserve the completed response but close without a second status in this probe. |
| Unread bodies after an early response | Keep 403 followed by closure. Native references can drain the body and reuse the connection, but that adds input work after rejection. ZHTPS deliberately avoids consuming unwanted bodies and never treats their bytes as a new request. |
| Early response to Expect | Keep rejecting before 100, as Go does when its handler does not read the body. Node's default 100 before the rejecting handler runs invites an unnecessary upload. |
| Slow response readers | Keep the fixed write deadline. ZHTPS and Go abort both stalled-download probes; Node completes after the shorter stall and aborts after the longer one. Inactivity-based tolerance is a different policy and would weaken the configured bound on fixed-response occupancy. |
| Client reset | Keep cancellation and cleanup of the producer. All three release it promptly after RST and serve a new connection successfully. |
| Client write half-close | Keep the distinction from reset: a client can finish sending its request and still read the response. ZHTPS and Go deliver the delayed finite response; Node closes before producing it. For the waiting producer, Node/Go cancel promptly while ZHTPS waits for its application deadline and then releases the producer. The deadline bounds that wait; copying immediate cancellation would sacrifice valid response delivery. |
| Application deadline | Keep explicit application cancellation and retain callback storage until the callback finishes. The short-lane probe closes before the late handler can respond; native fixtures without that policy return 200. |
| Graceful shutdown | Keep completing active requests within the deadline, then abort stalled work. Keep the brief final-request grace for established keep-alive sockets: it handles a reuse race with a closing 200 response, where Node/Go have already closed. Silent keep-alives do not consume the full shutdown deadline. |

All 27 cases that leave the server running return 200 on a fresh connection in all
three implementations. Both reset and half-close producer probes eventually show
one release for one producer. All five shutdown cases exit successfully and refuse
new connections afterward. No ZHTPS probe crashes or reaches the client's receive
observation timeout.

## Observations

Statuses are listed in wire order. `none` means no HTTP response. `partial` means
the advertised body or terminal chunk was not completed. A client-initiated reset
does not imply the server sent a complete response. The Go waiting producer returns
from its handler when its request context is canceled and sends a final zero chunk;
that framing completion does not establish successful application work.

| Case | ZHTPS | Node | Go |
| --- | --- | --- | --- |
| idle-new | none, close | 408, close | none, close |
| idle-reused | 200, idle close | 200, idle close | 200, idle close |
| reuse-before-idle | 200, 200 | 200, 200 | 200, 200 |
| partial-request-line | 408 | 408 | 400 |
| partial-header | 408 | 408 | none, close |
| trickle-header | 408 | 408 | none, close |
| fixed-body-stall | 408 | 408 | 400 |
| trickle-fixed-body | 408 | 408 | 400 |
| chunk-size-stall | 408 | 408 | 400 |
| chunk-data-stall | 408 | 408 | 400 |
| trailer-stall | 408 | 408 | 400 |
| split-phase-budget | 200, `hello` | 408 | 400 |
| pipeline-partial-header | 200, 408 | 200, close | 200, close |
| half-close-complete | 200, `hello` | 200, `hello` | 200, `hello` |
| half-close-truncated | 400 | 400 | 400 |
| half-close-pipeline | 200, 200 | 200, 200 | 200, 200 |
| half-close-delayed-response | 200, `late` | none, close | 200, `late` |
| early-unread-stall | 403, close | 403, close | 403, close |
| early-fixed-pipeline | 403, close | 403, 200 | 403, 200 |
| early-chunked-pipeline | 403, close | 403, 200 | 403, 200 |
| early-expect | 403 | 100, 403 | 403 |
| slow-response-reader | 200 partial | 200 complete | 200 partial |
| sustained-slow-response-reader | 200 partial | 200 partial | 200 partial |
| reset-large-response | 200, client reset | 200, client reset | 200, client reset |
| reset-producer | canceled, released | canceled, released | canceled, released |
| half-close-producer | deadline, partial, released | partial, released | final chunk, released |
| application-deadline | none, close | 200, `late` | 200, `late` |
| shutdown-idle | close after grace | close | close |
| shutdown-body-complete | 200, `hello` | 200, `hello` | 200, `hello` |
| shutdown-body-stall | deadline, close | close | deadline, close |
| shutdown-producer | 200 partial, close | 200 partial, close | 200 partial, close |
| shutdown-keepalive-reuse | 200, final closing 200 | 200, close | 200, close |

## Reproduction and remaining work

```sh
zig build install-response-fixture --system zig-pkg \
  --global-cache-dir /tmp/zhtps-edge-cache --summary all
python3 tests/lifecycle_comparison.py zig-out/bin/tls-application \
  --output /tmp/lifecycle.json
zig build test-wire test-response-streaming test-http2 test-tls check-fmt \
  --system zig-pkg --global-cache-dir /tmp/zhtps-edge-cache \
  -Dhttp2-python=/tmp/zhtps-edge-h2/bin/python --summary all
```

The comparison uses Python's standard library and requires Node and Go on PATH.
`--filter` selects a case-name substring. The fixture is a test application;
`install-response-fixture` installs it without installing it as the standalone
service. Socket/io_uring operations must be permitted. The verification command's
HTTP/2 Python environment follows [http2.md](http2.md#verification).

All 32 comparisons completed. The existing wire target (115 tests), response
streaming (9), HTTP/2 (40) and TLS (32) suites passed: 196 tests with no skips.
Repository formatting checks passed. No existing regression assertion was changed,
and this pass added no production changes beyond the earlier audit fixes.

HTTP/2 flow control, stream concurrency, GOAWAY races, TLS lifecycle, and resource
exhaustion still need direct reference comparison. Existing tests for those areas
are not a substitute for the remaining audit work.
