//! Worker-local permits and token buckets for both useful work and rejection.

const std = @import("std");
const Admission = @This();

options: Options = .{},
active: usize = 0,
rejecting: usize = 0,
tokens: u64 = 0,
rejection_tokens: u64 = 0,
last_refill_ns: u64 = 0,

pub const Options = struct {
    max_active: usize = 256,
    max_rejecting: usize = 32,
    requests_per_second: u32 = 0,
    burst: u32 = 256,
    rejections_per_second: u32 = 1000,
};

pub const Decision = enum {
    admit,
    reject,
    close,
};
const token_scale: u64 = 1_000_000_000;

/// Starts with full admission and rejection buckets at the supplied monotonic time.
pub fn init(admission: *Admission, options: Options, now_ns: u64) void {
    admission.* = .{
        .options = options,
        .tokens = @as(u64, options.burst) * token_scale,
        .rejection_tokens = @as(u64, options.rejections_per_second) * token_scale,
        .last_refill_ns = now_ns,
    };
}

/// Never waits. Every admit/reject decision owns one corresponding permit,
/// released when the response completes or its connection is abandoned.
pub fn acquire(admission: *Admission, now_ns: u64, draining: bool) Decision {
    admission.refill(now_ns);
    if (!draining and admission.active < admission.options.max_active and
        (admission.options.requests_per_second == 0 or admission.tokens >= token_scale))
    {
        admission.active += 1;
        if (admission.options.requests_per_second != 0) admission.tokens -= token_scale;
        return .admit;
    }
    return admission.acquireRejection();
}

/// Checks current balances without reserving a permit or adding credit. Refill
/// and check again before closing traffic; time may have restored either bucket.
pub fn exhausted(admission: *const Admission, draining: bool) bool {
    const can_admit = !draining and admission.active < admission.options.max_active and
        (admission.options.requests_per_second == 0 or admission.tokens >= token_scale);
    const can_reject = admission.rejecting < admission.options.max_rejecting and
        admission.rejection_tokens >= token_scale;
    return !can_admit and !can_reject;
}

/// Reserves a rejection permit and token, or returns close without acquiring either.
pub fn acquireRejection(admission: *Admission) Decision {
    if (admission.rejecting == admission.options.max_rejecting or
        admission.rejection_tokens < token_scale) return .close;
    admission.rejecting += 1;
    admission.rejection_tokens -= token_scale;
    return .reject;
}

/// Returns an acquired permit. Asserts that its corresponding count is nonzero.
pub fn release(admission: *Admission, decision: Decision) void {
    switch (decision) {
        .admit => {
            std.debug.assert(admission.active > 0);
            admission.active -= 1;
        },
        .reject => {
            std.debug.assert(admission.rejecting > 0);
            admission.rejecting -= 1;
        },
        .close => {},
    }
}

/// Adds elapsed-time credit up to each bucket capacity; backwards time adds no credit.
pub fn refill(admission: *Admission, now_ns: u64) void {
    const elapsed = now_ns -| admission.last_refill_ns;
    admission.last_refill_ns = now_ns;
    admission.tokens = refillBucket(
        admission.tokens,
        admission.options.burst,
        admission.options.requests_per_second,
        elapsed,
    );
    admission.rejection_tokens = refillBucket(
        admission.rejection_tokens,
        admission.options.rejections_per_second,
        admission.options.rejections_per_second,
        elapsed,
    );
}

fn refillBucket(tokens: u64, burst: u32, rate: u32, elapsed: u64) u64 {
    const capacity = @as(u64, burst) * token_scale;
    if (tokens >= capacity) return capacity;
    // A balance is at most maxInt(u32) * token_scale. Adding at most one
    // second of credit cannot overflow u64, and both multiply inputs fit u32.
    if (elapsed <= token_scale) {
        return @min(capacity, tokens + @as(u32, @intCast(elapsed)) * @as(u64, rate));
    }
    return @min(capacity, tokens +| (elapsed *| rate));
}

test "admission reserves rejection capacity and recovers after overload" {
    var admission: Admission = undefined;
    admission.init(.{
        .max_active = 1,
        .max_rejecting = 1,
        .rejections_per_second = 1,
    }, 0);
    try std.testing.expectEqual(.admit, admission.acquire(0, false));
    try std.testing.expectEqual(.reject, admission.acquire(0, false));
    try std.testing.expectEqual(.close, admission.acquire(0, false));
    admission.release(.reject);
    try std.testing.expectEqual(.close, admission.acquire(0, false));
    try std.testing.expectEqual(.reject, admission.acquire(token_scale, false));
    admission.release(.admit);
    try std.testing.expectEqual(.admit, admission.acquire(token_scale, false));
}

test "token bucket limits bursts independently of active connections" {
    var admission: Admission = undefined;
    admission.init(.{ .requests_per_second = 2, .burst = 1 }, 0);
    try std.testing.expectEqual(.admit, admission.acquire(0, false));
    admission.release(.admit);
    try std.testing.expectEqual(.reject, admission.acquire(0, false));
    admission.release(.reject);
    try std.testing.expectEqual(.admit, admission.acquire(token_scale / 2, false));
}

test "refill matches exact credit across rates capacities and clock boundaries" {
    const testing = std.testing;
    const amounts = [_]u32{
        0,
        1,
        250_000,
        std.math.maxInt(u32),
    };
    const intervals = [_]u64{
        0,
        1,
        token_scale - 1,
        token_scale,
        token_scale + 1,
        std.math.maxInt(u32),
        std.math.maxInt(u64),
    };
    for (amounts) |burst| for (amounts) |rate| for (intervals) |elapsed| {
        var admission: Admission = undefined;
        admission.init(.{
            .burst = burst,
            .requests_per_second = rate,
            .rejections_per_second = rate,
        }, 0);
        const capacity = @as(u64, burst) * token_scale;
        const rejection_capacity = @as(u64, rate) * token_scale;
        // Include full, empty, fractional, and nearly full buckets.
        for ([_]u64{
            0,
            capacity / 2,
            capacity -| 1,
            capacity,
            std.math.maxInt(u64),
        }) |balance| {
            admission.tokens = balance;
            admission.rejection_tokens = rejection_capacity / 2;
            admission.last_refill_ns = 0;
            const credit = @as(u128, elapsed) * rate;
            admission.refill(elapsed);
            const expected_tokens: u64 = @intCast(@min(capacity, balance + credit));
            const expected_rejections: u64 = @intCast(@min(
                rejection_capacity,
                rejection_capacity / 2 + credit,
            ));
            try testing.expectEqual(expected_tokens, admission.tokens);
            try testing.expectEqual(expected_rejections, admission.rejection_tokens);
            const tokens = admission.tokens;
            const rejection_tokens = admission.rejection_tokens;
            admission.refill(elapsed);
            admission.refill(0);
            try testing.expectEqual(tokens, admission.tokens);
            try testing.expectEqual(rejection_tokens, admission.rejection_tokens);
            try testing.expectEqual(@as(u64, 0), admission.last_refill_ns);
        }
    };
}

test "fractional credit and long idle preserve request and rejection decisions" {
    const testing = std.testing;
    var admission: Admission = undefined;
    admission.init(.{
        .requests_per_second = 3,
        .burst = 2,
        .rejections_per_second = 1,
    }, 0);
    for (0..2) |_| {
        try testing.expectEqual(.admit, admission.acquire(0, false));
        admission.release(.admit);
    }
    try testing.expectEqual(.reject, admission.acquire(0, false));
    admission.release(.reject);
    try testing.expectEqual(.close, admission.acquire(333_333_333, false));
    try testing.expectEqual(.admit, admission.acquire(333_333_334, false));
    admission.release(.admit);
    try testing.expectEqual(.close, admission.acquire(999_999_999, true));
    try testing.expectEqual(.reject, admission.acquire(token_scale, true));
    admission.release(.reject);
    admission.refill(std.math.maxInt(u64));
    for (0..2) |_| {
        try testing.expectEqual(.admit, admission.acquire(std.math.maxInt(u64), false));
        admission.release(.admit);
    }
    try testing.expectEqual(.reject, admission.acquire(std.math.maxInt(u64), false));
    admission.release(.reject);
    try testing.expectEqual(.close, admission.acquire(std.math.maxInt(u64), false));
    try testing.expectEqual(@as(usize, 0), admission.active);
    try testing.expectEqual(@as(usize, 0), admission.rejecting);
}
