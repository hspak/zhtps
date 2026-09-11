//! JSON metric snapshots with raw nanosecond histogram observations.

const std = @import("std");
const Metrics = @import("../Metrics.zig");
const log = std.log.scoped(.metrics_json);

pub const content_type = "application/json";

/// Borrows the snapshot and writer for this call. Emits counter/gauge names and
/// noncumulative histogram buckets with nanosecond bounds and sums, ending in a
/// newline. Does not allocate.
pub fn write(snapshot: *const Metrics.Snapshot, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("counters");
    try json.beginObject();
    inline for (std.meta.tags(Metrics.Counter)) |counter| {
        try json.objectField(@tagName(counter));
        try json.write(snapshot.counter(counter));
    }
    try json.endObject();
    try json.objectField("gauges");
    try json.beginObject();
    inline for (std.meta.tags(Metrics.Gauge)) |gauge| {
        try json.objectField(@tagName(gauge));
        try json.write(snapshot.gauge(gauge));
    }
    try json.endObject();
    try json.objectField("histograms");
    try json.beginObject();
    inline for (std.meta.tags(Metrics.Histogram)) |histogram| {
        const distribution = snapshot.histogram(histogram);
        try json.objectField(@tagName(histogram));
        try json.beginObject();
        try json.objectField("bounds_ns");
        try json.write(Metrics.bounds_ns);
        try json.objectField("buckets");
        try json.write(distribution.buckets);
        try json.objectField("sum_ns");
        try json.write(distribution.sum_ns);
        try json.endObject();
    }
    try json.endObject();
    try json.endObject();
    try writer.writeByte('\n');
}

test "json metrics preserve names and raw histogram units" {
    const testing = std.testing;
    var metrics: Metrics = .{};
    metrics.add(.requests_admitted_total, 2);
    metrics.set(.connections_active, 3);
    metrics.observe(.request_duration_seconds, 10_000);
    metrics.observe(.request_duration_seconds, 11_000);
    metrics.observe(.request_duration_seconds, 2_000_000_000);
    const snapshot = metrics.snapshot();
    var buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&snapshot, &writer);
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    const counters = parsed.value.object.get("counters").?.object;
    try testing.expectEqual(@as(i64, 2), counters.get("requests_admitted_total").?.integer);
    const gauges = parsed.value.object.get("gauges").?.object;
    try testing.expectEqual(@as(i64, 3), gauges.get("connections_active").?.integer);
    const histograms = parsed.value.object.get("histograms").?.object;
    const distribution = histograms.get("request_duration_seconds").?.object;
    const bounds = distribution.get("bounds_ns").?.array.items;
    try testing.expectEqual(@as(usize, 11), bounds.len);
    try testing.expectEqual(@as(i64, 10_000), bounds[0].integer);
    try testing.expectEqual(@as(i64, 1_000_000_000), bounds[10].integer);
    const buckets = distribution.get("buckets").?.array.items;
    try testing.expectEqual(@as(usize, 12), buckets.len);
    try testing.expectEqual(@as(i64, 1), buckets[0].integer);
    try testing.expectEqual(@as(i64, 1), buckets[1].integer);
    try testing.expectEqual(@as(i64, 0), buckets[10].integer);
    try testing.expectEqual(@as(i64, 1), buckets[11].integer);
    try testing.expectEqual(@as(i64, 2_000_021_000), distribution.get("sum_ns").?.integer);
}
