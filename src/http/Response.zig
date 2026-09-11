//! Response metadata and framing. The caller retains ownership of body and fields.

const std = @import("std");
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

pub const Error = std.Io.Writer.Error || error{
    InvalidStatus,
    InvalidHeader,
    ReservedHeader,
    InvalidBody,
    LengthMismatch,
    StreamRequiresEncoder,
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
    pub fn write(encoder: *Encoder, writer: *std.Io.Writer, bytes: []const u8) Error!void {
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

    /// Finishes the body, asserting length by a recoverable error. The caller
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

/// Validates all field metadata before emitting bytes. `date` is an IMF-fixdate
/// produced by `formatDate`. Status 101 and successful CONNECT require a tunnel
/// implementation and cannot be serialized by this origin-server response API.
/// The application supplies fields required by its status and representation
/// (for example Allow for 405 and WWW-Authenticate for 401), and valid semantic
/// field values. This layer validates field syntax and owns transport framing.
pub fn begin(response: Response, writer: *std.Io.Writer, request: *const http.Request, date: *const [29]u8) Error!Encoder {
    if (response.status < 100 or response.status > 599 or response.status == 101)
        return error.InvalidStatus;
    const connect = std.mem.eql(u8, request.method, "CONNECT");
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
    const head = std.mem.eql(u8, request.method, "HEAD");
    const closing = response.close or !request.keep_alive or
        (length == null and request.version == .http_1_0 and !head and !no_body);
    const chunked = length == null and !no_body and !head and !closing;
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
    if (!informational) {
        if (closing) {
            try writer.writeAll("Connection: close\r\n");
        } else if (request.version == .http_1_0) {
            try writer.writeAll("Connection: keep-alive\r\n");
        }
    }
    if (!prohibited_framing) {
        if (length) |len| {
            // For 304, a provided length describes the selected representation.
            try writer.print("Content-Length: {d}\r\n", .{len});
        } else if (chunked) try writer.writeAll("Transfer-Encoding: chunked\r\n");
    }
    for (response.headers) |field| {
        try writer.writeAll(field.name);
        try writer.writeAll(": ");
        try writer.writeAll(field.value);
        try writer.writeAll("\r\n");
    }
    try writer.writeAll("\r\n");
    return .{
        .mode = if (head or no_body) .suppressed else if (length) |len| .{ .fixed = len } else if (chunked) .chunked else .closing,
        .close = closing,
    };
}

/// Writes a complete response whose body is already available. Returns whether
/// the transport must be closed. Streaming responses use `begin` instead.
pub fn write(response: Response, writer: *std.Io.Writer, request: *const http.Request, date: *const [29]u8) Error!bool {
    const bytes = switch (response.body) {
        .bytes => |bytes| bytes,
        .stream => return error.StreamRequiresEncoder,
    };
    var encoder = try response.begin(writer, request, date);
    try encoder.write(writer, bytes);
    try encoder.end(writer);
    return encoder.close;
}

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
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        421 => "Misdirected Request",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        else => "",
    };
}

/// Formats a Unix timestamp in seconds as an HTTP IMF-fixdate in GMT.
pub fn formatDate(seconds: u64, buffer: *[29]u8) void {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    const days = "SunMonTueWedThuFriSat";
    const months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    const weekday: usize = @intCast((day.day + 4) % 7);
    const month: usize = month_day.month.numeric() - 1;
    _ = std.fmt.bufPrint(buffer, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        days[weekday * 3 ..][0..3],
        month_day.day_index + 1,
        months[month * 3 ..][0..3],
        year_day.year,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
    }) catch unreachable;
}

test "HEAD carries representation length without body and 204 has no framing fields" {
    const testing = std.testing;
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var date: [29]u8 = undefined;
    formatDate(0, &date);
    const response: Response = .{ .body = .{ .bytes = "hello" } };
    _ = try response.write(&writer, &.{ .method = "HEAD" }, &date);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Length: 5\r\n\r\n",
        writer.buffered(),
    );
    writer = .fixed(&buffer);
    _ = try (Response{ .status = 204 }).write(&writer, &.{ .method = "GET" }, &date);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Content-Length") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Transfer-Encoding") == null);
}

test "streaming uses chunks in HTTP 1.1 and closure in HTTP 1.0" {
    const testing = std.testing;
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const date = "Thu, 01 Jan 1970 00:00:00 GMT";
    const response: Response = .{ .body = .{ .stream = null } };
    var encoder = try response.begin(&writer, &.{ .method = "GET" }, date);
    try encoder.write(&writer, "abc");
    try encoder.write(&writer, "");
    try encoder.end(&writer);
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "\r\n\r\n3\r\nabc\r\n0\r\n\r\n"));
    try testing.expect(!encoder.close);
    writer = .fixed(&buffer);
    encoder = try response.begin(&writer, &.{ .method = "GET", .version = .http_1_0 }, date);
    try encoder.write(&writer, "abc");
    try encoder.end(&writer);
    try testing.expect(encoder.close);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Transfer-Encoding") == null);
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "\r\n\r\nabc"));
}

test "response rejects header injection before writing and enforces declared lengths" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const date = "Thu, 01 Jan 1970 00:00:00 GMT";
    const response: Response = .{ .headers = &.{.{ .name = "X-Test", .value = "a\r\nInjected: yes" }} };
    try std.testing.expectError(error.InvalidHeader, response.begin(&writer, &.{}, date));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var encoder = try (Response{ .body = .{ .stream = 3 } }).begin(&writer, &.{}, date);
    try encoder.write(&writer, "ab");
    try std.testing.expectError(error.LengthMismatch, encoder.end(&writer));
    try std.testing.expectError(error.LengthMismatch, encoder.write(&writer, "cd"));
}
