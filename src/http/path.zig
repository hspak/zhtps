//! URI path normalization for routing, without decoding reserved separators.

const std = @import("std");

pub const Error = error{ NoSpaceLeft, InvalidPath };

/// Normalizes an absolute path (or OPTIONS "*") into caller-owned storage.
/// The buffer must fit the original path and must not overlap it. Unreserved
/// escapes decode before RFC 3986 dot-segment removal; repeated slashes remain.
/// An empty path remains empty, as used by CONNECT request metadata.
pub fn normalize(buffer: []u8, path: []const u8) Error![]const u8 {
    if (buffer.len < path.len) return error.NoSpaceLeft;
    if (path.len > 0 and path[0] != '/' and !std.mem.eql(u8, path, "*")) return error.InvalidPath;
    var read: usize = 0;
    var len: usize = 0;
    while (read < path.len) {
        if (path[read] != '%') {
            buffer[len] = path[read];
            len += 1;
            read += 1;
            continue;
        }
        if (path.len - read < 3) return error.InvalidPath;
        const high = std.fmt.charToDigit(path[read + 1], 16) catch return error.InvalidPath;
        const low = std.fmt.charToDigit(path[read + 2], 16) catch return error.InvalidPath;
        const byte = high * 16 + low;
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) {
            buffer[len] = byte;
            len += 1;
        } else {
            buffer[len] = '%';
            buffer[len + 1] = std.ascii.toUpper(path[read + 1]);
            buffer[len + 2] = std.ascii.toUpper(path[read + 2]);
            len += 3;
        }
        read += 3;
    }
    read = 0;
    var written: usize = 0;
    while (read < len) {
        const rest = buffer[read..len];
        if (std.mem.startsWith(u8, rest, "/./")) {
            read += 2;
        } else if (std.mem.eql(u8, rest, "/.")) {
            buffer[written] = '/';
            written += 1;
            break;
        } else if (std.mem.startsWith(u8, rest, "/../") or std.mem.eql(u8, rest, "/..")) {
            written = std.mem.lastIndexOfScalar(u8, buffer[0..written], '/') orelse 0;
            read += 3;
            if (read == len) {
                buffer[written] = '/';
                written += 1;
            }
        } else {
            const end = std.mem.indexOfScalarPos(u8, buffer[0..len], read + 1, '/') orelse len;
            std.mem.copyForwards(u8, buffer[written..][0 .. end - read], buffer[read..end]);
            written += end - read;
            read = end;
        }
    }
    return buffer[0..written];
}

test "path normalization preserves separators and removes only dot segments" {
    const cases = [_][2][]const u8{
        .{ "/a/b/c/./../../g", "/a/g" },
        .{ "/../a/../../", "/" },
        .{ "/a/b/..", "/a/" },
        .{ "/a/.", "/a/" },
        .{ "/a//b/../c", "/a//c" },
        .{ "/%2e%2E/%73tream", "/stream" },
        .{ "/a/%2f/%3f/%23/%5c/%252e", "/a/%2F/%3F/%23/%5C/%252e" },
        .{ "/.../.well-known", "/.../.well-known" },
        .{ "*", "*" },
        .{ "", "" },
    };
    var buffer: [128]u8 = undefined;
    for (cases) |case| try std.testing.expectEqualStrings(case[1], try normalize(&buffer, case[0]));
    try std.testing.expectError(error.NoSpaceLeft, normalize(buffer[0..2], "/abc"));
    try std.testing.expectError(error.InvalidPath, normalize(&buffer, "/%2_"));
}
