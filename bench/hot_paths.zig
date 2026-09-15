//! Deterministic component workloads; timings exclude setup and printing.

const std = @import("std");
const zhtps = @import("zhtps");
const log = std.log.scoped(.hot_paths);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iterations = if (args.len > 1) try std.fmt.parseInt(
        u64,
        args[1],
        10,
    ) else 10_000_000;
    if (iterations == 0) return error.InvalidIterations;
    const cases = [_]struct {
        name: []const u8,
        options: zhtps.Admission.Options = .{},
        interval_ns: u64 = 4000,
        draining: bool = false,
    }{
        .{ .name = "admission_unlimited" },
        .{ .name = "admission_allowed", .options = .{ .requests_per_second = 250_000 } },
        .{
            .name = "admission_overload",
            .options = .{ .requests_per_second = 250_000 },
            .interval_ns = 1000,
        },
        .{ .name = "admission_draining", .draining = true },
        .{
            .name = "admission_idle",
            .options = .{ .requests_per_second = 1 },
            .interval_ns = 2_000_000_000,
        },
    };
    for (cases) |case| {
        var admission: zhtps.Admission align(64) = undefined;
        admission.init(case.options, 0);
        const begin = zhtps.platform.monotonicNs();
        const decisions = runAdmission(
            &admission,
            iterations,
            case.interval_ns,
            case.draining,
        );
        const elapsed = zhtps.platform.monotonicNs() - begin;
        std.debug.print(
            "{{\"case\":\"{s}\",\"iterations\":{d},\"elapsed_ns\":{d},\"decisions\":[{d},{d},{d}]}}\n",
            .{
                case.name,
                iterations,
                elapsed,
                decisions[0],
                decisions[1],
                decisions[2],
            },
        );
    }
    for ([_][]const u8{
        "short",
        "medium",
        "mixed",
    }, 0..) |name, index| {
        var metrics: zhtps.Metrics align(64) = .{};
        var samples: [1024]u64 align(64) = undefined;
        var random: std.Random.DefaultPrng = .init(0);
        const durations = [_]u64{
            0,
            10_000,
            25_001,
            50_001,
            100_001,
            250_001,
            500_001,
            1_000_001,
            5_000_001,
            10_000_001,
            100_000_001,
            1_000_000_001,
        };
        for (&samples) |*sample| sample.* = if (index == 2)
            durations[random.random().uintLessThan(usize, durations.len)]
        else if (index == 0) 5000 else 100_000;
        const begin = zhtps.platform.monotonicNs();
        runHistogram(
            &metrics,
            &samples,
            iterations,
        );
        const elapsed = zhtps.platform.monotonicNs() - begin;
        const snapshot = metrics.snapshot();
        std.debug.print(
            "{{\"case\":\"histogram_{s}\",\"iterations\":{d},\"elapsed_ns\":{d},\"sum_ns\":{d}}}\n",
            .{
                name,
                iterations,
                elapsed,
                snapshot.histogram(.request_duration_seconds).sum_ns,
            },
        );
    }
    const parser_iterations = @max(1, iterations / 20);
    for ([_][]const u8{
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n" ++
            "User-Agent: hot-path-benchmark/1.0\r\nAccept: text/html, application/json\r\n" ++
            "Cookie: session=" ++ "a" ** 256 ++ "\r\n\r\n",
    }, 0..) |request, index| {
        var head: [4096]u8 = undefined;
        var trailers: [256]u8 = undefined;
        var parser: zhtps.http.Parser align(64) = undefined;
        parser.init(
            &head,
            &trailers,
            .{},
        );
        const begin = zhtps.platform.monotonicNs();
        try runParser(
            &parser,
            request,
            parser_iterations,
        );
        const elapsed = zhtps.platform.monotonicNs() - begin;
        std.debug.print("{{\"case\":\"parser_{s}\",\"iterations\":{d},\"elapsed_ns\":{d}}}\n", .{
            if (index == 0) "short" else "headers",
            parser_iterations,
            elapsed,
        });
    }
}

// Stable function/cache-line placement keeps code layout changes elsewhere
// from dominating sub-nanosecond differences in these tight loops.
noinline fn runAdmission(
    admission: *zhtps.Admission,
    iterations: u64,
    interval_ns: u64,
    draining: bool,
) align(64) [3]u64 {
    var decisions: [3]u64 = @splat(0);
    var now: u64 = 0;
    for (0..iterations) |_| {
        now +%= interval_ns;
        // Keep runtime options and bucket storage visible as in the server loop.
        std.mem.doNotOptimizeAway(admission);
        const decision = admission.acquire(now, draining);
        decisions[@intFromEnum(decision)] += 1;
        admission.release(decision);
    }
    return decisions;
}

noinline fn runHistogram(
    metrics: *zhtps.Metrics,
    samples: *const [1024]u64,
    iterations: u64,
) align(64) void {
    const recorder = metrics.recorder();
    for (0..iterations) |i| recorder.observe(.request_duration_seconds, samples[i % samples.len]);
}

noinline fn runParser(
    parser: *zhtps.http.Parser,
    request: []const u8,
    iterations: u64,
) align(64) !void {
    for (0..iterations) |_| {
        const head = try parser.feed(request);
        std.debug.assert(head.event == .head and head.consumed == request.len);
        const end = try parser.feed("");
        std.debug.assert(end.event == .end);
        std.mem.doNotOptimizeAway(&parser.request);
        parser.reset();
    }
}
