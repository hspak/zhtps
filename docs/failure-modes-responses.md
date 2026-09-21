# Response failures compared with Node and Go

This continues the [failure-mode audit](failure-modes.md) with 90 observations:
30 cases each over HTTP/1.0, HTTP/1.1 and TLS HTTP/2. The production implementation
was retained after this pass. The differences below do not justify relaxing its
framing checks or changing its application failure contract.

The [retained results](runs/failure-modes-responses.json) identify the executable,
sources, versions, every case, response fields/body, completion, stream reset,
same-connection follow-up and fresh-connection recovery. Tests ran with Zig 0.16.0,
Node v26.9.0, Go go1.27.1-X:nodwarf5, and the repository's pinned TLS/HTTP/2 libraries.

## Experiment boundaries

The ZHTPS endpoint fixture returns byte responses or generated streams using the
public application API. The Node and Go fixtures attempt corresponding writes with
native server APIs. Native Node/Go handlers do not return errors: the `handler-error`
case explicitly maps a simulated failure to 500, while ZHTPS's framework performs
that mapping for a returned `InputOutput` error. These are distinct from the
`panic-before` and `panic-after` probes, which intentionally use an unhandled
exception or panic. Each implementation runs in a fresh local process per case;
core dumps are disabled in the test process and its children.

Node's fixture catches synchronous response API validation errors, records them,
and destroys that response. It does not catch the intentional exception probes.
Go's fixture records write errors and returns; for deliberate stream aborts it
uses `http.ErrAbortHandler`. These choices are part of the experiment, not claims
that every Node/Go application handles returned errors identically.

The client records actual bytes and frames. HTTP/2 responses use a raw frame and
HPACK reader so a client's automatic length validation does not obscure the server's
END_STREAM or reset decision. `complete` means an observed message boundary; the
separate `problems` list identifies missing final status, invalid fields, bodies on
bodyless statuses, invalid status ranges and completed length mismatches. It is not
a full independent HTTP conformance validator. In particular, a framing boundary
does not prove the application completed successfully.

HTTP/1.0 uses its default connection policy, without `Connection: keep-alive`, so
normal closure and successful fresh connections are expected. HTTP/1.1 and HTTP/2
attempt a second request on the same connection. Every nonpanic ZHTPS case also
served a successful request on a fresh connection. HTTP/2 preserved the connection
after every nonpanic rejection or producer failure. A one-second read deadline is
an observation bound, not a measurement of server timeout defaults.

## Decisions

| Cases | Observation | Decision |
| --- | --- | --- |
| `fixed`, `empty`, `stream`, `stream-empty`, `stream-exact` | All servers complete the expected bytes. HTTP/1.1 and HTTP/2 remain usable. Unknown-length HTTP/1.0 output ends by closing. | Keep. |
| HEAD `fixed` and `stream` | All suppress the body. ZHTPS's existing streaming tests also prove its producer is skipped. | Keep suppression without running an unnecessary producer. |
| `status-204`, `status-205`, `status-304` | All send the bodyless response and preserve supported reuse. ZHTPS retains the known representation length on 304. | Keep. |
| `body-204` | Node/Go suppress/reject the attempted body while returning 204. ZHTPS rejects the inconsistent response metadata before emission. | Keep explicit validation of a whole response supplied by the application; silently correcting a programmer error would hide it. |
| `body-205` | ZHTPS rejects the nonempty body. Node/Go emit it over HTTP/1; Go emits it over HTTP/2 too. Node HTTP/2 suppresses it. | Keep the prohibition rather than copying invalid output. |
| `status-99`, `status-600` | All reject 99. Node/Go HTTP/1 and Go HTTP/2 emit 600; ZHTPS rejects statuses outside 100–599. | Keep the status range. |
| `status-103` as the final application result | ZHTPS rejects the invalid final response. Go supplies 103 followed by an implicit 200; Node HTTP/1 emits only 103, while its HTTP/2 API rejects it. | Keep the explicit final-status contract. The low-level HTTP/1 encoder's supported informational response API is separate. |
| `duplicate-cookie`, `empty-field` | All preserve the two Set-Cookie fields and allow an empty ordinary field. | Keep; the comparison reader preserves duplicates rather than collapsing them into a map. |
| `invalid-name`, `invalid-value`, `nul-value` | ZHTPS closes/reset-streams before output. Node HTTP/1 reports API errors. Go sometimes drops/sanitizes invalid fields and can emit a NUL value over HTTP/1. Raw Node HTTP/2 output includes malformed fields for these probes. | Keep rejection before emission; discarding/sanitizing fields can change application semantics, and emitting invalid fields is undesirable. |
| `whitespace-value` | ZHTPS trims HTTP/2 edge whitespace. Both references emitted HTTP/2 edge whitespace in this fixture. HTTP/1 OWS remains legal. | Keep protocol-specific serialization. |
| `stream-short` | ZHTPS/Go HTTP/1 close after a truncated body; Node HTTP/1 remains incomplete at the observation deadline or closes. ZHTPS HTTP/2 resets the stream. Both references send END_STREAM despite the short declared body over HTTP/2. | Keep explicit truncation detection and stream-local failure. |
| `stream-long` | ZHTPS sends no excess bytes and aborts. Go reports a write error. Node writes past the HTTP/1 length, leaving the extra byte to corrupt the following status line. In HTTP/2, both references end with a declared-length mismatch (Go sends zero body bytes). | Keep ZHTPS's strict enforcement rather than weakening it to match defaults. |
| `stream-error-before`, `stream-error-after` | HTTP/1.1 aborts without the terminating chunk; HTTP/2 resets the affected stream and serves the next request. HTTP/1.0 EOF looks like a completed close-delimited response. | Keep; HTTP/1.0 cannot distinguish successful EOF from truncation without an independent length. |
| `stream-error-exact` | Once all advertised HTTP/1 bytes arrive, the client sees a complete response, although the connection then aborts. HTTP/2 still reports reset instead of END_STREAM. | Keep; already-delivered HTTP/1 length cannot be retracted. Applications needing a success boundary after production should use unknown-length HTTP/1.1 streaming or an application-level integrity/completion signal. |
| `stream-trailer` | Native reference APIs can emit response trailers. ZHTPS's whole-response API rejects the reserved Trailer field before output; it has no producer API that supplies final trailers. | Keep the explicit unsupported-feature boundary. Merely allowing a declaration without a trailer-producing API would create a misleading partial implementation. |
| `handler-error` | ZHTPS maps the returned recoverable error to 500; the explicit Node/Go mappings also return 500. Subsequent requests succeed. | Keep recovery through ordinary error returns. |
| `panic-before`, `panic-after` | Go recovers per request, closing HTTP/1 or resetting HTTP/2. ZHTPS terminates with SIGABRT; Node exits with code 1. Fresh connections fail for the terminated servers. | Keep the distinction between recoverable errors and programmer panics. Go's recovery relies on its runtime's stack unwinding. Pretending to recover a Zig panic without unwinding owned resources/locks would risk corrupting shared server state. Use returned errors for expected failures and process supervision for fatal faults. |

Node documents [strictContentLength as opt-in](https://nodejs.org/api/http.html#responsestrictcontentlength);
this experiment uses the default. Go documents
[write errors for excess content](https://pkg.go.dev/net/http#ErrContentLength) and
[per-request panic recovery](https://pkg.go.dev/net/http#Handler). The choice to keep
ZHTPS's stricter framing and its explicit error-return boundary is an implementation
decision based on the observed outcomes, rather than a requirement to imitate either
reference in every respect.

The bodyless and field-validity decisions were also checked against
[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-15) and
[RFC 9113 §8.2.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-8.2.1).

## Reproduction and verification

```sh
zig build install-response-fixture --system zig-pkg \
  --global-cache-dir /tmp/zhtps-edge-cache --summary all
/tmp/zhtps-edge-h2/bin/python tests/response_comparison.py \
  zig-out/bin/tls-application --output /tmp/responses.json
zig build test-response-streaming test-http2 test-tls check-fmt --system zig-pkg \
  --global-cache-dir /tmp/zhtps-edge-cache \
  -Dhttp2-python=/tmp/zhtps-edge-h2/bin/python --summary all
```

The Python environment uses `tests/requirements-http2.txt`; Node, Go and OpenSSL
must be on PATH. `--filter` selects a substring such as `1.1/GET/stream-long`.
The installed fixture is a test application with intentional crash routes, not
the standalone `zhtps` service. All 90 comparisons finished. The existing response
streaming (9), HTTP/2 (40) and TLS (32) suites passed, and repository formatting
checks passed. No existing regression assertion was changed.

The [lifecycle pass](failure-modes-lifecycle.md) compares HTTP/1 producer cancellation,
deadlines, stalled readers and graceful shutdown. HTTP/2 flow control and TLS
lifecycle interactions remain in the audit. This response pass covers immediate
application/encoding failures, not those timing interactions.
