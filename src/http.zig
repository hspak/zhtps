//! HTTP/1.1 message parsing and serialization, independent of transport.

pub const Request = @import("http/Request.zig");
pub const Parser = @import("http/Parser.zig");
pub const Response = @import("http/Response.zig");
pub const syntax = @import("http/syntax.zig");
pub const conditions = @import("http/conditions.zig");
pub const date = @import("http/date.zig");
pub const path = @import("http/path.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Version = enum {
    http_1_0,
    http_1_1,
    http_2,
};

test {
    _ = Request;
    _ = Parser;
    _ = Response;
    _ = syntax;
    _ = conditions;
    _ = date;
    _ = path;
}
