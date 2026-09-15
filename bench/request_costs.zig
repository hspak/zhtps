//! Request-path CPU costs; timings exclude setup and printing and reuse hot storage.

const std = @import("std");
const zhtps = @import("zhtps");
const log = std.log.scoped(.request_costs);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const n = if (args.len > 1) try std.fmt.parseInt(
        usize,
        args[1],
        10,
    ) else 5_000_000;
    if (n == 0) return error.InvalidIterations;
    const Shared = std.meta.Child(@FieldType(zhtps.DefaultServer, "shared"));
    const Worker = std.meta.Elem(@FieldType(Shared, "workers"));
    const Connection = std.meta.Elem(@FieldType(Worker, "connections"));
    std.debug.print("{{\"parser_bytes\":{d},\"exchange_bytes\":{d},\"connection_bytes\":{d}," ++
        "\"phase_offset\":{d},\"deadline_offset\":{d}}}\n", .{
        @sizeOf(zhtps.http.Parser),
        @sizeOf(zhtps.application.Exchange),
        @sizeOf(Connection),
        @offsetOf(Connection, "phase"),
        @offsetOf(Connection, "deadline"),
    });
    for ([_]Case{
        .monotonic,
        .realtime,
        .application,
        .response,
        .log_record,
    }) |case| {
        var storage: [65536]u8 align(64) = undefined;
        var output: [32768]u8 align(64) = undefined;
        var exchange: zhtps.application.Exchange = undefined;
        exchange.init(&storage);
        var request: zhtps.http.Request = .{
            .method = "GET",
            .path = "/",
            .target = "/",
            .headers = &.{.{ .name = "Host", .value = "127.0.0.1:8080" }},
        };
        _ = exchange.receiveHead(&request);
        var response = exchange.respond(&request);
        var date: [29]u8 = undefined;
        zhtps.http.Response.formatDate(1_789_100_000, &date);
        var slots: [1]zhtps.Logger.Slot = undefined;
        var metrics: zhtps.Metrics = .{};
        var logger: zhtps.Logger = undefined;
        logger.init(
            &slots,
            &metrics,
            false,
        );
        const begin = zhtps.platform.monotonicNs();
        switch (case) {
            .monotonic => for (0..n) |_| {
                std.mem.doNotOptimizeAway(zhtps.platform.monotonicNs());
            },
            .realtime => for (0..n) |_| {
                const timestamp = zhtps.platform.realtimeNs(init.io);
                std.mem.doNotOptimizeAway(timestamp);
            },
            .application => for (0..n) |_| {
                std.mem.doNotOptimizeAway(&request);
                exchange.init(&storage);
                std.mem.doNotOptimizeAway(exchange.receiveHead(&request));
                std.mem.doNotOptimizeAway(exchange.respond(&request));
            },
            .response => for (0..n) |_| {
                std.mem.doNotOptimizeAway(&response);
                std.mem.doNotOptimizeAway(&request);
                var writer: std.Io.Writer = .fixed(&output);
                std.mem.doNotOptimizeAway(try response.begin(
                    &writer,
                    &request,
                    &date,
                ));
                try writer.writeAll("ZHTPS\n");
                std.mem.doNotOptimizeAway(writer.buffered());
            },
            .log_record => for (0..n) |i| {
                logger.emit(.{
                    .timestamp_ns = 1_789_100_000_000_000_000 + i,
                    .event = "request_complete",
                    .connection = 4_294_967_296,
                    .request = i,
                    .status = 200,
                    .method = "GET",
                    .duration_ns = 10_000,
                    .bytes = 6,
                });
                std.mem.doNotOptimizeAway(logger.peek().?);
                logger.consume();
            },
        }
        const elapsed = zhtps.platform.monotonicNs() - begin;
        std.debug.print("{{\"case\":\"{s}\",\"iterations\":{d},\"elapsed_ns\":{d}}}\n", .{
            @tagName(case),
            n,
            elapsed,
        });
    }
}

const Case = enum {
    monotonic,
    realtime,
    application,
    response,
    log_record,
};
