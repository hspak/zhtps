//! Borrowed request metadata, valid until its owning exchange is released.

const std = @import("std");
const http = @import("../http.zig");
const syntax = @import("syntax.zig");
const log = std.log.scoped(.http_request);
const Request = @This();

method: []const u8 = "",
target: []const u8 = "",
/// The parser preserves path octets; Server replaces this with a normalized
/// routing path while preserving target and all header values.
path: []const u8 = "",
query: []const u8 = "",
authority: []const u8 = "",
/// Explicit scheme in parsed metadata. Server fills origin-form scheme and
/// empty authority from its listener before calling application hooks.
scheme: ?[]const u8 = null,
version: http.Version = .http_1_1,
headers: []const http.Header = &.{},
trailers: []const http.Header = &.{},
content_length: ?u64 = null,
chunked: bool = false,
/// HTTP/2 initial HEADERS left the request body open. Stable through cleanup;
/// unlike chunked, this describes stream framing without a Transfer-Encoding.
body_follows: bool = false,
keep_alive: bool = true,
expect_continue: bool = false,

pub const ParseError = error{
    InvalidRequestLine,
    InvalidMethod,
    InvalidTarget,
    UnsupportedVersion,
    InvalidHeader,
    TooManyHeaders,
    MissingHost,
    InvalidHost,
    DuplicateHost,
    InvalidContentLength,
    AmbiguousFraming,
    InvalidTransferEncoding,
    UnsupportedTransferCoding,
    ExpectationUnsupported,
};

/// Parses a complete CRLF-delimited request head into caller-owned header slots.
/// All returned strings borrow `bytes`; keep both buffers stable until reset.
pub fn parse(bytes: []const u8, slots: []http.Header) ParseError!Request {
    var lines = std.mem.splitSequence(
        u8,
        bytes,
        "\r\n",
    );
    const first = lines.next() orelse return error.InvalidRequestLine;
    const space = std.mem.indexOfScalar(
        u8,
        first,
        ' ',
    ) orelse return error.InvalidRequestLine;
    const method = first[0..space];
    if (!syntax.isToken(method)) return error.InvalidMethod;
    const last = std.mem.indexOfScalarPos(
        u8,
        first,
        space + 1,
        ' ',
    ) orelse
        return error.InvalidRequestLine;
    const target = first[space + 1 .. last];
    const version = first[last + 1 ..];
    if (version.len != 8 or !std.mem.startsWith(
        u8,
        version,
        "HTTP/",
    ) or
        !std.ascii.isDigit(version[5]) or version[6] != '.' or !std.ascii.isDigit(version[7]))
        return error.InvalidRequestLine;
    if (version[5] != '1') return error.UnsupportedVersion;
    const v: http.Version = if (version[7] == '0') .http_1_0 else .http_1_1;
    var request: Request = .{
        .method = method,
        .target = target,
        .version = v,
        .keep_alive = v == .http_1_1,
    };
    try request.parseTarget();
    var count: usize = 0;
    var host: ?[]const u8 = null;
    var connection_close = false;
    var connection_keep_alive = false;
    var transfer_seen = false;
    var unsupported_coding = false;
    var terminated = false;
    while (lines.next()) |line| {
        if (line.len == 0) {
            terminated = true;
            break;
        }
        if (count == slots.len) return error.TooManyHeaders;
        const header = try parseHeader(line);
        slots[count] = header;
        count += 1;
        if (syntax.eql(header.name, "host")) {
            if (host != null) return error.DuplicateHost;
            if (!syntax.isAuthority(
                header.value,
                false,
                true,
            )) return error.InvalidHost;
            host = header.value;
        } else if (syntax.eql(header.name, "content-length")) {
            if (request.content_length != null) return error.AmbiguousFraming;
            if (header.value.len == 0) return error.InvalidContentLength;
            for (header.value) |c| if (!std.ascii.isDigit(c)) return error.InvalidContentLength;
            request.content_length = std.fmt.parseInt(
                u64,
                header.value,
                10,
            ) catch
                return error.InvalidContentLength;
        } else if (syntax.eql(header.name, "transfer-encoding")) {
            if (v == .http_1_0) return error.InvalidTransferEncoding;
            transfer_seen = true;
            try parseTransfer(
                header.value,
                &request.chunked,
                &unsupported_coding,
            );
        } else if (syntax.eql(header.name, "connection")) {
            var tokens = std.mem.splitScalar(
                u8,
                header.value,
                ',',
            );
            while (tokens.next()) |part| {
                const token = syntax.trim(part);
                if (token.len == 0) continue;
                if (!syntax.isToken(token)) return error.InvalidHeader;
                if (syntax.eql(token, "close")) connection_close = true;
                if (syntax.eql(token, "keep-alive")) connection_keep_alive = true;
            }
        } else if (syntax.eql(header.name, "expect")) {
            var expectations = std.mem.splitScalar(
                u8,
                header.value,
                ',',
            );
            while (expectations.next()) |part| {
                const expectation = syntax.trim(part);
                if (expectation.len == 0) continue;
                if (!syntax.eql(expectation, "100-continue")) return error.ExpectationUnsupported;
                request.expect_continue = v == .http_1_1;
            }
        }
    }
    if (!terminated) return error.InvalidHeader;
    request.headers = slots[0..count];
    if (v == .http_1_1 and host == null) return error.MissingHost;
    if (request.scheme == null and !std.mem.eql(
        u8,
        request.method,
        "CONNECT",
    ))
        request.authority = host orelse "";
    if (transfer_seen and request.content_length != null) return error.AmbiguousFraming;
    if (transfer_seen and !request.chunked) return error.InvalidTransferEncoding;
    if (unsupported_coding) return error.UnsupportedTransferCoding;
    request.keep_alive = !connection_close and (v == .http_1_1 or connection_keep_alive);
    return request;
}

/// Parses one field line without CRLF. Returned name and value borrow line.
pub fn parseHeader(line: []const u8) ParseError!http.Header {
    const colon = std.mem.indexOfScalar(
        u8,
        line,
        ':',
    ) orelse return error.InvalidHeader;
    const name = line[0..colon];
    const value = syntax.trim(line[colon + 1 ..]);
    if (!syntax.isToken(name) or !syntax.isField(value)) return error.InvalidHeader;
    return .{ .name = name, .value = value };
}

/// Returns the first field with this case-insensitive name, or null when absent.
/// Repeated fields remain individually available through `headers`.
pub fn getHeader(request: *const Request, name: []const u8) ?[]const u8 {
    for (request.headers) |field| if (syntax.eql(field.name, name)) return field.value;
    return null;
}

/// True when request framing permits body bytes after the initial headers.
pub fn hasBody(request: *const Request) bool {
    return request.chunked or request.body_follows or (request.content_length orelse 0) > 0;
}

/// Rejects framing, routing, authentication and representation policy fields
/// that cannot safely be supplied after body processing starts.
pub fn forbidsTrailer(request: *const Request, name: []const u8) bool {
    for ([_][]const u8{
        "content-length",
        "transfer-encoding",
        "host",
        "connection",
        "trailer",
        "te",
        "upgrade",
        "expect",
        "authorization",
        "proxy-authorization",
        "cookie",
        "if-match",
        "if-none-match",
        "if-modified-since",
        "if-unmodified-since",
        "if-range",
        "range",
        "max-forwards",
        "cache-control",
        "pragma",
        "content-encoding",
        "content-type",
        "content-range",
        "content-disposition",
        "content-language",
        "content-location",
    }) |forbidden| if (syntax.eql(name, forbidden)) return true;
    for (request.headers) |field| {
        if (!syntax.eql(field.name, "connection")) continue;
        var tokens = std.mem.splitScalar(
            u8,
            field.value,
            ',',
        );
        while (tokens.next()) |token| if (syntax.eql(name, syntax.trim(token))) return true;
    }
    return false;
}

fn parseTarget(request: *Request) ParseError!void {
    const target = request.target;
    if (target.len == 0) return error.InvalidTarget;
    if (std.mem.eql(
        u8,
        request.method,
        "CONNECT",
    )) {
        if (!syntax.isAuthority(
            target,
            true,
            false,
        )) return error.InvalidTarget;
        request.authority = target;
        return;
    }
    if (std.mem.eql(
        u8,
        target,
        "*",
    )) {
        if (!std.mem.eql(
            u8,
            request.method,
            "OPTIONS",
        )) return error.InvalidTarget;
        request.path = target;
        return;
    }
    var path_query = target;
    if (target[0] != '/') {
        const scheme_end = std.mem.indexOf(
            u8,
            target,
            "://",
        ) orelse return error.InvalidTarget;
        const scheme = target[0..scheme_end];
        if (!syntax.eql(scheme, "http") and !syntax.eql(scheme, "https"))
            return error.InvalidTarget;
        const rest = target[scheme_end + 3 ..];
        const end = std.mem.indexOfAny(
            u8,
            rest,
            "/?",
        ) orelse rest.len;
        if (!syntax.isAuthority(
            rest[0..end],
            false,
            false,
        )) return error.InvalidTarget;
        request.authority = rest[0..end];
        request.scheme = scheme;
        path_query = rest[end..];
    }
    if (!syntax.isUriComponent(path_query, true)) return error.InvalidTarget;
    const question = std.mem.indexOfScalar(
        u8,
        path_query,
        '?',
    );
    const path = path_query[0 .. question orelse path_query.len];
    request.path = if (path.len == 0) "/" else path;
    if (question) |at| request.query = path_query[at + 1 ..];
}

fn parseTransfer(
    bytes: []const u8,
    chunked: *bool,
    unsupported: *bool,
) ParseError!void {
    var rest = syntax.trim(bytes);
    while (rest.len > 0) {
        if (rest[0] == ',') {
            rest = syntax.trim(rest[1..]);
            continue;
        }
        if (chunked.*) return error.InvalidTransferEncoding;
        var end: usize = 0;
        while (end < rest.len and syntax.isTokenByte(rest[end])) : (end += 1) {}
        if (end == 0) return error.InvalidTransferEncoding;
        const is_chunked = syntax.eql(rest[0..end], "chunked");
        rest = syntax.trim(rest[end..]);
        while (rest.len > 0 and rest[0] == ';') {
            if (is_chunked) return error.InvalidTransferEncoding;
            rest = syntax.trim(rest[1..]);
            end = 0;
            while (end < rest.len and syntax.isTokenByte(rest[end])) : (end += 1) {}
            if (end == 0) return error.InvalidTransferEncoding;
            rest = syntax.trim(rest[end..]);
            if (rest.len == 0 or rest[0] != '=') return error.InvalidTransferEncoding;
            rest = syntax.trim(rest[1..]);
            if (rest.len > 0 and rest[0] == '"') {
                end = syntax.quotedLength(rest) orelse return error.InvalidTransferEncoding;
            } else {
                end = 0;
                while (end < rest.len and syntax.isTokenByte(rest[end])) : (end += 1) {}
                if (end == 0) return error.InvalidTransferEncoding;
            }
            rest = syntax.trim(rest[end..]);
        }
        if (is_chunked) chunked.* = true else unsupported.* = true;
        if (rest.len == 0) break;
        if (rest[0] != ',') return error.InvalidTransferEncoding;
        rest = syntax.trim(rest[1..]);
    }
}

test "HTTP head requires one valid Host and strict framing" {
    const testing = std.testing;
    var slots: [32]http.Header = undefined;
    const cases = .{
        .{ "GET / HTTP/1.1\r\n\r\n", error.MissingHost },
        .{ "GET / HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n", error.DuplicateHost },
        .{ "GET / HTTP/1.1\r\nHost: user@host\r\n\r\n", error.InvalidHost },
        .{ "GET / HTTP/1.1\r\nHost : host\r\n\r\n", error.InvalidHeader },
        .{ "GET / HTTP/1.1\r\nHost: host\r\nContent-Length: +5\r\n\r\n", error.InvalidContentLength },
        .{
            "POST / HTTP/1.1\r\nHost: host\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
            error.AmbiguousFraming,
        },
        .{
            "POST / HTTP/1.1\r\nHost: host\r\nTransfer-Encoding: chunked, gzip\r\n\r\n",
            error.InvalidTransferEncoding,
        },
        .{
            "POST / HTTP/1.1\r\nHost: host\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
            error.UnsupportedTransferCoding,
        },
    };
    inline for (cases) |case| try testing.expectError(case[1], parse(case[0], &slots));
}

test "absolute target overrides Host and extension methods are preserved" {
    var slots: [8]http.Header = undefined;
    const request = try parse(
        "CUSTOM http://actual.example/path?x=1 HTTP/1.1\r\nHost: ignored.example\r\nConnection: upgrade, CLOSE\r\n\r\n",
        &slots,
    );
    try std.testing.expectEqualStrings("CUSTOM", request.method);
    try std.testing.expectEqualStrings("actual.example", request.authority);
    try std.testing.expectEqualStrings("/path", request.path);
    try std.testing.expectEqualStrings("x=1", request.query);
    try std.testing.expect(!request.keep_alive);
}
