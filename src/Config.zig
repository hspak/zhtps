//! Runtime resource budgets with admission defaults derived before binding.

const std = @import("std");
const Admission = @import("Admission.zig");
const VictoriaLogs = @import("Logger.zig").VictoriaLogs;
pub const Resources = @import("Config/Resources.zig");
const Config = @This();

address: []const u8 = "127.0.0.1",
port: u16 = 8080,
/// Encrypts the public listener. The separate admin listener remains HTTP.
tls: ?Tls = null,
/// Serves 308 redirects on a separate HTTP listener. Requires TLS credentials.
http_redirect: bool = false,
/// Uses the public address. Zero selects a free port; ignored unless enabled.
http_redirect_port: u16 = 80,
http2: Http2 = .{},
admin_address: []const u8 = "127.0.0.1",
admin_port: u16 = 9090,
/// `automatic` sizes transport and application threads within the CPU allocation.
workers: usize = automatic,
/// Ordered logical CPU IDs, one per worker, such as "9,10-12". Empty permits
/// NIC-aware placement; "inherit" keeps scheduler placement. Borrows storage
/// until server deinit. Automatic worker counts follow an explicit mapping.
worker_cpus: []const u8 = "",
/// Per worker. `automatic` derives capacity from memory and descriptor budgets.
max_connections: usize = automatic,
/// Process-wide sizing allowance; null uses one quarter of available memory
/// within host and cgroup limits. This is a planning budget, not an RSS limiter.
memory_budget_bytes: ?u64 = null,
/// Populated by server initialization; includes inputs and reasons for sizing.
resources: ?Resolution = null,
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
large_buffer_bytes: usize = automatic,
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
/// Borrowed descriptor for JSON events; null disables logging unless victoria_logs
/// is set. Keep it open until serving returns. Other writers must coordinate access.
log_fd: ?i32 = 2,
/// HTTP(S) origin for direct JSON ingestion. Borrows storage until server deinit;
/// overrides log_fd and requires access_log. The server owns the posting transport.
victoria_logs: ?[]const u8 = null,
verbose: bool = false,
access_log: bool = true,
admission: AdmissionOptions = .{},

/// Selects startup sizing for workers, connections, large buffers, and HTTP/2
/// worker limits. Zero retains its existing meaning for each option.
pub const automatic = std.math.maxInt(usize);

pub const Requirements = struct {
    process_bytes: u64 = 0,
    process_fds: usize = 0,
    process_threads: usize = 0,
    worker_bytes: u64,
    connection_bytes: u64,
    admin_bytes: u64,
    stream_bytes: u64,
    stream_queue_bytes: u64 = 0,
    lane_threads: usize = 0,
    worker_fds: usize = 3,
};

pub const Resolution = struct {
    detected: Resources.Report,
    memory_budget_bytes: u64,
    estimated_bytes: u64,
    threads_per_worker: usize,
    workers: enum {
        explicit,
        cpu,
        mapping,
        memory,
        descriptors,
        threads,
    },
    connections: enum {
        explicit,
        memory,
        descriptors,
        implementation,
    },
    large_buffers_automatic: bool,
    http2_memory_automatic: bool,
    http2_streams_automatic: bool,
};

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
    max_streams_per_worker: usize = automatic,
    /// Bounds protocol, stream, and transport allocations together per worker.
    memory_bytes: usize = automatic,
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
    InvalidVictoriaLogsUrl,
    ConflictingLogOptions,
    InvalidOption,
    HttpsRequired,
    MissingArgument,
    InvalidLimit,
    UnresolvedResources,
    MemoryBudgetExceeded,
    DescriptorBudgetTooSmall,
    ThreadBudgetExceeded,
};

/// Rejects unsupported limits and listener combinations without allocating or binding.
pub fn validate(config: Config) Error!void {
    if (config.victoria_logs) |url| {
        if (!config.access_log) return error.ConflictingLogOptions;
        _ = try VictoriaLogs.parseOrigin(url);
    }
    if (config.http_redirect) {
        if (config.tls == null) return error.HttpsRequired;
        if (config.port != 0 and config.http_redirect_port == config.port)
            return error.InvalidOption;
    }
    if (config.http2.max_streams == 0 or config.http2.max_streams > 65535 or
        config.http2.max_streams_per_worker == 0 or
        (config.http2.max_streams_per_worker != automatic and config.http2.max_streams_per_worker > 65535) or
        config.http2.memory_bytes < 1024 * 1024) return error.InvalidLimit;
    if (config.tls) |tls| {
        if (tls.certificate.len == 0 or tls.private_key.len == 0 or
            std.mem.indexOfScalar(u8, tls.certificate, 0) != null or
            std.mem.indexOfScalar(u8, tls.private_key, 0) != null or
            tls.handshake_timeout_ms == 0) return error.InvalidOption;
    }
    if (config.workers == 0 or (config.workers != automatic and config.workers > 256) or
        config.max_connections == 0 or (config.max_connections != automatic and config.max_connections > 8176) or
        config.admin_connections > 128 or
        (config.max_connections != automatic and config.max_connections + config.admin_connections > 8176) or
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
    if (config.memory_budget_bytes == 0) return error.InvalidLimit;
    var cpus: [256]u16 = undefined;
    _ = try config.resolveWorkerCpus(&cpus);
    if (config.admission.max_active) |limit| {
        if (limit == 0 or limit > @min(config.max_connections, 8176 - config.admin_connections))
            return error.InvalidLimit;
    }
    if (config.admission.max_rejecting) |limit| {
        if (limit > @min(config.max_connections, 8176 - config.admin_connections)) return error.InvalidLimit;
    }
}

/// Writes the ordered worker mapping into caller storage. An empty mapping
/// preserves scheduler placement; otherwise every worker needs a distinct CPU.
/// CPU availability is checked on the serving thread before workers start.
pub fn resolveWorkerCpus(config: Config, cpus: *[256]u16) Error![]const u16 {
    if (config.worker_cpus.len == 0 or std.mem.eql(u8, config.worker_cpus, "inherit")) return cpus[0..0];
    var count: usize = 0;
    var seen = std.StaticBitSet(1024).initEmpty();
    var parts = std.mem.splitScalar(u8, config.worker_cpus, ',');
    while (parts.next()) |part| {
        var range = std.mem.splitScalar(u8, part, '-');
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
    if (config.workers != automatic and count != config.workers) return error.InvalidLimit;
    return cpus[0..count];
}

fn parseCpu(text: []const u8) Error!usize {
    if (text.len == 0) return error.InvalidOption;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidOption;
    const cpu = std.fmt.parseInt(usize, text, 10) catch return error.InvalidOption;
    if (cpu >= 1024) return error.InvalidOption;
    return cpu;
}

/// Returns effective per-worker limits after validating the final configuration.
/// Defaults leave connection headroom for request heads, rejection, and draining;
/// they do not estimate CPU capacity or reserve slots against idle clients.
pub fn resolveAdmission(config: Config) Error!Admission.Options {
    try config.validate();
    if (config.max_connections == automatic) return error.UnresolvedResources;
    const max_active = config.admission.max_active orelse @max(1, config.max_connections * 3 / 4);
    return .{
        .max_active = max_active,
        .max_rejecting = config.admission.max_rejecting orelse @max(1, config.max_connections / 8),
        .requests_per_second = config.admission.requests_per_second,
        .burst = config.admission.burst orelse @intCast(max_active),
        .rejections_per_second = config.admission.rejections_per_second,
    };
}

/// Fills in admission defaults after resource sizing. Requires a numeric
/// connection budget; otherwise returns UnresolvedResources. Server initialization
/// performs host discovery and resolves resource budgets before calling this.
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

/// Resolves startup limits without I/O. `requirements` describes the compiled
/// application. Automatic CPU mapping borrows `mapping` until server deinit;
/// explicit configuration strings retain their original ownership.
pub fn resolveResources(
    config: Config,
    detected: *const Resources,
    requirements: Requirements,
    mapping: []u8,
) Error!Config {
    try config.validate();
    var result = config;
    const budget = config.memory_budget_bytes orelse detected.report.memory_available_bytes / 4;
    const shared_bytes = requirements.admin_bytes +| requirements.process_bytes;
    if (budget == 0 or budget > detected.report.memory_available_bytes or
        shared_bytes >= budget) return error.MemoryBudgetExceeded;
    const threads = std.math.add(usize, 1, requirements.lane_threads) catch return error.InvalidLimit;
    var resolution: Resolution = .{
        .detected = detected.report,
        .memory_budget_bytes = budget,
        .estimated_bytes = 0,
        .threads_per_worker = threads,
        .workers = if (config.workers == automatic) .cpu else .explicit,
        .connections = .explicit,
        .large_buffers_automatic = config.large_buffer_bytes == automatic,
        .http2_memory_automatic = config.http2.memory_bytes == automatic,
        .http2_streams_automatic = config.http2.max_streams_per_worker == automatic,
    };
    var cpu_storage: [256]u16 = undefined;
    const explicit_cpus = try config.resolveWorkerCpus(&cpu_storage);
    if (config.workers == automatic) {
        var cpu_count = detected.report.physical_cores;
        if (detected.report.cpu_quota_millis) |quota| cpu_count = @min(cpu_count, @max(1, quota / 1000));
        if (detected.placement_count != 0 and config.worker_cpus.len == 0)
            cpu_count = @min(cpu_count, detected.placement_count);
        result.workers = @min(256, @max(1, cpu_count / threads));
        if (explicit_cpus.len != 0) {
            result.workers = explicit_cpus.len;
            resolution.workers = .mapping;
        }
    }
    const adjustable_workers = config.workers == automatic and explicit_cpus.len == 0;
    const minimum_connections = if (config.max_connections == automatic)
        @max(1, config.admission.max_active orelse 1, config.admission.max_rejecting orelse 0)
    else
        config.max_connections;
    const descriptor_capacity = detected.report.nofile_limit -| detected.report.reserved_fds -|
        requirements.process_fds -|
        config.admin_connections -| @as(u64, @intFromBool(config.admin_connections != 0));
    if (config.max_connections == automatic) {
        const count = descriptor_capacity / (requirements.worker_fds + minimum_connections);
        if (count == 0) return error.DescriptorBudgetTooSmall;
        if (adjustable_workers and result.workers > count) {
            result.workers = @intCast(count);
            resolution.workers = .descriptors;
        }
    }
    if (detected.report.available_threads) |available| {
        const count = ((available +| 1) -| requirements.process_threads) / threads;
        if (result.workers > count) {
            if (!adjustable_workers or count == 0) return error.ThreadBudgetExceeded;
            result.workers = @intCast(count);
            resolution.workers = .threads;
        }
    }
    const minimum_large = if (config.large_buffer_bytes == automatic) 1024 * 1024 else config.large_buffer_bytes;
    const minimum_http2 = if (config.http2.memory_bytes == automatic) 1024 * 1024 else config.http2.memory_bytes;
    const minimum_streams = if (config.http2.max_streams_per_worker == automatic)
        1
    else
        config.http2.max_streams_per_worker;
    const fixed_bytes = requirements.worker_bytes +|
        requirements.connection_bytes *| minimum_connections +|
        requirements.stream_queue_bytes *| minimum_streams;
    const minimum_worker = fixed_bytes +| minimum_large +| if (config.tls != null) minimum_http2 else 0;
    const memory_workers = (budget - shared_bytes) / @max(1, minimum_worker);
    if (result.workers > memory_workers) {
        if (!adjustable_workers or memory_workers == 0) return error.MemoryBudgetExceeded;
        result.workers = @intCast(memory_workers);
        resolution.workers = .memory;
    }
    const worker_budget = (budget - shared_bytes) / result.workers;
    const flexible_bytes = worker_budget - minimum_worker;
    if (config.large_buffer_bytes == automatic)
        result.large_buffer_bytes = @intCast(@min(64 * 1024 * 1024, minimum_large + flexible_bytes / 4));
    if (config.http2.memory_bytes == automatic)
        result.http2.memory_bytes = if (config.tls != null)
            @intCast(@min(64 * 1024 * 1024, minimum_http2 + flexible_bytes / 4))
        else
            1024 * 1024;
    if (config.http2.max_streams_per_worker == automatic) {
        // Leave half of the HTTP/2 allowance for protocol and transport storage.
        result.http2.max_streams_per_worker = if (config.tls != null)
            @intCast(@min(256, @max(1, result.http2.memory_bytes / 2 / @max(1, requirements.stream_bytes))))
        else
            1;
        if (requirements.stream_queue_bytes != 0) {
            const queue_budget = worker_budget -| requirements.worker_bytes -|
                result.large_buffer_bytes -|
                (if (config.tls != null) @as(u64, result.http2.memory_bytes) else 0) -|
                requirements.connection_bytes *| minimum_connections;
            result.http2.max_streams_per_worker = @intCast(@min(
                result.http2.max_streams_per_worker,
                queue_budget / requirements.stream_queue_bytes,
            ));
        }
    }
    const worker_fixed = requirements.worker_bytes +| result.large_buffer_bytes +|
        (if (config.tls != null) @as(u64, result.http2.memory_bytes) else 0) +|
        requirements.stream_queue_bytes *| result.http2.max_streams_per_worker;
    if (worker_fixed >= worker_budget) return error.MemoryBudgetExceeded;
    if (config.max_connections == automatic) {
        const memory_count = (worker_budget - worker_fixed) / @max(1, requirements.connection_bytes);
        const fd_count = (descriptor_capacity / result.workers) -| requirements.worker_fds;
        const implementation_count = 8176 - config.admin_connections;
        result.max_connections = @intCast(@min(memory_count, fd_count, implementation_count));
        resolution.connections = if (result.max_connections == memory_count)
            .memory
        else if (result.max_connections == fd_count)
            .descriptors
        else
            .implementation;
        if (result.max_connections < minimum_connections) return error.DescriptorBudgetTooSmall;
    }
    resolution.estimated_bytes = shared_bytes +|
        result.workers *| (worker_fixed +| requirements.connection_bytes *| result.max_connections);
    if (resolution.estimated_bytes > budget) return error.MemoryBudgetExceeded;
    if (explicit_cpus.len != 0) {
        resolution.detected.placement = .explicit;
    } else if (config.worker_cpus.len == 0 and detected.placement_count >= result.workers) {
        var writer: std.Io.Writer = .fixed(mapping);
        for (detected.placement[0..result.workers], 0..) |cpu, index| {
            if (index != 0) writer.writeByte(',') catch return error.InvalidLimit;
            writer.print("{d}", .{cpu}) catch return error.InvalidLimit;
        }
        result.worker_cpus = writer.buffered();
    } else {
        result.worker_cpus = "";
        if (resolution.detected.placement == .nic) resolution.detected.placement = .unavailable;
    }
    result.resources = resolution;
    return result.resolve();
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
        if (std.mem.eql(u8, arg, "--no-access-log") or std.mem.eql(u8, arg, "--no-access-logs")) {
            config.access_log = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--http-redirect")) {
            config.http_redirect = true;
            continue;
        }
        if (i + 1 == args.len) return error.MissingArgument;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--victoria-logs")) {
            config.victoria_logs = value;
            config.log_fd = null;
        } else if (std.mem.eql(u8, arg, "--memory-budget-bytes")) {
            config.memory_budget_bytes = if (std.mem.eql(u8, value, "auto"))
                null
            else
                std.fmt.parseInt(u64, value, 10) catch return error.InvalidOption;
        } else if (std.mem.eql(u8, value, "auto") and
            (std.mem.eql(u8, arg, "--workers") or
                std.mem.eql(u8, arg, "--max-connections") or
                std.mem.eql(u8, arg, "--large-buffer-bytes") or
                std.mem.eql(u8, arg, "--http2-memory-bytes") or
                std.mem.eql(u8, arg, "--http2-worker-streams")))
        {
            if (std.mem.eql(u8, arg, "--workers")) {
                config.workers = automatic;
            } else if (std.mem.eql(u8, arg, "--max-connections")) {
                config.max_connections = automatic;
            } else if (std.mem.eql(u8, arg, "--large-buffer-bytes")) {
                config.large_buffer_bytes = automatic;
            } else if (std.mem.eql(u8, arg, "--http2-memory-bytes")) {
                config.http2.memory_bytes = automatic;
            } else if (std.mem.eql(u8, arg, "--http2-worker-streams")) {
                config.http2.max_streams_per_worker = automatic;
            } else return error.InvalidOption;
        } else if (std.mem.eql(u8, arg, "--address")) {
            config.address = value;
        } else if (std.mem.eql(u8, arg, "--tls-certificate")) {
            if (config.tls == null) config.tls = .{};
            config.tls.?.certificate = value;
        } else if (std.mem.eql(u8, arg, "--tls-key")) {
            if (config.tls == null) config.tls = .{};
            config.tls.?.private_key = value;
        } else if (std.mem.eql(u8, arg, "--tls-handshake-timeout-ms")) {
            if (config.tls == null) config.tls = .{};
            config.tls.?.handshake_timeout_ms = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidOption;
        } else if (std.mem.eql(u8, arg, "--admin-address")) {
            config.admin_address = value;
        } else if (std.mem.eql(u8, arg, "--worker-cpus")) {
            if (value.len == 0) return error.InvalidOption;
            config.worker_cpus = value;
        } else if (std.mem.eql(u8, arg, "--port")) {
            config.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidOption;
        } else if (std.mem.eql(u8, arg, "--admin-port")) {
            config.admin_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidOption;
        } else if (std.mem.eql(u8, arg, "--http-redirect-port")) {
            config.http_redirect_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidOption;
        } else if (std.mem.eql(u8, arg, "--tcp-retries")) {
            config.tcp_retries = if (std.mem.eql(u8, value, "system"))
                .system
            else if (std.mem.eql(u8, value, "thin-linear"))
                .thin_linear
            else
                return error.InvalidOption;
        } else {
            const number = std.fmt.parseInt(u32, value, 10) catch return error.InvalidOption;
            if (std.mem.eql(u8, arg, "--workers")) {
                config.workers = number;
            } else if (std.mem.eql(u8, arg, "--http2-max-streams")) {
                config.http2.max_streams = number;
            } else if (std.mem.eql(u8, arg, "--http2-worker-streams")) {
                config.http2.max_streams_per_worker = number;
            } else if (std.mem.eql(u8, arg, "--http2-memory-bytes")) {
                config.http2.memory_bytes = number;
            } else if (std.mem.eql(u8, arg, "--max-connections")) {
                config.max_connections = number;
            } else if (std.mem.eql(u8, arg, "--admin-connections")) {
                config.admin_connections = number;
            } else if (std.mem.eql(u8, arg, "--log-slots")) {
                config.log_slots = number;
            } else if (std.mem.eql(u8, arg, "--completion-budget")) {
                config.completion_budget = number;
            } else if (std.mem.eql(u8, arg, "--response-batches")) {
                config.response_batches = number;
            } else if (std.mem.eql(u8, arg, "--large-buffer-bytes")) {
                config.large_buffer_bytes = number;
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
            } else if (std.mem.eql(u8, arg, "--idle-reclaim-ms")) {
                config.idle_reclaim_ms = number;
            } else if (std.mem.eql(u8, arg, "--shutdown-timeout-ms")) {
                config.shutdown_timeout_ms = number;
            } else if (std.mem.eql(u8, arg, "--shutdown-keepalive-ms")) {
                config.shutdown_keepalive_ms = number;
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

test "HTTP redirect requires TLS and distinct listener ports" {
    const testing = std.testing;
    try testing.expectError(error.HttpsRequired, (Config{ .http_redirect = true }).validate());
    try testing.expectError(error.HttpsRequired, parse(&.{"--http-redirect"}));
    try testing.expectError(error.InvalidOption, parse(&.{
        "--http-redirect",
        "--tls-certificate",
        "server.pem",
    }));
    const credentials = [_][]const u8{
        "--tls-certificate",
        "server.pem",
        "--tls-key",
        "server.key",
    };
    try testing.expect(!(try parse(&credentials)).http_redirect);
    const defaults = try parse(&(.{"--http-redirect"} ++ credentials));
    try testing.expect(defaults.http_redirect);
    try testing.expectEqual(@as(u16, 80), defaults.http_redirect_port);
    const config = try parse(&(credentials ++ .{
        "--http-redirect-port",
        "8081",
        "--http-redirect",
    }));
    try testing.expect(config.http_redirect);
    try testing.expectEqual(@as(u16, 8081), config.http_redirect_port);
    try testing.expectError(error.InvalidOption, parse(&(credentials ++ .{
        "--http-redirect",
        "--http-redirect-port",
        "8080",
    })));
    try testing.expectError(error.InvalidOption, parse(&.{ "--http-redirect-port", "65536" }));
    try testing.expectError(error.MissingArgument, parse(&.{"--http-redirect-port"}));
    _ = try parse(&(credentials ++ .{
        "--http-redirect",
        "--http-redirect-port",
        "0",
        "--port",
        "0",
    }));
}

test "automatic defaults size the whole application within CPU and descriptor limits" {
    const testing = std.testing;
    const detected: Resources = .{ .report = .{
        .allowed_cpus = 32,
        .physical_cores = 16,
        .cpu_quota_millis = 2500,
        .memory_limit_bytes = 256 * 1024 * 1024,
        .memory_available_bytes = 256 * 1024 * 1024,
        .memory_source = .cgroup_max,
        .nofile_limit = 128,
    } };
    var mapping: [1280]u8 = undefined;
    const resolved = try (Config{}).resolveResources(&detected, .{
        .worker_bytes = 4 * 1024 * 1024,
        .connection_bytes = 64 * 1024,
        .admin_bytes = 1024 * 1024,
        .stream_bytes = 128 * 1024,
        .lane_threads = 1,
    }, &mapping);
    try testing.expectEqual(@as(usize, 1), resolved.workers);
    try testing.expectEqual(@as(usize, 84), resolved.max_connections);
    try testing.expectEqual(@as(?usize, 63), resolved.admission.max_active);
    try testing.expectEqual(@as(?usize, 10), resolved.admission.max_rejecting);
    try testing.expectEqual(@as(?u32, 63), resolved.admission.burst);
    try testing.expectEqual(.descriptors, resolved.resources.?.connections);
    try testing.expectEqual(@as(u64, 64 * 1024 * 1024), resolved.resources.?.memory_budget_bytes);
    try testing.expect(resolved.resources.?.estimated_bytes <= resolved.resources.?.memory_budget_bytes);
}

test "automatic workers shrink to memory and thread allowances while overrides remain exact" {
    const testing = std.testing;
    var detected: Resources = .{ .report = .{
        .allowed_cpus = 32,
        .physical_cores = 16,
        .memory_limit_bytes = 256 * 1024 * 1024,
        .memory_available_bytes = 256 * 1024 * 1024,
        .nofile_limit = 65536,
    } };
    const requirements: Requirements = .{
        .worker_bytes = 8 * 1024 * 1024,
        .connection_bytes = 64 * 1024,
        .admin_bytes = 1024 * 1024,
        .stream_bytes = 128 * 1024,
    };
    var mapping: [1280]u8 = undefined;
    const automatic_config = try (Config{}).resolveResources(&detected, requirements, &mapping);
    try testing.expectEqual(@as(usize, 6), automatic_config.workers);
    try testing.expectEqual(.memory, automatic_config.resources.?.workers);
    detected.report.available_threads = 1;
    const limited = try (Config{}).resolveResources(&detected, requirements, &mapping);
    try testing.expectEqual(@as(usize, 2), limited.workers);
    try testing.expectEqual(.threads, limited.resources.?.workers);
    const explicit = try (Config{
        .workers = 1,
        .max_connections = 7,
        .large_buffer_bytes = 123456,
        .http2 = .{ .memory_bytes = 2 * 1024 * 1024, .max_streams_per_worker = 17 },
        .admission = .{ .max_active = 3, .burst = 9 },
    }).resolveResources(&detected, requirements, &mapping);
    try testing.expectEqual(@as(usize, 7), explicit.max_connections);
    try testing.expectEqual(@as(usize, 123456), explicit.large_buffer_bytes);
    try testing.expectEqual(@as(usize, 17), explicit.http2.max_streams_per_worker);
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024), explicit.http2.memory_bytes);
    try testing.expectEqual(@as(?usize, 3), explicit.admission.max_active);
    try testing.expectEqual(@as(?u32, 9), explicit.admission.burst);
    try testing.expectError(
        error.ThreadBudgetExceeded,
        (Config{ .workers = 3 }).resolveResources(&detected, requirements, &mapping),
    );
    try testing.expectError(
        error.MemoryBudgetExceeded,
        (Config{ .memory_budget_bytes = 512 * 1024 * 1024 }).resolveResources(
            &detected,
            requirements,
            &mapping,
        ),
    );
}

test "automatic TLS streams include executor queues in the process budget" {
    const testing = std.testing;
    const detected: Resources = .{ .report = .{
        .physical_cores = 1,
        .memory_available_bytes = 80 * 1024 * 1024,
        .nofile_limit = 1024,
    } };
    var mapping: [1280]u8 = undefined;
    const config: Config = .{
        .tls = .{ .certificate = "server.pem", .private_key = "server.key" },
        .admin_connections = 0,
    };
    const resolved = try config.resolveResources(&detected, .{
        .worker_bytes = 8 * 1024 * 1024,
        .connection_bytes = 64 * 1024,
        .admin_bytes = 0,
        .stream_bytes = 256,
        .stream_queue_bytes = 1024 * 1024,
    }, &mapping);
    try testing.expectEqual(@as(usize, 5), resolved.http2.max_streams_per_worker);
    try testing.expectEqual(@as(usize, 8), resolved.max_connections);
    try testing.expect(resolved.resources.?.estimated_bytes <= 20 * 1024 * 1024);
}

test "automatic parsing preserves overrides in either order and accepts wide memory budgets" {
    const testing = std.testing;
    const defaults = try parse(&.{});
    try testing.expectEqual(automatic, defaults.workers);
    try testing.expectEqual(automatic, defaults.max_connections);
    try testing.expectEqual(automatic, defaults.http2.memory_bytes);
    const resolved = try parse(&.{
        "--workers",         "2",  "--workers",             "auto",
        "--max-connections", "17", "--memory-budget-bytes", "8589934592",
    });
    try testing.expectEqual(automatic, resolved.workers);
    try testing.expectEqual(@as(usize, 17), resolved.max_connections);
    try testing.expectEqual(@as(?u64, 8589934592), resolved.memory_budget_bytes);
    try testing.expectError(error.InvalidOption, parse(&.{ "--rate", "auto" }));
    try testing.expectError(error.InvalidLimit, parse(&.{ "--memory-budget-bytes", "0" }));
}

test "automatic worker count follows explicit CPU mapping and owns no borrowed mapping" {
    const testing = std.testing;
    const detected: Resources = .{ .report = .{
        .allowed_cpus = 8,
        .physical_cores = 4,
        .memory_available_bytes = 1024 * 1024 * 1024,
        .nofile_limit = 1024,
    } };
    var mapping: [1280]u8 = undefined;
    const config = try parse(&.{ "--worker-cpus", "3,1" });
    const resolved = try config.resolveResources(&detected, .{
        .worker_bytes = 1024 * 1024,
        .connection_bytes = 64 * 1024,
        .admin_bytes = 0,
        .stream_bytes = 128 * 1024,
    }, &mapping);
    try testing.expectEqual(@as(usize, 2), resolved.workers);
    try testing.expectEqualStrings("3,1", resolved.worker_cpus);
    try testing.expectEqual(.mapping, resolved.resources.?.workers);
    try testing.expectEqual(.explicit, resolved.resources.?.detected.placement);
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
    const config = try parse(&.{
        "--tcp-retries", "system", "--max-connections", "256",
    });
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
    try testing.expectError(error.InvalidLimit, parse(&.{
        "--worker-cpus", "2-3", "--workers", "1",
    }));
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

test "VictoriaLogs configuration validates embedded and command-line logging choices" {
    const testing = std.testing;
    try testing.expectError(error.ConflictingLogOptions, (Config{
        .victoria_logs = "http://localhost:9428",
        .access_log = false,
    }).validate());
    for ([_][]const u8{
        "http://localhost:9428",
        "https://logs.example.com/",
        "http://127.0.0.1:9428",
        "http://[::1]:9428",
    }) |url| {
        const config = try parse(&.{ "--victoria-logs", url });
        try testing.expectEqualStrings(url, config.victoria_logs.?);
        try testing.expect(config.log_fd == null);
        try testing.expect(config.access_log);
    }
    const config = try parse(&.{"--no-access-logs"});
    try testing.expect(!config.access_log);
    try testing.expectEqual(@as(?i32, 2), config.log_fd);
}
