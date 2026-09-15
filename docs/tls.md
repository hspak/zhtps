# TLS

The public listener can serve HTTPS using OpenSSL 3. The separate administration
listener remains HTTP. A server has one certificate chain; SNI does not select
different virtual hosts. Credentials are loaded and checked before listeners
start and remain owned until server deinit. Restart with new credentials to
replace a certificate. ACME and client certificate authentication are outside
the current server's scope. TLS listeners support [HTTP/2](http2.md).

The default build bundles OpenSSL 3.5.8 LTS, including its default and base
providers, threading, and x86-64 assembly acceleration. It reads the default
configuration from `/etc/ssl/openssl.cnf` (overridable with `OPENSSL_CONF`), but
does not load external providers or engines. Use `-Dsystem-openssl=true` for
deployments that need their system OpenSSL configuration and provider modules.
See [dependency maintenance](dependencies.md#openssl) for the build settings.

## Policy

Both the minimum and maximum version are TLS 1.3. The explicit cipher allowlist is:

- `TLS_AES_128_GCM_SHA256`
- `TLS_AES_256_GCM_SHA384`
- `TLS_CHACHA20_POLY1305_SHA256`

This is the TLS 1.3 set documented by [GCP SSL policies](https://docs.cloud.google.com/load-balancing/docs/ssl-policies-concepts).
GCP's profiles otherwise distinguish TLS 1.2 and earlier; those versions are
disabled here. OpenSSL supplies its modern key exchange defaults, including
hybrid post-quantum exchange in versions that enable it. Cipher policy cannot
be weakened through runtime options. [OpenSSL security level 2](https://docs.openssl.org/3.6/man3/SSL_CTX_set_security_level/)
requires at least 112-bit security, including RSA keys of at least 2048 bits.
Record compression and renegotiation are disabled, and 0-RTT early data is never
delivered to applications.

ALPN prefers `h2`, then `http/1.1`, rejects offers with no supported protocol, and allows
HTTP/1.1 when clients omit ALPN. The HTTP request's effective scheme is `https`;
absolute HTTP targets on HTTPS receive 421 before dispatch or 100 Continue.
Absolute HTTPS targets on HTTP likewise receive 421. Certificates must be PEM,
with the leaf followed by intermediates; private keys must be PEM, match the
leaf, and be unencrypted. Startup never prompts for a password.

## Relationship to nginx

The starting point was `../nginx/src/event/ngx_event_openssl.c`, specifically
`ngx_ssl_create`, `ngx_ssl_handshake`, `ngx_ssl_recv`, `ngx_ssl_write`, and
`ngx_ssl_shutdown`. The implementation retains nginx's useful principles:
configuration shared by connections, explicit handshakes with deadlines,
OpenSSL retry handling, bounded record buffering, and close_notify before TCP
shutdown. It omits compatibility workarounds for obsolete OpenSSL and TLS versions.

nginx adapts socket BIOs to readiness callbacks. ZHTPS already owns socket
operations through io_uring, so each session instead owns a **bounded BIO pair**
with 18 KiB per direction. `BIO_nread0`/`BIO_nwrite0` expose its storage directly
to io_uring for handshakes and HTTP/1. HTTP/2 instead copies ciphertext into
bounded transport buffers so receives and sends can overlap while SSL/BIO calls
remain on one worker. It batches frames into 16 KiB plaintext records and reserves
BIO space before a write, preserving read progress under send backpressure.
OpenSSL still owns its internal cryptographic and handshake allocations;
the BIO bound is not a claim that all TLS memory fits in 36 KiB.

The worker serializes operations on each SSL object. BIO storage and plaintext
write arguments remain stable through completion and retries. It drains TLS
output before waiting for input, including WANT_READ, as required to avoid the
[BIO-pair deadlock](https://docs.openssl.org/3.6/man3/BIO_s_bio/).
Existing HTTP aggregation, streaming, application executors, and admission
continue above the transport. HTTP/1 processing counts plaintext bytes; HTTP/2
and draining late input count transport bytes. TLS handshake, error, timeout, and
resumption counters are separate.

## Lifetimes and limits

TLS allocation occurs only for accepted public connections. Connection budgets
bound concurrent handshakes; `handshake_timeout_ms` bounds their lifetime.
Successful handshakes start the initial header deadline. Existing header, body,
write, idle, and server shutdown deadlines still apply. Timeout responses use
TLS after pending receives have been canceled and reaped.

One immutable SSL_CTX is shared by all workers. OpenSSL handles synchronization,
session tickets, and a cache bounded to 1024 sessions with a 300-second timeout.
Resumption therefore works across workers; tickets do not survive restart. No
custom ticket cryptography or replay exception is introduced.

Normal response closure sends close_notify, flushes it, half-closes TCP, and
drains late input until the existing close deadline. It does not wait indefinitely
for a reciprocal TLS alert. Fatal TLS errors, disconnected peers, and forced
deadlines close the transport. TCP EOF is never promoted to authenticated TLS
close_notify. Connection reuse waits for every outstanding I/O and cancellation
completion before freeing SSL/BIO storage.

## Verification

`zig build test-tls` uses ephemeral certificates and real Python/OpenSSL clients.
It covers allowed and denied negotiation, verified HTTPS, request fragmentation,
uploads, pipelining, streaming, resumption, deadlines, shutdown, and malformed
input. `zig build test test-library test-wire test-application test-upload`
checks the existing transport and application contracts. These tests require
permission to use io_uring and local sockets.

Verified on 2026-09-14 with Zig 0.16.0 and OpenSSL 3.6.4 in Debug and ReleaseSafe:

- 107 Zig tests and all endpoint declaration checks passed.
- All 32 TLS tests passed, including KeyUpdate, RSA key strength, certificate
  chains, startup allocation failures, and 8 MiB responses under backpressure.
- The separate library consumer, HTTP wire, executor, and upload suites passed.
- All 21 HTTP/2 integration tests passed; see [HTTP/2 verification](http2.md#verification).
- `zig fmt --check` and `git diff --check` passed.
