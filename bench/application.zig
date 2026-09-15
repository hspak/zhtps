//! Generated endpoints for executor scheduling and lifetime experiments.

const std = @import("std");
const zhtps = @import("zhtps");
const linux = zhtps.platform.linux;
const log = std.log.scoped(.bench_application);

var stopping: std.atomic.Value(bool) = .init(false);
var gate: std.atomic.Value(bool) = .init(false);

fn signal(sig: linux.SIG) callconv(.c) void {
    if (sig != .USR1) stopping.store(true, .monotonic);
    gate.store(true, .release);
}

const api = struct {
    const C = zhtps.Call(@This());
    pub const Services = struct {
        requests: std.atomic.Value(u64) = .init(0),
        holding: std.atomic.Value(u64) = .init(0),
        released: std.atomic.Value(u64) = .init(0),
    };
    pub const lanes = .{ .default = .{
        .threads = 1,
        .queue = 64,
        .timeout_ms = 1000,
    } };
    pub const routes = .{
        zhtps.get("/", fast),
        zhtps.get("/mixed", mixed),
        zhtps.get("/hold", hold),
        zhtps.get("/inspect", inspect),
        zhtps.endpoint(.{
            .method = .post,
            .path = "/body",
            .handler = fast,
            .body = .bytes,
            .max_body_bytes = 1024,
        }),
    };

    fn fast(call: *C) !zhtps.http.Response {
        return call.text(.ok, "ZHTPS\n");
    }

    fn mixed(call: *C) !zhtps.http.Response {
        if (call.services.requests.fetchAdd(1, .monotonic) % 10 == 0)
            std.Io.sleep(
                call.io,
                .fromMilliseconds(10),
                .awake,
            ) catch {};
        return fast(call);
    }

    fn hold(call: *C) !zhtps.http.Response {
        _ = call.services.holding.fetchAdd(1, .release);
        while (!gate.load(.acquire))
            std.Io.sleep(
                call.io,
                .fromMilliseconds(1),
                .awake,
            ) catch {};
        return fast(call);
    }

    fn inspect(call: *C) !zhtps.http.Response {
        return call.json(.ok, .{
            .holding = call.services.holding.load(.acquire),
            .released = call.services.released.load(.acquire),
        });
    }

    pub fn release(call: *C) void {
        if (std.mem.eql(
            u8,
            call.request.path,
            "/hold",
        ))
            _ = call.services.released.fetchAdd(1, .release);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try zhtps.Config.parse(args[1..]);
    const action: linux.Sigaction = .{
        .handler = .{ .handler = signal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    for ([_]linux.SIG{
        .TERM,
        .INT,
        .USR1,
    }) |sig|
        _ = try zhtps.platform.check(linux.sigaction(
            sig,
            &action,
            null,
        ));
    var services: api.Services = .{};
    var server: zhtps.Server(zhtps.Application(api)) = undefined;
    try server.initApplication(
        init.gpa,
        init.io,
        config,
        &services,
    );
    defer server.deinit();
    for (server.shared.workers) |*worker| worker.stop = &stopping;
    try server.serve();
}
