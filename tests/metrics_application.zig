//! Custom counter, gauge and histogram fixture for direct metric delivery.

const std = @import("std");
const zhtps = @import("zhtps");
const linux = zhtps.platform.linux;

var stopping: std.atomic.Value(bool) = .init(false);

fn stop(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .monotonic);
}

const api = struct {
    pub const metrics_namespace = "example";
    pub const metrics = struct {
        pub const Counter = enum { greetings_total };
        pub const Gauge = enum { workers_seen };
        pub const Histogram = enum { greeting_duration_seconds };
    };
    pub const routes = .{zhtps.get("/", greet)};

    fn greet(call: *zhtps.Call(api)) !zhtps.http.Response {
        call.metrics.add(.greetings_total, 1);
        call.metrics.set(.workers_seen, 1);
        call.metrics.observe(.greeting_duration_seconds, 25_000);
        return call.text(.ok, "hello\n");
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try zhtps.Config.parse(args[1..]);
    const action: linux.Sigaction = .{
        .handler = .{ .handler = stop },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = try zhtps.platform.check(linux.sigaction(.TERM, &action, null));
    try zhtps.Server(zhtps.Application(api)).run(init.gpa, init.io, config, &stopping);
}
