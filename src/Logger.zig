//! Bounded JSON event queue. The transport drains it asynchronously; emit never does I/O.

const std = @import("std");
const Metrics = @import("Metrics.zig");
const Logger = @This();

slots: []Slot = &.{},
metrics: *Metrics,
verbose: bool = false,
enabled: bool = true,
worker: u32 = 0,
read_index: usize = 0,
count: usize = 0,

pub const Slot = struct {
    bytes: [2048]u8 = undefined,
    len: usize = 0,
    sent: usize = 0,
};

pub const Level = enum {
    debug,
    info,
    warn,
    @"error",
};

pub const Attribute = struct {
    name: []const u8,
    value: Scalar,

    pub const Scalar = union(enum) {
        string: []const u8,
        signed: i64,
        unsigned: u64,
        float: f64,
        boolean: bool,
        null,
    };
};

pub const Event = struct {
    timestamp_ns: u64,
    level: Level = .info,
    event: []const u8,
    worker: u32 = 0,
    connection: ?u64 = null,
    request: ?u64 = null,
    status: ?u16 = null,
    reason: ?[]const u8 = null,
    method: ?[]const u8 = null,
    duration_ns: ?u64 = null,
    bytes: ?u64 = null,
    operation: ?[]const u8 = null,
    phase: ?[]const u8 = null,
    address: ?[]const u8 = null,
    port: ?u16 = null,
    result: ?i32 = null,
    route: ?[]const u8 = null,
    fields: []const Attribute = &.{},
};

/// Borrows queue storage and metrics until the logger is discarded. The owning
/// event-loop thread alone may mutate the queue. A peeked slot stays stable
/// until that record is consumed, including while the kernel references its bytes.
pub fn init(logger: *Logger, slots: []Slot, metrics: *Metrics, verbose: bool) void {
    logger.* = .{
        .slots = slots,
        .metrics = metrics,
        .verbose = verbose,
    };
}

/// Copies an event into the bounded queue without I/O. Drops disabled, oversized, or
/// full-queue events; caller-owned strings may be released on return.
pub fn emit(logger: *Logger, event: Event) void {
    if (!logger.enabled) return;
    if (event.level == .debug and !logger.verbose) return;
    if (logger.count == logger.slots.len) {
        logger.metrics.add(.log_dropped_total, 1);
        return;
    }
    const slot = &logger.slots[(logger.read_index + logger.count) % logger.slots.len];
    var writer: std.Io.Writer = .fixed(&slot.bytes);
    var record = event;
    record.worker = logger.worker;
    writeRecord(record, &writer) catch {
        logger.metrics.add(.log_dropped_total, 1);
        return;
    };
    writer.writeByte('\n') catch {
        logger.metrics.add(.log_dropped_total, 1);
        return;
    };
    slot.len = writer.buffered().len;
    slot.sent = 0;
    logger.count += 1;
    logger.metrics.add(.log_events_total, 1);
    logger.metrics.set(.log_pending, logger.count);
}

fn writeRecord(record: Event, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{{\"timestamp_ns\":{d},\"level\":", .{record.timestamp_ns});
    try writeJsonString(@tagName(record.level), writer);
    try writer.writeAll(",\"event\":");
    try writeJsonString(record.event, writer);
    try writer.print(",\"worker\":{d}", .{record.worker});
    if (record.connection) |value| try writer.print(",\"connection\":{d}", .{value});
    if (record.request) |value| try writer.print(",\"request\":{d}", .{value});
    if (record.status) |value| try writer.print(",\"status\":{d}", .{value});
    if (record.reason) |value| {
        try writer.writeAll(",\"reason\":");
        try writeJsonString(value, writer);
    }
    if (record.method) |value| {
        try writer.writeAll(",\"method\":");
        try writeJsonString(value, writer);
    }
    if (record.duration_ns) |value| try writer.print(",\"duration_ns\":{d}", .{value});
    if (record.bytes) |value| try writer.print(",\"bytes\":{d}", .{value});
    if (record.operation) |value| {
        try writer.writeAll(",\"operation\":");
        try writeJsonString(value, writer);
    }
    if (record.phase) |value| {
        try writer.writeAll(",\"phase\":");
        try writeJsonString(value, writer);
    }
    if (record.address) |value| {
        try writer.writeAll(",\"address\":");
        try writeJsonString(value, writer);
    }
    if (record.port) |value| try writer.print(",\"port\":{d}", .{value});
    if (record.result) |value| try writer.print(",\"result\":{d}", .{value});
    if (record.route) |value| {
        try writer.writeAll(",\"route\":");
        try writeJsonString(value, writer);
    }
    if (record.fields.len > 0) {
        try writer.writeAll(",\"fields\":{");
        for (record.fields, 0..) |field, index| {
            if (index != 0) try writer.writeByte(',');
            try writeJsonString(field.name, writer);
            try writer.writeByte(':');
            try writeAttribute(field.value, writer);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

fn writeJsonString(value: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeAttribute(value: Attribute.Scalar, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (value) {
        .string => |item| try writeJsonString(item, writer),
        .signed => |item| try writer.print("{d}", .{item}),
        .unsigned => |item| try writer.print("{d}", .{item}),
        .float => |item| try writer.print("{d}", .{item}),
        .boolean => |item| try writer.writeAll(if (item) "true" else "false"),
        .null => try writer.writeAll("null"),
    }
}

/// Borrows the next unsent slot until consume removes it; null means the queue is empty.
pub fn peek(logger: *Logger) ?*Slot {
    return logger.peekAt(0);
}

/// Borrows a queued record by offset from the oldest. The transport must finish
/// using its bytes before consuming it; null means the offset is not queued.
pub fn peekAt(logger: *Logger, offset: usize) ?*Slot {
    if (offset >= logger.count) return null;
    return &logger.slots[(logger.read_index + offset) % logger.slots.len];
}

/// Accounts for a completed write across queued records. Returns the number of
/// fully consumed records. Asserts written bytes belong to the queued prefix;
/// no in-flight kernel operation may still reference the consumed bytes.
pub fn consumeBytes(logger: *Logger, written: usize) usize {
    var remaining = written;
    var records: usize = 0;
    while (remaining > 0) {
        const slot = logger.peek().?;
        const count = @min(remaining, slot.len - slot.sent);
        slot.sent += count;
        remaining -= count;
        if (slot.sent == slot.len) {
            logger.consume();
            records += 1;
        }
    }
    return records;
}

/// Asserts a slot exists and its last kernel operation has completed.
pub fn consume(logger: *Logger) void {
    std.debug.assert(logger.count > 0);
    logger.read_index = (logger.read_index + 1) % logger.slots.len;
    logger.count -= 1;
    logger.metrics.set(.log_pending, logger.count);
}

test "logger escapes JSON, filters debug, and drops when queue is full" {
    const testing = std.testing;
    var slots: [1]Slot = undefined;
    var metrics: Metrics = .{};
    var logger: Logger = undefined;
    logger.init(&slots, &metrics, false);
    logger.emit(.{
        .timestamp_ns = 0,
        .level = .debug,
        .event = "hidden",
    });
    try testing.expect(logger.peek() == null);
    logger.emit(.{
        .timestamp_ns = 1,
        .event = "request",
        .reason = "quote\"\nnewline",
    });
    const first = logger.peek().?;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        first.bytes[0..first.len],
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("quote\"\nnewline", parsed.value.object.get("reason").?.string);
    logger.emit(.{ .timestamp_ns = 2, .event = "dropped" });
    try testing.expectEqual(@as(u64, 1), metrics.get(.log_dropped_total));
    try testing.expectEqual(@as(usize, 1), logger.count);
    logger.consume();
    logger.verbose = true;
    logger.emit(.{
        .timestamp_ns = 3,
        .level = .debug,
        .event = "visible",
    });
    try testing.expect(std.mem.indexOf(
        u8,
        logger.peek().?.bytes[0..logger.peek().?.len],
        "visible",
    ) != null);
}

test "batched log writes preserve partial records across queue wrap" {
    const testing = std.testing;
    var slots: [3]Slot = undefined;
    var metrics: Metrics = .{};
    var logger: Logger = undefined;
    logger.init(&slots, &metrics, false);
    logger.emit(.{ .timestamp_ns = 0, .event = "discard" });
    logger.consume();
    logger.emit(.{ .timestamp_ns = 1, .event = "first" });
    logger.emit(.{ .timestamp_ns = 2, .event = "second" });
    logger.emit(.{ .timestamp_ns = 3, .event = "third" });
    const first_len = logger.peekAt(0).?.len;
    const second_len = logger.peekAt(1).?.len;
    const third = logger.peekAt(2).?;
    try testing.expect(logger.peekAt(3) == null);
    try testing.expectEqual(@as(usize, 0), logger.consumeBytes(first_len - 1));
    try testing.expectEqual(@as(usize, 3), logger.count);
    try testing.expectEqual(@as(usize, 2), logger.consumeBytes(1 + second_len + 5));
    try testing.expect(logger.peek().? == third);
    try testing.expectEqual(@as(usize, 5), third.sent);
    logger.emit(.{ .timestamp_ns = 4, .event = "fourth" });
    try testing.expectEqual(@as(usize, 1), logger.consumeBytes(third.len - third.sent));
    try testing.expect(std.mem.indexOf(
        u8,
        logger.peek().?.bytes[0..logger.peek().?.len],
        "fourth",
    ) != null);
    try testing.expectEqual(@as(u64, 1), metrics.snapshot().gauge(.log_pending));
    try testing.expectEqual(@as(usize, 1), logger.consumeBytes(logger.peek().?.len));
    try testing.expect(logger.peek() == null);
}

test "access records preserve escaping, extra fields and overflow accounting" {
    const testing = std.testing;
    var slots: [1]Slot = undefined;
    var metrics: Metrics = .{};
    var logger: Logger = undefined;
    logger.init(&slots, &metrics, false);
    logger.worker = 7;
    var event: Event = .{
        .timestamp_ns = 1,
        .event = "request_complete",
        .worker = 99,
        .connection = 3,
        .request = 4,
        .status = 200,
        .method = "G\"ET\n",
        .duration_ns = 5,
        .bytes = 6,
    };
    logger.emit(event);
    const expected =
        \\{"timestamp_ns":1,"level":"info","event":"request_complete","worker":7,"connection":3,"request":4,"status":200,"method":"G\"ET\n","duration_ns":5,"bytes":6}
    ;
    try testing.expectEqualStrings(expected ++ "\n", logger.peek().?.bytes[0..logger.peek().?.len]);
    logger.consume();
    event.reason = "detail";
    logger.emit(event);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        logger.peek().?.bytes[0..logger.peek().?.len],
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("detail", parsed.value.object.get("reason").?.string);
    try testing.expectEqualStrings("G\"ET\n", parsed.value.object.get("method").?.string);
    try testing.expectEqual(@as(i64, 7), parsed.value.object.get("worker").?.integer);
    logger.consume();
    event.reason = null;
    event.method = "x" ** 2048;
    logger.emit(event);
    try testing.expect(logger.peek() == null);
    try testing.expectEqual(@as(u64, 1), metrics.get(.log_dropped_total));
    try testing.expectEqual(@as(u64, 2), metrics.get(.log_events_total));
}

test "logger appends route and structured fields" {
    const testing = std.testing;
    var slots: [1]Slot = undefined;
    var metrics: Metrics = .{};
    var logger: Logger = undefined;
    logger.init(&slots, &metrics, false);
    logger.emit(.{
        .timestamp_ns = 1,
        .event = "custom",
        .route = "create_widget",
        .fields = &.{
            .{ .name = "account_id", .value = .{ .unsigned = 12 } },
            .{ .name = "cached", .value = .{ .boolean = true } },
        },
    });
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        logger.peek().?.bytes[0..logger.peek().?.len],
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("create_widget", parsed.value.object.get("route").?.string);
    const fields = parsed.value.object.get("fields").?.object;
    try testing.expectEqual(@as(i64, 12), fields.get("account_id").?.integer);
    try testing.expect(fields.get("cached").?.bool);
}
