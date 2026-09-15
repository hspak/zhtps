//! Validated route declarations and deterministic resource matching.

const std = @import("std");
const http = @import("../http.zig");

/// Rejects non-struct options and fields not explicitly supported by the builder.
pub fn validateOptions(comptime T: type, comptime names: []const []const u8) void {
    if (@typeInfo(T) != .@"struct") @compileError("options must be a struct");
    // Tuple declarations share an evaluation budget before compileRoutes runs.
    @setEvalBranchQuota(1_000_000);
    for (std.meta.fields(T)) |field| {
        for (names) |name| {
            if (std.mem.eql(u8, field.name, name)) break;
        } else @compileError("unknown option: " ++ field.name);
    }
}

/// Requires a normalized absolute URI path with at most eight unique parameters.
pub fn validatePath(comptime path: []const u8) void {
    if (path.len == 0 or path[0] != '/') @compileError("endpoint paths must begin with '/'");
    if (!http.syntax.isUriComponent(path, true) or std.mem.indexOfScalar(u8, path, '?') != null)
        @compileError("endpoint paths must contain only URI path characters");
    var normalized: [path.len]u8 = undefined;
    const canonical = http.path.normalize(&normalized, path) catch
        @compileError("invalid endpoint path");
    if (!std.mem.eql(u8, canonical, path)) @compileError("endpoint paths must be normalized");
    var names: [8][]const u8 = undefined;
    var used: usize = 0;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (!parameter(segment)) continue;
        if (segment.len == 1) @compileError("path parameter names cannot be empty");
        for (segment[1..]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_')
                @compileError("path parameter names must contain letters, digits or underscores");
        }
        if (used == names.len) @compileError("an endpoint path has more than eight parameters");
        for (names[0..used]) |name| {
            if (std.mem.eql(u8, name, segment[1..]))
                @compileError("path parameter names must be unique");
        }
        names[used] = segment[1..];
        used += 1;
    }
}

/// Requires a normalized literal path; only the root prefix may end with '/'.
pub fn validatePrefix(comptime prefix: []const u8) void {
    validatePath(prefix);
    if (prefix.len > 1 and prefix[prefix.len - 1] == '/')
        @compileError("endpoint group prefixes must not end with '/'");
    var segments = std.mem.splitScalar(u8, prefix, '/');
    while (segments.next()) |segment| {
        if (parameter(segment)) @compileError("group prefixes cannot contain parameters");
    }
}

/// Counts leaf routes in a tuple or array containing routes and nested groups.
pub fn count(comptime entries: anytype) usize {
    var result: usize = 0;
    for (entries) |entry| {
        result += if (comptime @hasField(@TypeOf(entry), "handler")) 1 else count(entry.routes);
    }
    return result;
}

/// Flattens groups into static routes with inherited prefixes and middleware,
/// rejecting duplicate method/pattern pairs before any server can run.
pub fn compileRoutes(comptime Api: type, comptime R: type) [count(Api.routes)]R {
    var compilation: Compilation(Api, R) = .{};
    // Both path validation and pairwise ambiguity checks scale with declarations.
    @setEvalBranchQuota(100_000 + compilation.routes.len * compilation.routes.len * 1000);
    compilation.collect(Api.routes, .{});
    for (compilation.routes, 0..) |left, at| {
        for (compilation.routes[at + 1 ..]) |right| {
            if (left.method == right.method and left.subtree == right.subtree and
                samePattern(left.path, right.path))
                @compileError("duplicate endpoint method and path pattern");
        }
    }
    return compilation.routes;
}

fn Compilation(comptime Api: type, comptime R: type) type {
    return struct {
        const Self = @This();

        routes: [count(Api.routes)]R = undefined,
        len: usize = 0,

        const Options = struct {
            prefix: []const u8 = "",
            before: []const R.Middleware = &.{},
        };

        fn collect(self: *Self, comptime entries: anytype, comptime options: Options) void {
            for (entries) |entry| {
                if (@TypeOf(entry).Specification != Api)
                    @compileError("all endpoints must use the application API specification");
                var own: [entry.before.len]R.Middleware = undefined;
                for (entry.before, 0..) |middleware, at| own[at] = middleware;
                const middleware = options.before ++ own;
                if (middleware.len > 16)
                    @compileError("an endpoint has more than sixteen middleware functions");
                if (comptime @hasField(@TypeOf(entry), "handler")) {
                    const joined = options.prefix ++ entry.path;
                    const path = if (entry.subtree and joined.len > 1 and
                        joined[joined.len - 1] == '/') joined[0 .. joined.len - 1] else joined;
                    validatePath(path);
                    self.routes[self.len] = entry;
                    self.routes[self.len].path = path;
                    self.routes[self.len].before = middleware;
                    self.len += 1;
                } else {
                    self.collect(entry.routes, .{
                        .prefix = if (std.mem.eql(u8, entry.prefix, "/"))
                            options.prefix
                        else
                            options.prefix ++ entry.prefix,
                        .before = middleware,
                    });
                }
            }
        }
    };
}

/// Matches a normalized path; parameters consume exactly one nonempty segment.
pub fn matches(path: []const u8, pattern: []const u8) bool {
    var actual = std.mem.splitScalar(u8, path, '/');
    var expected = std.mem.splitScalar(u8, pattern, '/');
    while (expected.next()) |segment| {
        const part = actual.next() orelse return false;
        if (parameter(segment)) {
            if (part.len == 0) return false;
        } else if (!std.mem.eql(u8, part, segment)) return false;
    }
    return actual.next() == null;
}

/// Ignores parameter names but preserves literal segments and slash placement.
pub fn samePattern(left: []const u8, right: []const u8) bool {
    var a = std.mem.splitScalar(u8, left, '/');
    var b = std.mem.splitScalar(u8, right, '/');
    while (a.next()) |part| {
        const other = b.next() orelse return false;
        if (parameter(part) and parameter(other)) continue;
        if (!std.mem.eql(u8, part, other)) return false;
    }
    return b.next() == null;
}

/// Only compares patterns that match the same path. The first differing
/// segment decides: a literal is more specific than a parameter.
pub fn moreSpecific(left: []const u8, right: []const u8) bool {
    var a = std.mem.splitScalar(u8, left, '/');
    var b = std.mem.splitScalar(u8, right, '/');
    while (a.next()) |part| {
        const other = b.next().?;
        if (parameter(part) != parameter(other)) return !parameter(part);
    }
    return false;
}

fn parameter(segment: []const u8) bool {
    return segment.len > 0 and segment[0] == ':';
}
