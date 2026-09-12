//! One built-in origin exchange. Storage and request metadata live through response completion.

const std = @import("std");
const http = @import("../http.zig");
const log = std.log.scoped(.application);
const Exchange = @This();

storage: []u8,
used: usize = 0,
route: enum {
    root,
    echo,
    stream,
    missing,
} = .missing,
fields: [3]http.Header = undefined,

pub const BodyError = error{BodyTooLarge};

const root_body = "ZHTPS\n";
const stream_fragments = [_][]const u8{
    "one\n",
    "two\n",
    "three\n",
};
const stream_length = length: {
    var size: u64 = 0;
    for (stream_fragments) |fragment| size += fragment.len;
    break :length size;
};

pub fn init(exchange: *Exchange, storage: []u8) void {
    exchange.* = .{ .storage = storage };
}

/// Returns a final response before body processing. Its fields borrow the
/// exchange until all sends complete. Unread content requires connection closure.
pub fn receiveHead(exchange: *Exchange, request: *const http.Request) ?http.Response {
    exchange.route = if (std.mem.eql(u8, request.path, "/"))
        .root
    else if (std.mem.eql(u8, request.path, "/echo"))
        .echo
    else if (std.mem.eql(u8, request.path, "/stream"))
        .stream
    else
        .missing;
    if (std.mem.eql(u8, request.method, "OPTIONS")) return null;
    const implemented = std.mem.eql(u8, request.method, "GET") or
        std.mem.eql(u8, request.method, "HEAD") or std.mem.eql(u8, request.method, "POST");
    if (!implemented) return exchange.earlyStatus(501);
    if (exchange.route == .missing) return exchange.earlyStatus(404);
    if (exchange.route == .echo) {
        if (!std.mem.eql(u8, request.method, "POST")) return exchange.earlyStatus(405);
        if (request.content_length) |len| if (len > exchange.storage.len) return exchange.earlyStatus(413);
    } else if (!std.mem.eql(u8, request.method, "GET") and !std.mem.eql(u8, request.method, "HEAD")) {
        return exchange.earlyStatus(405);
    }
    // These representations have no modification time, so date preconditions do not apply.
    const precondition = http.conditions.evaluate(request, .{
        .exists = exchange.route != .echo,
        .etag = exchange.entityTag(),
    }, 0) catch return exchange.earlyStatus(400);
    if (precondition) |status| {
        if (status != 304) return exchange.earlyStatus(status);
        exchange.fields[0] = .{ .name = "ETag", .value = exchange.entityTag().? };
        return .{
            .status = 304,
            .headers = exchange.fields[0..1],
            .body = .{ .stream = if (exchange.route == .root) root_body.len else stream_length },
            // The head is already consumed. With no content, its boundary
            // is also the request boundary and pipelined bytes stay intact.
            .close = request.chunked or (request.content_length orelse 0) > 0,
        };
    }
    return null;
}

fn earlyStatus(exchange: *Exchange, status: u16) http.Response {
    exchange.fields[0] = .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" };
    exchange.fields[1] = .{ .name = "Allow", .value = exchange.allowedMethods() };
    return .{
        .status = status,
        .headers = exchange.fields[0..if (status == 405) @as(usize, 2) else 1],
        .body = .{ .bytes = http.Response.errorBody(status) },
        .close = true,
    };
}

fn entityTag(exchange: *const Exchange) ?[]const u8 {
    return switch (exchange.route) {
        .root => "\"zhtps-root-v1\"",
        .stream => "\"zhtps-stream-v1\"",
        .echo, .missing => null,
    };
}

pub fn allowedMethods(exchange: *const Exchange) []const u8 {
    return switch (exchange.route) {
        .root, .stream => "GET, HEAD, OPTIONS",
        .echo => "POST, OPTIONS",
        .missing => "OPTIONS",
    };
}

/// Produces a nonempty fragment or null at end. Returned bytes stay borrowed
/// until the next call or exchange completion. The transport may copy fragments
/// and batch producer calls before sending. No producer work is performed for HEAD.
pub fn produce(exchange: *Exchange, destination: []u8) ?[]const u8 {
    if (exchange.route != .stream or exchange.used == stream_fragments.len) return null;
    const bytes = stream_fragments[exchange.used];
    exchange.used += 1;
    @memcpy(destination[0..bytes.len], bytes);
    return destination[0..bytes.len];
}

/// Body fragments are consumed before returning; no borrowed fragment escapes.
pub fn receiveBody(exchange: *Exchange, bytes: []const u8) BodyError!void {
    if (exchange.route != .echo) return;
    if (bytes.len > exchange.storage.len - exchange.used) return error.BodyTooLarge;
    @memcpy(exchange.storage[exchange.used..][0..bytes.len], bytes);
    exchange.used += bytes.len;
}

/// The response borrows exchange storage until all sends finish.
pub fn respond(exchange: *Exchange, request: *const http.Request) http.Response {
    if (std.mem.eql(u8, request.method, "OPTIONS")) {
        exchange.fields[0] = .{
            .name = "Allow",
            .value = if (std.mem.eql(u8, request.path, "*")) "GET, HEAD, POST, OPTIONS" else exchange.allowedMethods(),
        };
        return .{ .status = 204, .headers = exchange.fields[0..1] };
    }
    return switch (exchange.route) {
        .root => .{
            .headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "ETag", .value = "\"zhtps-root-v1\"" },
            },
            .body = .{ .bytes = root_body },
        },
        .echo => .{
            .headers = &.{.{ .name = "Content-Type", .value = "application/octet-stream" }},
            .body = .{ .bytes = exchange.storage[0..exchange.used] },
        },
        .stream => .{
            .headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "ETag", .value = "\"zhtps-stream-v1\"" },
            },
            .body = .{ .stream = null },
        },
        .missing => exchange.earlyStatus(404),
    };
}
