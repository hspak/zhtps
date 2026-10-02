//! Static compression fixture with an isolated document root supplied as cwd.

const std = @import("std");
const zhtps = @import("zhtps");
const linux = zhtps.platform.linux;

var stopping: std.atomic.Value(bool) = .init(false);

fn stop(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .monotonic);
}

const api = struct {
    pub const lanes = .{ .files = .{ .timeout_ms = 30_000 } };
    pub const routes = .{
        zhtps.staticFiles(@This(), "/", .{ .root = ".", .zstd = true }),
        zhtps.staticFiles(@This(), "/plain", .{ .root = "." }),
    };
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try zhtps.Config.parse(args[1..]);
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const action: linux.Sigaction = .{
        .handler = .{ .handler = stop },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    for ([_]linux.SIG{ .TERM, .INT }) |sig|
        _ = try zhtps.platform.check(linux.sigaction(sig, &action, null));
    try zhtps.Server(zhtps.Application(api)).run(allocator.allocator(), init.io, config, &stopping);
}
