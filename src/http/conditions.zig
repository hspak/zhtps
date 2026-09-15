//! Origin-server precondition ordering and validator comparisons from RFC 9110 section 13.

const std = @import("std");
const http = @import("../http.zig");
const date = @import("date.zig");
const syntax = @import("syntax.zig");
const log = std.log.scoped(.http_conditions);

pub const Representation = struct {
    exists: bool = true,
    /// Complete quoted entity tag, optionally prefixed with W/; borrowed.
    etag: ?[]const u8 = null,
    last_modified: ?i64 = null,
};

pub const Error = error{InvalidEntityTag};

/// Returns 304 or 412 when a precondition prevents the method, otherwise null.
/// Call after normal routing, authentication, and method checks have succeeded,
/// before processing content or causing side effects. OPTIONS/TRACE/CONNECT
/// ignore preconditions. Repeated date fields and invalid dates are ignored;
/// malformed entity-tag lists return an error suitable for a 400 response.
/// `now` has the same clock range contract as date.parse. Range is optional and
/// handled separately by applications that implement partial responses.
pub fn evaluate(
    request: *const http.Request,
    selected: Representation,
    now: u64,
) Error!?u16 {
    for ([_][]const u8{
        "OPTIONS",
        "TRACE",
        "CONNECT",
    }) |method|
        if (std.mem.eql(
            u8,
            request.method,
            method,
        )) return null;
    const retrieval = std.mem.eql(
        u8,
        request.method,
        "GET",
    ) or std.mem.eql(
        u8,
        request.method,
        "HEAD",
    );
    if (try matches(
        request,
        "if-match",
        selected,
        true,
    )) |match| {
        if (!match) return 412;
    } else if (selected.last_modified) |modified| {
        if (uniqueDate(
            request,
            "if-unmodified-since",
            now,
        )) |limit| if (modified > limit) return 412;
    }
    if (try matches(
        request,
        "if-none-match",
        selected,
        false,
    )) |match| {
        if (match) return if (retrieval) 304 else 412;
    } else if (retrieval) {
        if (selected.last_modified) |modified| {
            if (uniqueDate(
                request,
                "if-modified-since",
                now,
            )) |limit| if (modified <= limit) return 304;
        }
    }
    return null;
}

fn uniqueDate(
    request: *const http.Request,
    name: []const u8,
    now: u64,
) ?i64 {
    var found: ?[]const u8 = null;
    for (request.headers) |field| {
        if (!syntax.eql(field.name, name)) continue;
        if (found != null) return null;
        found = field.value;
    }
    return date.parse(found orelse return null, now);
}

fn matches(
    request: *const http.Request,
    name: []const u8,
    selected: Representation,
    strong: bool,
) Error!?bool {
    var present = false;
    var matched = false;
    var wildcard = false;
    var tags: usize = 0;
    for (request.headers) |field| {
        if (!syntax.eql(field.name, name)) continue;
        present = true;
        var rest = syntax.trim(field.value);
        if (std.mem.eql(
            u8,
            rest,
            "*",
        )) {
            if (wildcard or tags != 0) return error.InvalidEntityTag;
            wildcard = true;
            matched = selected.exists;
            continue;
        }
        if (wildcard) return error.InvalidEntityTag;
        while (rest.len > 0) {
            if (rest[0] == ',') {
                rest = syntax.trim(rest[1..]);
                continue;
            }
            const weak = std.mem.startsWith(
                u8,
                rest,
                "W/",
            );
            const start: usize = if (weak) 2 else 0;
            if (rest.len <= start or rest[start] != '"') return error.InvalidEntityTag;
            var end = start + 1;
            while (end < rest.len and rest[end] != '"') : (end += 1) {
                if (rest[end] < 0x21 or rest[end] == 0x7f) return error.InvalidEntityTag;
            }
            if (end == rest.len) return error.InvalidEntityTag;
            const tag = rest[start .. end + 1];
            tags += 1;
            if (selected.exists) {
                if (selected.etag) |actual| {
                    const actual_weak = std.mem.startsWith(
                        u8,
                        actual,
                        "W/",
                    );
                    if ((!strong or (!weak and !actual_weak)) and
                        std.mem.eql(
                            u8,
                            tag,
                            if (actual_weak) actual[2..] else actual,
                        )) matched = true;
                }
            }
            rest = syntax.trim(rest[end + 1 ..]);
            if (rest.len > 0 and rest[0] != ',') return error.InvalidEntityTag;
        }
    }
    return if (present) matched else null;
}

test "conditional comparison respects strength, lists, and method semantics" {
    const testing = std.testing;
    const selected: Representation = .{ .etag = "\"a,b\"" };
    var request: http.Request = .{ .method = "GET" };
    request.headers = &.{.{ .name = "If-None-Match", .value = "\"other\", W/\"a,b\"" }};
    try testing.expectEqual(@as(?u16, 304), try evaluate(
        &request,
        selected,
        0,
    ));
    request.method = "POST";
    try testing.expectEqual(@as(?u16, 412), try evaluate(
        &request,
        selected,
        0,
    ));
    request.headers = &.{.{ .name = "If-Match", .value = "W/\"a,b\"" }};
    try testing.expectEqual(@as(?u16, 412), try evaluate(
        &request,
        selected,
        0,
    ));
    request.headers = &.{
        .{ .name = "If-Match", .value = "\"other\"" },
        .{ .name = "If-Match", .value = "\"a,b\"" },
    };
    try testing.expectEqual(@as(?u16, null), try evaluate(
        &request,
        selected,
        0,
    ));
    request.headers = &.{.{ .name = "If-Match", .value = "*" }};
    try testing.expectEqual(@as(?u16, 412), try evaluate(
        &request,
        .{ .exists = false },
        0,
    ));
    request.method = "OPTIONS";
    try testing.expectEqual(@as(?u16, null), try evaluate(
        &request,
        .{ .exists = false },
        0,
    ));
    request.method = "GET";
    request.headers = &.{.{ .name = "If-None-Match", .value = "*, \"a,b\"" }};
    try testing.expectError(error.InvalidEntityTag, evaluate(
        &request,
        selected,
        0,
    ));
}

test "preconditions use RFC ordering and ignore invalid or repeated dates" {
    const testing = std.testing;
    const selected: Representation = .{ .etag = "\"v1\"", .last_modified = 784111777 };
    var request: http.Request = .{ .method = "GET", .headers = &.{
        .{ .name = "If-Match", .value = "\"other\"" },
        .{ .name = "If-None-Match", .value = "\"v1\"" },
    } };
    try testing.expectEqual(@as(?u16, 412), try evaluate(
        &request,
        selected,
        0,
    ));
    request.headers = &.{
        .{ .name = "If-Match", .value = "\"v1\"" },
        .{ .name = "If-Unmodified-Since", .value = "Thu, 01 Jan 1970 00:00:00 GMT" },
        .{ .name = "If-None-Match", .value = "\"other\"" },
        .{ .name = "If-Modified-Since", .value = "Sun, 06 Nov 1994 08:49:37 GMT" },
    };
    try testing.expectEqual(@as(?u16, null), try evaluate(
        &request,
        selected,
        0,
    ));
    request.headers = &.{.{ .name = "If-Modified-Since", .value = "Sun, 06 Nov 1994 08:49:37 GMT" }};
    try testing.expectEqual(@as(?u16, 304), try evaluate(
        &request,
        selected,
        0,
    ));
    request.headers = &.{.{ .name = "If-Unmodified-Since", .value = "Thu, 01 Jan 1970 00:00:00 GMT" }};
    try testing.expectEqual(@as(?u16, 412), try evaluate(
        &request,
        selected,
        0,
    ));
    request.headers = &.{
        .{ .name = "If-Unmodified-Since", .value = "Thu, 01 Jan 1970 00:00:00 GMT" },
        .{ .name = "If-Unmodified-Since", .value = "Thu, 01 Jan 1970 00:00:00 GMT" },
    };
    try testing.expectEqual(@as(?u16, null), try evaluate(
        &request,
        selected,
        0,
    ));
    request.headers = &.{.{ .name = "If-Modified-Since", .value = "invalid" }};
    try testing.expectEqual(@as(?u16, null), try evaluate(
        &request,
        selected,
        0,
    ));
}

test "RFC 850 leap day precondition survives century rollover" {
    const request: http.Request = .{
        .method = "GET",
        .headers = &.{.{ .name = "If-Unmodified-Since", .value = "Tuesday, 29-Feb-00 00:00:00 GMT" }},
    };
    try std.testing.expectEqual(@as(?u16, 412), try evaluate(
        &request,
        .{ .last_modified = 978307200 },
        2524608000,
    ));
}
