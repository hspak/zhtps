//! Fixed-cardinality atomic metrics with allocation-free, format-neutral snapshots.

const std = @import("std");
const Atomic = std.atomic.Value(u64);
const Metrics = @This();

counters: [std.meta.fields(Counter).len]Atomic = @splat(.init(0)),
gauges: [std.meta.fields(Gauge).len]Atomic = @splat(.init(0)),
latency: [std.meta.fields(Histogram).len]AtomicDistribution = @splat(.{}),

pub const Counter = enum {
    connections_accepted_total,
    connections_closed_total,
    connections_refused_total,
    connections_idle_closed_total,
    connections_reclaimed_total,
    connection_reclaim_timeouts_total,
    tls_handshakes_total,
    tls_sessions_reused_total,
    tls_errors_total,
    tls_handshake_timeouts_total,
    requests_total,
    requests_admitted_total,
    requests_rejected_total,
    requests_closed_before_head_total,
    requests_completed_total,
    requests_aborted_total,
    protocol_errors_total,
    request_timeouts_total,
    header_timeouts_total,
    body_timeouts_total,
    application_timeouts_total,
    application_queue_rejections_total,
    write_timeouts_total,
    peer_disconnects_total,
    bytes_received_total,
    bytes_sent_total,
    io_submissions_total,
    io_completions_total,
    io_errors_total,
    response_batches_total,
    responses_batched_total,
    response_batch_fallbacks_total,
    buffer_allocations_total,
    buffer_exhaustions_total,
    connection_buffer_allocations_total,
    connection_buffer_exhaustions_total,
    request_storage_allocations_total,
    request_storage_exhaustions_total,
    log_events_total,
    log_dropped_total,
    log_write_errors_total,
    metrics_pushes_total,
    metrics_push_errors_total,
    rejection_aborted_total,
    responses_1xx_total,
    responses_2xx_total,
    responses_3xx_total,
    responses_4xx_total,
    responses_5xx_total,
};

pub const Gauge = enum {
    connections_active,
    requests_active,
    rejections_active,
    io_pending,
    log_pending,
    buffer_bytes_active,
    buffer_bytes_cached,
    connection_buffer_bytes_active,
    connection_buffer_bytes_cached,
    request_storage_active,
    request_storage_cached,
    http2_streams_active,
    http2_streams_cached,
    http2_bytes_allocated,
    draining,
};

pub const Histogram = enum {
    request_duration_seconds,
    admitted_duration_seconds,
    rejected_duration_seconds,
    aborted_duration_seconds,
    admin_duration_seconds,
    time_to_first_byte_seconds,
    header_duration_seconds,
    event_loop_duration_seconds,
};

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

const AtomicDistribution = struct {
    buckets: [bounds_ns.len + 1]Atomic = @splat(.init(0)),
    sum_ns: Atomic = .init(0),
};

/// Owns a copy of the observations, independent of subsequent metric updates.
pub const Snapshot = struct {
    counters: [std.meta.fields(Counter).len]u64 = @splat(0),
    gauges: [std.meta.fields(Gauge).len]u64 = @splat(0),
    histograms: [std.meta.fields(Histogram).len]Distribution = @splat(.{}),

    pub const Distribution = struct {
        /// Noncumulative counts with inclusive upper bounds from bounds_ns.
        /// The last bucket counts observations above the largest bound.
        buckets: [bounds_ns.len + 1]u64 = @splat(0),
        sum_ns: u64 = 0,
    };

    /// Returns the captured count, independent of subsequent recorder updates.
    pub fn counter(captured: *const Snapshot, id: Counter) u64 {
        return captured.counters[@intFromEnum(id)];
    }

    /// Returns the captured occupancy, independent of subsequent recorder updates.
    pub fn gauge(captured: *const Snapshot, id: Gauge) u64 {
        return captured.gauges[@intFromEnum(id)];
    }

    /// Borrows the distribution from this snapshot.
    pub fn histogram(captured: *const Snapshot, id: Histogram) *const Distribution {
        return &captured.histograms[@intFromEnum(id)];
    }

    /// Adds observations and occupancy from another worker. Draining means any
    /// worker is draining. Sources need not have been captured at the same time.
    pub fn merge(captured: *Snapshot, other: *const Snapshot) void {
        for (&captured.counters, other.counters) |*total, amount| total.* +%= amount;
        inline for (std.meta.tags(Gauge)) |id| {
            const index = @intFromEnum(id);
            if (id == .draining) {
                captured.gauges[index] = @max(captured.gauges[index], other.gauges[index]);
            } else captured.gauges[index] += other.gauges[index];
        }
        for (&captured.histograms, other.histograms) |*total, distribution| {
            for (&total.buckets, distribution.buckets) |*bucket, amount| bucket.* +%= amount;
            total.sum_ns +%= distribution.sum_ns;
        }
    }
};

pub const Recorder = struct {
    metrics: *Metrics,

    /// All updates must run on the recorder's owning thread; snapshot readers may run concurrently.
    pub fn add(owned: Recorder, counter: Counter, amount: u64) void {
        increment(&owned.metrics.counters[@intFromEnum(counter)], amount, false);
    }

    /// All updates must run on the recorder's owning thread; snapshot readers may run concurrently.
    pub fn observe(owned: Recorder, histogram: Histogram, nanoseconds: u64) void {
        record(owned.metrics, histogram, nanoseconds, false);
    }

    /// All updates must run on the recorder's owning thread; snapshot readers may run concurrently.
    pub fn response(owned: Recorder, status: u16) void {
        owned.add(statusCounter(status), 1);
    }
};

/// Updates from the owning thread without atomic read-modify-write operations.
/// All updates to these metrics must be serialized on that same thread while
/// this recorder is in use. Concurrent snapshot readers remain supported.
pub fn recorder(metrics: *Metrics) Recorder {
    return .{ .metrics = metrics };
}

fn increment(destination: *Atomic, amount: u64, comptime concurrent: bool) void {
    if (comptime concurrent) {
        _ = destination.fetchAdd(amount, .monotonic);
    } else destination.store(destination.load(.monotonic) +% amount, .monotonic);
}

/// Atomically adds a count, wrapping on overflow. Supports concurrent writers.
pub fn add(metrics: *Metrics, counter: Counter, amount: u64) void {
    increment(&metrics.counters[@intFromEnum(counter)], amount, true);
}

/// Reads the current count atomically without synchronizing unrelated memory.
pub fn get(metrics: *const Metrics, counter: Counter) u64 {
    return metrics.counters[@intFromEnum(counter)].load(.monotonic);
}

/// Publishes a gauge atomically. Concurrent writers replace, rather than combine, values.
pub fn set(metrics: *Metrics, gauge: Gauge, amount: u64) void {
    metrics.gauges[@intFromEnum(gauge)].store(amount, .monotonic);
}

/// Atomically records a duration and its bucket; snapshots may see the two updates separately.
pub fn observe(metrics: *Metrics, histogram: Histogram, nanoseconds: u64) void {
    record(metrics, histogram, nanoseconds, true);
}

fn record(
    metrics: *Metrics,
    histogram: Histogram,
    nanoseconds: u64,
    comptime concurrent: bool,
) void {
    const distribution = &metrics.latency[@intFromEnum(histogram)];
    var bucket: usize = 0;
    while (bucket < bounds_ns.len and nanoseconds > bounds_ns[bucket]) : (bucket += 1) {}
    increment(&distribution.buckets[bucket], 1, concurrent);
    increment(&distribution.sum_ns, nanoseconds, concurrent);
}

/// Records one response in its status class. Assumes status is between 100 and 599.
pub fn response(metrics: *Metrics, status: u16) void {
    metrics.add(statusCounter(status), 1);
}

fn statusCounter(status: u16) Counter {
    return switch (status / 100) {
        1 => .responses_1xx_total,
        2 => .responses_2xx_total,
        3 => .responses_3xx_total,
        4 => .responses_4xx_total,
        5 => .responses_5xx_total,
        else => unreachable, // Response status must belong to an HTTP status class.
    };
}

/// Reads each atomic field once without allocating or locking. Concurrent updates
/// may be observed independently, including a histogram's buckets and sum; this
/// is not a transactional snapshot across workers.
pub fn snapshot(metrics: *const Metrics) Snapshot {
    var result: Snapshot = undefined;
    for (&metrics.counters, &result.counters) |*source, *destination| {
        destination.* = source.load(.monotonic);
    }
    for (&metrics.gauges, &result.gauges) |*source, *destination| {
        destination.* = source.load(.monotonic);
    }
    for (&metrics.latency, &result.histograms) |*source, *destination| {
        for (&source.buckets, &destination.buckets) |*bucket, *count| {
            count.* = bucket.load(.monotonic);
        }
        destination.sum_ns = source.sum_ns.load(.monotonic);
    }
    return result;
}

test "metrics snapshot owns counters gauges and noncumulative distributions" {
    const testing = std.testing;
    var metrics: Metrics = .{};
    metrics.add(.requests_admitted_total, 2);
    metrics.add(.requests_admitted_total, 3);
    metrics.set(.connections_active, 9);
    metrics.set(.connections_active, 4);
    metrics.response(503);
    metrics.observe(.request_duration_seconds, 10_000);
    metrics.observe(.request_duration_seconds, 11_000);
    metrics.observe(.request_duration_seconds, 1_000_000_000);
    metrics.observe(.request_duration_seconds, 1_000_000_001);
    metrics.observe(.event_loop_duration_seconds, 0);
    const captured = metrics.snapshot();

    metrics.add(.requests_admitted_total, 1);
    metrics.set(.connections_active, 0);
    metrics.observe(.request_duration_seconds, 10_000);

    try testing.expectEqual(@as(u64, 5), captured.counter(.requests_admitted_total));
    try testing.expectEqual(@as(u64, 1), captured.counter(.responses_5xx_total));
    try testing.expectEqual(@as(u64, 0), captured.counter(.requests_rejected_total));
    try testing.expectEqual(@as(u64, 4), captured.gauge(.connections_active));
    try testing.expectEqual(@as(u64, 0), captured.gauge(.draining));
    const distribution = captured.histogram(.request_duration_seconds);
    try testing.expectEqualSlices(
        u64,
        &.{
            1,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            1,
            1,
        },
        &distribution.buckets,
    );
    try testing.expectEqual(@as(u64, 2_000_021_001), distribution.sum_ns);
    try testing.expectEqual(
        @as(u64, 1),
        captured.histogram(.event_loop_duration_seconds).buckets[0],
    );
    try testing.expectEqual(@as(u64, 0), captured.histogram(.admitted_duration_seconds).sum_ns);

    const latest = metrics.snapshot();
    try testing.expectEqual(@as(u64, 6), latest.counter(.requests_admitted_total));
    try testing.expectEqual(@as(u64, 0), latest.gauge(.connections_active));
    try testing.expectEqual(@as(u64, 2), latest.histogram(.request_duration_seconds).buckets[0]);
    try testing.expectEqual(
        @as(u64, 2_000_031_001),
        latest.histogram(.request_duration_seconds).sum_ns,
    );
}

test "merged worker snapshots sum observations and preserve draining as a flag" {
    const testing = std.testing;
    var first: Metrics = .{};
    var second: Metrics = .{};
    first.add(.requests_admitted_total, 5);
    second.add(.requests_admitted_total, 7);
    first.set(.requests_active, 2);
    second.set(.requests_active, 3);
    first.set(.draining, 1);
    second.set(.draining, 1);
    first.observe(.request_duration_seconds, 10_000);
    second.observe(.request_duration_seconds, 11_000);
    second.observe(.request_duration_seconds, 2_000_000_000);
    var merged = first.snapshot();
    const other = second.snapshot();
    merged.merge(&other);
    try testing.expectEqual(@as(u64, 12), merged.counter(.requests_admitted_total));
    try testing.expectEqual(@as(u64, 5), merged.gauge(.requests_active));
    try testing.expectEqual(@as(u64, 1), merged.gauge(.draining));
    const distribution = merged.histogram(.request_duration_seconds);
    try testing.expectEqual(@as(u64, 1), distribution.buckets[0]);
    try testing.expectEqual(@as(u64, 1), distribution.buckets[1]);
    try testing.expectEqual(@as(u64, 1), distribution.buckets[bounds_ns.len]);
    try testing.expectEqual(@as(u64, 2_000_021_000), distribution.sum_ns);
}

test "single writer recorder permits concurrent snapshot readers" {
    const testing = std.testing;
    const producer = struct {
        fn run(metrics: *Metrics, done: *std.atomic.Value(bool)) void {
            const owned = metrics.recorder();
            for (0..10_000) |_| {
                owned.add(.requests_admitted_total, 1);
                owned.response(200);
                owned.observe(.request_duration_seconds, 10_000);
            }
            done.store(true, .release);
        }
    };
    var metrics: Metrics = .{};
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, producer.run, .{ &metrics, &done });
    defer thread.join();
    var previous: u64 = 0;
    while (!done.load(.acquire)) {
        const captured = metrics.snapshot();
        const admitted = captured.counter(.requests_admitted_total);
        try testing.expect(admitted >= previous and admitted <= 10_000);
        previous = admitted;
    }
    const captured = metrics.snapshot();
    try testing.expectEqual(@as(u64, 10_000), captured.counter(.requests_admitted_total));
    try testing.expectEqual(@as(u64, 10_000), captured.counter(.responses_2xx_total));
    try testing.expectEqual(
        @as(u64, 10_000),
        captured.histogram(.request_duration_seconds).buckets[0],
    );
    try testing.expectEqual(
        @as(u64, 100_000_000),
        captured.histogram(.request_duration_seconds).sum_ns,
    );
}
