//! Response metadata and framing. The caller retains ownership of body and fields.

const std = @import("std");
const zeit = @import("zeit");
const http = @import("../http.zig");
const syntax = @import("syntax.zig");
const log = std.log.scoped(.http_response);
const Response = @This();

status: u16 = 200,
headers: []const http.Header = &.{},
body: Body = .{ .bytes = "" },
close: bool = false,

pub const Body = union(enum) {
    bytes: []const u8,
    /// A known length uses Content-Length; null uses chunked encoding on HTTP/1.1.
    stream: ?u64,
};

pub const ValidationError = error{
    InvalidStatus,
    InvalidHeader,
    ReservedHeader,
    InvalidBody,
};

pub const Error = std.Io.Writer.Error || ValidationError || error{
    LengthMismatch,
    StreamRequiresEncoder,
};

pub const Framing = struct {
    /// Null omits Content-Length, either because the length is unknown or because
    /// this status prohibits framing fields. HEAD/304 retain representation length.
    content_length: ?u64,
    suppressed: bool,
};

pub const Encoder = struct {
    mode: union(enum) {
        fixed: u64,
        chunked,
        closing,
        suppressed,
        finished,
    },
    close: bool,
    /// Encodes one body fragment. HEAD and bodyless statuses suppress payload.
    pub fn write(
        encoder: *Encoder,
        writer: *std.Io.Writer,
        bytes: []const u8,
    ) Error!void {
        switch (encoder.mode) {
            .fixed => |remaining| {
                if (bytes.len > remaining) return error.LengthMismatch;
                try writer.writeAll(bytes);
                encoder.mode = .{ .fixed = remaining - bytes.len };
            },
            .chunked => {
                if (bytes.len == 0) return;
                try writer.print("{x}\r\n", .{bytes.len});
                try writer.writeAll(bytes);
                try writer.writeAll("\r\n");
            },
            .closing => try writer.writeAll(bytes),
            .suppressed => {},
            .finished => return error.InvalidBody,
        }
    }

    /// Finishes the body, returning LengthMismatch for an incomplete fixed body. The caller
    /// must close the transport after any serialization or write failure.
    pub fn end(encoder: *Encoder, writer: *std.Io.Writer) Error!void {
        switch (encoder.mode) {
            .fixed => |remaining| if (remaining != 0) return error.LengthMismatch,
            .chunked => try writer.writeAll("0\r\n\r\n"),
            .closing, .suppressed => {},
            .finished => return error.InvalidBody,
        }
        encoder.mode = .finished;
    }
};

/// Validates origin response metadata without serializing it. Borrows all fields
/// and body bytes. Status 101 and successful CONNECT require a tunnel implementation
/// and cannot be serialized by this origin-server response API.
/// The application supplies fields required by its status and representation
/// (for example Allow for 405 and WWW-Authenticate for 401), and valid semantic
/// field values. This layer validates field syntax and owns transport framing.
pub fn framing(
    response: Response,
    request: *const http.Request,
) ValidationError!Framing {
    if (response.status < 100 or response.status > 599 or response.status == 101)
        return error.InvalidStatus;
    if (request.version == .http_1_0 and response.status < 200) return error.InvalidStatus;
    const connect = std.mem.eql(
        u8,
        request.method,
        "CONNECT",
    );
    if (connect and response.status >= 200 and response.status < 300) return error.InvalidStatus;
    for (response.headers) |field| {
        if (!syntax.isToken(field.name) or !syntax.isField(field.value)) return error.InvalidHeader;
        for ([_][]const u8{
            "content-length",
            "transfer-encoding",
            "connection",
            "date",
            "trailer",
        }) |reserved| if (syntax.eql(field.name, reserved)) return error.ReservedHeader;
    }
    const length: ?u64 = switch (response.body) {
        .bytes => |bytes| bytes.len,
        .stream => |len| len,
    };
    const informational = response.status < 200;
    const prohibited_framing = informational or response.status == 204;
    const no_body = prohibited_framing or response.status == 304 or response.status == 205;
    if ((informational or response.status == 204 or response.status == 205) and
        (length == null or length.? != 0)) return error.InvalidBody;
    return .{
        .content_length = if (prohibited_framing) null else length,
        .suppressed = no_body or std.mem.eql(
            u8,
            request.method,
            "HEAD",
        ),
    };
}

/// Validates all field metadata before emitting bytes. `date` is an IMF-fixdate
/// produced by `formatDate`. Response fields and body remain borrowed from the caller.
pub fn begin(
    response: Response,
    writer: *std.Io.Writer,
    request: *const http.Request,
    date: *const [29]u8,
) Error!Encoder {
    const plan = try response.framing(request);
    const closing = response.close or !request.keep_alive or
        (plan.content_length == null and request.version == .http_1_0 and !plan.suppressed);
    const chunked = plan.content_length == null and !plan.suppressed and request.version == .http_1_1;
    if (response.status == 200) {
        try writer.writeAll(if (request.version == .http_1_0)
            "HTTP/1.0 200 OK\r\nDate: "
        else
            "HTTP/1.1 200 OK\r\nDate: ");
    } else {
        try writer.print("HTTP/1.{d} {d} {s}\r\nDate: ", .{
            @as(u8, if (request.version == .http_1_0) 0 else 1),
            response.status,
            reason(response.status),
        });
    }
    try writer.writeAll(date);
    try writer.writeAll("\r\n");
    if (response.status >= 200) {
        if (closing) {
            try writer.writeAll("Connection: close\r\n");
        } else if (request.version == .http_1_0) {
            try writer.writeAll("Connection: keep-alive\r\n");
        }
    }
    if (plan.content_length) |len| {
        try writer.print("Content-Length: {d}\r\n", .{len});
    } else if (chunked) try writer.writeAll("Transfer-Encoding: chunked\r\n");
    for (response.headers) |field| {
        try writer.writeAll(field.name);
        try writer.writeAll(": ");
        try writer.writeAll(field.value);
        try writer.writeAll("\r\n");
    }
    try writer.writeAll("\r\n");
    return .{
        .mode = if (plan.suppressed)
            .suppressed
        else if (plan.content_length) |len|
            .{ .fixed = len }
        else if (chunked)
            .chunked
        else
            .closing,
        .close = closing,
    };
}

/// Writes a complete response whose body is already available. Returns whether
/// the transport must be closed. Streaming responses use `begin` instead.
pub fn write(
    response: Response,
    writer: *std.Io.Writer,
    request: *const http.Request,
    date: *const [29]u8,
) Error!bool {
    const bytes = switch (response.body) {
        .bytes => |bytes| bytes,
        .stream => return error.StreamRequiresEncoder,
    };
    var encoder = try response.begin(
        writer,
        request,
        date,
    );
    try encoder.write(writer, bytes);
    try encoder.end(writer);
    return encoder.close;
}

/// Returns a static reason phrase, or an empty string for an unlisted status.
pub fn reason(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        103 => "Early Hints",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        409 => "Conflict",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        421 => "Misdirected Request",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        else => "",
    };
}

/// A bounded explanation for built-in errors. Overload responses remain empty
/// to bound rejection bandwidth; other response statuses have no default body.
pub fn errorBody(status: u16) []const u8 {
    return switch (status) {
        400 => "400 Bad Request: the request syntax or parameters are invalid.\n",
        404 => "404 Not Found: no resource matches this path.\n",
        405 => "405 Method Not Allowed: use a method listed in Allow.\n",
        408 => "408 Request Timeout: the request did not arrive before its deadline.\n",
        412 => "412 Precondition Failed: a request condition does not match the resource.\n",
        413 => "413 Content Too Large: the request exceeds the configured body limit.\n",
        414 => "414 URI Too Long: the request target exceeds the configured limit.\n",
        417 => "417 Expectation Failed: the request expectation is unsupported.\n",
        421 => "421 Misdirected Request: this cleartext listener cannot serve an HTTPS target.\n",
        431 => "431 Request Header Fields Too Large: request fields exceed configured limits.\n",
        500 => "500 Internal Server Error: the server could not produce the response.\n",
        501 => "501 Not Implemented: the method or transfer coding is unsupported.\n",
        505 => "505 HTTP Version Not Supported: use HTTP/1.0 or HTTP/1.1.\n",
        else => "",
    };
}

/// Formats Unix seconds as an HTTP IMF-fixdate in GMT. Asserts the year fits
/// four digits; HTTP cannot represent years after 9999.
pub fn formatDate(seconds: u64, buffer: *[29]u8) void {
    std.debug.assert(seconds < (zeit.Time{ .year = 10000 }).instant().unixTimestamp());
    const time = zeit.instant(.{ .unix_timestamp = @intCast(seconds) }, &zeit.utc).time();
    var writer: std.Io.Writer = .fixed(buffer);
    time.strftime(&writer, "%a, %d %b %Y %H:%M:%S GMT") catch unreachable;
    std.debug.assert(writer.buffered().len == buffer.len);
}

test "HEAD carries representation length without body and 204 has no framing fields" {
    const testing = std.testing;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var date: [29]u8 = undefined;
    formatDate(0, &date);
    const response: Response = .{ .body = .{ .bytes = "hello" } };
    _ = try response.write(
        &writer,
        &.{ .method = "HEAD" },
        &date,
    );
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Length: 5\r\n\r\n",
        writer.buffered(),
    );
    writer = .fixed(&buffer);
    _ = try (Response{ .status = 204 }).write(
        &writer,
        &.{ .method = "GET" },
        &date,
    );
    try testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "Content-Length",
    ) == null);
    try testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "Transfer-Encoding",
    ) == null);
}

test "streaming uses chunks in HTTP 1.1 and closure in HTTP 1.0" {
    const testing = std.testing;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const date = "Thu, 01 Jan 1970 00:00:00 GMT";
    const response: Response = .{ .body = .{ .stream = null } };
    var encoder = try response.begin(
        &writer,
        &.{ .method = "GET" },
        date,
    );
    try encoder.write(&writer, "abc");
    try encoder.write(&writer, "");
    try encoder.end(&writer);
    try testing.expect(std.mem.endsWith(
        u8,
        writer.buffered(),
        "\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
    ));
    try testing.expect(!encoder.close);
    writer = .fixed(&buffer);
    encoder = try response.begin(
        &writer,
        &.{ .method = "GET", .version = .http_1_0 },
        date,
    );
    try encoder.write(&writer, "abc");
    try encoder.end(&writer);
    try testing.expect(encoder.close);
    try testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "Transfer-Encoding",
    ) == null);
    try testing.expect(std.mem.endsWith(
        u8,
        writer.buffered(),
        "\r\n\r\nabc",
    ));
}

test "response rejects header injection before writing and enforces declared lengths" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const date = "Thu, 01 Jan 1970 00:00:00 GMT";
    const response: Response = .{ .headers = &.{.{ .name = "X-Test", .value = "a\r\nInjected: yes" }} };
    try std.testing.expectError(error.InvalidHeader, response.begin(
        &writer,
        &.{},
        date,
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var encoder = try (Response{ .body = .{ .stream = 3 } }).begin(
        &writer,
        &.{},
        date,
    );
    try encoder.write(&writer, "ab");
    try std.testing.expectError(error.LengthMismatch, encoder.end(&writer));
    try std.testing.expectError(error.LengthMismatch, encoder.write(&writer, "cd"));
}

test "RFC informational responses reject HTTP 1.0 before writing" {
    const testing = std.testing;
    var buffer: [1024]u8 = undefined;
    const date = "Thu, 01 Jan 1970 00:00:00 GMT";
    for (100..200) |status| {
        var writer: std.Io.Writer = .fixed(&buffer);
        try testing.expectError(error.InvalidStatus, (Response{ .status = @intCast(status) }).begin(
            &writer,
            &.{
                .method = "GET",
                .version = .http_1_0,
                .keep_alive = false,
            },
            date,
        ));
        try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
    var writer: std.Io.Writer = .fixed(&buffer);
    _ = try (Response{ .status = 103 }).write(
        &writer,
        &.{ .method = "GET" },
        date,
    );
    try testing.expect(std.mem.startsWith(
        u8,
        writer.buffered(),
        "HTTP/1.1 103 Early Hints\r\n",
    ));
    try testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "Content-Length",
    ) == null);
}

test "HTTP Date formatting uses UTC across leap centuries and the year limit" {
    const cases = [_]struct { timestamp: u64, text: []const u8 }{
        .{ .timestamp = 951827696, .text = "Tue, 29 Feb 2000 12:34:56 GMT" },
        .{ .timestamp = 4107542400, .text = "Mon, 01 Mar 2100 00:00:00 GMT" },
        .{ .timestamp = 13574563200, .text = "Tue, 29 Feb 2400 00:00:00 GMT" },
        .{ .timestamp = 253402300799, .text = "Fri, 31 Dec 9999 23:59:59 GMT" },
    };
    var buffer: [29]u8 = undefined;
    for (cases) |case| {
        formatDate(case.timestamp, &buffer);
        try std.testing.expectEqualStrings(case.text, &buffer);
        try std.testing.expectEqual(@as(?i64, @intCast(case.timestamp)), http.date.parse(&buffer, 0));
    }
}
