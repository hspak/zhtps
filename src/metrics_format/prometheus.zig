//! Prometheus text exposition of metric snapshots, with durations in seconds.

const std = @import("std");
const Metrics = @import("../Metrics.zig");

pub const content_type = "text/plain; version=0.0.4; charset=utf-8";

/// Borrows the snapshot and writer for this call. Emits cumulative histogram
/// buckets and converts nanosecond bounds and sums to seconds without allocating.
pub fn write(snapshot: *const Metrics.Snapshot, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    inline for (std.meta.tags(Metrics.Counter)) |counter| {
        try writer.print("# TYPE zhtps_{s} counter\nzhtps_{s} {d}\n", .{
            @tagName(counter),
            @tagName(counter),
            snapshot.counter(counter),
        });
    }
    inline for (std.meta.tags(Metrics.Gauge)) |gauge| {
        try writer.print("# TYPE zhtps_{s} gauge\nzhtps_{s} {d}\n", .{
            @tagName(gauge),
            @tagName(gauge),
            snapshot.gauge(gauge),
        });
    }
    inline for (std.meta.tags(Metrics.Histogram)) |histogram| {
        const name = @tagName(histogram);
        const distribution = snapshot.histogram(histogram);
        try writer.print("# TYPE zhtps_{s} histogram\n", .{name});
        var count: u64 = 0;
        for (Metrics.bounds_ns, 0..) |bound, bucket| {
            count += distribution.buckets[bucket];
            try writer.print("zhtps_{s}_bucket{{le=\"{d}\"}} {d}\n", .{
                name,
                @as(f64, @floatFromInt(bound)) / 1e9,
                count,
            });
        }
        count += distribution.buckets[Metrics.bounds_ns.len];
        try writer.print("zhtps_{s}_bucket{{le=\"+Inf\"}} {d}\nzhtps_{s}_count {d}\nzhtps_{s}_sum {d}\n", .{
            name,
            count,
            name,
            count,
            name,
            @as(f64, @floatFromInt(distribution.sum_ns)) / 1e9,
        });
    }
}

test "prometheus metrics expose status counts and cumulative latency buckets" {
    const testing = std.testing;
    var metrics: Metrics = .{};
    metrics.add(.requests_admitted_total, 2);
    metrics.set(.connections_active, 3);
    metrics.response(503);
    metrics.observe(.request_duration_seconds, 10_000);
    metrics.observe(.request_duration_seconds, 11_000);
    const snapshot = metrics.snapshot();
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&snapshot, &writer);
    const output = writer.buffered();
    for ([_][]const u8{
        "# TYPE zhtps_requests_admitted_total counter\nzhtps_requests_admitted_total 2\n",
        "zhtps_responses_5xx_total 1\n",
        "# TYPE zhtps_connections_active gauge\nzhtps_connections_active 3\n",
        "# TYPE zhtps_request_duration_seconds histogram\n",
        "zhtps_request_duration_seconds_bucket{le=\"0.00001\"} 1\n",
        "zhtps_request_duration_seconds_bucket{le=\"0.000025\"} 2\n",
        "zhtps_request_duration_seconds_count 2\n",
        "zhtps_request_duration_seconds_sum 0.000021\n",
    }) |expected| {
        try testing.expect(std.mem.indexOf(u8, output, expected) != null);
    }

    metrics.observe(.request_duration_seconds, 2_000_000_000);
    const overflow = metrics.snapshot();
    writer = .fixed(&buffer);
    try write(&overflow, &writer);
    for ([_][]const u8{
        "zhtps_request_duration_seconds_bucket{le=\"1\"} 2\n",
        "zhtps_request_duration_seconds_bucket{le=\"+Inf\"} 3\n",
        "zhtps_request_duration_seconds_count 3\n",
    }) |expected| {
        try testing.expect(std.mem.indexOf(u8, writer.buffered(), expected) != null);
    }
}
