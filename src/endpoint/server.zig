//! Server façade for a generated endpoint application.

const std = @import("std");
const Config = @import("../Config.zig");
const server = @import("../server.zig");
const log = std.log.scoped(.endpoint_server);

/// Owns the transport and executor resources for a generated application.
pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();
        const Inner = server.Server(App);

        inner: Inner,

        pub const Services = App.Services;
        pub const Options = if (Services == void) struct {} else struct {
            services: *Services,
        };

        /// Binds listeners and allocates fixed worker and lane storage. Borrows
        /// gpa, io, configuration strings, log descriptor and services through deinit.
        /// io must support concurrent wall-clock reads and the I/O used by hooks.
        /// Errors release acquired resources and leave self undefined. On success,
        /// self may move but must not be copied. Call deinit even if never served.
        pub fn init(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            config: Config,
            options: Options,
        ) server.InitError!void {
            try self.inner.initApplication(
                gpa,
                io,
                config,
                if (comptime Services == void) {} else options.services,
            );
        }

        /// Returns the bound public port, including a kernel-selected port.
        pub fn port(self: *const Self) u16 {
            return self.inner.port();
        }

        /// Returns the bound admin port, or null when its listener is disabled.
        pub fn adminPort(self: *const Self) ?u16 {
            return self.inner.adminPort();
        }

        /// Runs once per initialization; repeat calls return AlreadyServed. Keep
        /// self at a stable address until return. Joins all workers and application
        /// threads, including on error. A nonreturning hook prevents return even
        /// after shutdown_timeout_ms. A stop requested before serving is honored.
        pub fn serve(self: *Self) server.RunError!void {
            return self.inner.serve();
        }

        /// Requests graceful shutdown without waiting. Safe from another thread
        /// after init and before deinit, and safe to repeat. The grace deadline
        /// cannot terminate application code; serve waits for running hooks.
        pub fn requestStop(self: *const Self) void {
            self.inner.requestStop();
        }

        /// Releases server resources. Asserts serve is not running; join its
        /// calling thread first. Borrowed services and descriptors remain owned
        /// by the caller. Also valid when serve was never called.
        pub fn deinit(self: *Self) void {
            self.inner.deinit();
            self.* = undefined;
        }
    };
}
