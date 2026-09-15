//! Buffered and incremental upload consumers with identical checksum responses.

const std = @import("std");
const zhtps = @import("zhtps");
const options = @import("upload_options");
const Crc32 = @import("Crc32.zig");
const linux = zhtps.platform.linux;
const log = std.log.scoped(.bench_upload);

const body_limit = 8 * 1024 * 1024;
var stopping: std.atomic.Value(bool) = .init(false);
var gate: std.atomic.Value(bool) = .init(false);

fn signal(sig: linux.SIG) callconv(.c) void {
    if (sig != .USR1) stopping.store(true, .monotonic);
    gate.store(true, .release);
}

const api = struct {
    const C = zhtps.Call(@This());
    pub const Services = struct {
        consumed: std.atomic.Value(u64) = .init(0),
        completed: std.atomic.Value(u64) = .init(0),
        released: std.atomic.Value(u64) = .init(0),
        holding: std.atomic.Value(u64) = .init(0),
    };
    pub const Local = struct {
        checksum: if (options.fast_crc) Crc32 else std.hash.Crc32 = if (options.fast_crc) .{} else .init(),
        bytes: usize = 0,
        response: [64]u8 = undefined,
    };
    pub const lanes = .{
        .default = .{
            .threads = 1,
            .queue = 256,
            .timeout_ms = 30000,
        },
        .control = .{
            .threads = 1,
            .queue = 32,
            .timeout_ms = 30000,
        },
        .short = .{
            .threads = 1,
            .queue = 32,
            .timeout_ms = 150,
        },
    };
    pub const routes = .{
        zhtps.endpoint(.{
            .method = .get,
            .path = "/",
            .handler = ready,
            .lane = .control,
        }),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/inspect",
            .handler = inspect,
            .lane = .control,
        }),
        upload(
            "/upload",
            body_limit,
            .default,
        ),
        upload(
            "/held",
            body_limit,
            .default,
        ),
        upload(
            "/invalid",
            body_limit,
            .default,
        ),
        upload(
            "/small",
            16,
            .default,
        ),
        upload(
            "/deadline",
            body_limit,
            .short,
        ),
        upload(
            "/deadline-held",
            body_limit,
            .short,
        ),
        if (options.streaming) zhtps.endpoint(.{
            .method = .post,
            .path = "/denied",
            .handler = finish,
            .body = .stream,
            .max_body_bytes = body_limit,
            .consume = consume,
            .before = &.{deny},
        }) else zhtps.endpoint(.{
            .method = .post,
            .path = "/denied",
            .handler = finish,
            .body = .bytes,
            .max_body_bytes = body_limit,
            .before = &.{deny},
        }),
    };

    fn upload(
        comptime path: []const u8,
        comptime limit: usize,
        comptime lane: @TypeOf(zhtps.get("/", finish)).Lane,
    ) @TypeOf(zhtps.get("/", finish)) {
        if (options.streaming) return zhtps.endpoint(.{
            .method = .post,
            .path = path,
            .handler = finish,
            .body = .stream,
            .max_body_bytes = limit,
            .consume = consume,
            .lane = lane,
        });
        return zhtps.endpoint(.{
            .method = .post,
            .path = path,
            .handler = finish,
            .body = .bytes,
            .max_body_bytes = limit,
            .lane = lane,
        });
    }

    fn ready(call: *C) C.HandlerError!zhtps.http.Response {
        return call.text(.ok, "ZHTPS\n");
    }

    fn inspect(call: *C) C.HandlerError!zhtps.http.Response {
        return call.json(.ok, .{
            .consumed = call.services.consumed.load(.acquire),
            .completed = call.services.completed.load(.acquire),
            .released = call.services.released.load(.acquire),
            .holding = call.services.holding.load(.acquire),
        });
    }

    fn deny(call: *C) C.HandlerError!?zhtps.http.Response {
        return call.text(.forbidden, "denied\n");
    }

    fn consume(call: *C, bytes: []const u8) C.HandlerError!void {
        if (options.observe) {
            if (std.mem.eql(
                u8,
                call.request.path,
                "/invalid",
            )) return error.InvalidInput;
            if ((std.mem.eql(
                u8,
                call.request.path,
                "/held",
            ) or
                std.mem.eql(
                    u8,
                    call.request.path,
                    "/deadline-held",
                )) and call.local.bytes == 0)
            {
                _ = call.services.holding.fetchAdd(1, .release);
                defer _ = call.services.holding.fetchSub(1, .release);
                while (!gate.load(.acquire))
                    std.Io.sleep(
                        call.io,
                        .fromMilliseconds(1),
                        .awake,
                    ) catch {};
            }
        }
        call.local.checksum.update(bytes);
        call.local.bytes += bytes.len;
        if (options.observe) _ = call.services.consumed.fetchAdd(bytes.len, .release);
    }

    fn finish(call: *C) C.HandlerError!zhtps.http.Response {
        if (!options.streaming) try consume(call, call.bodyBytes());
        const response = std.fmt.bufPrint(
            &call.local.response,
            "{d}:{x:0>8}\n",
            .{
                call.local.bytes,
                call.local.checksum.final(),
            },
        ) catch unreachable;
        if (options.observe) _ = call.services.completed.fetchAdd(1, .release);
        return call.text(.ok, response);
    }

    pub fn release(call: *C) void {
        if (options.observe and std.mem.eql(
            u8,
            call.request.method,
            "POST",
        ))
            _ = call.services.released.fetchAdd(1, .release);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config = try zhtps.Config.parse(args[1..]);
    config.application_bytes = if (options.streaming) 64 * 1024 else body_limit;
    config.receive_bytes = 64 * 1024;
    config.large_buffer_bytes = 256 * 1024 * 1024;
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
