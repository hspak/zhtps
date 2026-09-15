HTTP RFC review — 2026-09-11

**Remediation status: all four reported defects are fixed.** The follow-up also
resolves the routing, method-capability, stream-framing, diagnostic-body, and
default-authority choices identified below. Current contracts and tradeoffs are
recorded in the [conformance ledger](conformance.md#implementation-choices).
This closes the review findings; it is not an independent certification of all
HTTP RFCs or of arbitrary embedded applications.

| Finding | Implemented resolution | Permanent evidence |
| --- | --- | --- |
| 1. HTTPS target on a cleartext listener | 421 and closure before application callbacks, preconditions, or 100 Continue, on both listeners | `test_rfc_https_targets_are_rejected_before_continue_and_dispatch` |
| 2. Worker pagination checked too late | Shared `parseStart` validation in the head phase for both pagination routes | `test_rfc_admin_query_errors_precede_preconditions_and_continue` |
| 3. HTTP/1.0 informational output | `Response.begin` rejects all 1xx before writing any bytes | `RFC informational responses reject HTTP 1.0 before writing` |
| 4. RFC 850 leap-day century | Select the century before calendar validation; zeit supplies calendar checks/conversion | `RFC 850 selects the century before validating leap days`; `RFC 850 leap day precondition survives century rollover` |

The three new component regressions and all six new wire behavior tests failed
against the pre-fix implementation. Their assertions were retained across the
fixes. The expanded suites contain 60 component tests and 58 raw TCP tests,
including additional coverage for UTC limits, embedded request metadata, and
stream 304 length consistency. Existing tests changed only where the borrowed
`std.Io` argument became necessary for wall-clock acquisition; their behavioral
assertions remain intact.

zeit is now used for all calendar and wall-clock operations. HTTP-specific text
grammar and the RFC 850 cutoff policy remain local. Timeouts/rate limits retain
monotonic timing, which zeit does not provide. `Server.run` and
`platform.realtimeNs` now accept the caller's `std.Io`.

Final verification with Zig 0.16.0: **60/60 component tests and 58/58 raw TCP
tests passed in both Debug and ReleaseSafe**, with no io_uring skips. All four
deployment checks passed; both benchmarks compiled, and the request-cost
workload completed a short smoke run. The 51 pre-existing wire test functions
are unchanged. Formatting and whitespace checks also passed.

```sh
zig build test test-wire --system zig-pkg \
  --global-cache-dir /tmp/zhtps-fixes-cache --summary all
zig build test test-wire test-deploy install install-hot-paths install-request-costs \
  --system zig-pkg --global-cache-dir /tmp/zhtps-fixes-cache \
  -Doptimize=ReleaseSafe --summary all
```

`--system zig-pkg` uses the locally downloaded pinned dependency; omit it when
using Zig's normal dependency download/cache mechanism.

The remainder is the original review, preserved as historical evidence. Its line
numbers, observed failures, and inferred rationale describe the pre-fix snapshot.
At review time, two mandatory-requirement gaps were reproduced in the running
server and two in the exported library; no implementation or existing test was
changed by that review.

The review covers the HTTP/1.1 origin-server role, HTTP/1.0 interoperability,
the public and admin applications, exported protocol APIs, admission, response
ordering, and connection teardown. It uses [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html),
[RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html),
[RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html), and the applicable status
definition in [RFC 6585](https://www.rfc-editor.org/rfc/rfc6585.html#section-5).
The review also checked the newer
[RFC 9931 update](https://www.rfc-editor.org/rfc/rfc9931.html#section-8): the built-in
CONNECT rejection already closes the connection without processing subsequent
requests. ZHTPS does not implement a proxy, cache, TLS endpoint, HTTP/2, HTTP/3,
WebSocket, or tunnel. Their implementation requirements are outside this scope;
declining an optional feature still needs correct HTTP behavior.

The working tree changed during the review. A source snapshot was captured in
`/tmp/zhtps-rfc-review/snapshot`, with hashes in
`/tmp/zhtps-rfc-review/snapshot-sha256.json`. A final comparison found only two
subsequent changes among the recorded files: additional parser-test assertions
and inclusion of `deploy` in the package manifest. Neither changes runtime
behavior or these findings. References below refer to the reviewed files.
Earlier historical test and fuzz claims in
`conformance.md` were not independently reconstructed.

**1. [P1] Reject cleartext requests for an HTTPS target before dispatch.**

Locations: `src/http/Request.zig:153`, `src/application/Exchange.zig:26`,
`src/server.zig:775`, and `src/server.zig:867`.

The request parser accepts an absolute `https://` URI and records its scheme.
Both applications then select resources using only `request.path`; the server
has no check tying that scheme to the connection and no configured trusted-gateway
mechanism. Direct loopback requests reproduced:

| Listener | Request line | Observed |
| --- | --- | --- |
| Public | `GET https://local/ HTTP/1.1` | `200`, body `ZHTPS\n` |
| Admin | `GET https://local/healthz HTTP/1.1` | `200` |
| Public control | `GET http://local/ HTTP/1.1` | `200`, body `ZHTPS\n` |

Each request included `Host: local` and a terminating empty line. No gateway or
TLS connection was involved. Scheme-specific security requirements are mandatory
outside the trusted-gateway exception.
([RFC 9110 §7.4](https://www.rfc-editor.org/rfc/rfc9110.html#section-7.4))

Observed impact is acceptance of a resource request under an inappropriate
scheme. Deployment-specific authentication or cache consequences would require
additional integration analysis. Treat this as a transport/routing check before
either application's callbacks or `100 Continue`. A direct cleartext HTTPS target
can receive 421; any future gateway exception needs explicit connection trust.

The documented path-only routing policy and lack of virtual-host authorization
explain the current structure, but do not provide a rationale for bypassing this
requirement. No deliberate exception or supporting security contract was found.

**2. [P2] Validate `/debug/workers` query arguments before preconditions.**

Locations: `src/server.zig:900`, `src/server.zig:910`,
`src/server.zig:956`, and `src/server.zig:1097`.

`receiveAdminHead` validates pagination for `/debug/connections` but omits
`/debug/workers`. The latter's query is first validated during response rendering.
Consequently, conditional processing can bypass a known request error:

| Request to admin listener | Observed | Required outcome |
| --- | --- | --- |
| `GET /debug/workers?start=nope` | 400 | 400 |
| Same, with `If-None-Match: *` | 304 | 400 |
| Same, with `If-Match: "missing"` | 412 | 400 |
| `/debug/connections?start=nope`, with `If-None-Match: *` | 400 | 400; control case |

Normal request failures must precede precondition evaluation.
([RFC 9110 §13.2.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.2.1))
The 304 incorrectly signals that an invalid target request can reuse a stored
representation. An additional probe with `Expect: 100-continue` and
`Content-Length: 1` received 100, then 400 after supplying the byte. This also
contradicts the ledger's claim that known errors precede 100.

Validate both pagination routes in the head phase, sharing the same parser used
by rendering. Preserve the existing `/debug/connections` coverage and add the
conditional and Expect variants for `/debug/workers`. There is no documented
tradeoff here; validation placement is inconsistent between equivalent routes.

**3. [P2] The exported response encoder emits informational HTTP/1.0 responses.**

Location: `src/http/Response.zig:78`.

Calling `Response.begin` with status 103 and an HTTP/1.0 request succeeds and
emits:

```http
HTTP/1.0 103 Early Hints
Date: Thu, 01 Jan 1970 00:00:00 GMT

```

HTTP/1.0 clients must not receive 1xx responses.
([RFC 9110 §15.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.2))
The API already validates the request version for framing and rejects 101 and
successful CONNECT, but lacks this version/status check. Reject it before any
bytes are written, and retain successful HTTP/1.1 informational serialization.

This finding affects direct users of `zhtps.http.Response`. The built-in transport
prevents application responses below 200 in `startResponse`, and its automatic
100 response is gated on HTTP/1.1, so the normal executable does not expose this
particular output. Those guards are useful but do not protect standalone encoder
consumers. A focused component probe expecting `InvalidStatus` failed.

**4. [P3] RFC 850 century selection rejects a valid leap-day date.**

Location: `src/http/date.zig:82`.

With `now = 2524608000` (2050-01-01), parsing
`Tuesday, 29-Feb-00 00:00:00 GMT` returns null. The expected interpretation is
2000-02-29, timestamp 951782400. The implementation first constructs 2100, then
validates its calendar date before deciding whether to subtract a century.
Because 2100 has no February 29, it returns before applying the rollover rule.
([RFC 9110 §5.6.7](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.7))

A second probe used that value in `If-Unmodified-Since`, with a representation
modified on 2001-01-01. Evaluation returned null instead of 412: the condition
was discarded as an invalid date. Select the century using the date components
and cutoff before validating the resulting calendar date.

The reproduction uses a future clock within the API's documented range. The
built-in resources currently have no Last-Modified validator, so present-day
traffic to those resources is unaffected. This is a library boundary defect,
not an intentional tolerance policy.

**Discretionary behavior and rationale**

“Documented” below means the reason appears in code comments or repository
documentation. “Inferred” means the implementation supports that explanation,
but the repository does not establish author intent. A SHOULD-level departure
needs an understood reason; it should not silently become a claim of complete
conformance.

| Choice and implementation | Rationale and tradeoff assessment |
| --- | --- |
| Strict CRLF, single-space request lines, no obs-fold; `Parser.feed`, `Request.parseHeader` | Strictness is documented in `conformance.md`; reducing parser disagreement is an inferred motivation. The cost is rejection of permissively parsed legacy traffic. This is a sound policy under [RFC 9112 §§2.2–3](https://www.rfc-editor.org/rfc/rfc9112.html#section-2.2). |
| Reject every repeated Content-Length, including equal values; `Request.zig:84` | Documented singleton-ambiguity policy. Simpler framing and less normalization ambiguity cost interoperability with redundant equal lengths. Rejection is expressly available in [RFC 9110 §8.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.6). Keep it. |
| Reject TE plus CL and close; validate chunk order and overflow | Documented rejection of ambiguous framing. Existing tests cover malformed input and pipeline isolation. Good boundary policy; accepting both is unnecessary. [RFC 9112 §6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3). |
| Decode chunked, reject unsupported preceding transfer codings | Documented capability boundary. Avoids decompression complexity and work budgets; clients must send supported encodings. The unsupported-coding and unframeable-request cases are distinguished. [RFC 9112 §§6.1–6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.1). |
| Ignore unknown chunk extensions; keep trailers separate and reject sensitive trailer names | Documented ownership and security policy. Bounds processing and prevents late fields from altering routing/framing. The fixed denylist is not a complete semantic registry: custom applications still need rules for newly introduced fields. [RFC 9112 §7.1](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1). |
| Explicit head, target, body, trailer, count, framing, and time limits | Documented resource-budget design. Default target limit is 8 KiB, head storage 32 KiB, and chunk overhead 64 KiB. Many tiny chunks can exhaust the overhead budget before reaching the content limit. The limits favor bounded work over accepting every syntactically valid large message. The framing-overhead error is 413, and the ledger should keep that distinction visible. |
| Admission before application work and 100; 503 or connection closure on exhaustion | Strong documented rationale in `native-admission.md` and README: bound both accepted work and rejection cost. Closing avoids unbounded queues but can amplify retries; bodyless 503 reuse mitigates reconnect cost. The transport-close latitude in [RFC 9112 §9.5](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.5) does not promise a response under exhaustion. This deployment tradeoff is explicit and tested. |
| Half-close, then drain for at most 100 ms / 64 KiB by default | Documented compromise between response delivery and slot retention. Slow peers can outlast the drain. This is a reasonable bounded version of staged teardown; it does not guarantee delivery. [RFC 9112 §9.6](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.6). |
| Sequential pipeline processing and bounded TCP batching | Ownership/order rationale is documented in README and performance notes. The cost is head-of-line blocking; the benefit is straightforward response correlation and buffer lifetime. Tests cover flushing before waiting for an incomplete next request. |
| Ignore Range, If-Range, Upgrade, and negotiation preferences | Scope is documented, but most feature-specific cost/benefit decisions are only implicit. Inferred benefits are simpler representations, cache metadata, and transport ownership. Costs include full transfers instead of ranges and no upgrade or alternate encoding support. These omissions are compatible with the selected role; see [Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-14.2), [Upgrade](https://www.rfc-editor.org/rfc/rfc9110.html#section-7.8), and [negotiation](https://www.rfc-editor.org/rfc/rfc9110.html#section-12). |
| Static ETags, no Last-Modified, opaque POST echo | The no-modification-time rationale is explicit in `Exchange.zig:45`. `/echo` represents a computation with no stored current representation, explaining `exists = false`. Fixed ETags must change when the fixed bytes change. A conditional `/stream` length is separately hardcoded as 14; regression coverage should guard that coupling. |
| HEAD does not run stream production | Documented API contract. Saves work and avoids producer side effects; streamed HEAD responses omit unknown lengths. This is compatible with the HEAD metadata allowance in [RFC 9110 §9.3.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.2). |
| Match raw paths without percent or dot-segment normalization | Behavior is observable: `/%73tream` gives 404 while `/stream` gives 200. Inferred motivation is preserving original octets and avoiding unsafe decoding. The cost is inconsistent treatment of equivalent spellings and possible differences from ingress routing. No explicit rationale was found. Establish one canonical routing policy with ingress; do not decode reserved separators indiscriminately. See [RFC 3986 §6.2.2](https://www.rfc-editor.org/rfc/rfc3986.html#section-6.2.2). |
| Accept arbitrary Host authorities and empty Host values | The absence of virtual-host authorization is documented. This simplifies a single-service deployment, but application authors must not infer host authorization from successful parsing. Empty authority stays empty in the request API; default-origin reconstruction is not exposed. Document the default origin or rejection policy, especially before adding redirects, signatures, or virtual hosting. [RFC 9112 §3.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.3). |
| Use Zig's known-method enum to distinguish 501 from 405 | `Exchange.zig:36` treats enum recognition as implementation support. For example, PUT on `/` returns 405 although no built-in route implements PUT; CONNECT falls through to 404. Explicitly disabling recognized methods could explain this policy, but that rationale is absent. Prefer a server capability set and separate per-resource Allow; the recommended distinction is in [RFC 9110 §9.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.1). |
| Use close-delimited HTTP/1.1 streams whenever closure is selected | `Response.zig:103` makes chunking conditional on keeping the connection. Omitting chunks saves a little framing, but loses explicit completion detection even when the encoder could produce a terminating chunk. This SHOULD-level departure has no documented rationale. Prefer chunking HTTP/1.1 streams even with `Connection: close`; retain close delimiting for HTTP/1.0. [RFC 9112 §6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3). |
| Empty error responses; no Retry-After on 503 | Cheap overload rejection is documented; applying empty bodies to every error is not separately justified. Static bounded diagnostic bodies could improve usability without allocation. Explanations are recommended by [RFC 9110 §§15.5–15.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5); Retry-After is optional for 503. This is a rationale gap, not a missing mandatory 503 field. |

**Coverage and verification**

The snapshot passed **53/53 component tests and 51/51 raw TCP tests** in Debug
with Zig 0.16.0, including the io_uring cases. The initial sandboxed run skipped
six io_uring cases; the completed runs used the permitted local execution
environment. Test counts grew during the concurrent workspace changes, which is
why the final snapshot was rebuilt and verified.

```sh
cd /tmp/zhtps-rfc-review/snapshot
zig build test test-wire --global-cache-dir /tmp/zhtps-rfc-review/zig-cache --summary all
```

Separate audit probes deliberately exercised previously uncovered cases:

```sh
python3 /tmp/zhtps-rfc-review/wire_probe.py /tmp/zhtps-rfc-review/snapshot/zig-out/bin/zhtps
zig test --global-cache-dir /tmp/zhtps-rfc-review/zig-cache \
  --dep zhtps -Mroot=/tmp/zhtps-rfc-review/probe.zig \
  -Mzhtps=/tmp/zhtps-rfc-review/snapshot/src/root.zig --test-filter review
```

The wire observations are recorded in `/tmp/zhtps-rfc-review/wire-results.jsonl`.
All three focused component assertions failed: one for finding 3, and two for
finding 4, including the externally meaningful precondition result. The temporary
probe files and snapshot are session artifacts. This report preserves their key
inputs and observed outputs; the production regression suite remains unchanged.

| Area reviewed | Assessment of current evidence |
| --- | --- |
| Start lines, Host, targets, field syntax, list handling, version compatibility | Good existing parser and wire coverage; scheme/connection validation is missing. |
| CL/TE precedence, bodies independent of method, chunk extensions, trailers, size/overflow boundaries | No additional framing violation found in the reviewed paths. Tests exercise fragmentation, malformed input, and reuse boundaries. |
| GET/HEAD/POST/OPTIONS, Allow, preconditions, validators | Built-in normal paths are covered; worker-query ordering and the date boundary remain gaps. Method capability policy needs a rationale. |
| Response bytes/streams, 204/205/304, length enforcement, injection prevention, Date | Built-in framing is covered. The exported informational encoder needs the HTTP/1.0 check; close-delimited HTTP/1.1 streams merit reconsideration. |
| Persistence, pipeline ordering, early responses, EOF, timeouts, partial writes, teardown, cancellation | Broad functional and fault-injection coverage. No additional violation identified. This does not prove all kernel timing interleavings. |
| Admin and observability | Separate listener, bounded snapshots, no-store on generated diagnostic representations, and escaped JSON are established. Admin access is deployment trust, not authentication supplied by this server. |
| Extensible application semantics | Callers own status-specific fields, validators, representation metadata, and transactional side effects. `receiveBody` can run before a later framing/trailer failure; applications that mutate persistent resources need their own commit/rollback discipline. |

The fragmentation fuzzer checks agreement between fragment sizes. That is useful
for incremental parsing but cannot establish that an interpretation shared by all
fragment sizes matches the RFC. Add the reproduced cases as durable regressions
when fixing them, and retain the existing behavioral coverage.

`docs/conformance.md` currently overstates routing, precondition ordering, and
date coverage, and its 34-component/40-wire counts are stale. Revise those claims
after fixing the demonstrated failures. Full conformance should remain an open
review outcome until the mandatory gaps and the documented SHOULD-level choices
have been resolved.
