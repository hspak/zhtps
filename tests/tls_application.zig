//! TLS fixture exercising generated handlers and responses larger than socket buffers.

const std = @import("std");
const zhtps = @import("zhtps");
const linux = zhtps.platform.linux;

var stopping: std.atomic.Value(bool) = .init(false);
var gate: std.atomic.Value(bool) = .init(false);
var holding: std.atomic.Value(u64) = .init(0);
var released: std.atomic.Value(u64) = .init(0);
var generated_bytes: std.atomic.Value(u64) = .init(0);

fn stop(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .monotonic);
    gate.store(true, .release);
}

const api = struct {
    const C = zhtps.Call(api);
    pub const Local = struct { bytes: usize = 0, retained: []const u8 = "" };
    pub const lanes = .{
        .default = .{
            .threads = 1,
            .queue = 8,
            .timeout_ms = 2000,
        },
        .control = .{
            .threads = 1,
            .queue = 8,
            .timeout_ms = 2000,
        },
        .short = .{
            .threads = 1,
            .queue = 8,
            .timeout_ms = 80,
        },
    };
    pub const routes = .{
        zhtps.staticFiles(api, "/static", .{ .root = "." }),
        zhtps.get("/events", events),
        zhtps.get("/stream-cancel", events),
        zhtps.get("/generated", generated),
        zhtps.get("/stream-error", streamError),
        zhtps.get("/stream-short", streamShort),
        zhtps.get("/stream-long", streamLong),
        zhtps.get("/stream-empty", streamEmpty),
        zhtps.get("/stream-bodyless", streamBodyless),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/stream-timeout",
            .handler = events,
            .lane = .short,
        }),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/origin",
            .handler = origin,
            .lane = .control,
        }),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/metadata",
            .handler = metadata,
            .lane = .control,
        }),
        zhtps.get("/headers", headers),
        zhtps.get("/response-fields", responseFields),
        zhtps.get("/response-count", responseCount),
        zhtps.get("/response-budget", responseBudget),
        zhtps.get("/response-uppercase", responseUppercase),
        zhtps.get("/response-case", responseCase),
        zhtps.get("/large", large),
        zhtps.get("/lifecycle-delay", slow),
        zhtps.endpoint(.{
            .method = .post,
            .path = "/lifecycle-echo",
            .handler = lifecycleEcho,
            .body = .bytes,
            .max_body_bytes = 32 * 1024,
        }),
        zhtps.endpoint(.{
            .method = .post,
            .path = "/lifecycle-early",
            .handler = lifecycleEcho,
            .before = &.{lifecycleEarly},
            .body = .bytes,
            .max_body_bytes = 32 * 1024,
        }),
        zhtps.get("/hold", hold),
        zhtps.get("/cancel", cancel),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/timeout",
            .handler = slow,
            .lane = .short,
        }),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/inspect",
            .handler = inspect,
            .lane = .control,
        }),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/unblock",
            .handler = unblock,
            .lane = .control,
        }),
        zhtps.endpoint(.{
            .method = .post,
            .path = "/upload",
            .handler = uploaded,
            .body = .stream,
            .consume = consume,
            .max_body_bytes = 8 * 1024 * 1024,
        }),
    };

    fn events(call: *C) !zhtps.http.Response {
        call.local.retained = try call.scratch.allocator().dupe(u8, "data: last\n\n");
        return call.stream(.{
            .headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
        }, produceEvents);
    }

    fn produceEvents(call: *C, stream: *zhtps.ResponseStream) !void {
        _ = holding.fetchAdd(1, .release);
        try stream.writer.writeAll("data: first\n\n");
        try stream.flush();
        while ((!gate.load(.acquire) or std.mem.eql(u8, call.request.path, "/stream-cancel")) and
            !call.isCanceled())
            std.Io.sleep(call.io, .fromMilliseconds(1), .awake) catch {};
        try stream.writer.writeAll(call.local.retained);
    }

    fn generated(call: *C) !zhtps.http.Response {
        return call.stream(.{ .length = 8 * 1024 * 1024 }, produceDownload);
    }

    fn produceDownload(_: *C, stream: *zhtps.ResponseStream) !void {
        for (0..8192) |_| {
            try stream.writer.writeAll("0123456789abcdef" ** 64);
            _ = generated_bytes.fetchAdd(1024, .release);
        }
    }

    fn streamError(call: *C) !zhtps.http.Response {
        return call.stream(.{}, produceError);
    }

    fn produceError(call: *C, stream: *zhtps.ResponseStream) !void {
        if (try call.query("early")) |_| return error.InvalidInput;
        try stream.writer.print("part {d}", .{@as(u32, 1)});
        try stream.writer.flush();
        return error.InvalidInput;
    }

    fn streamShort(call: *C) !zhtps.http.Response {
        return call.stream(.{ .length = 9 }, produceSmall);
    }

    fn streamLong(call: *C) !zhtps.http.Response {
        return call.stream(.{ .length = 2 }, produceSmall);
    }

    fn produceSmall(_: *C, stream: *zhtps.ResponseStream) !void {
        var bytes = [_]u8{
            'a',
            'b',
            'c',
        };
        try stream.writer.writeAll(&bytes);
        @memset(&bytes, 'x');
    }

    fn streamEmpty(call: *C) !zhtps.http.Response {
        return call.stream(.{}, produceEmpty);
    }

    fn produceEmpty(_: *C, stream: *zhtps.ResponseStream) !void {
        try stream.flush();
    }

    fn streamBodyless(call: *C) !zhtps.http.Response {
        return call.stream(.{ .status = .no_content, .length = 0 }, produceEvents);
    }

    fn origin(call: *C) !zhtps.http.Response {
        return call.json(.ok, .{
            .scheme = call.request.scheme,
            .authority = call.request.authority,
        });
    }

    fn metadata(call: *C) !zhtps.http.Response {
        return call.json(.ok, .{
            .scheme = call.request.scheme,
            .authority = call.request.authority,
            .version = @tagName(call.request.version),
            .path = call.request.path,
            .query = call.request.query,
        });
    }

    fn large(call: *C) !zhtps.http.Response {
        return call.text(.ok, "0123456789abcdef" ** (512 * 1024));
    }

    fn lifecycleEcho(call: *C) !zhtps.http.Response {
        return call.text(.ok, call.bodyBytes());
    }

    fn lifecycleEarly(call: *C) C.HandlerError!?zhtps.http.Response {
        return call.text(.forbidden, "denied");
    }

    fn headers(call: *C) !zhtps.http.Response {
        return call.json(.ok, .{ .cookie = call.header("cookie"), .chunked = call.request.chunked });
    }

    fn responseFields(call: *C) !zhtps.http.Response {
        const fields: []const zhtps.http.Header = if (std.mem.eql(
            u8,
            call.request.query,
            "invalid-name",
        ))
            &.{.{ .name = "bad name", .value = "value" }}
        else if (std.mem.eql(u8, call.request.query, "invalid-value"))
            &.{.{ .name = "x-value", .value = "a\r\nb" }}
        else if (std.mem.eql(u8, call.request.query, "reserved"))
            &.{.{ .name = "Date", .value = "invalid" }}
        else
            &.{
                .{ .name = "X-MiXeD", .value = "  abc\t" },
                .{ .name = "Set-Cookie", .value = "a=1" },
                .{ .name = "Set-Cookie", .value = "b=2" },
                .{ .name = "Keep-Alive", .value = "timeout=5" },
                .{ .name = "Upgrade", .value = "test" },
                .{ .name = "Proxy-Connection", .value = "keep-alive" },
            };
        return .{ .headers = fields, .body = .{ .bytes = "ok" } };
    }

    fn responseCount(call: *C) !zhtps.http.Response {
        const count = std.fmt.parseInt(
            usize,
            call.request.query,
            10,
        ) catch return error.InvalidInput;
        const fields = try call.scratch.allocator().alloc(zhtps.http.Header, count);
        for (fields) |*field| field.* = .{ .name = "x-value", .value = "ok" };
        return .{ .headers = fields, .body = .{ .bytes = "ok" } };
    }

    fn responseBudget(call: *C) !zhtps.http.Response {
        const len = std.fmt.parseInt(usize, call.request.query, 10) catch return error.InvalidInput;
        const fields = try call.scratch.allocator().alloc(zhtps.http.Header, 1);
        const text = try call.scratch.allocator().alloc(u8, len);
        @memset(text, 'x');
        fields[0] = .{ .name = "x-large", .value = text };
        return .{ .headers = fields, .body = .{ .bytes = "ok" } };
    }

    fn responseUppercase(call: *C) !zhtps.http.Response {
        const gpa = call.scratch.allocator();
        const fields = try gpa.alloc(zhtps.http.Header, 40);
        for (fields, 0..) |*field, index| {
            field.* = .{
                .name = try std.fmt.allocPrint(gpa, "X-Custom-Header-{d}-Padding", .{index}),
                .value = try std.fmt.allocPrint(gpa, "value-{d}", .{index}),
            };
        }
        return .{ .headers = fields, .body = .{ .bytes = "ok" } };
    }

    fn responseCase(call: *C) !zhtps.http.Response {
        const name = call.request.query;
        if (std.mem.eql(u8, name, "panic-before")) @panic("response comparison panic");
        if (std.mem.eql(u8, name, "handler-error")) return error.InputOutput;
        if (std.mem.startsWith(u8, name, "stream") or std.mem.eql(u8, name, "panic-after")) {
            const length: ?u64 = if (std.mem.eql(u8, name, "stream-short")) 9 else if (std.mem.eql(
                u8,
                name,
                "stream-long",
            )) 2 else if (std.mem.eql(u8, name, "stream-exact") or
                std.mem.eql(u8, name, "stream-error-exact")) 3 else null;
            return call.stream(.{
                .length = length,
                .headers = if (std.mem.eql(u8, name, "stream-trailer"))
                    &.{.{ .name = "trailer", .value = "x-checksum" }}
                else
                    &.{},
            }, comparisonStream);
        }
        if (std.mem.startsWith(u8, name, "status-")) {
            const code = std.fmt.parseInt(u16, name[7..], 10) catch return error.InvalidInput;
            return .{ .status = code, .body = .{ .bytes = if (code == 304) "abc" else "" } };
        }
        if (std.mem.eql(u8, name, "body-204")) return .{ .status = 204, .body = .{ .bytes = "abc" } };
        if (std.mem.eql(u8, name, "body-205")) return .{ .status = 205, .body = .{ .bytes = "abc" } };
        if (std.mem.eql(u8, name, "duplicate-cookie")) return .{
            .headers = &.{
                .{ .name = "set-cookie", .value = "a=1" },
                .{ .name = "set-cookie", .value = "b=2" },
            },
            .body = .{ .bytes = "abc" },
        };
        const field: ?zhtps.http.Header = if (std.mem.eql(u8, name, "invalid-name"))
            .{ .name = "bad name", .value = "x" }
        else if (std.mem.eql(u8, name, "invalid-value"))
            .{ .name = "x-test", .value = "x\r\ny" }
        else if (std.mem.eql(u8, name, "nul-value"))
            .{ .name = "x-test", .value = "x\x00y" }
        else if (std.mem.eql(u8, name, "whitespace-value"))
            .{ .name = "x-test", .value = " \tabc\t " }
        else if (std.mem.eql(u8, name, "empty-field"))
            .{ .name = "x-test", .value = "" }
        else
            null;
        if (field) |header| {
            const fields = try call.scratch.allocator().alloc(zhtps.http.Header, 1);
            fields[0] = header;
            return .{ .headers = fields, .body = .{ .bytes = "abc" } };
        }
        return .{ .body = .{ .bytes = if (std.mem.eql(u8, name, "empty")) "" else "abc" } };
    }

    fn comparisonStream(call: *C, stream: *zhtps.ResponseStream) !void {
        const name = call.request.query;
        if (std.mem.eql(u8, name, "stream-error-before")) return error.InputOutput;
        if (std.mem.eql(u8, name, "stream-empty")) return;
        try stream.writer.writeAll("abc");
        if (std.mem.eql(u8, name, "stream-error-after") or
            std.mem.eql(u8, name, "stream-error-exact") or std.mem.eql(u8, name, "panic-after"))
        {
            try stream.flush();
            if (std.mem.eql(u8, name, "panic-after")) @panic("response comparison panic");
            return error.InputOutput;
        }
    }

    fn hold(call: *C) !zhtps.http.Response {
        _ = holding.fetchAdd(1, .release);
        while (!gate.load(.acquire)) std.Io.sleep(call.io, .fromMilliseconds(1), .awake) catch {};
        return call.text(.ok, "released");
    }

    fn slow(call: *C) !zhtps.http.Response {
        std.Io.sleep(call.io, .fromMilliseconds(250), .awake) catch {};
        return call.text(.ok, "late");
    }

    fn cancel(call: *C) !zhtps.http.Response {
        _ = holding.fetchAdd(1, .release);
        while (!call.isCanceled() and !stopping.load(.monotonic))
            std.Io.sleep(call.io, .fromMilliseconds(1), .awake) catch {};
        return call.text(.ok, "canceled");
    }

    fn inspect(call: *C) !zhtps.http.Response {
        return call.json(.ok, .{
            .holding = holding.load(.acquire),
            .released = released.load(.acquire),
            .generated_bytes = generated_bytes.load(.acquire),
        });
    }

    fn unblock(call: *C) !zhtps.http.Response {
        gate.store(true, .release);
        return call.text(.ok, "ok");
    }

    fn consume(call: *C, bytes: []const u8) !void {
        if (call.local.bytes == 0)
            if (call.header("x-preserve")) |text| {
                call.local.retained = text;
            };
        if (call.request.getHeader("x-hold") != null and call.local.bytes == 0) {
            _ = holding.fetchAdd(1, .release);
            while (!gate.load(.acquire)) std.Io.sleep(
                call.io,
                .fromMilliseconds(1),
                .awake,
            ) catch {};
        }
        call.local.bytes += bytes.len;
    }

    fn uploaded(call: *C) !zhtps.http.Response {
        if (call.header("x-preserve") != null) return call.json(.ok, .{
            .bytes = call.local.bytes,
            .trailers = call.request.trailers,
            .preserved = call.local.retained,
        });
        return call.json(.ok, .{ .bytes = call.local.bytes, .trailers = call.request.trailers });
    }

    pub fn release(call: *C) void {
        if (std.mem.eql(u8, call.request.path, "/hold") or std.mem.eql(u8, call.request.path, "/upload") or
            std.mem.eql(u8, call.request.path, "/cancel") or
            std.mem.eql(u8, call.request.path, "/events") or
            std.mem.eql(u8, call.request.path, "/stream-cancel") or
            std.mem.eql(u8, call.request.path, "/stream-timeout") or
            std.mem.eql(u8, call.request.path, "/generated"))
            _ = released.fetchAdd(1, .release);
    }
};

fn initialize(gpa: std.mem.Allocator, io: std.Io, config: zhtps.Config) !void {
    var server: zhtps.DefaultServer = undefined;
    try server.init(gpa, io, config);
    defer server.deinit();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const check_allocations = args.len > 1 and std.mem.eql(u8, args[1], "--check-allocations");
    var config = try zhtps.Config.parse(args[if (check_allocations) @as(usize, 2) else 1..]);
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (check_allocations) {
        config.workers = 2;
        config.max_connections = 2;
        config.admin_connections = 0;
        config.log_fd = null;
        try std.testing.checkAllAllocationFailures(
            allocator.allocator(),
            initialize,
            .{ init.io, config },
        );
        return;
    }
    const action: linux.Sigaction = .{
        .handler = .{ .handler = stop },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    for ([_]linux.SIG{ .TERM, .INT }) |sig|
        _ = try zhtps.platform.check(linux.sigaction(sig, &action, null));
    try zhtps.Server(zhtps.Application(api)).run(allocator.allocator(), init.io, config, &stopping);
}
