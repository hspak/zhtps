//! Limits JSON nesting before recursive parsing and while serializing responses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const log = std.log.scoped(.endpoint_json);

// Stay below std.json.Stringify's fixed 256-level nesting stack.
pub const max_depth = 128;
pub const DepthError = error{JsonTooDeep};
pub const WriteError = Allocator.Error || DepthError;

/// Checks structural depth without recursion or allocation. Syntax and schema
/// validation remain the parser's responsibility, including mismatched closers.
pub fn checkDepth(bytes: []const u8) DepthError!void {
    var nesting: Nesting = .{};
    try nesting.consume(bytes);
}

/// Returns serialized bytes borrowing destination. On error, its contents are
/// unspecified; no partially serialized response should be sent.
pub fn write(destination: []u8, value: anytype) WriteError![]const u8 {
    var output: Output = .{ .destination = destination };
    std.json.Stringify.value(
        value,
        .{},
        &output.writer,
    ) catch
        return output.failure orelse error.OutOfMemory;
    return destination[0..output.used];
}

const Nesting = struct {
    depth: usize = 0,
    in_string: bool = false,
    escaped: bool = false,
    fn consume(nesting: *Nesting, bytes: []const u8) DepthError!void {
        for (bytes) |byte| {
            if (nesting.in_string) {
                if (nesting.escaped) {
                    nesting.escaped = false;
                } else switch (byte) {
                    '\\' => nesting.escaped = true,
                    '"' => nesting.in_string = false,
                    else => {},
                }
                continue;
            }
            switch (byte) {
                '"' => nesting.in_string = true,
                '{', '[' => {
                    if (nesting.depth == max_depth) return error.JsonTooDeep;
                    nesting.depth += 1;
                },
                '}', ']' => nesting.depth -|= 1,
                else => {},
            }
        }
    }
};

const Output = struct {
    // No buffering: reject an opening delimiter before Stringify pushes its
    // fixed nesting stack. A buffered writer could defer this check too late.
    writer: Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    destination: []u8 = &.{},
    used: usize = 0,
    nesting: Nesting = .{},
    failure: ?WriteError = null,
    fn drain(
        writer: *Writer,
        slices: []const []const u8,
        splat: usize,
    ) Writer.Error!usize {
        const output: *Output = @fieldParentPtr("writer", writer);
        const start = output.used;
        for (slices[0 .. slices.len - 1]) |bytes| try output.append(bytes);
        const pattern = slices[slices.len - 1];
        if (pattern.len > 0) {
            if (splat > (output.destination.len - output.used) / pattern.len) {
                output.failure = error.OutOfMemory;
                return error.WriteFailed;
            }
            for (0..splat) |_| try output.append(pattern);
        }
        return output.used - start;
    }

    fn append(output: *Output, bytes: []const u8) Writer.Error!void {
        if (bytes.len > output.destination.len - output.used) {
            output.failure = error.OutOfMemory;
            return error.WriteFailed;
        }
        output.nesting.consume(bytes) catch |err| {
            output.failure = err;
            return error.WriteFailed;
        };
        @memcpy(output.destination[output.used..][0..bytes.len], bytes);
        output.used += bytes.len;
    }
};

test "JSON depth counts containers and ignores escaped string delimiters" {
    try checkDepth("[" ** max_depth ++ "0" ++ "]" ** max_depth);
    try std.testing.expectError(error.JsonTooDeep, checkDepth(
        "[" ** (max_depth + 1) ++ "0" ++ "]" ** (max_depth + 1),
    ));
    try checkDepth("{\"escaped\":\"\\\"" ++ "[{" ** 300 ++ "\\\\\"}");
    try std.testing.expectError(error.JsonTooDeep, checkDepth(
        "{\"escaped\":\"\\\\\",\"child\":" ++ "[" ** max_depth ++ "0" ++ "]" ** max_depth ++ "}",
    ));
}

test "JSON output bounds recursive values and preserves scalar formatting" {
    const Node = struct { next: ?*@This() = null };
    var nodes: [max_depth + 1]Node = @splat(.{});
    for (nodes[0 .. nodes.len - 1], nodes[1..]) |*node, *next| node.next = next;
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"next\":" ** max_depth ++ "null" ++ "}" ** max_depth,
        try write(&buffer, nodes[1]),
    );
    try std.testing.expectError(error.JsonTooDeep, write(&buffer, nodes[0]));
    nodes[0].next = &nodes[0];
    try std.testing.expectError(error.JsonTooDeep, write(&buffer, nodes[0]));
    const values = .{
        .text = "\\\"[{\n",
        .number = @as(i64, -42),
        .float = 1.25,
        .ok = true,
    };
    var expected: [256]u8 = undefined;
    var writer: Writer = .fixed(&expected);
    try std.json.Stringify.value(
        values,
        .{},
        &writer,
    );
    try std.testing.expectEqualStrings(writer.buffered(), try write(&buffer, values));
    try std.testing.expectError(error.OutOfMemory, write(buffer[0..1], values));
}

test "JSON output bounds custom serializers including raw and repeated writes" {
    const Custom = struct {
        depth: usize,
        pub fn jsonStringify(custom: @This(), stringify: *std.json.Stringify) Writer.Error!void {
            for (0..custom.depth) |_| try stringify.beginArray();
            try stringify.write("\\\"" ++ "[{" ** 300);
            for (0..custom.depth) |_| try stringify.endArray();
        }
    };
    const Raw = struct {
        pub fn jsonStringify(_: @This(), stringify: *std.json.Stringify) Writer.Error!void {
            try stringify.beginWriteRaw();
            try stringify.writer.splatBytesAll("[", max_depth + 1);
            try stringify.writer.writeAll("0");
            try stringify.writer.splatBytesAll("]", max_depth + 1);
            stringify.endWriteRaw();
        }
    };
    var buffer: [4096]u8 = undefined;
    _ = try write(&buffer, Custom{ .depth = max_depth });
    try std.testing.expectError(
        error.JsonTooDeep,
        write(&buffer, Custom{ .depth = max_depth + 1 }),
    );
    try std.testing.expectError(error.JsonTooDeep, write(&buffer, Raw{}));
}
