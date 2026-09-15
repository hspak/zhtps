# HTTP conformance audit

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

Scope: an HTTP/1.1 origin server, with HTTP/1.0 interoperability. Normative sources
are [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html) (wire protocol) and
[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) (semantics). URI components
follow [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html).

This ledger describes HTTP/1. For the implemented HTTP/2 transport, stream
ownership, limits, and verification, see [HTTP/2](http2.md).

This is an implementation requirements/evidence ledger, not independent
certification. It covers the built-in origin application and protocol layer;
custom applications retain the semantic responsibilities described below.

## Wire protocol

| Requirement | Implementation / evidence |
|---|---|
| RFC 9112 §§2–3: octet parsing, CRLF lines, method token, request target, version | Incremental Parser + Request; malformed head and fragmented wire tests. Strict CRLF is an allowed parsing choice. Leading empty lines are ignored up to an explicit bound. |
| §2.3: same-major minor-version interoperability | HTTP/1.9 is processed with HTTP/1.1 semantics and receives an HTTP/1.1 response; permanent wire regression. Unsupported major versions receive 505. |
| §3.2: origin/absolute/authority/asterisk target forms | Request target parser, percent validation, authority tests. Absolute-form authority overrides Host. Asterisk only for OPTIONS; authority form only for CONNECT. CONNECT tunneling is declined with 501. The cleartext runtime rejects HTTPS targets with 421 before callbacks or 100 Continue. |
| §3.2: exactly one valid Host in HTTP/1.1 | Missing, duplicate, malformed Host returns 400; parser and wire tests. |
| §4: response status line | Response encoder emits version, three-digit status and optional reason, then CRLF. |
| §5: field-name grammar, whitespace, obsolete folding | Rejects whitespace before colon, invalid field bytes and obs-fold with 400. OWS around values is removed. Unknown headers remain available to applications. |
| §6.1: transfer codings | Decodes chunked; rejects unsupported preceding codings with 501, invalid order with 400. Chunked parameters are rejected. HTTP/1.0 transfer coding is rejected. Repeated fields combine as a list, including empty members; permanent regression. |
| §§6.2–6.3: Content-Length, ambiguity, method-independent boundaries | Strict decimal/overflow checks, reject repeated Content-Length (including equal values), reject TE+CL and close. GET bodies are framed; unframed POST is empty. Permanent parser/wire tests. |
| §6.3: HEAD/1xx/204/304 response framing | Encoder suppresses content correctly; no framing fields on 1xx/204; HEAD and 304 lengths describe the selected representation. Unit and conditional wire tests. HTTP/1.0 1xx responses fail validation before serialization. |
| §6.3: unknown response length | HTTP/1.1 streams use chunks even with Connection: close, including a terminating zero chunk. Only HTTP/1.0 uses close-delimited streaming. Permanent wire regression. |
| §7.1: chunk sizes, extensions, delimiters, trailers | Incremental hexadecimal parser with checked arithmetic, bounded extension lines, cumulative chunk framing and trailer storage; ignores unknown extensions. Fragmented chunked echo, grammar, overflow, trailer and pipelining tests. |
| §7.1.2: trailers remain separate | `request.trailers` is separate from `request.headers`; routing/framing/authentication trailer names are rejected and never merged into the head. |
| §8: incomplete messages | EOF before body completion returns 400 when a response is still possible; partial header/body deadlines return 408 and close. Half-close/truncated body wire tests. |
| §§9.3–9.3.2: persistence and pipelining | Sequential responses, complete framing before reuse, Connection close dominance, HTTP/1.0 opt-in keep-alive. GET/HEAD/chunked/conditional pipelining tests. |
| §9.6: teardown | Half-close write, bounded read drain, then close. Pending kernel references survive cancellation until all related CQEs are collected. Churn, half-close, unread-log, slow-writer, active-shutdown, late-cancellation and fatal-error ownership tests. |

## Semantics

| Requirement | Implementation / evidence |
|---|---|
| RFC 9110 §§5–6: fields, lists, dates | Case-insensitive field names; list handling for Connection, Transfer-Encoding, Expect and validators. HTTP-date supports IMF-fixdate, RFC 850 and asctime, leap seconds and the 50-year rule. zeit supplies calendar validation/conversion; strict HTTP grammar remains local. Regression tests cover leap-day century selection before validation and propagation into preconditions. |
| §6.6.1: Date | Cached IMF-fixdate generated with zeit in UTC for final responses, including errors. Golden fixtures cover leap centuries and year 9999; logged wall-clock timestamps also use zeit. |
| §§7–8: routing and representation metadata | Both listeners normalize unreserved escapes and dot segments for routing; raw target/headers remain unchanged. Absolute authority overrides Host; empty authority uses a listener-specific default. No virtual-host authorization policy is claimed. ETag values identify fixed GET representations; application fields cannot override transport framing. |
| §8.6: Content-Length | Encoder computes byte lengths, verifies streamed lengths and prevents forbidden framing fields. HEAD/304 representation lengths are handled explicitly. |
| §§9.2–9.3: method semantics | GET and HEAD supported for read resources, POST for echo, OPTIONS for resource capabilities. The public capability set is GET/HEAD/POST/OPTIONS; admin implements GET/HEAD/OPTIONS. All other methods receive 501; implemented methods disallowed on a public resource receive 405 with accurate Allow. No application side effects occur before admission or precondition checks. |
| §10.1.1: Expect/100 Continue | Known errors/admission failures precede 100; valid lists combine 100-continue; unsupported expectations receive 417. HTTP/1.0 100-continue is ignored. Both admin pagination routes validate queries before conditions or 100. |
| §10.2.1: Allow | Per-resource method sets, including 405 and OPTIONS. Wire regression verifies POST is not advertised for `/`. |
| §12: content negotiation | The application serves one selected representation and may ignore negotiation preferences, as permitted. No compression negotiation is implemented. |
| §13: preconditions | If-Match strong comparison; If-None-Match weak comparison; precedence over date validators; safe retrieval yields 304, other failed conditions 412; missing/invalid/repeated date handling. Preconditions follow normal route/method checks and are ignored for OPTIONS/TRACE/CONNECT. Component and wire regressions. |
| §14: Range | Range support is optional. Range and If-Range are ignored; full representations are returned. No partial PUT support. |
| §15: status-specific requirements | Relevant generated statuses have appropriate framing and Allow. Routine errors include bounded static text explanations with HEAD suppression; 503 remains empty to bound rejection cost. Retry-After is optional and is not emitted because recovery time is unknown. 205 is encoded with zero content. |
| §17: input boundaries | Explicit head, target, field-count, body, extension, trailer and time limits; no ambiguous framing reuse. JSON escaping, bounded queues and fixed metrics cardinality limit observability costs. |

Proxy forwarding, caching, TLS client authentication, CONNECT tunneling, Upgrade,
authentication challenges, conditional mutations of application-owned resources,
and status-specific requirements for responses the built-in application does not
generate are separate responsibilities. A custom application must meet the
semantics of the methods/statuses/fields it introduces; a generic transport cannot
infer its authorization, representation history, or transaction effects.

## Implementation choices

- Parsing uses strict CRLF and rejects obsolete folding and repeated
  Content-Length, including equal values. This favors one framing interpretation
  over compatibility with redundant or permissive senders. TE plus CL is rejected
  and the connection closes. Unknown chunk extensions are ignored within limits;
  unsupported transfer codings receive 501 rather than being partially decoded.
- Both listeners apply RFC 3986 unreserved-escape, percent-hex case, and
  dot-segment normalization before routing. Reserved characters such as `%2F`
  stay escaped, repeated slashes remain distinct, and the query is untouched.
  Original target/header bytes remain available for logging and signature
  verification. An 8 KiB buffer per connection preserves both views without
  per-request allocation; default buffer reservation is now 160 KiB per slot.
  Ingress and applications must use the same routing interpretation.
- The built-in service accepts any syntactically valid supplied HTTP authority.
  Empty Host and HTTP/1.0 requests without Host use the configured listener IP
  and actual bound port (omit 80; bracket IPv6). Wildcard binds therefore use
  their literal configured address as the fallback. This is a default service,
  not host authorization or a public URL-discovery mechanism. An application
  that generates public absolute URLs must supply its deployment's public origin.
  Forwarded scheme/host fields are not trusted; a cleartext request for an HTTPS
  target receives 421 and closure even when Host names an HTTP resource.
- GET/HEAD/POST/OPTIONS are actual public capabilities. Admin has no POST
  capability. Enum recognition does not imply implementation, so PUT, DELETE,
  PATCH, TRACE, CONNECT and extension methods receive 501. Per-resource 405 and
  Allow apply only within an implemented capability set.
- Chunking remains enabled when an HTTP/1.1 stream must close. A small framing
  cost buys explicit completion detection; HTTP/1.0 still needs close delimiting.
  HEAD skips producer work and may omit unknown representation lengths. Static
  304 lengths derive from the bytes/fragments used for the corresponding GET.
- Routine errors carry static text under 512 bytes and never echo request input.
  HEAD carries the same length while suppressing content. Empty 503 responses,
  rejection quotas, and eventual connection closure bound overload cost.
  Retry-After is omitted because the server cannot predict capacity recovery.
  Sequential pipeline handling preserves response order, at the cost of
  head-of-line blocking. Bounded half-close/drain balances delivery against slot
  retention; it cannot guarantee delivery to indefinitely slow peers.
- Date syntax remains strict and accepts all three HTTP-date forms. zeit 0.9.0
  supplies UTC calendars, weekday/month names, leap-year checks, Unix conversion,
  response date formatting, and wall-clock acquisition. Its general text parsers
  do not implement the full HTTP-date contract. RFC 850's two-digit year is
  resolved against the full civil date/time before validating the chosen date;
  the 50-year anniversary of a leap day clamps to that month's last day. Leap
  seconds map to the following Unix second. Monotonic deadlines and durations
  retain the Linux clock: zeit's wall clock is not suitable for elapsed time.
- Fixed representations use static ETags and have no modification time;
  maintainers must change an ETag when its bytes change. POST echo computes a
  result rather than updating a stored representation. Range, Upgrade, and
  negotiation preferences are ignored: these optional features would add
  alternate representation/framing or transport ownership rules for no benefit
  to the built-in routes. The tradeoff is full responses and no protocol switch
  or alternate encoding. Custom applications must implement the semantics they
  introduce and review any additional sensitive trailer fields.

## Verification and operational boundaries

- URI/authority, start-line, field-byte, list, framing, chunk and trailer parsing
  were reviewed against the referenced grammar. Strict rejection choices and
  configured size limits are explicit; no malformed message is reused as a new
  request after an error. Host and Content-Length singleton ambiguity is rejected.
- The response API validates wire syntax and framing. Applications must supply
  semantically valid field values and status-specific fields such as Allow or
  WWW-Authenticate. The built-in application only generates the statuses covered
  above. Range, negotiation, upgrade, and method choices are explicit optional
  behaviors, not partially implemented features.
- The RFC follow-up fixes are covered by 60 component tests and 58 raw TCP
  tests. The reported defects and routing/method/framing/error-body cases were
  reproduced before implementation; the same regression tests pass afterward.
  Additional tests cover embedded request metadata, UTC boundary dates, and
  stream 304 representation lengths.
- The original conformance pass covered 34 component tests and 40 raw TCP tests.
  The later [security review](security.md) records the expanded suite and results.
  The component suite includes actual io_uring fault injection; it must run in an
  environment permitting io_uring. Those cases explicitly skip when sandboxed.
- Fragmentation fuzz campaigns passed 101,658 Debug cases initially and 101,027
  after the final grammar fix. LLVM and the error-tracing flag in [the testing guide](testing.md) resolve
  the toolchain issues without disabling runtime safety.
- Descriptor exhaustion has a permanent regression and 100 ms retry backoff.
  Fatal loop errors synchronously cancel by operation token and drain completions
  before returning. Unsubmitted entries do not require nonexistent CQEs, and
  accepted descriptors in abandoned CQ batches are closed. Linux 6.0 synchronous
  cancellation is probed before the server submits any work.
- Cancellation must finish before its buffers can be released. Uninterruptible
  kernel I/O can extend shutdown beyond the work-drain deadline. Losing both
  cancellation and CQ access to the private ring terminates the process instead
  of freeing referenced buffers.
- Normal idle expiration and response-drain expiration do not count as request
  failures. Header/body/write timeout counters are separate. Admin resource
  preconditions run before 100 Continue, just like public resource preconditions.
- The [ReleaseSafe load sweep](runs/standalone.json "Summary of docs/load-sweep.json; raw artifact retired") maintains its configured admission
  rate under excess offers, exercises both 503 and close-without-response paths,
  and recovers afterward. Python scheduling lag limits latency interpretation;
  the result is not a measurement of maximum server capacity.

- Worker ownership, aggregated metrics, per-worker load shedding, remote admin
  snapshots and shutdown are covered by the [worker verification](workers.md).
  A small submission queue is tested with more active receives than SQ slots;
  cancellation remains safe across incremental submissions.

## Regression history

The following permanent tests failed against the implementation before their
fixes and were retained unchanged across those fixes: HTTP/1.9 compatibility,
per-resource Allow, conditional root representation, streaming response reuse,
valid Expect lists, combined Transfer-Encoding fields, configuration resource
budgets, descriptor exhaustion, admin preconditions, idle-timeout accounting,
fatal completion ownership, and late canceled receives during response drain.
The listening-event test harness changed from a generic `bytes` field to `port`
when the log schema was clarified; it retains ephemeral listener discovery and
structured-log coverage.
