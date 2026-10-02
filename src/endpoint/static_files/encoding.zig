//! Accept-Encoding negotiation for identity and zstd representations.

const std = @import("std");
const http = @import("../../http.zig");

pub const Preferences = struct {
    zstd: u16,
    identity: u16,
};

pub const Error = error{InvalidInput};

/// Combines repeated fields. Absent and empty fields select identity by policy.
/// Rejects malformed weights and conflicting duplicate coding preferences.
pub fn parse(headers: []const http.Header) Error!Preferences {
    var zstd: ?u16 = null;
    var identity: ?u16 = null;
    var wildcard: ?u16 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) continue;
        var items = std.mem.splitScalar(u8, header.value, ',');
        while (items.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t");
            if (trimmed.len == 0) continue;
            var parts = std.mem.splitScalar(u8, trimmed, ';');
            const coding = std.mem.trim(u8, parts.next().?, " \t");
            if (!http.syntax.isToken(coding)) return error.InvalidInput;
            var weight: u16 = 1000;
            if (parts.next()) |parameter| {
                const pair = std.mem.trim(u8, parameter, " \t");
                if (pair.len < 2 or std.ascii.toLower(pair[0]) != 'q' or pair[1] != '=')
                    return error.InvalidInput;
                weight = try quality(pair[2..]);
                if (parts.next() != null) return error.InvalidInput;
            }
            const slot = if (std.ascii.eqlIgnoreCase(coding, "zstd")) &zstd else if (std.ascii.eqlIgnoreCase(coding, "identity")) &identity else if (std.mem.eql(u8, coding, "*")) &wildcard else continue;
            if (slot.*) |previous| if (previous != weight) return error.InvalidInput;
            slot.* = weight;
        }
    }
    return .{
        .zstd = zstd orelse wildcard orelse 0,
        .identity = identity orelse if (wildcard == 0) @as(u16, 0) else 1000,
    };
}

fn quality(bytes: []const u8) Error!u16 {
    if (bytes.len == 0 or (bytes[0] != '0' and bytes[0] != '1')) return error.InvalidInput;
    if (bytes.len == 1) return if (bytes[0] == '1') 1000 else 0;
    if (bytes[1] != '.' or bytes.len > 5) return error.InvalidInput;
    var fraction: u16 = 0;
    var place: u16 = 100;
    for (bytes[2..]) |digit| {
        if (!std.ascii.isDigit(digit) or (bytes[0] == '1' and digit != '0')) return error.InvalidInput;
        fraction += @as(u16, digit - '0') * place;
        place /= 10;
    }
    return if (bytes[0] == '1') 1000 else fraction;
}
