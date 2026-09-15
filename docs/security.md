# Security review

Reviewed on 2026-09-11 against the working tree based on `03aedf4`, using Zig
0.16.0 on Linux x86_64. The review covers all production Zig modules, the build,
and deployment configuration generators. Benchmark execution and report tooling
were checked for their trust boundaries; they are operator tools, not services
reachable from HTTP requests. Existing untracked documentation, deployment tools,
and tests were present before the review and were preserved.

The threat model includes arbitrary HTTP bytes, fragmentation, pipelining,
connection churn, slow readers/writers, concurrency, and malformed deployment
inputs. The kernel, compiler, allocator implementation, and application hooks
are trusted components. The work combines source review, pre-fix reproductions,
real socket tests, fault injection, and fuzzing. It does not establish the absence
of unknown vulnerabilities or certify kernel or microarchitectural isolation.

These findings resulted in defensive changes. Severity describes the stated
prerequisites, rather than assuming every issue is remotely exploitable.

| Finding and prerequisites | Before | Defense and evidence |
|---|---|---|
| Admin/public listener collision; configuration error, potentially high confidentiality impact | Both listeners enabled `SO_REUSEPORT`. Identical endpoints could start successfully and distribute connections across different trust domains. | `platform.ListenOptions` defaults to exclusive port binding; only public worker listeners opt into sharing. A wire regression formerly allowed the collision and now requires `AddressInUse`. Existing multi-worker startup and admin tests still pass. |
| Chunk framing amplification; remote availability risk | Each chunk size/extension line was bounded, but an attacker could repeat long extensions with one-byte chunks. Decoded body limits did not bound total framing work. Existing deadlines bounded retention, not total bytes per request. | Parser counts cumulative size lines, extensions and delimiters, default 65,536 bytes. Over-limit requests get 413 and close before pipelined requests are processed. A wire regression sent 18 chunks with 4,000-byte extensions: previously 200, now 413. Boundary, fragmentation, reuse, and public/admin override tests also pass. |
| Late security-sensitive fields; defense for custom applications | Cookie, conditional, range and some representation/control fields were accepted in trailers. The built-in application ignores trailers, so no built-in authentication bypass was demonstrated. | Reject these known fields with 400, extending the existing framing/authentication trailer denylist. Eight formerly accepted examples are permanent wire regressions. Unknown extension trailers remain separate; applications must explicitly define which they consume. |
| IPv6 scope text in generated NGINX configuration; operator-supplied input | Python accepted scope suffixes containing whitespace and directive text, which were interpolated into the origin server directive. This reproduced unsafe configuration generation, not execution of injected directives by NGINX. | Reject scope suffixes for both origin and listener addresses before creating output. Plain scoped IPv6 and a newline/directive payload both failed the pre-fix regression and now pass it. |
| Equivalent IPv6 addresses bypass self-proxy validation; configuration availability risk | Textual comparison treated `::1` and `0:0:0:0:0:0:0:1` as different origins at the same port. | Compare parsed IP addresses and ports. The generator rejects equivalent endpoints before creating output. This does not resolve aliases across interfaces, NAT, or external routing; operators still own topology. |
| Configuration output overwrite and symlink race; local filesystem access required | `exists()` followed by `write_text()` followed dangling symlinks and overwrote files created between those calls. | Both generators open each output with exclusive creation. Permanent tests cover dangling symlinks and deterministically create a competing file after the precheck. The competing file remains unchanged. Output directories and their ancestors must still be controlled by the operator; the bundle is not a filesystem transaction. |
| Predictable executable placement; exploit-hardening gap | The default executable was ELF `ET_EXEC`, fixing its code load address. No memory-corruption exploit was demonstrated. | Build the server as PIE. ELF inspection shows `ET_DYN` and a non-executable stack. This enables code-address randomization where host ASLR is enabled; it is not a Spectre defense or a substitute for bounds checks. |

The framing budget follows the recommendation to bound total extension work in
[RFC 9112 section 7.1.1](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1.1).
Keeping trailer fields separate and rejecting fields needed before body processing
is consistent with [RFC 9110 section 6.5](https://www.rfc-editor.org/rfc/rfc9110.html#section-6.5).

The following attack vectors were also checked. “Retained” means a defense already
existed and was reviewed and tested, rather than a vulnerability silently assumed
fixed by the new changes.

| Attack vector | Evidence, defense, and practical limit |
|---|---|
| CL/TE request smuggling, duplicate lengths, duplicate Host, malformed whitespace or line endings | `Request.parse` rejects ambiguous framing and malformed field syntax. `Parser.feed` requires CRLF, rejects obs-fold, and preserves the exact next-message boundary. Error responses close; GET bodies are consumed according to framing. Retained parser and wire tests cover these cases. |
| Integer overflow in body/chunk sizes and allocation budgets | Decimal lengths require digits before checked parsing. Hex sizes use checked parsing and compare against the remaining body budget before accepting content. Configuration bounds allocation dimensions; storage multiplication is checked. Framing accounting checks its bound before incrementing. |
| Buffer overrun and SIMD boundary reads | Head, trailer, receive, output and application buffers have bounded slices. The 16-byte head scan and 32-byte field validator check remaining input before vector loads. Existing unaligned, exact-capacity, sentinel and field-byte tests exercise vector boundaries; fragmentation fuzzing checks parsing consistency. These establish architectural behavior, not transient-execution safety. |
| Response splitting and response desynchronization | `Response.begin` validates field names/values before output, rejects application overrides of transport framing, and suppresses HEAD/bodyless payloads. Streamed lengths are checked. Invalid responses close. Retained response and wire tests cover injection, truncation, and pipelined streaming. |
| Slowloris, drip-fed bodies, slow readers | Separate absolute header/body/write deadlines, idle expiration, bounded close draining, and per-connection request limits prevent indefinite normal retention. Completion batching bounds event-loop work. Timers remain subject to scheduler delay; application hooks must not block. |
| Connection floods and rejection amplification | Fixed connection pools, per-worker active permits, rate/burst settings, rejection permits/tokens, early close when exhausted, and sampled rejection logs are retained. Admission defaults do not reserve slots against idle clients. SYN floods and aggregate multi-worker rates require calibrated ingress/kernel budgets. |
| Descriptor exhaustion and allocation failure | Startup allocations unwind with owned-resource cleanup; accept failures back off for 100 ms. Descriptor-exhaustion and partial worker-startup tests pass. Kernel socket memory is additional to user buffer budgets. |
| Log injection, blocked logs, log memory growth | JSON escaping, fixed-size records, bounded queues, asynchronous writes, and drop counters are retained. Multi-worker log ownership serializes complete record batches. Blocked and closed log-pipe tests verify network progress and shutdown. Request bodies, cookies and authorization fields are not logged by the built-in server. |
| Cross-client body disclosure during reuse | Each worker owns its connection pool and buffers. Parser/exchange lengths reset before reuse; echo sends only initialized received bytes. Borrowed response bodies and sendmsg vectors survive until send completion. Multi-worker echo/pipeline and disconnect-churn tests cover ownership and reuse. Memory is not scrubbed after each request; custom code must never expose unused capacity. |
| Concurrent admin inspection | Metrics use atomic loads/stores; they are observational snapshots, not transactions. Connection pages are captured by the owning worker and transferred using release/acquire phases. Requester generation and connection phase are checked before delivering a page. Admin pagination and worker inspection tests exercise this path. |
| Authentication, authorization, host poisoning, browser/SSRF access to admin | The built-in public routes have no private resources or authentication. Admin is unauthenticated and bound to loopback by default. The new exclusive binding prevents accidental port sharing, but loopback is not an authentication boundary against local processes, browser rebinding, or a local SSRF-capable service. Keep admin in a trusted network context; remote exposure requires an authenticated, restricted gateway. Host, absolute-target scheme and forwarded headers must not be treated as authenticated identity by custom applications. |
| Path traversal, SQL/shell injection, SSRF, decompression bombs | Built-in HTTP handlers do not access files, databases, subprocesses or outbound URLs, and do not decompress bodies. Paths select fixed routes; CONNECT and upgrades do not create tunnels. These vectors become relevant if application capabilities are added. Deployment generators validate values used in configuration; benchmark SSH commands use argument arrays/quoting and strict host-key checks. |
| Cache poisoning or conditional-write races | The built-in application serves fixed representations and echo; it is not a cache and performs no shared persistent mutations. Admin responses use no-store where representations are emitted. Custom mutating applications must make authorization/precondition checks and writes atomic at the storage layer; transport serialization is only per connection. |

The combined failure scenarios below received additional attention:

1. **Timeout, send completion, late receive, cancellation, then slot reuse.** A
   connection remains in cancellation until all original and cancellation CQEs
   arrive. A cancellation CQE alone does not release the original buffer. The new
   component test enumerates all 24 completion orders for receive, send and their
   cancellations, including the maximum generation value. It checks that the FD,
   free list and admission permit are retained until the last result and released
   exactly once. Synthetic delivery is used because socket timing cannot reliably
   force all orders. The existing real-I/O late-canceled-receive regression also
   preserves the response drain.
2. **Fatal error partway through a copied CQ batch, with queued accepts and
   unsubmitted work.** `loop` accounts for the abandoned batch; successful accepts
   in that batch are closed. `quiesce` excludes unsubmitted SQEs, synchronously
   cancels submitted work by token, and drains completions before freeing storage.
   No SQPOLL or second submitter exists. Zig 0.16's `copy_cqes` calls `enter` with
   zero submissions, so draining does not submit abandoned SQEs. Existing fault
   injection tests cover fatal completion, unsubmitted work, accepted descriptors,
   and worker failure/join. The synchronous cancellation contract was checked
   against the [liburing documentation](https://github.com/axboe/liburing/blob/master/man/io_uring_register_sync_cancel.3).
3. **More live receives than SQ entries, all workers shutting down, blocked
   stderr.** Submission capacity is made available incrementally; each worker
   retains its own operation storage and releases shared log ownership on exit.
   Existing wire tests exercise hundreds of receives with a smaller SQ, blocked
   logs, and multi-worker shutdown. Cancellation can exceed the grace deadline
   for uninterruptible kernel I/O. The implementation waits or terminates on an
   unusable cancellation/CQ mechanism rather than freeing referenced memory.
4. **Chunk overhead flood, rate pressure, then a smuggled-looking pipeline.** The
   new cumulative framing bound limits metadata work independently of decoded
   content. Over-limit requests close, so leftover bytes cannot become another
   request. The regression verifies 413, EOF without a second response, and a
   successful subsequent connection. Existing overload tests verify recovery of
   admission/rejection budgets.
5. **Worker inspection racing disconnect and reuse.** The requesting admin
   connection is identified by slot and generation, and must still be in the
   inspecting phase. Worker zero does not directly read another worker's mutable
   connection objects. Snapshot fields can reflect different times, so metrics
   and inspection output must not be used as authorization decisions.
6. **Speculative access alongside buffer reuse and a hostile local tenant.** No
   remote-controlled raw pointer, shared request pool across workers, or proven
   transient-disclosure gadget was found. That is not proof of Spectre immunity:
   architectural checks and ReleaseSafe checks are not speculation barriers.
   PIE improves address unpredictability. Host kernel/microcode mitigations and
   isolation from untrusted tenants remain necessary where this threat matters;
   the [Linux Spectre documentation](https://docs.kernel.org/admin-guide/hw-vuln/spectre.html)
   describes their scope and costs. No blanket LFENCE insertion or host policy
   changes were made without an identified gadget to address.

Validation performed in this review:

- The unchanged baseline passed 47 wire tests. The new collision, framing-flood,
  and sensitive-trailer regressions failed before their fixes and passed unchanged
  afterward. The four deployment tests likewise reproduced unsafe behavior before
  the generator fixes. Added boundary/configuration and cancellation-order tests
  specify defenses; they are not claimed as reproduced race vulnerabilities.
- `zig build test test-wire test-deploy --summary all`: 53 component tests,
  51 raw TCP tests, and four deployment tests passed in Debug and ReleaseSafe.
  The actual io_uring tests ran outside the workspace sandbox; they were not
  counted as successful skips. The sandbox itself rejects io_uring startup.
- `zig build test test-wire -Doptimize=ReleaseFast --summary all`: the same
  53 component and 51 wire tests passed with runtime safety assertions disabled.
- `zig build test -Dtest-filter='fuzz framing' -Derror-tracing=false --fuzz=100K`:
  101,042 fuzz runs completed. The target compares whole, bytewise and 17-byte
  parsing transcripts, including body hashes, trailers, boundaries and errors.
  This campaign reached 548 of 11,061 instrumented coverage locations; it is
  targeted fragmentation evidence, not full server or syscall fuzz coverage.
- `python3 tests/ingress.py --nginx /tmp/nginx-1.30.4/objs/nginx -v`: all eight
  existing NGINX integration tests passed using the locally available binary.
  No host firewall rules were installed or changed by this review.
- ELF inspection confirms PIE (`ET_DYN`) and a non-executable `GNU_STACK`.
  `zig fmt` and `git diff --check` validate formatting.

Production should use ReleaseSafe, a dedicated service identity, a patched host,
explicit resource budgets, and TLS at a trusted endpoint when traffic leaves the
trusted network. Keep admin access restricted. Generate deployment bundles in
operator-controlled directories and discard partial bundles after generation
errors. These requirements follow from the intentionally small origin-server
scope; application authentication, filesystem serving, and transactional
application storage remain outside it. Native TLS 1.3 support is described in
[TLS design and policy](tls.md); the earlier review above predates that addition.
