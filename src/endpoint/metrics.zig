//! Fixed-cardinality application metrics composed at compile time.

const std = @import("std");
const log = std.log.scoped(.endpoint_metrics);

/// Generates fixed storage from metric enums; void disables custom metrics while
/// retaining the same API. Names must be unique across all emitted series.
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
    validateNames(Counter, Gauge, Histogram);

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

            /// Adds another worker's samples, including gauges; totals wrap on overflow.
            pub fn merge(captured: *Snapshot, other: *const Snapshot) void {
                for (&captured.counters, other.counters) |*total, amount| total.* +%= amount;
                for (&captured.gauges, other.gauges) |*total, amount| total.* +%= amount;
                for (&captured.histograms, other.histograms) |*total, distribution| {
                    for (&total.buckets, distribution.buckets) |*bucket, amount|
                        bucket.* +%= amount;
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

        /// Returns owned samples from atomic reads, not a transactionally consistent
        /// view. Concurrent updates may appear in different samples.
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

        /// Emits seconds-based histogram series with a validated, nonreserved prefix.
        pub fn writePrometheus(
            captured: *const Snapshot,
            writer: *std.Io.Writer,
            comptime namespace: []const u8,
        ) std.Io.Writer.Error!void {
            comptime validateNamespace(namespace);
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

        /// Emits an object with raw, noncumulative histogram buckets in nanoseconds.
        pub fn writeJson(
            captured: *const Snapshot,
            json: *std.json.Stringify,
        ) std.Io.Writer.Error!void {
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
    if (!@typeInfo(T).@"enum".is_exhaustive)
        @compileError("metric enums must be exhaustive and numbered from zero without gaps");
    for (std.meta.fields(T), 0..) |field, index| {
        if (field.value != index)
            @compileError("metric enums must be exhaustive and numbered from zero without gaps");
    }
}

/// Requires a metric identifier outside the server's reserved zhtps namespace.
pub fn validateNamespace(comptime namespace: []const u8) void {
    validateName(namespace);
    if (std.mem.eql(u8, namespace, "zhtps") or std.mem.startsWith(u8, namespace, "zhtps_"))
        @compileError("the zhtps metric namespace is reserved");
}

fn validateName(comptime name: []const u8) void {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_'))
        @compileError("metric names must start with a letter or underscore");
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_')
            @compileError("metric names must contain only letters, digits and underscores");
    }
}

fn validateNames(comptime Counter: type, comptime Gauge: type, comptime Histogram: type) void {
    const count = std.meta.fields(Counter).len + std.meta.fields(Gauge).len +
        4 * std.meta.fields(Histogram).len;
    var names: [count][]const u8 = undefined;
    var index: usize = 0;
    @setEvalBranchQuota(10_000 + count * count * 1000);
    for (.{ Counter, Gauge }) |T| {
        for (std.meta.fields(T)) |field| {
            validateName(field.name);
            names[index] = field.name;
            index += 1;
        }
    }
    for (std.meta.fields(Histogram)) |field| {
        validateName(field.name);
        for (.{
            "",
            "_bucket",
            "_count",
            "_sum",
        }) |suffix| {
            names[index] = field.name ++ suffix;
            index += 1;
        }
    }
    for (names, 0..) |name, at| {
        for (names[at + 1 ..]) |other| {
            if (std.mem.eql(u8, name, other))
                @compileError("duplicate emitted metric name: " ++ name);
        }
    }
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
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "example_jobs_active 3\n",
    ) != null);
}
