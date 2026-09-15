# Build and run

A Zig 0.16.0 HTTP/1.1 and HTTP/2 server library with a standalone executable. Serving
requires Linux x86-64-v4 and the io_uring capabilities described below. The transport uses
`std.os.linux.IoUring` directly. Each worker thread owns a ring, connections,
request storage, admission permits, and completion lifetimes. The pinned
[zeit](https://github.com/rockorager/zeit) dependency supplies UTC calendar
conversion, HTTP Date formatting, and wall-clock timestamps.

The implementation has protocol, raw TCP, overload, and cancellation tests.
See the [conformance audit](conformance.md) for the applicable RFC
requirements, supported origin-server scope, application responsibilities, and
test evidence. This is an implementation audit, not independent certification.

The [security review](security.md) records attack vectors, defensive changes,
regression evidence, and the remaining deployment and application responsibilities.


## Requirements and commands

Run shell commands from the repository root unless another directory is specified.

Zig fetches pinned OpenSSL 3.5.8 LTS and nghttp2 1.70.0 releases, verifies their
package hashes, and compiles them as static libraries. Normal builds need no
system OpenSSL/nghttp2 development packages, Perl, Make, CMake, or Autotools.
The initial build needs network access unless the dependencies are already cached.

The dependencies can independently use system installations:

- `-Dsystem-openssl=true`: requires OpenSSL 3 development headers and libraries
  (`libssl-dev` on Debian/Ubuntu, `openssl-devel` on Fedora).
- `-Dsystem-nghttp2=true`: requires nghttp2 development headers and libraries
  (`libnghttp2-dev` or `libnghttp2-devel`; tested with 1.70.0).

Each system option skips fetching its bundled source. All modes link libc. The
default target is Linux x86-64-v4 with glibc; cross builds need matching headers
and libraries for any dependency selected in system mode. Native builds select
the host glibc version.

Bundled builds install dependency licenses under `zig-out/share/licenses/zhtps/`.
Include those notices when distributing the executable. TLS integration tests
still use the system `openssl` command to generate credentials and test clients.
See [dependency maintenance](dependencies.md) for configuration and update procedures.

TLS listeners support HTTP/2 through ALPN, including independent application
streams, HPACK, flow control, streaming uploads/responses, cancellation, and
graceful GOAWAY. nghttp2 owns protocol processing; zhtps owns socket I/O,
scheduling, admission, and bounded stream storage. See [HTTP/2](http2.md)
for configuration, integration tests, and the Go comparison.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zhtps --port 8080 --admin-port 9090
curl http://127.0.0.1:8080/
curl --data-binary 'hello' http://127.0.0.1:8080/echo
curl http://127.0.0.1:8080/stream
```

The default build selects the reproducible x86-64-v4 target, including AVX-512,
without depending on the build host's newer extensions. `-Dcpu=native` may tune
for a particular deployment CPU, but the selected CPU must still provide the
x86-64-v4 instruction set. See the [SIMD and admission measurements](simd.md)
for the optimized header scan, token refill costs, and benchmark commands.

`GET /` returns `ZHTPS\n`; `POST /echo` echoes up to 64 KiB; `/stream` demonstrates
incremental chunked output. GET resources also support HEAD and entity-tag
preconditions. OPTIONS reports the selected resource's methods. There is no
forward proxy, CONNECT tunnel, or protocol upgrade implementation. Optional
range requests are ignored and receive the full representation. Cleartext
listeners reject absolute HTTPS targets with 421 before application callbacks
or 100 Continue. Unsupported methods receive 501; implemented methods rejected
by a resource receive 405 with Allow.

Enable HTTPS on the public listener with a PEM certificate chain (leaf first)
and its unencrypted PEM private key:

```sh
./zig-out/bin/zhtps --port 8443 \
  --tls-certificate /etc/zhtps/fullchain.pem --tls-key /etc/zhtps/key.pem
curl --cacert /path/to/ca.pem https://localhost:8443/
zig build test-tls
```

TLS is **TLS 1.3 only**, with AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305,
matching the TLS 1.3 cipher set of GCP's RESTRICTED policy. ALPN prefers `h2`, then `http/1.1`;
clients without ALPN also use HTTP/1.1. Handshakes have a separate five-second
deadline (`--tls-handshake-timeout-ms`). Early data is disabled. The admin listener
remains HTTP and should remain private. Library hosts set `Config.tls` to
`.{ .certificate = "/path/fullchain.pem", .private_key = "/path/key.pem" }`.
See [TLS design and policy](tls.md) for ownership, resumption, and shutdown.

Both listeners route normalized paths: unreserved percent escapes decode and
dot segments disappear; reserved separators and repeated slashes stay distinct.
The original target and headers remain available to embedded applications. See
the [routing and protocol choices](conformance.md#implementation-choices)
for the default authority, error bodies, and interoperability tradeoffs.

Run `./zig-out/bin/zhtps --help` for CLI settings. Both listeners bind loopback
by default. `--address 0.0.0.0` exposes the public listener; the admin listener
remains separate. IP literals, including IPv6, are supported. Port `0` chooses an
available port, reported in the corresponding JSON listening event's `port` field.
Admin sockets do not enable port sharing: overlapping public/admin listeners fail
startup instead of routing public connections to the admin interface.

The server requires Linux 6.0 or later, including synchronous io_uring
cancellation for fatal-error cleanup. Startup probes this capability. The
execution environment must permit `io_uring_setup`, cancellation registration,
and the networking operations used by the server. Some container/workspace seccomp policies deny
these calls even on a capable kernel. Startup fails explicitly in that case.
The current implementation does not silently switch to another I/O backend.

Continue with [configuration and tuning](configuration.md), [observability](observability.md),
or [embedding the library](embedding.md).
