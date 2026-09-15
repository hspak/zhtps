//! Compile-failure specifications, run by zig build test-endpoint-declarations.

const std = @import("std");
const zhtps = @import("zhtps");
const scenario = @import("scenario").index;
const log = std.log.scoped(.endpoint_declarations);

const api = struct {
    const C = zhtps.Call(@This());
    fn respond(call: *C) zhtps.EndpointError!zhtps.http.Response {
        if (scenario == 15) return call.json(.no_content, .{});
        return call.text(.ok, "ok");
    }
    fn before(_: *C) zhtps.EndpointError!?zhtps.http.Response {
        return null;
    }
    fn consume(_: *C, _: []const u8) zhtps.EndpointError!void {}
    pub const metrics = switch (scenario) {
        4 => struct {
            pub const Counter = enum(u8) { jobs = 5 };
        },
        5 => struct {
            pub const Gauge = enum(u8) { jobs, _ };
        },
        6 => struct {
            pub const Counter = enum { jobs };
            pub const Gauge = enum { jobs };
        },
        7 => struct {
            pub const Counter = enum { latency_sum };
            pub const Histogram = enum { latency };
        },
        8 => struct {
            pub const Counter = enum { @"invalid-name" };
        },
        else => struct {},
    };
    pub const metrics_namespace = if (scenario == 9) "zhtps" else "example";
    pub const lanes = if (scenario == 3)
        .{ .api = .{ .timeot_ms = 10 } }
    else if (scenario == 17)
        .{}
    else
        .{ .api = .{} };
    pub const routes = switch (scenario) {
        0 => .{zhtps.endpoint(.{
            .method = .get,
            .path = "/",
            .handler = respond,
            .befor = &.{before},
        })},
        1 => .{zhtps.endpoint(.{
            .method = .post,
            .path = "/",
            .handler = respond,
            .body = .bytes,
            .max_body_byte = 8,
        })},
        2 => .{zhtps.group(.{
            .prefix = "/",
            .routes = .{zhtps.get("/", respond)},
            .befor = .{before},
        })},
        10 => .{zhtps.get("/%61", respond)},
        11 => .{zhtps.get("/a/../b", respond)},
        12 => .{zhtps.group(.{ .prefix = "/:tenant", .routes = .{zhtps.get("/", respond)} })},
        13 => .{ zhtps.get("/:id", respond), zhtps.get("/:name", respond) },
        14 => .{zhtps.group(.{ .prefix = "/", .routes = .{} })},
        16 => .{zhtps.get("/a?b", respond)},
        18 => .{zhtps.endpoint(.{
            .method = .post,
            .path = "/",
            .handler = respond,
            .body = .stream,
        })},
        19 => .{zhtps.endpoint(.{
            .method = .post,
            .path = "/",
            .handler = respond,
            .body = .bytes,
            .consume = consume,
        })},
        else => .{zhtps.get("/", respond)},
    };
};

test "invalid declaration is rejected before serving" {
    const App = zhtps.Application(api);
    _ = @sizeOf(App.CustomMetrics);
    var storage: [1024]u8 = undefined;
    var exchange: App.Exchange = undefined;
    exchange.initApplication(&storage, {});
    const req: zhtps.http.Request = .{ .method = "GET", .path = "/" };
    _ = exchange.receiveHead(&req);
    _ = exchange.respond(&req);
}
