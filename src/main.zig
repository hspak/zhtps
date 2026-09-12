const std = @import("std");
const zhtps = @import("zhtps");
const linux = zhtps.platform.linux;
const log = std.log.scoped(.main);

var stopping: std.atomic.Value(bool) = .init(false);

fn stopSignal(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "ZHTPS — Linux x86_64 io_uring HTTP/1.1 server\n" ++
            "  --address IP                 default 127.0.0.1\n" ++
            "  --port PORT                  default 8080; 0 chooses a free port\n" ++
            "  --admin-address IP           default 127.0.0.1\n" ++
            "  --admin-port PORT            default 9090; 0 chooses a free port\n" ++
            "  --workers N                  event-loop threads/rings; default 1\n" ++
            "  --max-connections N          per worker; default 256\n" ++
            "  --admin-connections N        reserved admin slots; 0 disables; default 8\n" ++
            "  --completion-budget N        completions per loop; default 64\n" ++
            "  --log-slots N                buffered JSON records; default 256\n" ++
            "  --max-active N               per worker; default 3/4 of public slots, min 1\n" ++
            "  --max-rejecting N            per worker; default 1/8 of public slots, min 1\n" ++
            "  --rate N                     requests/second/worker; default 0 (disabled)\n" ++
            "  --burst N                    per worker; default effective max-active\n" ++
            "  --rejection-rate N           rejection responses/second/worker; default 1000\n" ++
            "  --header-timeout-ms N        default 5000\n" ++
            "  --body-timeout-ms N          default 30000\n" ++
            "  --write-timeout-ms N         default 5000\n" ++
            "  --idle-timeout-ms N          default 15000\n" ++
            "  --close-timeout-ms N         bounded response drain; default 100\n" ++
            "  --shutdown-timeout-ms N      graceful drain; default 5000\n" ++
            "  --max-body-bytes N           default 67108864\n" ++
            "  --max-chunk-framing-bytes N  cumulative chunk overhead; default 65536\n" ++
            "  --max-requests N             per connection; default 1000\n" ++
            "  --no-access-log              omit per-response logs; keep metrics\n" ++
            "  --verbose                    include JSON debug events\n");
        return;
    }
    const config = zhtps.Config.parse(args[1..]) catch |err| {
        try fatal(init.io, @errorName(err));
        std.process.exit(2);
    };
    const action: linux.Sigaction = .{
        .handler = .{ .handler = stopSignal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = try zhtps.platform.check(linux.sigaction(.TERM, &action, null));
    _ = try zhtps.platform.check(linux.sigaction(.INT, &action, null));
    zhtps.DefaultServer.run(init.gpa, init.io, config, &stopping) catch |err| {
        try fatal(init.io, @errorName(err));
        std.process.exit(1);
    };
}

fn fatal(io: std.Io, reason: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.json.Stringify.value(.{
        .timestamp_ns = zhtps.platform.realtimeNs(io),
        .level = "error",
        .event = "startup_or_runtime_error",
        .reason = reason,
    }, .{}, &writer);
    try writer.writeByte('\n');
    try std.Io.File.stderr().writeStreamingAll(io, writer.buffered());
}
