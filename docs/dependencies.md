# Dependency maintenance

## OpenSSL

The default build statically links the pinned
[OpenSSL 3.5.8 LTS release](https://github.com/openssl/openssl/releases/tag/openssl-3.5.8).
The release URL and Zig package hash are pinned in `build.zig.zon` as a lazy
dependency. `-Dsystem-openssl=true` links system libssl/libcrypto without fetching it.

The build follows the approach used by
[allyourcodebase/openssl](https://github.com/allyourcodebase/openssl/tree/6b318b447c8ff7529e3a2337a1df2a9b4816fee2):
Zig compiles upstream C sources alongside checked-in generated headers, C files,
and x86-64 assembly. Our inputs are generated from OpenSSL 3.5.8's own build graph;
the reference package's older generated files are not used.
The generated CPU-detection assembly registers its initializer through
`.init_array`: Zig 0.16's native ELF linker does not provide the CRT wrapping
required by upstream's legacy `.init` fragment. The initializer itself is unchanged.

`build/openssl/regenerate.py` owns the configuration and generates
`build/openssl/sources.zon` and `build/openssl/generated/`. The configuration is
`linux-x86_64` with static libraries, built-in default/base providers, threading,
and assembly acceleration. External modules, DSO loading, engines, the legacy
provider, applications, documentation, and upstream test binaries are disabled.
The default configuration directory is `/etc/ssl`; `OPENSSL_CONF` still applies.
This build does not supply external provider modules. Applications requiring
those modules should select system OpenSSL.

`build/openssl.zig` supplies the consumer's target, optimization mode, and PIC.
It rejects upstream version metadata that differs from the generated inputs.
It keeps C assertions in Debug/ReleaseSafe and disables them in ReleaseFast/ReleaseSmall.
The function-type sanitizer is disabled for OpenSSL's generic callback casts;
other checks selected by Zig's optimization mode remain enabled.
Build metadata identifies Zig and the optimization mode without embedding a
generation timestamp or the generator's compiler flags. Normal builds require
Zig alone; regeneration requires Python 3, Perl, Make, and a working C toolchain.

To update OpenSSL:

1. Select a supported 3.5 LTS patch release, review its release notes and security
   fixes, and obtain its URL and package hash with `zig fetch <release-archive-url>`.
2. Extract a clean release directory and run
   `python3 build/openssl/regenerate.py <clean-release-directory>`.
   The script configures a temporary copy and derives all library objects,
   feature macros, and generated assembly from upstream's build graph.
   It replaces only the generated directory and source manifest.
3. Update the URL/hash in `build.zig.zon`, refresh `licenses/openssl.txt` from
   upstream `LICENSE.txt`, and update the documented version. Review changes to
   both generated sources and build options. A source URL change alone is insufficient.
4. Run `zig build check-fmt`, `zig build test`, `zig build test-library`,
   `zig build test-tls`, and `zig build test-http2` in bundled and system modes.
   Also check mixed dependency modes, TLS cipher throughput, and handshakes.
5. Check `readelf -d zig-out/bin/zhtps`: bundled mode must not require libssl,
   libcrypto, or libnghttp2 shared libraries. Keep the installed license notices
   from `zig-out/share/licenses/zhtps/` with distributed binaries.

The 3.5 LTS line is [supported through April 2030](https://openssl-library.org/roadmap/).
Bundled security fixes require updating the pin, regenerating the build inputs,
and rebuilding and redeploying each consuming executable or shared library.

### Verification

Verified with Zig 0.16.0 and OpenSSL 3.5.8 on 2026-09-14:

- Debug and ReleaseSafe passed 108 Zig tests, endpoint declaration checks,
  32 TLS tests, 34 HTTP/2 tests, and the separate embedded-consumer tests.
- System OpenSSL with bundled nghttp2 passed the same suites. Bundled OpenSSL
  with system nghttp2 passed the TLS, HTTP/2, and embedded-consumer suites.
- ReleaseFast built successfully. An x86-64-v4 musl ReleaseSafe cross build
  produced a static PIE executable and passed the `--help` startup check.
- The default glibc executable's only shared-library dependency was libc.
- Regeneration from a clean release reproduced the checked-in inputs.
- A focused crypto probe completed TLS 1.3 handshakes using `X25519MLKEM768`
  and exercised all three configured TLS ciphers.

## libnghttp2

The default build statically links libnghttp2 from the unmodified
[nghttp2 1.70.0 release archive](https://github.com/nghttp2/nghttp2/releases/tag/v1.70.0).
`build.zig.zon` pins the archive URL and Zig package hash. The dependency is lazy:
`-Dsystem-nghttp2=true` uses the system installation without fetching the archive.

`build/nghttp2.zig` compiles the C library with the selected Zig target and
optimization mode. The release archive includes the generated public version
header. Linux feature definitions enable network byte-order helpers and the
monotonic clock used for stream-reset rate limiting. Library code is built with
position-independent code so consumers can link it into shared libraries.

To update the bundled dependency:

1. Review the upstream release notes and security fixes. Fetch the release tar
   archive with `zig fetch <release-archive-url>` to obtain its package hash.
2. Update the URL and hash in `build.zig.zon`. Compare the source list in
   `build/nghttp2.zig` against upstream `lib/CMakeLists.txt`, and review changes
   to feature macros in the library sources.
3. Refresh `licenses/nghttp2.txt` from the release's `COPYING`, and update the
   documented bundled version.
4. Run `zig build check-fmt`, `zig build test`, `zig build test-library`,
   `zig build test-http2`, and `zig build test-tls`. Repeat the tests with
   `-Dsystem-nghttp2=true`; HTTP/2 tests need `tests/requirements-http2.txt`
   installed in the interpreter selected by `-Dhttp2-python=<path>`.
5. Build the executable and inspect its dynamic dependencies with
   `readelf -d zig-out/bin/zhtps`. Bundled mode must not have a `NEEDED` entry
   for libnghttp2. Check that its license is installed under
   `zig-out/share/licenses/zhtps/`.

Security fixes to bundled libnghttp2 require rebuilding and redeploying each
consuming executable or shared library. Applications embedding zhtps must include
the [nghttp2 license](../licenses/nghttp2.txt) in their distribution.
