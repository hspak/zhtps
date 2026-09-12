//! Server façade for a generated endpoint application.

const std = @import("std");
const Config = @import("../Config.zig");
const server = @import("../server.zig");
const log = std.log.scoped(.endpoint_server);

pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();
        const Inner = server.Server(App);

        inner: Inner,

        pub const Services = App.Services;
        pub const Options = if (Services == void) struct {} else struct {
            services: *Services,
        };

        /// Binds listeners, allocates fixed worker and lane storage, and borrows
        /// application services through deinit. Call deinit after success.
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
                if (Services == void) {} else options.services,
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

        /// Runs transport workers and bounded application lanes until stopped.
        pub fn serve(self: *Self) server.RunError!void {
            return self.inner.serve();
        }

        /// Requests graceful shutdown without waiting and is safe to repeat.
        pub fn requestStop(self: *const Self) void {
            self.inner.requestStop();
        }

        /// Releases server resources after serving has returned.
        pub fn deinit(self: *Self) void {
            self.inner.deinit();
            self.* = undefined;
        }
    };
}
