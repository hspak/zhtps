//! Incremental HTTP/1 request framing with bounded caller-owned storage.

const std = @import("std");
const http = @import("../http.zig");
const syntax = @import("syntax.zig");
const Request = http.Request;
const log = std.log.scoped(.http_parser);
const Parser = @This();

head_storage: []u8,
trailer_storage: []u8,
limits: Limits,
request: Request = .{},
phase: Phase = .head,
head_len: usize = 0,
leading_lines: usize = 0,
first_line: bool = true,
spaces: usize = 0,
target_len: usize = 0,
head_fields: [max_fields]http.Header = undefined,
trailer_fields: [max_fields]http.Header = undefined,
trailer_len: usize = 0,
trailer_start: usize = 0,
trailer_count: usize = 0,
chunk_line: [max_chunk_line]u8 = undefined,
chunk_line_len: usize = 0,
remaining: u64 = 0,
body_bytes: u64 = 0,
chunk_framing_bytes: u64 = 0,

pub const max_fields = 128;
pub const max_chunk_line = 4096;

pub const Limits = struct {
    max_target_bytes: usize = 8192,
    max_body_bytes: u64 = 64 * 1024 * 1024,
    /// Cumulative size lines, extensions, and chunk delimiters, excluding trailers.
    max_chunk_framing_bytes: u64 = 64 * 1024,
    max_header_count: usize = max_fields,
    max_trailer_count: usize = max_fields,
};

pub const Phase = enum {
    head,
    fixed_body,
    chunk_size,
    chunk_body,
    chunk_cr,
    chunk_lf,
    trailers,
    ending,
    complete,
    invalid,
};

pub const EofError = error{UnexpectedEof};

pub const Error = Request.ParseError || EofError || error{
    HeadersTooLarge,
    TargetTooLong,
    BodyTooLarge,
    InvalidChunk,
    ChunkExtensionTooLarge,
    ChunkFramingTooLarge,
    TrailersTooLarge,
    ForbiddenTrailer,
    TooManyTrailers,
};

pub const Event = union(enum) {
    need_input,
    head: *const Request,
    body: []const u8,
    trailer: http.Header,
    end,
};

pub const Step = struct {
    consumed: usize,
    event: Event,
};

/// Borrows stable buffers until the parser is discarded. Neither buffer may
/// overlap incoming bytes. Asserts field limits fit the built-in field tables.
pub fn init(parser: *Parser, head_storage: []u8, trailer_storage: []u8, limits: Limits) void {
    std.debug.assert(limits.max_header_count <= max_fields);
    std.debug.assert(limits.max_trailer_count <= max_fields);
    parser.* = .{
        .head_storage = head_storage,
        .trailer_storage = trailer_storage,
        .limits = limits,
    };
}

/// Invalidates all borrowed request strings. Asserts the previous message ended.
pub fn reset(parser: *Parser) void {
    std.debug.assert(parser.phase == .complete);
    parser.init(parser.head_storage, parser.trailer_storage, parser.limits);
}

/// Consumes at most one event. Head/trailer slices live until reset; body slices
/// borrow `input` only. Call again after a head/body/trailer event even when no
/// input remains: a completed message emits `end` without consuming another byte.
/// After an error the connection must be closed; the parser cannot be resumed.
pub fn feed(parser: *Parser, input: []const u8) Error!Step {
    std.debug.assert(parser.phase != .complete and parser.phase != .invalid);
    errdefer parser.phase = .invalid;
    var consumed: usize = 0;
    while (true) switch (parser.phase) {
        .head => {
            if (consumed == input.len) return .{ .consumed = consumed, .event = .need_input };
            if (parser.head_len == parser.head_storage.len) return error.HeadersTooLarge;
            const c = input[consumed];
            if (parser.head_len > 0 and parser.head_storage[parser.head_len - 1] == '\r' and c != '\n')
                return error.InvalidHeader;
            if (c == '\n' and (parser.head_len == 0 or parser.head_storage[parser.head_len - 1] != '\r'))
                return error.InvalidHeader;
            if (!parser.first_line and c != '\r' and c != '\n') {
                const available = @min(input.len - consumed, parser.head_storage.len - parser.head_len);
                if (available >= 64) {
                    const bytes: @Vector(64, u8) = input[consumed..][0..64].*;
                    const cr = bytes == @as(@Vector(64, u8), @splat('\r'));
                    const lf = bytes == @as(@Vector(64, u8), @splat('\n'));
                    const mask: u64 = @bitCast(cr | lf);
                    const length = if (mask == 0) 64 else @ctz(mask);
                    @memcpy(
                        parser.head_storage[parser.head_len..][0..length],
                        input[consumed..][0..length],
                    );
                    parser.head_len += length;
                    consumed += length;
                    continue;
                }
                if (available >= 16) {
                    const bytes: @Vector(16, u8) = input[consumed..][0..16].*;
                    const cr = bytes == @as(@Vector(16, u8), @splat('\r'));
                    const lf = bytes == @as(@Vector(16, u8), @splat('\n'));
                    // Keep delimiter-free copies fixed-size; leave CR/LF for
                    // the scalar framing checks, including split CRLF pairs.
                    const mask: u16 = @bitCast(cr | lf);
                    if (mask == 0) {
                        @memcpy(parser.head_storage[parser.head_len..][0..16], input[consumed..][0..16]);
                        parser.head_len += 16;
                        consumed += 16;
                        continue;
                    }
                    const length = @ctz(mask);
                    @memcpy(parser.head_storage[parser.head_len..][0..length], input[consumed..][0..length]);
                    parser.head_len += length;
                    consumed += length;
                    continue;
                }
            }
            parser.head_storage[parser.head_len] = c;
            parser.head_len += 1;
            consumed += 1;
            if (parser.first_line) {
                if (c == ' ') parser.spaces += 1 else if (parser.spaces == 1) {
                    parser.target_len += 1;
                    if (parser.target_len > parser.limits.max_target_bytes) return error.TargetTooLong;
                }
            }
            if (c != '\n') continue;
            if (parser.head_len == 2) {
                parser.leading_lines += 1;
                if (parser.leading_lines > 8) return error.InvalidRequestLine;
                parser.head_len = 0;
                continue;
            }
            parser.first_line = false;
            if (parser.head_len < 4 or
                !std.mem.endsWith(u8, parser.head_storage[0..parser.head_len], "\r\n\r\n")) continue;
            parser.request = try Request.parse(
                parser.head_storage[0..parser.head_len],
                parser.head_fields[0..parser.limits.max_header_count],
            );
            if (parser.request.chunked) {
                parser.phase = .chunk_size;
            } else {
                parser.remaining = parser.request.content_length orelse 0;
                if (parser.remaining > parser.limits.max_body_bytes) return error.BodyTooLarge;
                parser.phase = if (parser.remaining == 0) .ending else .fixed_body;
            }
            return .{ .consumed = consumed, .event = .{ .head = &parser.request } };
        },
        .fixed_body, .chunk_body => {
            if (consumed == input.len) return .{ .consumed = consumed, .event = .need_input };
            const count: usize = @intCast(@min(parser.remaining, input.len - consumed));
            const body = input[consumed..][0..count];
            parser.remaining -= count;
            parser.body_bytes += count;
            consumed += count;
            if (parser.remaining == 0) {
                parser.phase = if (parser.phase == .fixed_body) .ending else .chunk_cr;
            }
            return .{ .consumed = consumed, .event = .{ .body = body } };
        },
        .chunk_size => {
            if (consumed == input.len) return .{ .consumed = consumed, .event = .need_input };
            try parser.countChunkFramingByte();
            if (parser.chunk_line_len == parser.chunk_line.len) return error.ChunkExtensionTooLarge;
            const c = input[consumed];
            const len = parser.chunk_line_len;
            if (len > 0 and parser.chunk_line[len - 1] == '\r' and c != '\n') return error.InvalidChunk;
            parser.chunk_line[len] = c;
            parser.chunk_line_len += 1;
            consumed += 1;
            if (c != '\n') continue;
            if (len == 0 or parser.chunk_line[len - 1] != '\r') return error.InvalidChunk;
            parser.remaining = try parseChunkSize(parser.chunk_line[0 .. len - 1]);
            parser.chunk_line_len = 0;
            if (parser.remaining > parser.limits.max_body_bytes - parser.body_bytes)
                return error.BodyTooLarge;
            parser.phase = if (parser.remaining == 0) .trailers else .chunk_body;
        },
        .chunk_cr, .chunk_lf => {
            if (consumed == input.len) return .{ .consumed = consumed, .event = .need_input };
            try parser.countChunkFramingByte();
            const wanted: u8 = if (parser.phase == .chunk_cr) '\r' else '\n';
            if (input[consumed] != wanted) return error.InvalidChunk;
            consumed += 1;
            parser.phase = if (parser.phase == .chunk_cr) .chunk_lf else .chunk_size;
        },
        .trailers => {
            if (consumed == input.len) return .{ .consumed = consumed, .event = .need_input };
            if (parser.trailer_len == parser.trailer_storage.len) return error.TrailersTooLarge;
            const c = input[consumed];
            const len = parser.trailer_len;
            if (len > parser.trailer_start and parser.trailer_storage[len - 1] == '\r' and c != '\n')
                return error.InvalidHeader;
            parser.trailer_storage[len] = c;
            parser.trailer_len += 1;
            consumed += 1;
            if (c != '\n') continue;
            if (len == parser.trailer_start or parser.trailer_storage[len - 1] != '\r')
                return error.InvalidHeader;
            const line = parser.trailer_storage[parser.trailer_start .. len - 1];
            parser.trailer_start = parser.trailer_len;
            if (line.len == 0) {
                parser.phase = .ending;
                continue;
            }
            if (parser.trailer_count == parser.limits.max_trailer_count) return error.TooManyTrailers;
            const field = try Request.parseHeader(line);
            if (forbiddenTrailer(field.name, &parser.request)) return error.ForbiddenTrailer;
            parser.trailer_fields[parser.trailer_count] = field;
            parser.trailer_count += 1;
            parser.request.trailers = parser.trailer_fields[0..parser.trailer_count];
            return .{ .consumed = consumed, .event = .{ .trailer = field } };
        },
        .ending => {
            parser.phase = .complete;
            return .{ .consumed = consumed, .event = .end };
        },
        .complete, .invalid => unreachable,
    };
}

/// Distinguishes a clean idle EOF from a truncated request or body.
pub fn eof(parser: *const Parser) EofError!void {
    if (parser.phase == .complete or (parser.phase == .head and parser.head_len == 0)) return;
    return error.UnexpectedEof;
}

pub fn status(err: Error) u16 {
    return switch (err) {
        error.HeadersTooLarge, error.TooManyHeaders, error.TrailersTooLarge, error.TooManyTrailers => 431,
        error.TargetTooLong => 414,
        error.BodyTooLarge, error.ChunkFramingTooLarge => 413,
        error.UnsupportedVersion => 505,
        error.UnsupportedTransferCoding => 501,
        error.ExpectationUnsupported => 417,
        error.InvalidRequestLine,
        error.InvalidMethod,
        error.InvalidTarget,
        error.InvalidHeader,
        error.MissingHost,
        error.InvalidHost,
        error.DuplicateHost,
        error.InvalidContentLength,
        error.AmbiguousFraming,
        error.InvalidTransferEncoding,
        error.InvalidChunk,
        error.ChunkExtensionTooLarge,
        error.ForbiddenTrailer,
        error.UnexpectedEof,
        => 400,
    };
}

fn countChunkFramingByte(parser: *Parser) error{ChunkFramingTooLarge}!void {
    if (parser.chunk_framing_bytes == parser.limits.max_chunk_framing_bytes)
        return error.ChunkFramingTooLarge;
    parser.chunk_framing_bytes += 1;
}

fn parseChunkSize(bytes: []const u8) Error!u64 {
    var i: usize = 0;
    while (i < bytes.len and syntax.isHex(bytes[i])) : (i += 1) {}
    if (i == 0) return error.InvalidChunk;
    const size = std.fmt.parseInt(u64, bytes[0..i], 16) catch return error.InvalidChunk;
    var rest = bytes[i..];
    while (rest.len > 0) {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0 or rest[0] != ';') return error.InvalidChunk;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
        i = 0;
        while (i < rest.len and syntax.isTokenByte(rest[i])) : (i += 1) {}
        if (i == 0) return error.InvalidChunk;
        rest = rest[i..];
        const after_name = std.mem.trimStart(u8, rest, " \t");
        if (after_name.len > 0 and after_name[0] == '=') {
            rest = std.mem.trimStart(u8, after_name[1..], " \t");
            if (rest.len > 0 and rest[0] == '"') {
                i = syntax.quotedLength(rest) orelse return error.InvalidChunk;
            } else {
                i = 0;
                while (i < rest.len and syntax.isTokenByte(rest[i])) : (i += 1) {}
                if (i == 0) return error.InvalidChunk;
            }
            rest = rest[i..];
        }
    }
    return size;
}

fn forbiddenTrailer(name: []const u8, request: *const Request) bool {
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
        var tokens = std.mem.splitScalar(u8, field.value, ',');
        while (tokens.next()) |token| if (syntax.eql(name, syntax.trim(token))) return true;
    }
    return false;
}

test "fragmented chunked body and trailers preserve pipelined request boundary" {
    const testing = std.testing;
    const wire = "POST /upload HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: Chunked\r\n\r\n" ++
        "3; ext=\"a\\\"b\"\r\nabc\r\n2\r\nde\r\n0\r\nDigest: test\r\n\r\n";
    for (1..wire.len + 1) |fragment| {
        var head: [1024]u8 = undefined;
        var trailers: [256]u8 = undefined;
        var parser: Parser = undefined;
        parser.init(&head, &trailers, .{});
        var output: [5]u8 = undefined;
        var body_len: usize = 0;
        var offset: usize = 0;
        var heads: usize = 0;
        var trailer_count: usize = 0;
        while (parser.phase != .complete) {
            const end = @min(wire.len, offset + fragment);
            const step = try parser.feed(wire[offset..end]);
            offset += step.consumed;
            switch (step.event) {
                .head => heads += 1,
                .body => |part| {
                    @memcpy(output[body_len..][0..part.len], part);
                    body_len += part.len;
                },
                .trailer => |field| {
                    try testing.expectEqualStrings("Digest", field.name);
                    try testing.expectEqualStrings("test", field.value);
                    trailer_count += 1;
                },
                .end => {},
                .need_input => try testing.expect(offset < wire.len),
            }
        }
        try testing.expectEqualStrings("abcde", &output);
        try testing.expectEqual(wire.len, offset);
        try testing.expectEqual(@as(usize, 1), heads);
        try testing.expectEqual(@as(usize, 1), trailer_count);
        parser.reset();
        const next = try parser.feed("GET /next HTTP/1.1\r\nHost: local\r\n\r\n");
        try testing.expectEqualStrings("/next", next.event.head.path);
    }
}

test "framing is independent of request method and unframed POST has zero body" {
    const testing = std.testing;
    var head: [1024]u8 = undefined;
    var trailers: [256]u8 = undefined;
    var parser: Parser = undefined;
    parser.init(&head, &trailers, .{});
    const wire = "GET / HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\nabcNEXT";
    const first = try parser.feed(wire);
    const body = try parser.feed(wire[first.consumed..]);
    try testing.expectEqualStrings("abc", body.event.body);
    const end = try parser.feed(wire[first.consumed + body.consumed ..]);
    try testing.expectEqual(.end, std.meta.activeTag(end.event));
    try testing.expectEqual(@as(usize, 0), end.consumed);
    parser.reset();
    _ = try parser.feed("POST / HTTP/1.1\r\nHost: local\r\n\r\n");
    try testing.expectEqual(.end, std.meta.activeTag((try parser.feed("")).event));
}

test "chunk grammar rejects non-hex digits and malformed extensions" {
    for ([_][]const u8{
        "G",
        "1z",
        "+1",
        " 1",
        "1;",
        "1; x=",
        "1; x=\"unterminated",
        "10000000000000000",
    }) |line| try std.testing.expectError(error.InvalidChunk, parseChunkSize(line));
    try std.testing.expectEqual(@as(u64, 255), try parseChunkSize("ff ; x = \"quoted\"; y"));
}

test "incomplete body reports truncation and body size is bounded" {
    var head: [1024]u8 = undefined;
    var trailers: [256]u8 = undefined;
    var parser: Parser = undefined;
    parser.init(&head, &trailers, .{ .max_body_bytes = 3 });
    _ = try parser.feed("POST / HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\n");
    _ = try parser.feed("ab");
    try std.testing.expectError(error.UnexpectedEof, parser.eof());
    parser.init(&head, &trailers, .{ .max_body_bytes = 3 });
    try std.testing.expectError(error.BodyTooLarge, parser.feed(
        "POST / HTTP/1.1\r\nHost: local\r\nContent-Length: 4\r\n\r\n",
    ));
}

test "header block scans preserve line endings fragmentation and pipeline boundaries" {
    const testing = std.testing;
    const padding = "a" ** 96;
    for (0..97) |length| {
        var storage: [256]u8 = undefined;
        const wire = try std.fmt.bufPrint(
            &storage,
            "GET / HTTP/1.1\r\nHost: local\r\nX-Pad: {s}\r\n\r\nNEXT",
            .{padding[0..length]},
        );
        for (1..wire.len + 1) |fragment| {
            const transcript = try parseTranscript(wire, fragment);
            try testing.expectEqual(@as(?Error, null), transcript.failure);
            try testing.expectEqual(@as(?usize, wire.len - 4), transcript.boundary);
            try testing.expectEqual(@as(u64, 0), transcript.body_len);
        }
        for ([_][]const u8{ "\rX", "\n" }) |ending| {
            const invalid = try std.fmt.bufPrint(
                &storage,
                "GET / HTTP/1.1\r\nHost: local\r\nX-Pad: {s}{s}" ++ "b" ** 32,
                .{ padding[0..length], ending },
            );
            for (1..invalid.len + 1) |fragment| {
                const transcript = try parseTranscript(invalid, fragment);
                try testing.expectEqual(@as(?Error, error.InvalidHeader), transcript.failure);
                try testing.expectEqual(@as(?usize, null), transcript.boundary);
            }
        }
    }
}

test "header block scans respect exact storage limits and unaligned input" {
    const testing = std.testing;
    const wire = "GET / HTTP/1.1\r\nHost: local\r\nX-Pad: " ++ "a" ** 64 ++ "\r\n\r\n";
    var input: [wire.len + 64]u8 = undefined;
    for (0..64) |offset| {
        @memcpy(input[offset..][0..wire.len], wire);
        for (wire.len - 1..wire.len + 2) |capacity| {
            var head: [wire.len + 3]u8 = @splat(0xa5);
            var trailers: [8]u8 = undefined;
            var parser: Parser = undefined;
            parser.init(head[1..][0..capacity], &trailers, .{});
            const result = parser.feed(input[offset..][0..wire.len]);
            if (capacity < wire.len) {
                try testing.expectError(error.HeadersTooLarge, result);
            } else {
                const step = try result;
                try testing.expectEqual(wire.len, step.consumed);
                try testing.expectEqualStrings("a" ** 64, step.event.head.headers[1].value);
                try testing.expectEqualStrings(wire, head[1..][0..wire.len]);
            }
            try testing.expectEqual(@as(u8, 0xa5), head[0]);
            try testing.expectEqual(@as(u8, 0xa5), head[capacity + 1]);
        }
    }
}

test "fuzz framing is invariant under transport fragmentation" {
    const corpus = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: local\r\nX-Long: " ++ "a" ** 95 ++ "\r\n\r\nNEXT",
        "GET / HTTP/1.1\r\nHost: local\r\n\r\nNEXT",
        "POST / HTTP/1.1\r\nHost: local\r\nContent-Length: 3\r\n\r\nabcNEXT",
        "POST / HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n3;x=\"y\"\r\nabc\r\n0\r\nDigest: v\r\n\r\nNEXT",
        "GET / HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n",
    };
    const seeds = comptime seeds: {
        var result: [corpus.len][]const u8 = undefined;
        for (corpus, 0..) |wire, i| result[i] = &std.mem.toBytes(@as(u32, wire.len)) ++ wire;
        break :seeds result;
    };
    try std.testing.fuzz({}, fuzzFraming, .{ .corpus = &seeds });
}

fn fuzzFraming(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const len = smith.sliceWithHash(&bytes, 0x51aa937c);
    const wire = bytes[0..len];
    const whole = try parseTranscript(wire, @max(wire.len, 1));
    try std.testing.expectEqualDeep(whole, try parseTranscript(wire, 1));
    try std.testing.expectEqualDeep(whole, try parseTranscript(wire, 17));
}

const Transcript = struct {
    head_hash: ?u64 = null,
    body_hash: u64 = 0,
    body_len: usize = 0,
    trailer_hash: u64 = 0,
    boundary: ?usize = null,
    failure: ?Error = null,
};

fn parseTranscript(wire: []const u8, fragment: usize) !Transcript {
    var head: [8192]u8 = undefined;
    var trailers: [4096]u8 = undefined;
    var parser: Parser = undefined;
    parser.init(&head, &trailers, .{});
    var transcript: Transcript = .{};
    var body_hash = std.hash.Wyhash.init(0);
    var trailer_hash = std.hash.Wyhash.init(0);
    var offset: usize = 0;
    while (true) {
        const end = @min(wire.len, offset + fragment);
        const step = parser.feed(wire[offset..end]) catch |err| {
            transcript.failure = err;
            break;
        };
        try std.testing.expect(step.consumed <= end - offset);
        offset += step.consumed;
        switch (step.event) {
            .head => {
                try std.testing.expect(transcript.head_hash == null);
                transcript.head_hash = std.hash.Wyhash.hash(0, parser.head_storage[0..parser.head_len]);
            },
            .body => |part| {
                try std.testing.expect(part.len > 0);
                body_hash.update(part);
                transcript.body_len += part.len;
            },
            .trailer => |field| {
                trailer_hash.update(field.name);
                trailer_hash.update(":");
                trailer_hash.update(field.value);
                trailer_hash.update("\r\n");
            },
            .end => {
                transcript.boundary = offset;
                break;
            },
            .need_input => {
                try std.testing.expect(offset == end);
                if (offset != wire.len) continue;
                parser.eof() catch |err| {
                    transcript.failure = err;
                };
                break;
            },
        }
    }
    transcript.body_hash = body_hash.final();
    transcript.trailer_hash = trailer_hash.final();
    return transcript;
}

test "field bytes retain validation at vector boundaries" {
    const testing = std.testing;
    const prefix = "GET / HTTP/1.1\r\nHost: local\r\nX-Test: ";
    const lengths = [_]usize{
        31,
        32,
        33,
        63,
        64,
        65,
        96,
        127,
        128,
        129,
    };
    var wire: [prefix.len + 129 + 4]u8 = undefined;
    var head: [256]u8 = undefined;
    var trailers: [2]u8 = undefined;
    for (lengths) |length| {
        for (0..length) |offset| {
            for (0..256) |byte| {
                @memcpy(wire[0..prefix.len], prefix);
                @memset(wire[prefix.len..][0..length], 'a');
                wire[prefix.len + offset] = @intCast(byte);
                @memcpy(wire[prefix.len + length ..][0..4], "\r\n\r\n");
                var parser: Parser = undefined;
                parser.init(&head, &trailers, .{});
                const input = wire[0 .. prefix.len + length + 4];
                if (byte == '\t' or (byte >= 0x20 and byte != 0x7f)) {
                    const step = try parser.feed(input);
                    try testing.expect(step.event == .head);
                    try testing.expectEqual(input.len, step.consumed);
                    try testing.expect((try parser.feed("")).event == .end);
                } else {
                    try testing.expectError(error.InvalidHeader, parser.feed(input));
                }
            }
        }
    }
}

test "chunk framing budget counts all overhead across fragments and resets per request" {
    const testing = std.testing;
    const prefix = "POST /echo HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n";
    const wire = prefix ++ "1;x=v\r\na\r\n1\r\nb\r\n0\r\nDigest: ok\r\n\r\nNEXT";
    for ([_]usize{ 1, 7, wire.len }) |fragment| {
        for ([_]u64{ 16, 17 }) |limit| {
            var head: [256]u8 = undefined;
            var trailers: [64]u8 = undefined;
            var parser: Parser = undefined;
            parser.init(&head, &trailers, .{ .max_chunk_framing_bytes = limit });
            var offset: usize = 0;
            var body_len: usize = 0;
            while (parser.phase != .complete) {
                const end = @min(wire.len, offset + fragment);
                const step = parser.feed(wire[offset..end]) catch |err| {
                    try testing.expectEqual(@as(u64, 16), limit);
                    try testing.expectEqual(error.ChunkFramingTooLarge, err);
                    try testing.expectEqual(.invalid, parser.phase);
                    break;
                };
                offset += step.consumed;
                if (step.event == .body) body_len += step.event.body.len;
                try testing.expect(offset < wire.len);
            }
            try testing.expectEqual(@as(usize, 2), body_len);
            if (limit == 17) {
                try testing.expectEqual(.complete, parser.phase);
                try testing.expectEqual(wire.len - 4, offset);
                parser.reset();
                _ = try parser.feed(prefix);
                try testing.expectEqual(.end, (try parser.feed("0\r\n\r\n")).event);
            } else {
                try testing.expectEqual(.invalid, parser.phase);
            }
        }
    }
}
