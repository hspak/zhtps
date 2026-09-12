//! Fixed-cardinality application metrics composed at compile time.

const std = @import("std");
const log = std.log.scoped(.endpoint_metrics);

pub fn Metrics(comptime Definition: type) type {
    const Counter = if (Definition != void and @hasDecl(Definition, "Counter"))
        Definition.Counter
    else
        enum {};
    const Gauge = if (Definition != void and @hasDecl(Definition, "Gauge"))
        Definition.Gauge
    else
        enum {};
    const Histogram = if (Definition != void and @hasDecl(Definition, "Histogram"))
        Definition.Histogram
    else
        enum {};
    validateEnum(Counter, "Counter");
    validateEnum(Gauge, "Gauge");
    validateEnum(Histogram, "Histogram");

    return struct {
        const Self = @This();
        const Atomic = std.atomic.Value(u64);

        pub const CounterId = Counter;
        pub const GaugeId = Gauge;
        pub const HistogramId = Histogram;
        pub const bounds_ns = [_]u64{
            10_000,
            25_000,
            50_000,
            100_000,
            250_000,
            500_000,
            1_000_000,
            5_000_000,
            10_000_000,
            100_000_000,
            1_000_000_000,
        };

        counters: [std.meta.fields(Counter).len]Atomic = @splat(.init(0)),
        gauges: [std.meta.fields(Gauge).len]Atomic = @splat(.init(0)),
        histograms: [std.meta.fields(Histogram).len]AtomicDistribution = @splat(.{}),

        const AtomicDistribution = struct {
            buckets: [bounds_ns.len + 1]Atomic = @splat(.init(0)),
            sum_ns: Atomic = .init(0),
        };

        pub const Snapshot = struct {
            counters: [std.meta.fields(Counter).len]u64 = @splat(0),
            gauges: [std.meta.fields(Gauge).len]u64 = @splat(0),
            histograms: [std.meta.fields(Histogram).len]Distribution = @splat(.{}),

            pub const Distribution = struct {
                buckets: [bounds_ns.len + 1]u64 = @splat(0),
                sum_ns: u64 = 0,
            };

            pub fn merge(captured: *Snapshot, other: *const Snapshot) void {
                for (&captured.counters, other.counters) |*total, amount| total.* +%= amount;
                for (&captured.gauges, other.gauges) |*total, amount| total.* +%= amount;
                for (&captured.histograms, other.histograms) |*total, distribution| {
                    for (&total.buckets, distribution.buckets) |*bucket, amount| bucket.* +%= amount;
                    total.sum_ns +%= distribution.sum_ns;
                }
            }
        };

        /// Safe from application executor threads and concurrent snapshot readers.
        pub fn add(metrics: *Self, id: Counter, amount: u64) void {
            _ = metrics.counters[@intFromEnum(id)].fetchAdd(amount, .monotonic);
        }

        /// Gauges are summed across workers. Callers partitioned by worker should
        /// record their local value rather than a process-wide duplicate.
        pub fn set(metrics: *Self, id: Gauge, amount: u64) void {
            metrics.gauges[@intFromEnum(id)].store(amount, .monotonic);
        }

        /// Records a nanosecond duration using the server's histogram bounds.
        pub fn observe(metrics: *Self, id: Histogram, nanoseconds: u64) void {
            const distribution = &metrics.histograms[@intFromEnum(id)];
            var bucket: usize = 0;
            while (bucket < bounds_ns.len and nanoseconds > bounds_ns[bucket]) : (bucket += 1) {}
            _ = distribution.buckets[bucket].fetchAdd(1, .monotonic);
            _ = distribution.sum_ns.fetchAdd(nanoseconds, .monotonic);
        }

        pub fn snapshot(metrics: *const Self) Snapshot {
            var result: Snapshot = undefined;
            for (&metrics.counters, &result.counters) |*source, *destination| {
                destination.* = source.load(.monotonic);
            }
            for (&metrics.gauges, &result.gauges) |*source, *destination| {
                destination.* = source.load(.monotonic);
            }
            for (&metrics.histograms, &result.histograms) |*source, *destination| {
                for (&source.buckets, &destination.buckets) |*bucket, *count| {
                    count.* = bucket.load(.monotonic);
                }
                destination.sum_ns = source.sum_ns.load(.monotonic);
            }
            return result;
        }

        pub fn writePrometheus(
            captured: *const Snapshot,
            writer: *std.Io.Writer,
            namespace: []const u8,
        ) std.Io.Writer.Error!void {
            inline for (std.meta.tags(Counter)) |id| {
                const name = @tagName(id);
                try writer.print("# TYPE {s}_{s} counter\n{s}_{s} {d}\n", .{
                    namespace,
                    name,
                    namespace,
                    name,
                    captured.counters[@intFromEnum(id)],
                });
            }
            inline for (std.meta.tags(Gauge)) |id| {
                const name = @tagName(id);
                try writer.print("# TYPE {s}_{s} gauge\n{s}_{s} {d}\n", .{
                    namespace,
                    name,
                    namespace,
                    name,
                    captured.gauges[@intFromEnum(id)],
                });
            }
            inline for (std.meta.tags(Histogram)) |id| {
                const name = @tagName(id);
                const distribution = &captured.histograms[@intFromEnum(id)];
                try writer.print("# TYPE {s}_{s} histogram\n", .{ namespace, name });
                var count: u64 = 0;
                for (bounds_ns, 0..) |bound, bucket| {
                    count += distribution.buckets[bucket];
                    try writer.print("{s}_{s}_bucket{{le=\"{d}\"}} {d}\n", .{
                        namespace,
                        name,
                        @as(f64, @floatFromInt(bound)) / 1e9,
                        count,
                    });
                }
                count += distribution.buckets[bounds_ns.len];
                try writer.print(
                    "{s}_{s}_bucket{{le=\"+Inf\"}} {d}\n{s}_{s}_count {d}\n{s}_{s}_sum {d}\n",
                    .{
                        namespace,
                        name,
                        count,
                        namespace,
                        name,
                        count,
                        namespace,
                        name,
                        @as(f64, @floatFromInt(distribution.sum_ns)) / 1e9,
                    },
                );
            }
        }

        pub fn writeJson(captured: *const Snapshot, json: *std.json.Stringify) std.Io.Writer.Error!void {
            try json.beginObject();
            try json.objectField("counters");
            try json.beginObject();
            inline for (std.meta.tags(Counter)) |id| {
                try json.objectField(@tagName(id));
                try json.write(captured.counters[@intFromEnum(id)]);
            }
            try json.endObject();
            try json.objectField("gauges");
            try json.beginObject();
            inline for (std.meta.tags(Gauge)) |id| {
                try json.objectField(@tagName(id));
                try json.write(captured.gauges[@intFromEnum(id)]);
            }
            try json.endObject();
            try json.objectField("histograms");
            try json.beginObject();
            inline for (std.meta.tags(Histogram)) |id| {
                const distribution = &captured.histograms[@intFromEnum(id)];
                try json.objectField(@tagName(id));
                try json.beginObject();
                try json.objectField("bounds_ns");
                try json.write(bounds_ns);
                try json.objectField("buckets");
                try json.write(distribution.buckets);
                try json.objectField("sum_ns");
                try json.write(distribution.sum_ns);
                try json.endObject();
            }
            try json.endObject();
            try json.endObject();
        }
    };
}

fn validateEnum(comptime T: type, comptime name: []const u8) void {
    if (@typeInfo(T) != .@"enum") @compileError(name ++ " must be an enum");
}

test "custom metrics aggregate and format without dynamic names" {
    const Definition = struct {
        pub const Counter = enum { widgets_created_total };
        pub const Gauge = enum { jobs_active };
        pub const Histogram = enum { auth_duration_seconds };
    };
    const Custom = Metrics(Definition);
    var first: Custom = .{};
    var second: Custom = .{};
    first.add(.widgets_created_total, 2);
    second.add(.widgets_created_total, 3);
    first.set(.jobs_active, 1);
    second.set(.jobs_active, 2);
    first.observe(.auth_duration_seconds, 10_000);
    second.observe(.auth_duration_seconds, 11_000);
    var captured = first.snapshot();
    const other = second.snapshot();
    captured.merge(&other);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try Custom.writePrometheus(&captured, &writer, "example");
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "example_widgets_created_total 5\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "example_jobs_active 3\n") != null);
}
