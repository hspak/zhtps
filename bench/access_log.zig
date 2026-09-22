//! Access-log formatting and queue costs, excluding clocks, transport, and sink I/O.

const std = @import("std");
const zhtps = @import("zhtps");

const Case = enum {
    minimal,
    browser,
    escaped,
    structured,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iterations = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 2_000_000;
    if (iterations == 0) return error.InvalidIterations;
    const selected = if (args.len > 2)
        std.meta.stringToEnum(Case, args[2]) orelse return error.InvalidCase
    else
        null;
    const selected_batch = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else null;
    if (selected_batch) |count| {
        if (count == 0 or count > 256) return error.InvalidBatch;
    }
    for (std.enums.values(Case)) |case| {
        if (selected != null and selected.? != case) continue;
        if (selected_batch) |count| {
            try measure(case, count, iterations);
        } else {
            for ([_]usize{
                1,
                16,
                64,
            }) |count| try measure(case, count, iterations);
        }
    }
}

fn measure(case: Case, batch_size: usize, iterations: usize) !void {
    var slots: [256]zhtps.Logger.Slot = undefined;
    var metrics: zhtps.Metrics = .{};
    var logger: zhtps.Logger = undefined;
    logger.init(&slots, &metrics, false);
    logger.worker = 3;
    var event: zhtps.Logger.Event = .{
        .timestamp_ns = 1_790_000_000_000_000_000,
        .event = "request_complete",
        .connection = 253403071232,
        .client_ip = "192.0.2.42",
        .status = 200,
        .method = "GET",
        .duration_ns = 25_000,
        .bytes = 6,
    };
    switch (case) {
        .minimal => {},
        .browser => event.user_agent =
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " ++
            "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        .escaped => event.user_agent = "client/1 (\"quoted\" \\path)\tunicode/\xc3\xa9",
        .structured => {
            event.user_agent = "curl/8.14.1";
            event.route = "/assets";
            event.fields = &.{
                .{ .name = "file_path", .value = .{ .string = "guide/index.html" } },
                .{ .name = "cached", .value = .{ .boolean = true } },
                .{ .name = "size", .value = .{ .unsigned = 12345 } },
            };
        },
    }
    // Compile and fault in the same queue storage before starting the timer.
    for (0..slots.len) |_| logger.emit(event);
    while (logger.peek() != null) logger.consume();
    metrics = .{};
    var produced: usize = 0;
    var bytes: u64 = 0;
    var checksum: u64 = 0;
    const started = zhtps.platform.monotonicNs();
    while (produced < iterations) {
        const count = @min(batch_size, iterations - produced);
        for (0..count) |_| {
            event.timestamp_ns += 1;
            event.duration_ns = 10_000 + produced % 100_000;
            std.mem.doNotOptimizeAway(&event);
            logger.emit(event);
            produced += 1;
        }
        if (logger.count != count) return error.DroppedRecord;
        var written: usize = 0;
        for (0..count) |index| {
            const slot = logger.peekAt(index).?;
            std.mem.doNotOptimizeAway(slot.bytes[0..slot.len]);
            written += slot.len;
            checksum +%= slot.bytes[slot.len - 2];
        }
        if (logger.consumeBytes(written) != count) return error.IncompleteDrain;
        bytes += written;
    }
    const elapsed = zhtps.platform.monotonicNs() - started;
    if (metrics.get(.log_events_total) != iterations or metrics.get(.log_dropped_total) != 0 or
        metrics.snapshot().gauge(.log_pending) != 0) return error.IncorrectAccounting;
    std.debug.print(
        "{{\"case\":\"{s}\",\"batch\":{d},\"iterations\":{d},\"elapsed_ns\":{d}," ++
            "\"bytes\":{d},\"checksum\":{d},\"dropped\":{d}}}\n",
        .{
            @tagName(case),
            batch_size,
            iterations,
            elapsed,
            bytes,
            checksum,
            metrics.get(.log_dropped_total),
        },
    );
}
