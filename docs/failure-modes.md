# Failure modes compared with Node and Go

This audit is in progress. The first pass exercises 90 HTTP/1 cases and 46 HTTP/2
cases against real local servers. It fixes two HTTP/2 validation gaps. The
[response-failure pass](failure-modes-responses.md) adds 90 cases over HTTP/1.0,
HTTP/1.1 and HTTP/2 and retains the existing production response policy. The
[lifecycle pass](failure-modes-lifecycle.md) adds 32 HTTP/1.1 cases covering deadlines,
half-closes, resets, unread bodies and shutdown. The
[HTTP/2 control-frame pass](failure-modes-http2-control.md) adds 78 cases covering
control frames, HPACK, bounded floods, flow control and fatal-error cancellation,
for 336 cases so far. The remaining work below is part of the same audit; this is
not a claim that every server failure mode has been covered.

## Setup and interpretation

Measured on 2026-09-17 with Zig 0.16.0, Node v26.9.0 and Go
go1.27.1-X:nodwarf5 on Linux amd64. ZHTPS's baseline production sources were commit
`2e7ae2b`; the after run includes the changes described here. The builds use the
repository's pinned OpenSSL 3.5.8 and nghttp2 1.70.0 sources.

The checked-in runners send the same request bytes or HTTP/2 fields to all three
servers. Each Node/Go fixture reads the body and returns its bytes for `/echo`, or
`ZHTPS\n` otherwise. Parser, expectation and protocol behavior use library defaults.
Go's fixture explicitly sends 400 when its body reader returns an error; those
results include application behavior. Neither fixture implements ZHTPS's routing,
method capabilities, admission policy or resource limits. Those differences require
a policy decision, rather than an assertion that every status should match.

HTTP/1 cases normally request connection closure, and record every response status
plus EOF/reset/timeout. Separate pipeline cases check boundaries and ordering.
The client has a two-second observation timeout, not a measurement of the servers'
default timeouts. Small writes exercise fragmented input but TCP may coalesce them.
HTTP/2 runs over TLS with ALPN and disables client-side field normalization and
validation so malformed fields reach the servers. After each completed/reset stream,
the client requests `/` on the same connection. ZHTPS returned 200 to every such
neighbor, both before and after the fixes. No ZHTPS case crashed or timed out.

The HTTP/2 comparison sends request content immediately. ZHTPS can therefore omit
100 once input is complete; the regression suite separately waits for 100 before
sending content to verify that clients waiting for permission do not deadlock.
The Node result for a coalesced pipeline after `Connection: close` is an observation
of these writes, not a timing-independent guarantee about every packet layout.

Machine-readable results include each case, baseline and changed ZHTPS outcomes,
and both reference outcomes: [HTTP/1](runs/failure-modes-http1.json) and
[HTTP/2](runs/failure-modes-http2.json). The runners produce the full HTTP/1 response
bytes too; the retained summaries omit volatile dates and preserve status/closure
observations. Request bytes remain reproducible from the source corpus and are
identified by their length and SHA-256 in the HTTP/1 summary.

## Adopted behavior

**Reject malformed HTTP/2 fields instead of silently discarding them.** An initial
`authorization` field containing NUL, for example, previously disappeared and the
request returned 200. Go resets the stream; Node and the old ZHTPS accept it after
nghttp2 discards the field. Rejecting avoids changing request semantics through
field loss. ZHTPS now registers nghttp2's invalid-field callback and returns a
stream-local protocol error for malformed headers and trailers. It also rejects
leading/trailing field whitespace, as required by
[RFC 9113 §8.2.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-8.2.1), although
both reference servers accepted those particular probes. The callback's stream
error behavior is defined by
[nghttp2](https://nghttp2.org/documentation/types.html#c.nghttp2_on_invalid_header_callback).
No extra allocation or field scan is added to valid traffic.

**Use the same Expect list validation for HTTP/1 and HTTP/2.** HTTP/2 previously
required the first Expect field to equal `100-continue` exactly. This rejected valid
lists and empty fields, and ignored unsupported expectations in later fields.
Go accepts the valid list/empty cases; Node rejects an unknown expectation in a
later repeated field. Both are useful behaviors. A shared parser now ignores empty
members, recognizes case-insensitive `100-continue`, and rejects any other member
with 417 before an interim response or application dispatch. Every repeated field
is validated. Existing HTTP/1 results are unchanged. This follows the list rules
and expectation semantics in [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.1.1).

Five new end-to-end tests failed on the unchanged executable (15 failing subcases)
and passed without test edits after the fixes. They cover invalid names/values,
malformed trailers, waiting for 100 with valid lists and repeated fields, rejection
of later unsupported expectations without 100, empty expectations, and successful
neighbor requests after each scenario.

## Retained choices

| Concern | Decision and reason |
| --- | --- |
| HTTP/1 versions | Keep same-major minor-version compatibility and 505 for unsupported major versions, matching Go in these cases. Node's acceptance of textual HTTP/2.0 or 0.9 is not useful for an HTTP/1 origin listener. |
| Request-line/field grammar | Keep strict spacing, CRLF, tokens and no folded fields. Go's tolerance for bare LF/folding and Node's extra-space tolerance add parser disagreement without a needed application capability. |
| Methods, targets, Host | Keep capability-specific 501s, authority validation, percent validation and scheme/transport checks. Reference applications intentionally accept more paths and methods; this does not establish a reason to broaden ZHTPS's application or proxy role. |
| Content-Length and Transfer-Encoding | Keep singleton lengths, TE+CL rejection, overflow rejection and chunk ordering. Go accepts equal duplicate lengths and TE+CL; rejecting ambiguity remains desirable. |
| Transfer coding lists | Keep valid empty list members and repeated fields. Unsupported codings before final chunked receive 501; unframeable requests receive 400. Do not copy Node's acceptance of a coding ZHTPS cannot decode. |
| Chunk extensions | Keep RFC grammar and bounded work. Accept valid extension whitespace, reject malformed extension names, signed sizes, overflow and invalid delimiters. Both references accepting a malformed extension does not make it desirable. |
| Trailers | Keep sensitive-field rejection and separation from initial headers. Reference acceptance of late authorization/Host/length fields would weaken the existing application boundary. |
| Limits | Keep bounded target/head/count budgets and explicit 414/431. Node/Go have different defaults; raising limits to obtain identical results would undo deliberate resource bounds. |
| EOF and pipelines | Preserve completed responses, reject truncated requests, and stop after an error/close. The corpus found no needed change. |
| HTTP/2 malformed pseudo-fields and framing | Keep stream-local resets for missing/duplicate/invalid pseudo-fields and length mismatches. Go sometimes returns 400 from the body-reading handler; Node closed a connection for one excess-body case. Isolating the bad stream is preferable. |
| HTTP/2 authority and trailers | Keep rejection of conflicting Host/:authority and sensitive trailers. Neither reference's permissiveness provides a reason to weaken those checks. |
| 100 timing | Keep omission after body completion and on known bodyless requests. The request can receive its final response without an unnecessary interim response. |

Node's public defaults and compatibility API are described in its
[HTTP](https://nodejs.org/api/http.html) and [HTTP/2](https://nodejs.org/api/http2.html)
documentation. Go's HTTP/1 parsing/expectation behavior was cross-checked against
[server.go](https://go.dev/src/net/http/server.go) and
[transfer.go](https://go.dev/src/net/http/transfer.go); the installed Go source under
`src/net/http/internal/http2` was used for HTTP/2 inspection. Measured results, rather
than a different release's documentation, determine the tables below.

## Validation and reproduction

Debug: 122 component/checksum tests, all 115 tests under `test-wire`, 40 HTTP/2 tests
and 32 TLS tests passed, with no skips. The first combined run had one failure while
the existing shutdown test tried to establish backpressure before sending a signal.
The unchanged test passed alone, then the complete wire target passed on retry.
ReleaseSafe: 122 component/checksum, 40 HTTP/2 and 32 TLS tests passed with no skips.
Both differential corpora were rerun after the fixes. Node/Go status and terminal
outcomes were unchanged between runs; all 90 ZHTPS HTTP/1 outcomes were unchanged.

```sh
zig build install test test-wire test-http2 test-tls --system zig-pkg \
  --global-cache-dir /tmp/zhtps-edge-cache \
  -Dhttp2-python=/tmp/zhtps-edge-h2/bin/python --summary all
zig build test test-http2 test-tls --system zig-pkg \
  --global-cache-dir /tmp/zhtps-edge-cache -Doptimize=ReleaseSafe \
  -Dhttp2-python=/tmp/zhtps-edge-h2/bin/python --summary all
python3 tests/http1_comparison.py zig-out/bin/zhtps --output /tmp/http1.json
/tmp/zhtps-edge-h2/bin/python tests/http2_comparison.py zig-out/bin/zhtps \
  --output /tmp/http2.json
```

Create the temporary HTTP/2 environment using the instructions in [http2.md](http2.md#verification).
The comparisons also require Node and Go on PATH. `--system zig-pkg` uses the
already-downloaded pinned dependencies; omit it when using normal Zig downloads.
Socket and io_uring tests must run where those operations are allowed.

## Remaining audit work

These areas have existing ZHTPS tests, but still require direct reference comparison
and a decision on differences as part of this goal:

- Response encoding and immediate application failures are compared in the
  [response pass](failure-modes-responses.md). HTTP/1 deadlines, producer cancellation,
  half-close/reset handling, unread bodies and graceful shutdown are compared in the
  [lifecycle pass](failure-modes-lifecycle.md). TLS/HTTP/2 lifecycle interactions remain.
- Resource pressure: connection/request/stream limits, allocation failure,
  descriptor exhaustion, admission recovery and fairness.
- The [HTTP/2 control-frame pass](failure-modes-http2-control.md) compares malformed
  frames and HPACK, CONTINUATION bounds, stream resets, bounded SETTINGS/PING
  floods, flow-control violations, zero-window stalls, peer GOAWAY and fatal errors
  with active work. Server-initiated GOAWAY races, receive-window exhaustion while
  an application refuses input, and sustained resource pressure remain.
- TLS: handshake failures/deadlines, unsupported protocol/ciphers, ALPN, abrupt EOF,
  close_notify, key updates/resumption, and shutdown with records in flight.
- Resource semantics: path normalization, conditional requests, range/static-file
  behavior, and differences between standalone and embedded applications.

## Enumerated observations

All HTTP/1 cases ended with EOF in both runs. HTTP/2 `RST(1)` means a protocol-error
stream reset; `GOAWAY(2)` is a connection-level internal error. Multiple statuses
show interim responses or pipeline responses in order. The JSON contains response
completion and neighbor results. Case names map directly to the runner source.

### HTTP/1

| Case | ZHTPS before | ZHTPS after | Node | Go |
| --- | --- | --- | --- | --- |
| `ordinary_get` | 200 | 200 | 200 | 200 |
| `head` | 200 | 200 | 200 | 200 |
| `version_1.0` | 200 | 200 | 200 | 200 |
| `version_1.9` | 200 | 200 | 400 | 200 |
| `version_2.0` | 505 | 505 | 200 | 505 |
| `version_0.9` | 505 | 505 | 200 | 505 |
| `version_01.1` | 400 | 400 | 400 | 400 |
| `version_1.10` | 400 | 400 | 400 | 400 |
| `tab_separator` | 400 | 400 | 400 | 400 |
| `double_space` | 400 | 400 | 200 | 400 |
| `lowercase_method` | 501 | 501 | 400 | 200 |
| `unknown_method` | 501 | 501 | 400 | 200 |
| `invalid_method` | 400 | 400 | 400 | 400 |
| `absolute_target` | 200 | 200 | 200 | 200 |
| `https_on_cleartext` | 421 | 421 | 200 | 200 |
| `bad_percent` | 400 | 400 | 200 | 400 |
| `fragment_in_target` | 400 | 400 | 200 | 200 |
| `raw_non_ascii` | 400 | 400 | 400 | 200 |
| `connect` | 501 | 501 | no response | 200 |
| `asterisk_get` | 400 | 400 | 200 | 200 |
| `leading_crlf` | 200 | 200 | 200 | 400 |
| `nine_leading_crlf` | 400 | 400 | 200 | 400 |
| `bare_lf` | 400 | 400 | 400 | 200 |
| `missing_host` | 400 | 400 | 400 | 400 |
| `empty_host` | 200 | 200 | 200 | 200 |
| `duplicate_host` | 400 | 400 | 200 | 400 |
| `host_space` | 400 | 400 | 200 | 400 |
| `host_bad_port` | 400 | 400 | 200 | 200 |
| `host_bad_ipv6` | 400 | 400 | 200 | 200 |
| `host_userinfo` | 400 | 400 | 200 | 400 |
| `header_space_before_colon` | 400 | 400 | 400 | 400 |
| `obs_fold` | 400 | 400 | 400 | 200 |
| `header_nul` | 400 | 400 | 400 | 400 |
| `header_del` | 400 | 400 | 400 | 400 |
| `header_obs_text` | 200 | 200 | 200 | 200 |
| `empty_header_name` | 400 | 400 | 400 | 400 |
| `duplicate_cl_equal` | 400 | 400 | 400 | 200 |
| `duplicate_cl_different` | 400 | 400 | 400 | 400 |
| `cl_list` | 400 | 400 | 400 | 400 |
| `cl_plus` | 400 | 400 | 400 | 400 |
| `cl_negative` | 400 | 400 | 400 | 400 |
| `cl_hex` | 400 | 400 | 400 | 400 |
| `cl_leading_zero` | 200 | 200 | 200 | 200 |
| `cl_empty` | 400 | 400 | 400 | 400 |
| `cl_overflow` | 400 | 400 | 400 | 400 |
| `te_and_cl` | 400 | 400 | 400 | 200 |
| `te_unsupported` | 400 | 400 | 400 | 501 |
| `te_before_chunked` | 501 | 501 | 200 | 501 |
| `te_after_chunked` | 400 | 400 | 400 | 501 |
| `te_duplicate_chunked` | 400 | 400 | 400 | 501 |
| `te_parameter` | 400 | 400 | 400 | 501 |
| `te_empty` | 400 | 400 | 400 | 501 |
| `te_list_empty_members` | 200 | 200 | 400 | 501 |
| `te_repeated_empty_field` | 200 | 200 | 400 | 501 |
| `connection_invalid_token` | 400 | 400 | 200 | 200 |
| `expect_unknown` | 417 | 417 | 417 | 417 |
| `expect_empty` | 200 | 200 | 417 | 200 |
| `ordinary_chunk` | 200 | 200 | 200 | 200 |
| `chunk_extension` | 200 | 200 | 200 | 200 |
| `chunk_quoted_extension` | 200 | 200 | 200 | 200 |
| `chunk_extension_whitespace` | 200 | 200 | 400 | 400 |
| `chunk_trailing_whitespace` | 400 | 400 | 400 | 200 |
| `chunk_plus` | 400 | 400 | 400 | 400 |
| `chunk_hex_prefix` | 400 | 400 | 400 | 400 |
| `chunk_overflow` | 400 | 400 | 400 | 400 |
| `chunk_invalid_extension` | 400 | 400 | 200 | 200 |
| `chunk_bare_lf` | 400 | 400 | 400 | 400 |
| `chunk_bad_delimiter` | 400 | 400 | 400 | 400 |
| `trailer` | 200 | 200 | 200 | 200 |
| `trailer_content_length` | 400 | 400 | 400 | 200 |
| `trailer_authorization` | 400 | 400 | 200 | 200 |
| `trailer_obs_fold` | 400 | 400 | 400 | 200 |
| `expect_continue` | 100, 200 | 100, 200 | 100, 200 | 100, 200 |
| `expect_list` | 100, 200 | 100, 200 | 100, 200 | 100, 200 |
| `expect_zero_body` | 200 | 200 | 100, 200 | 200 |
| `fixed_body` | 200 | 200 | 200 | 200 |
| `unframed_post` | 200 | 200 | 200 | 200 |
| `truncated_head` | 400 | 400 | 400 | 400 |
| `truncated_fixed` | 400 | 400 | 400 | 400 |
| `truncated_chunk` | 400 | 400 | 400 | 400 |
| `truncated_trailer` | 400 | 400 | 400 | 400 |
| `complete_half_close` | 200 | 200 | 200 | 200 |
| `fragmented_chunk` | 200 | 200 | 200 | 200 |
| `pipeline` | 200, 200 | 200, 200 | 200, 200 | 200, 200 |
| `pipeline_fixed_body` | 200, 200 | 200, 200 | 200, 200 | 200, 200 |
| `pipeline_malformed_then_get` | 400 | 400 | 400 | 400 |
| `pipeline_close_then_get` | 200 | 200 | 400 | 200 |
| `header_count_129` | 431 | 431 | 200 | 200 |
| `header_bytes_40k` | 431 | 431 | 431 | 200 |
| `target_bytes_9k` | 414 | 414 | 200 | 200 |

### HTTP/2

| Case | ZHTPS before | ZHTPS after | Node | Go |
| --- | --- | --- | --- | --- |
| `ordinary_get` | 200 | 200 | 200 | 200 |
| `host_matches` | 200 | 200 | 200 | 200 |
| `host_mismatch` | 400 | 400 | 200 | 200 |
| `duplicate_host` | RST(1) | RST(1) | RST(1) | 200 |
| `duplicate_authority` | RST(1) | RST(1) | RST(1) | RST(1) |
| `unknown_pseudo` | RST(1) | RST(1) | RST(1) | RST(1) |
| `connection` | RST(1) | RST(1) | RST(1) | 400 |
| `transfer_encoding` | RST(1) | RST(1) | RST(1) | 400 |
| `te_trailers` | 200 | 200 | 200 | 200 |
| `te_gzip` | RST(1) | RST(1) | RST(1) | 400 |
| `uppercase_header` | RST(1) | RST(1) | RST(1) | RST(1) |
| `header_nul` | 200 | RST(1) | 200 | RST(1) |
| `header_leading_space` | 200 | RST(1) | 200 | 200 |
| `header_trailing_space` | 200 | RST(1) | 200 | 200 |
| `cl_plus` | RST(1) | RST(1) | RST(1) | 200 |
| `cl_negative` | RST(1) | RST(1) | RST(1) | 200 |
| `duplicate_cl` | RST(1) | RST(1) | RST(1) | 200 |
| `cl_nonzero_ended` | RST(1) | RST(1) | RST(1) | RST(1) |
| `expect_unknown` | 417 | 417 | 417 | 200 |
| `expect_empty` | 417 | 200 | 417 | 200 |
| `expect_list` | 417 | 200 | 417 | 100, 200 |
| `expect_duplicate_unknown` | 200 | 417 | 417 | 100, 200 |
| `empty_path` | RST(1) | RST(1) | RST(1) | RST(1) |
| `relative_path` | RST(1) | RST(1) | RST(1) | RST(1) |
| `absolute_path` | RST(1) | RST(1) | RST(1) | RST(1) |
| `asterisk_get` | RST(1) | RST(1) | RST(1) | 200 |
| `path_fragment` | 400 | 400 | 200 | 200 |
| `path_invalid_percent` | 400 | 400 | 200 | RST(1) |
| `path_nul` | RST(1) | RST(1) | RST(1) | RST(1) |
| `query_only_path` | RST(1) | RST(1) | RST(1) | RST(1) |
| `query_only_empty` | RST(1) | RST(1) | RST(1) | RST(1) |
| `missing_method` | RST(1) | RST(1) | RST(1) | RST(1) |
| `missing_scheme` | RST(1) | RST(1) | RST(1) | RST(1) |
| `missing_authority` | RST(1) | RST(1) | RST(1) | 200 |
| `missing_path` | RST(1) | RST(1) | RST(1) | RST(1) |
| `host_without_authority` | 200 | 200 | 200 | 200 |
| `fixed_body` | 200 | 200 | 200 | 200 |
| `cl_short_body` | RST(1) | RST(1) | RST(1) | 400 |
| `cl_long_body` | RST(1) | RST(1) | GOAWAY(2) | RST(1) |
| `upload_expect_continue` | 200 | 200 | 100, 200 | 100, 200 |
| `upload_expect_list` | 417 | 200 | 417 | 100, 200 |
| `upload_expect_empty` | 417 | 200 | 417 | 200 |
| `trailer_x-checksum` | 200 | 200 | 200 | 200 |
| `trailer_authorization` | RST(1) | RST(1) | 200 | 200 |
| `trailer_content-length` | RST(1) | RST(1) | RST(1) | 200 |
| `trailer_host` | RST(1) | RST(1) | 200 | 200 |
