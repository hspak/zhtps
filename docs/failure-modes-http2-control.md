# HTTP/2 control frames compared with Node and Go

This pass of the [failure-mode audit](failure-modes.md) compares 78 cases covering
control frames, HPACK, continuation limits, bounded floods, flow-control stalls,
and fatal errors with work still active. It finds and fixes delayed cancellation
after a fatal GOAWAY. Together with the earlier request, response and lifecycle
passes, the audit now contains 336 cases.

The [retained results](runs/failure-modes-http2-control.json) contain input
descriptions and hashes, advertised settings, response/reset observations, GOAWAY
codes, closure, fresh-connection recovery and diagnostic summaries. Long input
payloads retain a prefix and hash; the runner reconstructs the exact frames.
The two fatal-error cases also retain their pre-fix outcomes. The runner is
[http2_control_comparison.py](../tests/http2_control_comparison.py).

## Setup and interpretation

Measured on 2026-09-17 with Zig 0.16.0, Node v26.9.0 and Go go1.27.1-X:nodwarf5 on Linux,
with ZHTPS's pinned OpenSSL 3.5.8 and nghttp2 1.70.0. Each implementation starts in
a fresh process for each case. Connections use TLS with ALPN `h2`. The raw frame
writer bypasses client validation; the response reader decodes HPACK and retains
GOAWAY without preventing observation of existing streams.

Most cases establish an unfinished upload on stream 1 and synchronize it with PING
before sending the test input. The probe then attempts a neighboring request on
stream 1001 and finishes stream 1. The malformed subject is usually stream 3.
No additional DATA is sent on a malformed subject after the test frame: an extra
error on that stream could hide the first error's isolation behavior. Consequently,
a valid control frame on an unfinished subject need not produce a response there.

The normal observation budget is 800 ms plus a brief drain. `terminal: null`
means closure was not observed during that interval, not that the connection is
permanently retained. Separate fatal-error cases allow up to 1.4 seconds for server
closure and keep the client socket open while inspecting producer cleanup. ZHTPS's input
budgets are two seconds, and its stream write budget is 300 ms. The reference
fixtures retain their native timeout defaults. Go's fixture maps body-read errors
to 400; other parser and frame handling comes from the native servers.

The 16,385-byte cases deliberately use the same bytes despite different advertised
limits: Go advertises a larger receive frame size than ZHTPS and Node. A separate
case sends one byte beyond each server's actual advertised maximum. The flood
probes contain at most 129 PING/SETTINGS frames or 110 promptly reset streams;
they demonstrate configured thresholds under this packetization, not resistance
to every sustained traffic pattern. The synchronization PING also needs an ACK.

## Adopted behavior: retire a fatally failed connection promptly

Previously, ZHTPS sent a fatal GOAWAY but waited for its application stream count
to reach zero before closing. nghttp2 had already stopped processing input, so an
unfinished upload could not complete. A waiting producer retained its application
slot until the normal application deadline. After 1.4 seconds, both connections
were still open, and the producer had not been released. Node closed and released
the work promptly; Go did so after its approximately one-second error drain.

ZHTPS now flushes the queued protocol output, notices that the engine no longer
accepts input, cancels remaining application work, and starts TLS closure. Borrowed
storage still survives until pending I/O and application callbacks finish. Graceful
GOAWAY continues to wait for accepted streams: nghttp2 keeps input enabled while
those streams remain usable. The change adds no allocation or frame parsing.

The distinction follows nghttp2's
[input-interest contract](https://nghttp2.org/documentation/nghttp2_session_want_read.html),
cross-checked against the pinned source's terminal-GOAWAY handling. Two new end-to-end
regressions fail before the fix and pass unchanged afterward: one holds an upload
open with a five-second body deadline, and the other waits inside a response
producer and checks its cleanup and subsequent lane reuse.

## Retained decisions

| Concern | Decision and reason |
| --- | --- |
| Invalid control-frame sizes, stream IDs and SETTINGS values | Keep rejection. Most references agree; neither accepting malformed control input nor suppressing useful protocol errors improves the server contract. |
| HPACK corruption | Keep connection-level compression errors for absent/zero indices, truncated encodings, invalid Huffman strings and illegal table updates. A shared compression table must not continue after loss of synchronization. |
| Stream versus connection errors | Keep nghttp2's connection-fatal policy for malformed padding, self-dependency in HEADERS, DATA after request end, and invalid stream window updates. Go isolates some of these errors more narrowly. ZHTPS chooses to retire a peer violating the frame/state contract; overriding this engine policy would require private dependency changes or a second parser and stream-state representation. Application-level malformed fields remain isolated as documented in the first pass. |
| Duplicate SETTINGS | Keep ordered replacement, matching Node. Go rejects the duplicate identifier in this probe. Changing a valid last-value policy to obtain identical results offers no benefit. |
| Unknown settings/frames and reserved stream bit | Keep extension tolerance and masking the reserved bit. All three preserve useful work for these ordinary extension cases. |
| Unsolicited PING ACK | Keep ignoring it, matching Go. Node closes with INTERNAL_ERROR. A stricter reaction adds connection loss without improving request handling. |
| Deprecated PRIORITY frames | Keep the engine's treatment of standalone legacy priorities. Go rejects some forms that nghttp2 ignores. This server does not restore the deprecated priority tree merely to add those rejection paths. |
| Continuation count | Keep the limit of eight. Node also closes above it; Go accepts the tested longer chains. A bounded amount of work per field block is preferable to accepting arbitrary fragmentation. |
| ACK/reset bursts | Keep bounded queued ACKs and reset-rate accounting. Both references accept the tested bursts that trigger ZHTPS's limits. Their acceptance does not justify removing ZHTPS's resource bounds. A reset-rate GOAWAY uses nghttp2's INTERNAL_ERROR code; flood failures can close without a GOAWAY. |
| Peer GOAWAY race | Keep completion of accepted input and retirement once active work ends. ZHTPS also handles the request coalesced after the peer's GOAWAY; Node/Go send a reciprocal GOAWAY and stop accepting it. The accepted upload completes in all three; ZHTPS and Node close within the observation window, while Go's closure is not observed. |
| Flow control | Keep honoring both windows, negative stream credit after a SETTINGS reduction, and independent progress for streams with available credit. All three agree in these probes. |
| Zero-window deadline | Keep the configured ZHTPS stream deadline: reset the stalled stream, preserve its neighbor and accept a subsequent upload. The reference streams remain pending at the observation deadline under their native defaults and are explicitly canceled by the client. |

[RFC 9113 §5.4](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.4) permits
escalating a stream error to a connection error. Its
[SETTINGS rules](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.5) specify
ordered replacement, and its
[flow-control rules](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.9) cover
both window levels and reductions. Engine limits were checked against the pinned
implementation and nghttp2's [continuation limit](https://nghttp2.org/documentation/nghttp2_option_set_max_continuations.html)
and [reset-rate limit](https://nghttp2.org/documentation/nghttp2_option_set_stream_reset_rate_limit.html)
contracts. Native Node options are described in its
[HTTP/2 documentation](https://nodejs.org/api/http2.html).

## Reproduction

Completion checks passed on 2026-09-17: the Debug build completed all 83 steps,
including 122 Zig tests, 42 HTTP/2 tests, 32 TLS tests, the wire and response-streaming
suites, and formatting. ReleaseSafe completed all 68 steps, including the same
122 Zig, 42 HTTP/2 and 32 TLS tests. The HTTP/2 suite includes both fatal-error
regressions and the existing graceful-GOAWAY completion tests.

```sh
zig build install install-response-fixture --system zig-pkg \
  --global-cache-dir /tmp/zhtps-edge-cache --summary all
/tmp/zhtps-edge-h2/bin/python tests/http2_control_comparison.py \
  zig-out/bin/tls-application --output /tmp/h2-control.json
zig build test test-wire test-http2 test-tls test-response-streaming check-fmt \
  --system zig-pkg --global-cache-dir /tmp/zhtps-edge-cache \
  -Dhttp2-python=/tmp/zhtps-edge-h2/bin/python --summary all
zig build test test-http2 test-tls --system zig-pkg \
  --global-cache-dir /tmp/zhtps-edge-cache -Doptimize=ReleaseSafe \
  -Dhttp2-python=/tmp/zhtps-edge-h2/bin/python --summary all
```

Use the environment from [HTTP/2 verification](http2.md#verification), with Node,
Go and OpenSSL on PATH. `--filter` selects a case-name substring. The installed
fixture is a test application, not the standalone production service.

Server-initiated GOAWAY races, receive-window exhaustion while an application
refuses to consume input, sustained admission/resource pressure, and TLS lifecycle
comparisons remain in the overall audit.

## Enumerated observations

`G(n)` is GOAWAY, `R(n)` is a reset of the subject stream, and `close` means
observed EOF without a GOAWAY. `EOF` after `G(n)` marks observed closure; its
absence means closure was not observed during this probe. Codes:
0 = NO_ERROR, 1 = PROTOCOL_ERROR, 2 = INTERNAL_ERROR,
3 = FLOW_CONTROL_ERROR, 5 = STREAM_CLOSED, 6 = FRAME_SIZE_ERROR,
8 = CANCEL, 9 = COMPRESSION_ERROR. `OK` means the existing upload and the
neighbor both completed successfully; it does not mean the malformed subject was
accepted. `subject 200` marks a completed subject response; `upload 200` marks
completion of the existing upload when the neighbor did not complete. Flow rows
describe the relevant window boundary and subsequent reuse.

### Control frames and HPACK

| Case | ZHTPS after | Node | Go |
| --- | --- | --- | --- |
| `ping-valid` | OK | OK | OK |
| `ping-short` | G(6); EOF | G(6); EOF | G(6) |
| `ping-long` | G(6); EOF | G(6); EOF | G(6) |
| `ping-stream` | G(1); EOF | G(1); EOF | G(1) |
| `ping-unsolicited-ack` | OK | G(2); EOF | OK |
| `settings-stream` | G(1); EOF | G(1); EOF | G(1) |
| `settings-invalid-length` | G(6); EOF | G(6); EOF | G(6) |
| `settings-ack-payload` | G(6); EOF | G(6); EOF | G(6) |
| `settings-invalid-push` | G(1); EOF | G(1); EOF | G(1) |
| `settings-window-overflow` | G(3); EOF | G(3); EOF | G(3) |
| `settings-frame-too-small` | G(1); EOF | G(1); EOF | G(1) |
| `settings-frame-too-large` | G(1); EOF | G(1); EOF | G(1) |
| `settings-unknown` | OK | OK | OK |
| `settings-duplicate` | OK | OK | G(1) |
| `settings-extra-ack` | G(1); EOF | G(1); EOF | G(1) |
| `window-zero-connection` | G(1); EOF | G(1); EOF | G(1) |
| `window-overflow-connection` | G(3); EOF | G(3); EOF | G(3) |
| `window-short` | G(6); EOF | G(6); EOF | G(6) |
| `window-idle-stream` | G(1); EOF | G(1); EOF | G(1) |
| `rst-connection` | G(1); EOF | G(1); EOF | G(1) |
| `rst-idle-stream` | G(1); EOF | G(1); EOF | G(1) |
| `rst-short` | G(6); EOF | G(6); EOF | G(6) |
| `priority-connection` | OK | OK | G(1) |
| `priority-short` | G(6); EOF | G(6); EOF | G(6) |
| `priority-idle` | OK | OK | OK |
| `headers-zero-stream` | G(1); EOF | G(1); EOF | G(1) |
| `headers-even-stream` | G(1); EOF | G(1); EOF | G(1) |
| `headers-bad-padding` | G(1); EOF | G(1); EOF | R(1); OK |
| `headers-missing-pad-length` | G(1); EOF | G(1); EOF | close |
| `headers-short-priority` | G(6); EOF | G(6); EOF | close |
| `headers-self-priority` | G(1); EOF | G(1); EOF | R(1); OK |
| `data-zero-stream` | G(1); EOF | G(1); EOF | G(1) |
| `data-idle-stream` | G(1); EOF | G(1); EOF | G(1) |
| `data-after-end` | G(5); EOF | G(5); EOF | R(5); OK |
| `goaway-stream` | G(1); EOF | G(1); EOF | G(1) |
| `goaway-short` | G(6); EOF | G(6); EOF | G(6) |
| `goaway-normal` | OK; close | G(0); upload 200; EOF | G(0); upload 200 |
| `client-push-promise` | G(1); EOF | G(1); EOF | G(1) |
| `continuation-without-head` | G(1); EOF | G(1); EOF | G(1) |
| `continuation-wrong-stream` | G(1); EOF | G(1); EOF | G(1) |
| `continuation-interleaved-ping` | G(1); EOF | G(1); EOF | G(1) |
| `continuation-interleaved-unknown` | G(1); EOF | G(1); EOF | G(1) |
| `unknown-connection-frame` | OK | OK | OK |
| `unknown-stream-frame` | OK | OK | OK |
| `unknown-frame-16385` | G(6); EOF | G(6); EOF | OK |
| `reserved-stream-bit` | subject 200; OK | subject 200; OK | subject 200; OK |
| `window-zero-stream` | G(1); EOF | G(1); EOF | R(1); OK |
| `window-overflow-stream` | G(3); EOF | G(3); EOF | R(3); OK |
| `rst-cancel-stream` | OK | OK | OK |
| `rst-unknown-code` | OK | OK | OK |
| `priority-self` | OK | OK | R(1); OK |
| `data-bad-padding` | G(1); EOF | G(1); EOF | G(1) |
| `data-missing-pad-length` | G(1); EOF | G(1); EOF | close |
| `data-frame-16385` | G(6); EOF | G(6); EOF | R(1); OK |
| `continuation-count-1` | subject 200; OK | subject 200; OK | subject 200; OK |
| `continuation-count-8` | subject 200; OK | subject 200; OK | subject 200; OK |
| `continuation-count-9` | close | G(2); EOF | subject 200; OK |
| `continuation-count-32` | close | G(2); EOF | subject 200; OK |
| `hpack-index-zero` | G(9); EOF | G(9); EOF | G(9) |
| `hpack-index-absent` | G(9); EOF | G(9); EOF | G(9) |
| `hpack-truncated-integer` | G(9); EOF | G(9); EOF | G(9) |
| `hpack-table-update-after-field` | G(9); EOF | G(9); EOF | G(9) |
| `hpack-truncated-string` | G(9); EOF | G(9); EOF | G(9) |
| `hpack-invalid-huffman` | G(9); EOF | G(9); EOF | G(9) |
| `hpack-table-too-large` | G(9); EOF | G(9); EOF | G(9) |
| `ping-burst-127` | OK | OK | OK |
| `settings-burst-127` | OK | OK | OK |
| `ping-burst-129` | close | OK | OK |
| `settings-burst-129` | close | OK | OK |
| `reset-burst-110` | G(2); upload 200; EOF | OK | OK |
| `unknown-frame-over-advertised-max` | G(6); EOF | G(6); EOF | G(6) |

### Flow control

Every flow case completes the neighbor and a subsequent upload on the same
connection. Stalled reference streams are canceled by the client after observation.

| Case | ZHTPS | Node | Go |
| --- | --- | --- | --- |
| `flow-zero-window-resume` | 0 bytes before credit; 1024 after | 0 bytes before credit; 1024 after | 0 bytes before credit; 1024 after |
| `flow-zero-window-deadline` | R(8) after deadline | pending at observation deadline | pending at observation deadline |
| `flow-stream-stall-neighbor` | stalls at 1024 bytes; neighbor completes | stalls at 1024 bytes; neighbor completes | stalls at 1024 bytes; neighbor completes |
| `flow-connection-stall-recovery` | 65535 bytes; neighbor body 0 before credit, completes after | 65535 bytes; neighbor body 0 before credit, completes after | 65535 bytes; neighbor body 0 before credit, completes after |
| `flow-settings-window-reduction` | 1024 bytes at zero credit; 1025 after one byte of credit | 1024 bytes at zero credit; 1025 after one byte of credit | 1024 bytes at zero credit; 1025 after one byte of credit |

### Fatal errors with active work

All four columns observe G(6). Times are single observations, rounded to
milliseconds; `<1 ms` records a rounded zero. Cleanup is checked while the
client still holds its socket open.

| Case | ZHTPS before | ZHTPS after | Node | Go |
| --- | --- | --- | --- | --- |
| `fatal-with-waiting-upload` | still open at 1401 ms | EOF in <1 ms | EOF in 1 ms | EOF in 1001 ms |
| `fatal-with-waiting-producer` | still open at 1401 ms; released 0/1 | EOF in <1 ms; released 1/1 | EOF in 1 ms; released 1/1 | EOF in 1001 ms; released 1/1 |
