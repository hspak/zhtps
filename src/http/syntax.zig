//! Shared HTTP field and URI grammar. All string slices borrow their input.

const std = @import("std");
const log = std.log.scoped(.http_syntax);

pub fn isTokenByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn isToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |c| if (!isTokenByte(c)) return false;
    return true;
}

pub fn isField(bytes: []const u8) bool {
    var offset: usize = 0;
    while (bytes.len - offset >= 64) : (offset += 64) {
        const part: @Vector(64, u8) = bytes[offset..][0..64].*;
        const control = part < @as(@Vector(64, u8), @splat(0x20));
        const not_tab = part != @as(@Vector(64, u8), @splat('\t'));
        const del = part == @as(@Vector(64, u8), @splat(0x7f));
        if (@reduce(.Or, (control & not_tab) | del)) return false;
    }
    while (bytes.len - offset >= 32) : (offset += 32) {
        const part: @Vector(32, u8) = bytes[offset..][0..32].*;
        const control = part < @as(@Vector(32, u8), @splat(0x20));
        const not_tab = part != @as(@Vector(32, u8), @splat('\t'));
        const del = part == @as(@Vector(32, u8), @splat(0x7f));
        if (@reduce(.Or, (control & not_tab) | del)) return false;
    }
    for (bytes[offset..]) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return false;
    return true;
}

pub fn trim(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t");
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn isHex(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null;
}

fn isSubDelimiter(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!$&'()*+,;=", c) != null;
}

/// Validates a URI reg-name or a path/query component without decoding it.
pub fn isUriComponent(bytes: []const u8, path: bool) bool {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '%') {
            if (bytes.len - i < 3 or !isHex(bytes[i + 1]) or !isHex(bytes[i + 2]))
                return false;
            i += 2;
        } else if (!isUnreserved(c) and !isSubDelimiter(c)) {
            if (!path or std.mem.indexOfScalar(u8, ":@/?", c) == null) return false;
        }
    }
    return true;
}

/// Empty authority is valid for Host, but not for an absolute HTTP URI or CONNECT.
pub fn isAuthority(bytes: []const u8, require_port: bool, allow_empty: bool) bool {
    if (bytes.len == 0) return allow_empty and !require_port;
    var port: ?[]const u8 = null;
    if (bytes[0] == '[') {
        const end = std.mem.indexOfScalar(u8, bytes, ']') orelse return false;
        const literal = bytes[1..end];
        if (literal.len == 0) return false;
        if (literal[0] == 'v' or literal[0] == 'V') {
            const dot = std.mem.indexOfScalar(u8, literal, '.') orelse return false;
            if (dot < 2 or dot + 1 == literal.len) return false;
            for (literal[1..dot]) |c| if (!isHex(c)) return false;
            for (literal[dot + 1 ..]) |c| {
                if (!isUnreserved(c) and !isSubDelimiter(c) and c != ':') return false;
            }
        } else {
            _ = std.Io.net.Ip6Address.parse(literal, 0) catch return false;
        }
        if (end + 1 < bytes.len) {
            if (bytes[end + 1] != ':') return false;
            port = bytes[end + 2 ..];
        }
    } else {
        const colon = std.mem.indexOfScalar(u8, bytes, ':');
        const host = bytes[0 .. colon orelse bytes.len];
        if (host.len == 0 or !isUriComponent(host, false)) return false;
        if (colon) |at| port = bytes[at + 1 ..];
    }
    if (port) |digits| {
        if (require_port and digits.len == 0) return false;
        for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    } else if (require_port) return false;
    return true;
}

/// Consumes one quoted-string, including escapes, or returns null for invalid syntax.
pub fn quotedLength(bytes: []const u8) ?usize {
    if (bytes.len == 0 or bytes[0] != '"') return null;
    var i: usize = 1;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '"') return i + 1;
        if (c == '\\') {
            i += 1;
            if (i == bytes.len) return null;
            if ((bytes[i] < 0x20 and bytes[i] != '\t') or bytes[i] == 0x7f) return null;
        } else if ((c < 0x20 and c != '\t') or c == 0x7f) return null;
    }
    return null;
}

test "authority validates IPv6 literals, ports, and reg-name escapes" {
    const testing = std.testing;
    for ([_][]const u8{
        "example.com:8080",
        "[::1]:80",
        "[v1.test:address]:443",
        "ex%61mple.com",
    }) |valid| try testing.expect(isAuthority(valid, false, false));
    for ([_][]const u8{
        "user@example.com",
        "[bad]:80",
        "host:abc",
        "host:80:90",
        "host/path",
        "host%GG",
    }) |invalid| try testing.expect(!isAuthority(invalid, false, false));
    try testing.expect(!isAuthority("host", true, false));
    try testing.expect(isAuthority("", false, true));
}
