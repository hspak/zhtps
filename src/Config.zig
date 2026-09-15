//! Runtime resource budgets with admission defaults derived before binding.

const std = @import("std");
const Admission = @import("Admission.zig");
const log = std.log.scoped(.config);
const Config = @This();

address: []const u8 = "127.0.0.1",
port: u16 = 8080,
/// Encrypts the public listener. The separate admin listener remains HTTP.
tls: ?Tls = null,
http2: Http2 = .{},
admin_address: []const u8 = "127.0.0.1",
admin_port: u16 = 9090,
workers: usize = 1,
/// Ordered logical CPU IDs, one per worker, such as "9,10-12". Empty inherits
/// the serving thread's affinity. Borrows storage until server deinit.
worker_cpus: []const u8 = "",
max_connections: usize = 256,
/// Zero disables the admin listener and its reserved connection storage.
admin_connections: usize = 8,
header_bytes: usize = 32 * 1024,
trailer_bytes: usize = 8 * 1024,
receive_bytes: usize = 16 * 1024,
response_bytes: usize = 32 * 1024,
/// Total request body and handler scratch budget. After body ingestion, its
/// unused tail becomes scratch retained through cleanup. JSON endpoints need
/// room beyond their largest body for parsing and response serialization.
/// Streaming endpoints use this region for scratch without retaining body chunks.
application_bytes: usize = 64 * 1024,
/// Per-worker bytes leased from large-buffer pools and response stream handoffs.
/// Cached buffers are bounded separately by BufferPool's count/byte limits.
/// Admin storage is reserved at startup.
large_buffer_bytes: usize = 64 * 1024 * 1024,
max_body_bytes: u64 = 64 * 1024 * 1024,
max_chunk_framing_bytes: u64 = 64 * 1024,
header_timeout_ms: u32 = 5000,
body_timeout_ms: u32 = 30000,
write_timeout_ms: u32 = 5000,
idle_timeout_ms: u32 = 15000,
/// TCP retries on public sockets. Linux bounds thin-stream linear retries;
/// system mode leaves kernel defaults unchanged.
tcp_retries: TcpRetries = .thin_linear,
/// Minimum completed keepalive idle time before reclaiming a public slot for
/// an accepted peer under slot pressure. Zero disables reclamation.
idle_reclaim_ms: u32 = 0,
close_timeout_ms: u32 = 100,
/// Final-request window for established public keepalives when shutdown begins.
/// Zero closes idle keepalives immediately; capped by shutdown_timeout_ms.
shutdown_keepalive_ms: u32 = 100,
shutdown_timeout_ms: u32 = 5000,
max_requests_per_connection: u32 = 1000,
completion_budget: usize = 64,
/// Preallocated aggregate buffers per worker for the built-in application.
/// Zero disables aggregation. Custom applications use ordinary sends.
response_batches: usize = 64,
log_slots: usize = 256,
/// Borrowed descriptor for JSON events; null disables logging. Keep it open
/// until serving returns. Writers outside this server must coordinate access.
log_fd: ?i32 = 2,
verbose: bool = false,
access_log: bool = true,
admission: AdmissionOptions = .{},

pub const TcpRetries = enum {
    system,
    thin_linear,
};

pub const Tls = struct {
    /// PEM leaf followed by intermediates. Paths are borrowed until server deinit.
    certificate: []const u8 = "",
    /// PEM private key matching the leaf; encrypted keys are rejected without prompting.
    private_key: []const u8 = "",
    handshake_timeout_ms: u32 = 5000,
};

pub const Http2 = struct {
    /// Advertised per connection. Closed streams with running hooks still count
    /// against the worker limit until their application storage can be released.
    max_streams: u32 = 100,
    max_streams_per_worker: usize = 256,
    /// Bounds protocol, stream, and transport allocations together per worker.
    memory_bytes: usize = 64 * 1024 * 1024,
};

/// Counts apply per worker. Null selects a default from the public connection
/// budget; admin slots do not contribute. Rates require workload-specific tuning.
pub const AdmissionOptions = struct {
    max_active: ?usize = null,
    max_rejecting: ?usize = null,
    requests_per_second: u32 = 0,
    burst: ?u32 = null,
    rejections_per_second: u32 = 1000,
};

pub const Error = error{
    InvalidOption,
    MissingArgument,
    InvalidLimit,
};

/// Rejects unsupported limits and listener combinations without allocating or binding.
pub fn validate(config: Config) Error!void {
    if (config.http2.max_streams == 0 or config.http2.max_streams > 65535 or
        config.http2.max_streams_per_worker == 0 or config.http2.max_streams_per_worker > 65535 or
        config.http2.memory_bytes < 1024 * 1024) return error.InvalidLimit;
    if (config.tls) |tls| {
        if (tls.certificate.len == 0 or tls.private_key.len == 0 or
            std.mem.indexOfScalar(
                u8,
                tls.certificate,
                0,
            ) != null or
            std.mem.indexOfScalar(
                u8,
                tls.private_key,
                0,
            ) != null or
            tls.handshake_timeout_ms == 0) return error.InvalidOption;
    }
    if (config.workers == 0 or config.workers > 256 or
        config.max_connections == 0 or config.max_connections > 8176 or
        config.admin_connections > 128 or
        config.max_connections + config.admin_connections > 8176 or
        config.header_bytes < 8192 or config.header_bytes > 1024 * 1024 or
        config.trailer_bytes < 2 or config.trailer_bytes > 1024 * 1024 or
        config.receive_bytes == 0 or config.receive_bytes > 1024 * 1024 or
        config.response_bytes < 16384 or config.response_bytes > 1024 * 1024 or
        config.application_bytes < 32 * 1024 or config.application_bytes > 16 * 1024 * 1024 or
        config.log_slots == 0 or config.log_slots > 65536 or
        config.completion_budget == 0 or config.completion_budget > 256 or
        config.response_batches > 8176 or
        config.max_chunk_framing_bytes < 3 or
        config.max_requests_per_connection == 0 or config.header_timeout_ms == 0 or
        config.body_timeout_ms == 0 or config.write_timeout_ms == 0 or
        config.idle_timeout_ms == 0 or config.close_timeout_ms == 0 or
        (config.idle_reclaim_ms != 0 and config.idle_reclaim_ms >= config.idle_timeout_ms) or
        config.shutdown_timeout_ms == 0 or
        (config.admission.requests_per_second != 0 and config.admission.burst == 0))
        return error.InvalidLimit;
    if (config.log_fd) |fd| if (fd < 0) return error.InvalidLimit;
    var cpus: [256]u16 = undefined;
    _ = try config.resolveWorkerCpus(&cpus);
    if (config.admission.max_active) |limit| {
        if (limit == 0 or limit > config.max_connections) return error.InvalidLimit;
    }
    if (config.admission.max_rejecting) |limit| {
        if (limit > config.max_connections) return error.InvalidLimit;
    }
}

/// Writes the ordered worker mapping into caller storage. An empty mapping
/// preserves scheduler placement; otherwise every worker needs a distinct CPU.
/// CPU availability is checked on the serving thread before workers start.
pub fn resolveWorkerCpus(config: Config, cpus: *[256]u16) Error![]const u16 {
    if (config.worker_cpus.len == 0) return cpus[0..0];
    var count: usize = 0;
    var seen = std.StaticBitSet(1024).initEmpty();
    var parts = std.mem.splitScalar(
        u8,
        config.worker_cpus,
        ',',
    );
    while (parts.next()) |part| {
        var range = std.mem.splitScalar(
            u8,
            part,
            '-',
        );
        const first = try parseCpu(range.next().?);
        const last = if (range.next()) |end| try parseCpu(end) else first;
        if (range.next() != null or last < first) return error.InvalidOption;
        for (first..last + 1) |cpu| {
            if (count == cpus.len or seen.isSet(cpu)) return error.InvalidOption;
            seen.set(cpu);
            cpus[count] = @intCast(cpu);
            count += 1;
        }
    }
    if (count != config.workers) return error.InvalidLimit;
    return cpus[0..count];
}

fn parseCpu(text: []const u8) Error!usize {
    if (text.len == 0) return error.InvalidOption;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidOption;
    const cpu = std.fmt.parseInt(
        usize,
        text,
        10,
    ) catch return error.InvalidOption;
    if (cpu >= 1024) return error.InvalidOption;
    return cpu;
}

/// Returns effective per-worker limits after validating the final configuration.
/// Defaults leave connection headroom for request heads, rejection, and draining;
/// they do not estimate CPU capacity or reserve slots against idle clients.
pub fn resolveAdmission(config: Config) Error!Admission.Options {
    try config.validate();
    const max_active = config.admission.max_active orelse @max(1, config.max_connections * 3 / 4);
    return .{
        .max_active = max_active,
        .max_rejecting = config.admission.max_rejecting orelse @max(1, config.max_connections / 8),
        .requests_per_second = config.admission.requests_per_second,
        .burst = config.admission.burst orelse @intCast(max_active),
        .rejections_per_second = config.admission.rejections_per_second,
    };
}

/// Returns a validated configuration with automatic admission counts filled in.
/// Apply connection budgets and overrides before resolving; the result retains
/// effective limits for worker startup and configuration inspection.
pub fn resolve(config: Config) Error!Config {
    const options = try config.resolveAdmission();
    var resolved = config;
    resolved.admission = .{
        .max_active = options.max_active,
        .max_rejecting = options.max_rejecting,
        .requests_per_second = options.requests_per_second,
        .burst = options.burst,
        .rejections_per_second = options.rejections_per_second,
    };
    return resolved;
}

/// `args` excludes the executable name. All string fields borrow its storage.
pub fn parse(args: []const []const u8) Error!Config {
    var config: Config = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(
            u8,
            arg,
            "--verbose",
        )) {
            config.verbose = true;
            continue;
        }
        if (std.mem.eql(
            u8,
            arg,
            "--no-access-log",
        )) {
            config.access_log = false;
            continue;
        }
        if (i + 1 == args.len) return error.MissingArgument;
        i += 1;
        const value = args[i];
        if (std.mem.eql(
            u8,
            arg,
            "--address",
        )) {
            config.address = value;
        } else if (std.mem.eql(
            u8,
            arg,
            "--tls-certificate",
        )) {
            if (config.tls == null) config.tls = .{};
            config.tls.?.certificate = value;
        } else if (std.mem.eql(
            u8,
            arg,
            "--tls-key",
        )) {
            if (config.tls == null) config.tls = .{};
            config.tls.?.private_key = value;
        } else if (std.mem.eql(
            u8,
            arg,
            "--tls-handshake-timeout-ms",
        )) {
            if (config.tls == null) config.tls = .{};
            config.tls.?.handshake_timeout_ms = std.fmt.parseInt(
                u32,
                value,
                10,
            ) catch
                return error.InvalidOption;
        } else if (std.mem.eql(
            u8,
            arg,
            "--admin-address",
        )) {
            config.admin_address = value;
        } else if (std.mem.eql(
            u8,
            arg,
            "--worker-cpus",
        )) {
            if (value.len == 0) return error.InvalidOption;
            config.worker_cpus = value;
        } else if (std.mem.eql(
            u8,
            arg,
            "--port",
        )) {
            config.port = std.fmt.parseInt(
                u16,
                value,
                10,
            ) catch return error.InvalidOption;
        } else if (std.mem.eql(
            u8,
            arg,
            "--admin-port",
        )) {
            config.admin_port = std.fmt.parseInt(
                u16,
                value,
                10,
            ) catch return error.InvalidOption;
        } else if (std.mem.eql(
            u8,
            arg,
            "--tcp-retries",
        )) {
            config.tcp_retries = if (std.mem.eql(
                u8,
                value,
                "system",
            ))
                .system
            else if (std.mem.eql(
                u8,
                value,
                "thin-linear",
            ))
                .thin_linear
            else
                return error.InvalidOption;
        } else {
            const number = std.fmt.parseInt(
                u32,
                value,
                10,
            ) catch return error.InvalidOption;
            if (std.mem.eql(
                u8,
                arg,
                "--workers",
            )) {
                config.workers = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--http2-max-streams",
            )) {
                config.http2.max_streams = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--http2-worker-streams",
            )) {
                config.http2.max_streams_per_worker = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--http2-memory-bytes",
            )) {
                config.http2.memory_bytes = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--max-connections",
            )) {
                config.max_connections = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--admin-connections",
            )) {
                config.admin_connections = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--log-slots",
            )) {
                config.log_slots = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--completion-budget",
            )) {
                config.completion_budget = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--response-batches",
            )) {
                config.response_batches = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--large-buffer-bytes",
            )) {
                config.large_buffer_bytes = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--max-active",
            )) {
                config.admission.max_active = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--max-rejecting",
            )) {
                config.admission.max_rejecting = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--rate",
            )) {
                config.admission.requests_per_second = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--burst",
            )) {
                config.admission.burst = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--rejection-rate",
            )) {
                config.admission.rejections_per_second = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--header-timeout-ms",
            )) {
                config.header_timeout_ms = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--body-timeout-ms",
            )) {
                config.body_timeout_ms = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--write-timeout-ms",
            )) {
                config.write_timeout_ms = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--idle-timeout-ms",
            )) {
                config.idle_timeout_ms = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--idle-reclaim-ms",
            )) {
                config.idle_reclaim_ms = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--shutdown-timeout-ms",
            )) {
                config.shutdown_timeout_ms = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--shutdown-keepalive-ms",
            )) {
                config.shutdown_keepalive_ms = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--close-timeout-ms",
            )) {
                config.close_timeout_ms = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--max-body-bytes",
            )) {
                config.max_body_bytes = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--max-chunk-framing-bytes",
            )) {
                config.max_chunk_framing_bytes = number;
            } else if (std.mem.eql(
                u8,
                arg,
                "--max-requests",
            )) {
                config.max_requests_per_connection = number;
            } else return error.InvalidOption;
        }
    }
    try config.validate();
    return config;
}

test "resource budgets reject overflow and ring capacity violations" {
    const testing = std.testing;
    try testing.expectError(
        error.InvalidLimit,
        (Config{ .trailer_bytes = std.math.maxInt(usize) }).validate(),
    );
    try testing.expectError(error.InvalidLimit, (Config{ .max_connections = 8192 }).validate());
    try testing.expectError(error.InvalidLimit, (Config{ .application_bytes = 1 }).validate());
    try (Config{}).validate();
}

test "response batch pool is bounded and can be disabled" {
    const testing = std.testing;
    try testing.expectEqual(
        @as(usize, 0),
        (try parse(&.{ "--response-batches", "0" })).response_batches,
    );
    try testing.expectEqual(@as(usize, 64), (try parse(&.{})).response_batches);
    try testing.expectError(error.InvalidLimit, parse(&.{ "--response-batches", "8177" }));
}

test "TCP retry parsing preserves the selected policy through resolution" {
    const testing = std.testing;
    try testing.expectEqual(.thin_linear, (try parse(&.{})).tcp_retries);
    try testing.expectEqual(
        .thin_linear,
        (try parse(&.{ "--tcp-retries", "thin-linear" })).tcp_retries,
    );
    const config = try parse(&.{ "--tcp-retries", "system" });
    try testing.expectEqual(.system, (try config.resolve()).tcp_retries);
    try testing.expectError(error.InvalidOption, parse(&.{ "--tcp-retries", "unknown" }));
    try testing.expectError(error.MissingArgument, parse(&.{"--tcp-retries"}));
}

test "chunk framing configuration preserves a terminal size line budget" {
    const testing = std.testing;
    try testing.expectError(error.InvalidLimit, parse(&.{ "--max-chunk-framing-bytes", "2" }));
    const config = try parse(&.{ "--max-chunk-framing-bytes", "3" });
    try testing.expectEqual(@as(u64, 3), config.max_chunk_framing_bytes);
}

test "worker budgets multiply capacity and reject invalid worker counts" {
    const testing = std.testing;
    const config = try parse(&.{
        "--workers",
        "16",
        "--max-connections",
        "8168",
    });
    try testing.expectEqual(@as(usize, 16), config.workers);
    try testing.expectEqual(@as(usize, 8168), config.max_connections);
    try testing.expectError(error.InvalidLimit, (Config{ .workers = 0 }).validate());
    try testing.expectError(error.InvalidLimit, (Config{ .workers = 257 }).validate());
    try testing.expectError(
        error.InvalidLimit,
        (Config{ .workers = 16, .max_connections = 8169 }).validate(),
    );
}

test "worker CPU mapping preserves order and validates ranges and cardinality" {
    const testing = std.testing;
    var storage: [256]u16 = undefined;
    const config = try parse(&.{
        "--worker-cpus",
        "9,2-3",
        "--workers",
        "3",
    });
    try testing.expectEqualSlices(
        u16,
        &.{
            9,
            2,
            3,
        },
        try config.resolveWorkerCpus(&storage),
    );
    try testing.expectEqual(@as(usize, 0), (try (Config{}).resolveWorkerCpus(&storage)).len);
    try testing.expectError(error.InvalidLimit, parse(&.{ "--worker-cpus", "2-3" }));
    for ([_][]const u8{
        "",
        "2,",
        ",2",
        "-1",
        "+2",
        "2-1",
        "1-2-3",
        "1024",
        "1,1",
        "1-2,2",
        "1 2",
    }) |text| {
        try testing.expectError(error.InvalidOption, parse(&.{ "--worker-cpus", text }));
    }
}

test "admission defaults follow public connection budgets" {
    const testing = std.testing;
    const cases = [_]struct {
        connections: usize,
        active: usize,
        rejecting: usize,
    }{
        .{
            .connections = 1,
            .active = 1,
            .rejecting = 1,
        },
        .{
            .connections = 2,
            .active = 1,
            .rejecting = 1,
        },
        .{
            .connections = 3,
            .active = 2,
            .rejecting = 1,
        },
        .{
            .connections = 4,
            .active = 3,
            .rejecting = 1,
        },
        .{
            .connections = 17,
            .active = 12,
            .rejecting = 2,
        },
        .{
            .connections = 256,
            .active = 192,
            .rejecting = 32,
        },
        .{
            .connections = 2048,
            .active = 1536,
            .rejecting = 256,
        },
        .{
            .connections = 8168,
            .active = 6126,
            .rejecting = 1021,
        },
    };
    for (cases) |case| {
        const options = try (Config{ .max_connections = case.connections }).resolveAdmission();
        try testing.expectEqual(case.active, options.max_active);
        try testing.expectEqual(case.rejecting, options.max_rejecting);
        try testing.expectEqual(case.active, options.burst);
        try testing.expectEqual(@as(u32, 0), options.requests_per_second);
        try testing.expectEqual(@as(u32, 1000), options.rejections_per_second);
    }
}

test "admission defaults exclude worker count and admin slots" {
    const testing = std.testing;
    const single = try (Config{
        .workers = 1,
        .max_connections = 64,
        .admin_connections = 1,
    }).resolveAdmission();
    const multi = try (Config{
        .workers = 16,
        .max_connections = 64,
        .admin_connections = 128,
    }).resolveAdmission();
    try testing.expectEqual(@as(usize, 48), multi.max_active);
    try testing.expectEqual(@as(usize, 8), multi.max_rejecting);
    try testing.expectEqualDeep(single, multi);
}

test "admission parsing preserves explicit limits regardless of option order" {
    const testing = std.testing;
    const orders = [_][]const []const u8{
        &.{
            "--max-active",
            "4",
            "--max-rejecting",
            "0",
            "--burst",
            "8",
            "--rate",
            "2",
            "--rejection-rate",
            "0",
            "--max-connections",
            "16",
        },
        &.{
            "--max-connections",
            "16",
            "--rejection-rate",
            "0",
            "--rate",
            "2",
            "--burst",
            "8",
            "--max-rejecting",
            "0",
            "--max-active",
            "4",
        },
    };
    for (orders) |args| {
        const config = try parse(args);
        try testing.expectEqualDeep(Admission.Options{
            .max_active = 4,
            .max_rejecting = 0,
            .requests_per_second = 2,
            .burst = 8,
            .rejections_per_second = 0,
        }, try config.resolveAdmission());
    }
}

test "admission burst follows the effective active limit until explicitly set" {
    const testing = std.testing;
    var config = try parse(&.{
        "--max-active",
        "5",
        "--max-connections",
        "32",
    });
    try testing.expectEqual(@as(u32, 5), (try config.resolveAdmission()).burst);
    config.admission.burst = 9;
    config.admission.max_active = 7;
    try testing.expectEqual(@as(u32, 9), (try config.resolveAdmission()).burst);
}

test "automatic admission uses the final embedded connection budget" {
    const testing = std.testing;
    var config = try parse(&.{ "--max-connections", "16" });
    config.max_connections = 64;
    const resolved = try config.resolve();
    try testing.expectEqual(@as(?usize, 48), resolved.admission.max_active);
    try testing.expectEqual(@as(?usize, 8), resolved.admission.max_rejecting);
    try testing.expectEqual(@as(?u32, 48), resolved.admission.burst);
    try testing.expectEqual(@as(?usize, null), config.admission.max_active);
}

test "admission overrides reject impossible concurrency and invalid bursts" {
    const testing = std.testing;
    try testing.expectError(error.InvalidLimit, (Config{
        .max_connections = 16,
        .admission = .{ .max_active = 17 },
    }).resolveAdmission());
    try testing.expectError(error.InvalidLimit, (Config{
        .max_connections = 16,
        .admission = .{ .max_rejecting = 17 },
    }).resolveAdmission());
    try testing.expectError(error.InvalidLimit, (Config{
        .admission = .{ .max_active = 0 },
    }).resolveAdmission());
    try testing.expectError(error.InvalidLimit, (Config{
        .admission = .{ .requests_per_second = 1, .burst = 0 },
    }).resolveAdmission());
    const options = try (Config{
        .max_connections = 1,
        .admission = .{
            .max_active = 1,
            .max_rejecting = 0,
            .burst = 0,
        },
    }).resolveAdmission();
    try testing.expectEqual(@as(usize, 1), options.max_active);
    try testing.expectEqual(@as(usize, 0), options.max_rejecting);
    try testing.expectEqual(@as(u32, 0), options.burst);
}
