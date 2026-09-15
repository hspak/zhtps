# Use from another Zig project

Add a local checkout to your project's `build.zig.zon` dependencies (the path is
relative to that manifest):

```zig
.dependencies = .{
    .zhtps = .{ .path = "../zhtps" },
},
```

For a remote dependency, use `zig fetch --save=zhtps <archive-url>` with an archive
of the desired revision. Remove an existing local `.path` entry first: Zig 0.16
otherwise keeps that field when overwriting the dependency. Zig records the
archive URL and content hash in your manifest. This
project currently targets Zig 0.16.0; serving requires Linux x86-64-v4, Linux 6.0+
and permission to use io_uring. It does not provide a portable transport backend.

In your `build.zig`, import the module into your executable or library's root
module. `target` and `optimize` below are your usual build options:

```zig
const zhtps = b.dependency("zhtps", .{
    .target = target,
    .optimize = optimize,
    .@"build-server" = false,
});
exe.root_module.addImport("zhtps", zhtps.module("zhtps"));
```

The dependency wires up zeit, bundled OpenSSL/libnghttp2, and libc linkage itself.
Set `.@"system-openssl" = true` or `.@"system-nghttp2" = true` in the dependency
options to use the corresponding system library; its development headers and
libraries must match the target. The embedded example exposes these choices as
`-Dsystem-openssl=true` and `-Dsystem-nghttp2=true`.
Distributions using bundled dependencies must include their license notices:
[OpenSSL](../licenses/openssl.txt) and [nghttp2](../licenses/nghttp2.txt).

No copied source files or changes to your root declarations are needed. Importing
the module does not install the standalone executable. `-Dbuild-server=false` also disables its
installation when building this repository directly; `zig build run` remains
available.

## Server lifecycle

A minimal host can serve the bundled `/`, `/echo`, and `/stream` resources:

```zig
const std = @import("std");
const zhtps = @import("zhtps");

pub fn main(init: std.process.Init) !void {
    var server: zhtps.DefaultServer = undefined;
    try server.init(init.gpa, init.io, .{
        .port = 8080,
        .admin_connections = 0,
        .log_fd = null,
    });
    defer server.deinit();
    try server.serve();
}
```

`init` binds all listeners and allocates worker storage. After it returns,
`server.port()` reports the public port, including when you requested port zero;
`server.adminPort()` returns the admin port or null when disabled. `serve` blocks
on the calling thread and starts any additional configured workers. Call
`server.requestStop()` from another thread to request graceful shutdown, then
join the thread running `serve` before calling `deinit`. A server can serve once
per initialization. You may deinitialize it without ever serving, or request a
stop before serving. Startup and runtime errors return to the host.

The host owns the allocator, I/O implementation, configuration strings, signal
handlers, and log descriptor. Keep borrowed resources alive through `deinit`.
The library installs no process signal handlers. `log_fd` defaults to stderr;
set it to a borrowed file descriptor to redirect JSON events, or null to disable
them. The server never closes it. `admin_connections = 0` disables the admin
listener; its default remains eight reserved slots on port 9090.

The [complete standalone consumer](../examples/embedded/main.zig) runs `serve` on
a host-owned thread and shuts it down when Enter is pressed. Build or run it
from `examples/embedded` with `zig build` or `zig build run`. Its tests import
only the public module and exercise HTTP requests, multiple workers, bound ports,
shutdown, startup rollback, allocation failures, and borrowed log ownership.
Run them from this repository with `zig build test-library`.

## Public API and low-level applications

For routed handlers, middleware, and streaming producers, see [custom endpoints](endpoints.md).

`@import("zhtps")` also exports `Server(App)`, `InitError`, `RunError`, `Config`,
`Application(Api)`, `Call(Api)`, `ResponseStream`, `EndpointError`, `Method`, `Body`, `Status`,
`endpoint`, `group`, `application`, `http`,
`Metrics`, `metrics_format`, `Logger`, `Admission`, and `platform`.
`DefaultServer` is `Server(application)`. The existing low-level application
hooks remain available for streaming and specialized protocols. See
`application.Exchange` for the
application contract: initialize provided storage, validate the head with an optional early response,
consume borrowed body fragments, return response metadata, and optionally
produce bounded response fragments. Trailers remain separate in
`request.trailers`. Low-level hooks run synchronously on the event-loop thread;
they must perform bounded work and must not block on databases, files, or locks.

Call `Server(App).run(gpa, io, config, stop)`, passing a `std.Io` that supports
concurrent wall-clock reads for the lifetime of the workers (for example
`std.process.Init.io`). `platform.realtimeNs(io)` also takes that borrowed I/O
implementation. Calendar operations and wall-clock reads use zeit in UTC;
deadlines, durations, and rate limits use the Linux monotonic clock because
zeit's clock API supplies wall time, which can jump.

Application hooks receive normalized `request.path` and a reconstructed scheme
and authority. `request.target` and `request.headers` retain original octets.
An empty Host or a missing HTTP/1.0 authority uses the listener's configured IP
and actual bound port, omitting port 80 and bracketing IPv6. Supplied authorities
remain untrusted: the built-in application serves one default service, with no
virtual-host authorization or trusted-proxy inference.

Embedded `Config` literals use the same admission defaults as the CLI. Leave
`config.admission.max_active`, `max_rejecting`, or `burst` null to derive them
from the final connection budget at startup. `Config.resolveAdmission()` returns
the validated, concrete `Admission.Options` for callers that need those limits.

`http.Parser` and `http.Response` can be used independently of the runtime. The
parser exposes explicit framing events and owns no allocator. The response
encoder validates metadata, chooses framing, and checks streamed lengths.
`http.conditions.evaluate` implements origin preconditions for applications that
provide a representation's existence, entity tag, and optional modification time.
Application-specific routing, authorization, validators, and side effects remain
the application's responsibility.

`platform.listen` takes `ListenOptions` as its third argument. Port sharing is
disabled by default; the server enables it explicitly for public worker sockets.
Server executables use position-independent code so Linux can randomize their
load address. Prefer ReleaseSafe for production runtime checks.
