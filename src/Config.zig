//! Runtime resource budgets with admission defaults derived before binding.

const std = @import("std");
const Admission = @import("Admission.zig");
const log = std.log.scoped(.config);
const Config = @This();

address: []const u8 = "127.0.0.1",
port: u16 = 8080,
admin_address: []const u8 = "127.0.0.1",
admin_port: u16 = 9090,
workers: usize = 1,
max_connections: usize = 256,
/// Zero disables the admin listener and its reserved connection storage.
admin_connections: usize = 8,
header_bytes: usize = 32 * 1024,
trailer_bytes: usize = 8 * 1024,
receive_bytes: usize = 16 * 1024,
response_bytes: usize = 32 * 1024,
application_bytes: usize = 64 * 1024,
max_body_bytes: u64 = 64 * 1024 * 1024,
max_chunk_framing_bytes: u64 = 64 * 1024,
header_timeout_ms: u32 = 5000,
body_timeout_ms: u32 = 30000,
write_timeout_ms: u32 = 5000,
idle_timeout_ms: u32 = 15000,
close_timeout_ms: u32 = 100,
shutdown_timeout_ms: u32 = 5000,
max_requests_per_connection: u32 = 1000,
completion_budget: usize = 64,
log_slots: usize = 256,
/// Borrowed descriptor for JSON events; null disables logging. Keep it open
/// until serving returns. Writers outside this server must coordinate access.
log_fd: ?i32 = 2,
verbose: bool = false,
access_log: bool = true,
admission: AdmissionOptions = .{},

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

pub fn validate(config: Config) Error!void {
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
        config.max_chunk_framing_bytes < 3 or
        config.max_requests_per_connection == 0 or config.header_timeout_ms == 0 or
        config.body_timeout_ms == 0 or config.write_timeout_ms == 0 or
        config.idle_timeout_ms == 0 or config.close_timeout_ms == 0 or
        config.shutdown_timeout_ms == 0 or
        (config.admission.requests_per_second != 0 and config.admission.burst == 0))
        return error.InvalidLimit;
    if (config.log_fd) |fd| if (fd < 0) return error.InvalidLimit;
    if (config.admission.max_active) |limit| {
        if (limit == 0 or limit > config.max_connections) return error.InvalidLimit;
    }
    if (config.admission.max_rejecting) |limit| {
        if (limit > config.max_connections) return error.InvalidLimit;
    }
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
        if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-access-log")) {
            config.access_log = false;
            continue;
        }
        if (i + 1 == args.len) return error.MissingArgument;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--address")) {
            config.address = value;
        } else if (std.mem.eql(u8, arg, "--admin-address")) {
            config.admin_address = value;
        } else if (std.mem.eql(u8, arg, "--port")) {
            config.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidOption;
        } else if (std.mem.eql(u8, arg, "--admin-port")) {
            config.admin_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidOption;
        } else {
            const number = std.fmt.parseInt(u32, value, 10) catch return error.InvalidOption;
            if (std.mem.eql(u8, arg, "--workers")) {
                config.workers = number;
            } else if (std.mem.eql(u8, arg, "--max-connections")) {
                config.max_connections = number;
            } else if (std.mem.eql(u8, arg, "--admin-connections")) {
                config.admin_connections = number;
            } else if (std.mem.eql(u8, arg, "--log-slots")) {
                config.log_slots = number;
            } else if (std.mem.eql(u8, arg, "--completion-budget")) {
                config.completion_budget = number;
            } else if (std.mem.eql(u8, arg, "--max-active")) {
                config.admission.max_active = number;
            } else if (std.mem.eql(u8, arg, "--max-rejecting")) {
                config.admission.max_rejecting = number;
            } else if (std.mem.eql(u8, arg, "--rate")) {
                config.admission.requests_per_second = number;
            } else if (std.mem.eql(u8, arg, "--burst")) {
                config.admission.burst = number;
            } else if (std.mem.eql(u8, arg, "--rejection-rate")) {
                config.admission.rejections_per_second = number;
            } else if (std.mem.eql(u8, arg, "--header-timeout-ms")) {
                config.header_timeout_ms = number;
            } else if (std.mem.eql(u8, arg, "--body-timeout-ms")) {
                config.body_timeout_ms = number;
            } else if (std.mem.eql(u8, arg, "--write-timeout-ms")) {
                config.write_timeout_ms = number;
            } else if (std.mem.eql(u8, arg, "--idle-timeout-ms")) {
                config.idle_timeout_ms = number;
            } else if (std.mem.eql(u8, arg, "--shutdown-timeout-ms")) {
                config.shutdown_timeout_ms = number;
            } else if (std.mem.eql(u8, arg, "--close-timeout-ms")) {
                config.close_timeout_ms = number;
            } else if (std.mem.eql(u8, arg, "--max-body-bytes")) {
                config.max_body_bytes = number;
            } else if (std.mem.eql(u8, arg, "--max-chunk-framing-bytes")) {
                config.max_chunk_framing_bytes = number;
            } else if (std.mem.eql(u8, arg, "--max-requests")) {
                config.max_requests_per_connection = number;
            } else return error.InvalidOption;
        }
    }
    try config.validate();
    return config;
}

test "resource budgets reject overflow and ring capacity violations" {
    const testing = std.testing;
    try testing.expectError(error.InvalidLimit, (Config{ .trailer_bytes = std.math.maxInt(usize) }).validate());
    try testing.expectError(error.InvalidLimit, (Config{ .max_connections = 8192 }).validate());
    try testing.expectError(error.InvalidLimit, (Config{ .application_bytes = 1 }).validate());
    try (Config{}).validate();
}

test "chunk framing configuration preserves a terminal size line budget" {
    const testing = std.testing;
    try testing.expectError(error.InvalidLimit, parse(&.{ "--max-chunk-framing-bytes", "2" }));
    const config = try parse(&.{ "--max-chunk-framing-bytes", "3" });
    try testing.expectEqual(@as(u64, 3), config.max_chunk_framing_bytes);
}

test "worker budgets multiply capacity and reject invalid worker counts" {
    const testing = std.testing;
    const config = try parse(&.{ "--workers", "16", "--max-connections", "8168" });
    try testing.expectEqual(@as(usize, 16), config.workers);
    try testing.expectEqual(@as(usize, 8168), config.max_connections);
    try testing.expectError(error.InvalidLimit, (Config{ .workers = 0 }).validate());
    try testing.expectError(error.InvalidLimit, (Config{ .workers = 257 }).validate());
    try testing.expectError(error.InvalidLimit, (Config{ .workers = 16, .max_connections = 8169 }).validate());
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
