//! Private completion-driven workers. Application hooks run on the owning worker.

const std = @import("std");
const platform = @import("../platform.zig");
const linux = platform.linux;
const http = @import("../http.zig");
const Config = @import("../Config.zig");
const Metrics = @import("../Metrics.zig");
const metrics_format = @import("../metrics_format.zig");
const Logger = @import("../Logger.zig");
const Admission = @import("../Admission.zig");
const application = @import("../application.zig");
const log = std.log.scoped(.server_worker);

pub const RunError = std.mem.Allocator.Error || platform.Error || Config.Error || error{
    IoUringUnavailable,
    IoUringOperationUnsupported,
    IoUringResources,
};

// The built-in service accepts any syntactically valid authority. An omitted
// HTTP/1.0 authority or empty Host uses this listener-specific default origin.
fn defaultAuthority(buffer: *[64]u8, address: []const u8, port: u16) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (std.mem.indexOfScalar(u8, address, ':') != null) {
        writer.print("[{s}]", .{address}) catch unreachable;
    } else writer.writeAll(address) catch unreachable;
    if (port != 80) writer.print(":{d}", .{port}) catch unreachable;
    return writer.buffered();
}

fn cancelSync(ring: *linux.IoUring, user_data: u64) error{IoUringOperationUnsupported}!void {
    const registration: linux.io_uring_sync_cancel_reg = .{
        .addr = user_data,
        .fd = -1,
        .flags = 0,
        .timeout = .{ .sec = -1, .nsec = -1 },
        .pad = @splat(0),
    };
    while (true) {
        const result = linux.io_uring_register(ring.fd, .REGISTER_SYNC_CANCEL, &registration, 1);
        switch (linux.errno(result)) {
            .SUCCESS, .NOENT => return,
            .INTR => continue,
            else => return error.IoUringOperationUnsupported,
        }
    }
}

/// App.Exchange implements init, receiveHead, receiveBody, respond, produce,
/// and allowedMethods, as illustrated by application.Exchange. Hooks must be
/// bounded and nonblocking. Their buffers remain owned by the connection until
/// its response finishes. The server owns no application-global resources.
pub fn Worker(comptime App: type) type {
    return struct {
        const Self = @This();

        config: Config,
        io: std.Io,
        shared: ?*Shared = null,
        worker_id: u32 = 0,
        thread_id: std.atomic.Value(u32) = .init(0),
        failure: ?RunError = null,
        inspection: Inspection = .{},
        gpa: std.mem.Allocator,
        ring: linux.IoUring,
        listener: platform.Listener,
        admin_listener: platform.Listener,
        connections: []Connection,
        active_slots: []usize = &.{},
        storage: []u8,
        log_slots: []Logger.Slot,
        metrics: Metrics = .{},
        logger: Logger = undefined,
        admission: Admission = undefined,
        stop: *const std.atomic.Value(bool),
        pending: usize = 0,
        accepting: bool = false,
        admin_accepting: bool = false,
        accept_retry_ns: u64 = 0,
        admin_retry_ns: u64 = 0,
        ticking: bool = false,
        logging: bool = false,
        // Descriptors and queued record bytes stay stable until the log CQE.
        log_iovecs: [16]std.posix.iovec_const = undefined,
        log_batch_remaining: usize = 0,
        log_disabled: bool = false,
        draining: bool = false,
        stopping: bool = false,
        shutdown_deadline: u64 = 0,
        next_request: u64 = 1,
        rejection_events: u64 = 0,
        tick_interval: linux.kernel_timespec = .{ .sec = 0, .nsec = 10_000_000 },
        active_connections: usize = 0,
        public_free: ?usize = null,
        admin_free: ?usize = null,
        date: [29]u8 = undefined,
        date_second: u64 = std.math.maxInt(u64),
        public_authority: [64]u8 = undefined,
        public_authority_len: usize = 0,
        admin_authority: [64]u8 = undefined,
        admin_authority_len: usize = 0,

        pub const Shared = struct {
            workers: []Self,
            abort: std.atomic.Value(bool) = .init(false),
            ready: std.atomic.Value(usize) = .init(0),
            log_owner: std.atomic.Value(u32) = .init(no_log_owner),
        };
        const no_log_owner = std.math.maxInt(u32);

        const Inspection = struct {
            phase: std.atomic.Value(enum(u8) { idle, requested, ready }) = .init(.idle),
            // Worker zero owns requester. start/page transfer ownership via phase.
            requester: ?struct { index: usize, generation: u32 } = null,
            start: usize = 0,
            page: Page = undefined,
        };

        const Page = struct {
            worker: u32,
            capacity: usize,
            connections: [32]Entry = undefined,
            len: usize = 0,
            next: ?usize = null,

            const Entry = struct {
                id: u64,
                worker: u32,
                admin: bool,
                phase: Connection.Phase,
                requests: u32,
                request: ?u64,
                permit: ?Admission.Decision,
                pending: usize,
                deadline_remaining_ns: u64,
                elapsed_ns: u64,
            };
        };

        const Kind = enum(u8) {
            accept,
            accept_admin,
            tick,
            log_write,
            receive,
            send,
            cancel_receive,
            cancel_send,
            cancel_accept,
            cancel_admin,
            cancel_tick,
            cancel_log,
        };

        const Connection = struct {
            fd: linux.fd_t = -1,
            next_free: ?usize = null,
            active_position: usize = 0,
            generation: u32 = 0,
            admin: bool = false,
            phase: Phase = .reading,
            parser: http.Parser = undefined,
            exchange: App.Exchange = undefined,
            receive_buffer: []u8 = undefined,
            output_buffer: []u8 = undefined,
            application_buffer: []u8 = undefined,
            path_buffer: []u8 = undefined,
            receive_start: usize = 0,
            receive_end: usize = 0,
            output_len: usize = 0,
            output_sent: usize = 0,
            body: []const u8 = "",
            body_sent: usize = 0,
            send_vectors: [2]std.posix.iovec_const = undefined,
            send_message: linux.msghdr_const = undefined,
            response_body_bytes: usize = 0,
            encoder: http.Response.Encoder = undefined,
            streaming: bool = false,
            // A produced fragment that did not fit stays borrowed until the next fill.
            stream_fragment: ?[]const u8 = null,
            receive_pending: bool = false,
            send_pending: bool = false,
            // MSG_MORE must be flushed before waiting for more request bytes.
            more_pending: bool = false,
            more_count: u8 = 0,
            cancel_receive_pending: bool = false,
            cancel_send_pending: bool = false,
            pending: usize = 0,
            interim: bool = false,
            close_after_response: bool = false,
            request_started: bool = false,
            request_completed: bool = false,
            first_byte_recorded: bool = false,
            request_id: u64 = 0,
            started_ns: u64 = 0,
            deadline: u64 = 0,
            requests: u32 = 0,
            response_status: u16 = 0,
            drained_bytes: usize = 0,
            permit: ?Admission.Decision = null,

            const Phase = enum { reading, inspecting, writing, drain, canceling };
        };

        fn token(kind: Kind, index: usize, generation: u32) u64 {
            return (@as(u64, generation) << 32) | (@as(u64, index) << 8) | @intFromEnum(kind);
        }

        fn control(kind: Kind) u64 {
            return token(kind, 0, 0);
        }

        /// Runs on the owning thread after every worker has initialized. Records
        /// errors in failure and signals shared abort before draining pending I/O.
        pub fn workerMain(self: *Self) void {
            self.thread_id.store(std.Thread.getCurrentId(), .monotonic);
            const shared = self.shared.?;
            _ = shared.ready.fetchAdd(1, .release);
            while (shared.ready.load(.acquire) != shared.workers.len) {
                if (shared.abort.load(.monotonic)) return;
                std.Thread.yield() catch {};
            }
            self.loop() catch |err| {
                self.failure = err;
                self.shared.?.abort.store(true, .monotonic);
            };
            // Error cleanup may collect a canceled write without dispatching it.
            self.releaseLog();
        }

        /// Allocates owned ring, listeners, and buffers. Borrows config strings,
        /// io, stop, and shared until deinit; self must stay at a stable address.
        /// Releases acquired resources on error without invoking application hooks.
        pub fn init(self: *Self, gpa: std.mem.Allocator, io: std.Io, config: Config, stop: *const std.atomic.Value(bool), worker_id: u32, shared: *Shared) RunError!void {
            const admission_options = try config.resolveAdmission();
            const count = config.max_connections + if (worker_id == 0) config.admin_connections else 0;
            var transferred = false;
            const entries = std.math.ceilPowerOfTwo(usize, 4 * count + 64) catch return error.InvalidLimit;
            if (entries > 32768) return error.InvalidLimit;
            // SQ slots are reusable after submission. The CQ still accommodates
            // every outstanding receive/send/cancel plus control operations.
            var params = std.mem.zeroes(linux.io_uring_params);
            params.flags = linux.IORING_SETUP_CQSIZE | linux.IORING_SETUP_COOP_TASKRUN;
            params.cq_entries = @intCast(entries);
            var ring = linux.IoUring.init_params(@intCast(@min(entries, 256)), &params) catch |err| switch (err) {
                error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => return error.IoUringResources,
                else => return error.IoUringUnavailable,
            };
            errdefer if (!transferred) ring.deinit();
            // Probe before submitting anything: error cleanup depends on this
            // Linux 6.0 capability even when the SQ/CQ processing path fails.
            try cancelSync(&ring, 0);
            const listener = try platform.listen(config.address, config.port, .{ .reuse_port = true });
            errdefer if (!transferred) platform.close(listener.fd);
            const admin_listener = if (worker_id == 0 and config.admin_connections > 0)
                try platform.listen(config.admin_address, config.admin_port, .{ .backlog = 32 })
            else
                platform.Listener{ .fd = -1, .port = config.admin_port };
            errdefer if (!transferred and admin_listener.fd >= 0) platform.close(admin_listener.fd);
            const connections = try gpa.alloc(Connection, count);
            errdefer if (!transferred) gpa.free(connections);
            const active_slots = try gpa.alloc(usize, count);
            errdefer if (!transferred) gpa.free(active_slots);
            const path_bytes = (http.Parser.Limits{}).max_target_bytes;
            const per_connection = config.header_bytes + config.trailer_bytes + path_bytes + config.receive_bytes +
                config.response_bytes + config.application_bytes;
            const storage_len = std.math.mul(usize, count, per_connection) catch return error.InvalidLimit;
            const storage = try gpa.alloc(u8, storage_len);
            errdefer if (!transferred) gpa.free(storage);
            const log_slots = try gpa.alloc(Logger.Slot, if (config.log_fd != null) config.log_slots else 0);
            errdefer if (!transferred) gpa.free(log_slots);
            self.* = .{
                .config = config,
                .io = io,
                .shared = shared,
                .worker_id = worker_id,
                .public_free = 0,
                .admin_free = if (worker_id == 0 and config.admin_connections > 0) config.max_connections else null,
                .gpa = gpa,
                .ring = ring,
                .listener = listener,
                .admin_listener = admin_listener,
                .connections = connections,
                .active_slots = active_slots,
                .storage = storage,
                .log_slots = log_slots,
                .stop = stop,
            };
            // From here, self owns every resource; its ring is destroyed before
            // freeing any buffer that might still be referenced by the kernel.
            transferred = true;
            self.public_authority_len = defaultAuthority(&self.public_authority, config.address, listener.port).len;
            if (admin_listener.fd >= 0)
                self.admin_authority_len = defaultAuthority(&self.admin_authority, config.admin_address, admin_listener.port).len;
            self.logger.init(log_slots, &self.metrics, config.verbose);
            self.logger.worker = worker_id;
            self.logger.enabled = config.log_fd != null;
            self.admission.init(admission_options, platform.monotonicNs());
            for (connections, 0..) |*connection, index| {
                connection.* = .{
                    .admin = index >= config.max_connections,
                    .next_free = if (index + 1 == config.max_connections or index + 1 == count) null else index + 1,
                };
                var rest = storage[index * per_connection ..][0..per_connection];
                const head = rest[0..config.header_bytes];
                rest = rest[config.header_bytes..];
                const trailers = rest[0..config.trailer_bytes];
                rest = rest[config.trailer_bytes..];
                connection.parser.init(head, trailers, .{
                    .max_body_bytes = config.max_body_bytes,
                    .max_chunk_framing_bytes = config.max_chunk_framing_bytes,
                });
                connection.path_buffer = rest[0..path_bytes];
                rest = rest[path_bytes..];
                connection.receive_buffer = rest[0..config.receive_bytes];
                rest = rest[config.receive_bytes..];
                connection.output_buffer = rest[0..config.response_bytes];
                rest = rest[config.response_bytes..];
                connection.application_buffer = rest;
            }
        }

        /// Releases worker-owned resources. Asserts all I/O has completed; the
        /// owning event-loop thread must have returned before this call.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.pending == 0);
            self.ring.deinit();
            for (self.connections) |connection| if (connection.fd >= 0) platform.close(connection.fd);
            platform.close(self.listener.fd);
            if (self.admin_listener.fd >= 0) platform.close(self.admin_listener.fd);
            self.gpa.free(self.log_slots);
            self.gpa.free(self.storage);
            self.gpa.free(self.active_slots);
            self.gpa.free(self.connections);
            self.* = undefined;
        }

        fn shouldStop(self: *const Self) bool {
            return self.stop.load(.monotonic) or if (self.shared) |shared|
                shared.abort.load(.monotonic)
            else
                false;
        }

        fn queued(self: *Self) void {
            self.pending += 1;
            self.metrics.recorder().add(.io_submissions_total, 1);
        }

        fn loop(self: *Self) RunError!void {
            errdefer {
                if (self.shared) |shared| shared.abort.store(true, .monotonic);
                self.quiesce();
            }
            var completions: [256]linux.io_uring_cqe = undefined;
            while (true) {
                const begin_ns = platform.monotonicNs();
                if (self.shouldStop() and !self.draining) try self.beginShutdown(begin_ns);
                if (!self.stopping) {
                    if (!self.draining) {
                        try self.queueAccept(false);
                        if (self.admin_listener.fd >= 0) try self.queueAccept(true);
                    }
                    if (!self.ticking) {
                        try self.ensureSubmission();
                        _ = self.ring.timeout(control(.tick), &self.tick_interval, 0, 0) catch
                            return error.IoUringResources;
                        self.ticking = true;
                        self.queued();
                    }
                    try self.queueLog();
                }
                self.metrics.set(.io_pending, self.pending);
                self.metrics.set(.connections_active, self.active_connections);
                self.metrics.set(.requests_active, self.admission.active);
                self.metrics.set(.rejections_active, self.admission.rejecting);
                if (self.pending == 0) break;
                self.metrics.recorder().observe(.event_loop_duration_seconds, platform.monotonicNs() - begin_ns);
                _ = self.ring.submit() catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return error.IoUringResources,
                };
                const n = self.ring.copy_cqes(completions[0..self.config.completion_budget], 1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return error.IoUringResources,
                };
                for (completions[0..n], 0..) |completion, index| {
                    self.complete(completion) catch |err| {
                        // copy_cqes already advanced past the whole batch.
                        // Account for its remaining results before draining.
                        for (completions[index + 1 .. n]) |remaining| self.discardCompletion(remaining);
                        return err;
                    };
                }
                if (self.draining and !self.stopping and (self.active_connections == 0 or
                    platform.monotonicNs() >= self.shutdown_deadline)) try self.stopOperations();
            }
        }

        fn discardCompletion(self: *Self, completion: linux.io_uring_cqe) void {
            std.debug.assert(self.pending > 0);
            self.pending -= 1;
            const kind: Kind = @enumFromInt(@as(u8, @truncate(completion.user_data)));
            if ((kind == .accept or kind == .accept_admin) and completion.res >= 0)
                platform.close(completion.res);
        }

        fn quiesce(self: *Self) void {
            if (self.pending == 0) return;
            // No SQPOLL and no second submitting thread: entries not consumed
            // by the kernel cannot acquire buffers while cleanup is running.
            const unsubmitted = (self.ring.sq.sqe_tail -% self.ring.sq.sqe_head) +
                (@atomicLoad(u32, self.ring.sq.tail, .acquire) -% @atomicLoad(u32, self.ring.sq.head, .acquire));
            std.debug.assert(unsubmitted <= self.pending);
            self.pending -= unsubmitted;
            if (self.pending == 0) return;
            for (self.connections, 0..) |connection, index| {
                if (connection.fd < 0) continue;
                const kinds = [_]Kind{
                    .receive,
                    .send,
                    .cancel_receive,
                    .cancel_send,
                };
                for (kinds) |kind| {
                    // Cancel by unique token, without ALL: an in-progress
                    // operation must finish before its cancellation returns.
                    cancelSync(&self.ring, token(kind, index, connection.generation)) catch
                        @panic("previously available synchronous cancellation failed");
                }
            }
            const controls = [_]Kind{
                .accept,
                .accept_admin,
                .tick,
                .log_write,
                .cancel_accept,
                .cancel_admin,
                .cancel_tick,
                .cancel_log,
            };
            for (controls) |kind| cancelSync(&self.ring, control(kind)) catch
                @panic("previously available synchronous cancellation failed");
            var completions: [256]linux.io_uring_cqe = undefined;
            while (self.pending > 0) {
                const count = self.ring.copy_cqes(&completions, 1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    // A private, preflighted ring must remain usable for CQ
                    // collection. Never free referenced memory on violation.
                    else => @panic("unable to collect canceled I/O completions"),
                };
                for (completions[0..count]) |completion| self.discardCompletion(completion);
            }
        }

        fn queueAccept(self: *Self, admin: bool) RunError!void {
            if (if (admin) self.admin_accepting else self.accepting) return;
            const retry_ns = if (admin) self.admin_retry_ns else self.accept_retry_ns;
            if (retry_ns != 0 and platform.monotonicNs() < retry_ns) return;
            if (self.freeSlot(admin) == null) return;
            const kind: Kind = if (admin) .accept_admin else .accept;
            const fd = if (admin) self.admin_listener.fd else self.listener.fd;
            try self.ensureSubmission();
            _ = self.ring.accept(control(kind), fd, null, null, linux.SOCK.CLOEXEC) catch
                return error.IoUringResources;
            if (admin) self.admin_accepting = true else self.accepting = true;
            self.queued();
        }

        fn freeSlot(self: *Self, admin: bool) ?usize {
            return if (admin) self.admin_free else self.public_free;
        }

        fn ensureSubmission(self: *Self) RunError!void {
            while (self.ring.sq_ready() == self.ring.sq.sqes.len) {
                _ = self.ring.submit() catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return error.IoUringResources,
                };
            }
        }

        fn queueLog(self: *Self) RunError!void {
            if (self.logging or self.log_disabled) return;
            const log_fd = self.config.log_fd orelse return;
            if (self.logger.peek() == null) return;
            if (self.shared) |shared| {
                const owner = shared.log_owner.load(.monotonic);
                if (owner != self.worker_id and
                    shared.log_owner.cmpxchgStrong(no_log_owner, self.worker_id, .acquire, .monotonic) != null) return;
            }
            try self.ensureSubmission();
            // Keep the selected prefix fixed across short writes so a worker
            // cannot extend its log ownership indefinitely as records arrive.
            if (self.log_batch_remaining == 0)
                self.log_batch_remaining = @min(self.logger.count, self.log_iovecs.len);
            for (self.log_iovecs[0..self.log_batch_remaining], 0..) |*vector, index| {
                const slot = self.logger.peekAt(index).?;
                vector.* = .{ .base = slot.bytes[slot.sent..].ptr, .len = slot.len - slot.sent };
            }
            const sqe = self.ring.writev(control(.log_write), log_fd, self.log_iovecs[0..self.log_batch_remaining], std.math.maxInt(u64)) catch
                return error.IoUringResources;
            sqe.flags |= linux.IOSQE_ASYNC;
            self.logging = true;
            self.queued();
        }

        fn releaseLog(self: *Self) void {
            if (self.shared) |shared| {
                _ = shared.log_owner.cmpxchgStrong(self.worker_id, no_log_owner, .release, .monotonic);
            }
        }

        fn complete(self: *Self, completion: linux.io_uring_cqe) RunError!void {
            std.debug.assert(self.pending > 0);
            self.pending -= 1;
            self.metrics.recorder().add(.io_completions_total, 1);
            const kind: Kind = @enumFromInt(@as(u8, @truncate(completion.user_data)));
            if (self.config.verbose and kind != .log_write and kind != .tick) self.logger.emit(.{
                .timestamp_ns = platform.realtimeNs(self.io),
                .level = .debug,
                .event = "io_completion",
                .operation = @tagName(kind),
                .connection = if (completion.user_data >> 32 != 0) completion.user_data & ~@as(u64, 255) else null,
                .result = completion.res,
            });
            switch (kind) {
                .accept, .accept_admin => {
                    const admin = kind == .accept_admin;
                    if (admin) self.admin_accepting = false else self.accepting = false;
                    if (completion.res < 0) {
                        if (completion.res == -@as(i32, @intFromEnum(linux.E.CANCELED))) return;
                        if (completion.res == -@as(i32, @intFromEnum(linux.E.INVAL)) or
                            completion.res == -@as(i32, @intFromEnum(linux.E.NOSYS)) or
                            completion.res == -@as(i32, @intFromEnum(linux.E.OPNOTSUPP)))
                            return error.IoUringOperationUnsupported;
                        self.metrics.recorder().add(.io_errors_total, 1);
                        // Descriptor/memory exhaustion must not become a loop
                        // of immediately failing accepts that consumes the CPU.
                        const retry = platform.monotonicNs() + 100_000_000;
                        if (admin) self.admin_retry_ns = retry else self.accept_retry_ns = retry;
                        self.logger.emit(.{
                            .timestamp_ns = platform.realtimeNs(self.io),
                            .level = .warn,
                            .event = "accept_error",
                            .operation = @tagName(kind),
                            .result = completion.res,
                        });
                        return;
                    }
                    if (admin) self.admin_retry_ns = 0 else self.accept_retry_ns = 0;
                    const fd = completion.res;
                    const index = self.freeSlot(admin) orelse {
                        platform.close(fd);
                        self.metrics.recorder().add(.connections_refused_total, 1);
                        return;
                    };
                    if (self.draining) {
                        platform.close(fd);
                        return;
                    }
                    platform.setOption(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1) catch {
                        platform.close(fd);
                        self.metrics.recorder().add(.io_errors_total, 1);
                        return;
                    };
                    const connection = &self.connections[index];
                    if (admin) self.admin_free = connection.next_free else self.public_free = connection.next_free;
                    connection.next_free = null;
                    connection.fd = fd;
                    connection.generation +%= 1;
                    connection.phase = .reading;
                    connection.requests = 0;
                    connection.receive_start = 0;
                    connection.receive_end = 0;
                    connection.pending = 0;
                    connection.receive_pending = false;
                    connection.send_pending = false;
                    connection.more_pending = false;
                    connection.more_count = 0;
                    connection.cancel_receive_pending = false;
                    connection.cancel_send_pending = false;
                    connection.permit = null;
                    connection.drained_bytes = 0;
                    self.prepareRequest(connection, platform.monotonicNs());
                    connection.active_position = self.active_connections;
                    self.active_slots[self.active_connections] = index;
                    self.active_connections += 1;
                    self.metrics.recorder().add(.connections_accepted_total, 1);
                    self.event(index, .debug, "connection_accepted", null);
                    try self.queueReceive(index);
                },
                .tick => {
                    self.ticking = false;
                    if (!self.stopping) try self.tick();
                },
                .log_write => {
                    self.logging = false;
                    if (completion.res <= 0) {
                        self.metrics.recorder().add(.log_write_errors_total, 1);
                        self.log_disabled = true;
                        self.releaseLog();
                        while (self.logger.peek() != null) self.logger.consume();
                    } else {
                        self.log_batch_remaining -= self.logger.consumeBytes(@intCast(completion.res));
                        if (self.log_batch_remaining == 0) self.releaseLog();
                    }
                },
                .cancel_accept, .cancel_admin, .cancel_tick, .cancel_log => {},
                .receive, .send, .cancel_receive, .cancel_send => {
                    const index: usize = @intCast((completion.user_data >> 8) & 0xffffff);
                    const generation: u32 = @truncate(completion.user_data >> 32);
                    const connection = &self.connections[index];
                    std.debug.assert(connection.fd >= 0 and connection.generation == generation);
                    std.debug.assert(connection.pending > 0);
                    connection.pending -= 1;
                    switch (kind) {
                        .receive => {
                            connection.receive_pending = false;
                            if (connection.phase != .canceling) try self.received(index, completion.res);
                        },
                        .send => {
                            connection.send_pending = false;
                            if (connection.phase != .canceling) try self.sent(index, completion.res);
                        },
                        .cancel_receive => connection.cancel_receive_pending = false,
                        .cancel_send => connection.cancel_send_pending = false,
                        else => unreachable,
                    }
                    if (connection.phase == .canceling) self.finishClose(index);
                },
            }
        }

        fn prepareRequest(self: *Self, connection: *Connection, now: u64) void {
            connection.parser.init(connection.parser.head_storage, connection.parser.trailer_storage, .{
                .max_body_bytes = self.config.max_body_bytes,
                .max_chunk_framing_bytes = self.config.max_chunk_framing_bytes,
            });
            connection.exchange.init(connection.application_buffer);
            connection.request_started = false;
            connection.request_completed = false;
            connection.first_byte_recorded = false;
            connection.output_len = 0;
            connection.output_sent = 0;
            connection.body = "";
            connection.body_sent = 0;
            connection.response_body_bytes = 0;
            connection.streaming = false;
            connection.stream_fragment = null;
            connection.close_after_response = false;
            connection.interim = false;
            connection.deadline = now + @as(u64, self.config.idle_timeout_ms) * 1_000_000;
        }

        fn queueReceive(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            if (connection.more_pending) {
                // A fragmented next request must not hold an earlier response.
                const enabled: c_int = 1;
                if (linux.errno(linux.setsockopt(connection.fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&enabled), @sizeOf(c_int))) != .SUCCESS) {
                    try self.forceClose(index);
                    return;
                }
                connection.more_pending = false;
                connection.more_count = 0;
            }
            if (connection.receive_pending) return;
            std.debug.assert(connection.receive_start == connection.receive_end or connection.phase == .drain);
            connection.receive_start = 0;
            connection.receive_end = 0;
            try self.ensureSubmission();
            _ = self.ring.recv(token(.receive, index, connection.generation), connection.fd, .{
                .buffer = connection.receive_buffer,
            }, 0) catch return error.IoUringResources;
            connection.receive_pending = true;
            connection.pending += 1;
            self.queued();
        }

        fn received(self: *Self, index: usize, result: i32) RunError!void {
            const connection = &self.connections[index];
            if (result <= 0) {
                if (result < 0 and connection.phase == .writing) return;
                if (connection.phase == .drain and (result == -@as(i32, @intFromEnum(linux.E.CANCELED)) or
                    result == -@as(i32, @intFromEnum(linux.E.INTR))))
                {
                    // The deadline canceled the old body/header read. Its CQE
                    // can arrive after the final response send has completed.
                    try self.queueReceive(index);
                    return;
                }
                self.metrics.recorder().add(.peer_disconnects_total, 1);
                if (connection.phase == .reading and connection.request_started and result == 0) {
                    connection.parser.eof() catch {
                        try self.reject(index, 400, "UnexpectedEof");
                        return;
                    };
                }
                try self.forceClose(index);
                return;
            }
            const count: usize = @intCast(result);
            self.metrics.recorder().add(.bytes_received_total, count);
            if (connection.phase == .drain) {
                connection.drained_bytes += count;
                if (connection.drained_bytes >= 64 * 1024) {
                    try self.forceClose(index);
                } else try self.queueReceive(index);
                return;
            }
            if (connection.phase != .reading) return;
            connection.receive_end = count;
            connection.receive_start = 0;
            try self.processInput(index);
        }

        fn processInput(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            while (connection.phase == .reading) {
                if (!connection.request_started and connection.receive_start < connection.receive_end) {
                    connection.request_started = true;
                    connection.started_ns = platform.monotonicNs();
                    connection.deadline = connection.started_ns + @as(u64, self.config.header_timeout_ms) * 1_000_000;
                    connection.request_id = self.next_request;
                    self.next_request +%= 1;
                    self.metrics.recorder().add(.requests_total, 1);
                }
                if (!connection.admin and connection.request_started and connection.parser.phase == .head and
                    self.admission.exhausted(self.draining))
                {
                    self.admission.refill(platform.monotonicNs());
                    if (self.admission.exhausted(self.draining)) {
                        // No application work or HTTP response can be admitted.
                        // Avoid parsing more bytes solely to decide to close.
                        connection.permit = .close;
                        self.metrics.recorder().add(.requests_rejected_total, 1);
                        self.metrics.recorder().add(.requests_closed_before_head_total, 1);
                        self.metrics.recorder().add(.rejection_aborted_total, 1);
                        self.rejectionEvent(index, "admission_before_head");
                        try self.forceClose(index);
                        return;
                    }
                }
                const step = connection.parser.feed(connection.receive_buffer[connection.receive_start..connection.receive_end]) catch |err| {
                    self.metrics.recorder().add(.protocol_errors_total, 1);
                    try self.reject(index, http.Parser.status(err), @errorName(err));
                    return;
                };
                connection.receive_start += step.consumed;
                switch (step.event) {
                    .need_input => {
                        try self.queueReceive(index);
                        return;
                    },
                    .head => |request| {
                        const now = platform.monotonicNs();
                        self.metrics.recorder().observe(.header_duration_seconds, now - connection.started_ns);
                        connection.deadline = now + @as(u64, self.config.body_timeout_ms) * 1_000_000;
                        if (request.scheme) |scheme| {
                            if (!http.syntax.eql(scheme, "http")) {
                                try self.reject(index, 421, "target_scheme");
                                return;
                            }
                        }
                        // Raw target/headers keep their original octets. Only the
                        // routing view is canonicalized, in separate stable storage.
                        connection.parser.request.path = http.path.normalize(connection.path_buffer, request.path) catch {
                            try self.reject(index, 400, "target_path");
                            return;
                        };
                        if (request.scheme == null and !std.mem.eql(u8, request.method, "CONNECT")) {
                            connection.parser.request.scheme = "http";
                            if (request.authority.len == 0) {
                                connection.parser.request.authority = if (connection.admin)
                                    self.admin_authority[0..self.admin_authority_len]
                                else
                                    self.public_authority[0..self.public_authority_len];
                            }
                        }
                        if (!connection.admin) {
                            const decision = self.admission.acquire(now, self.draining);
                            connection.permit = decision;
                            switch (decision) {
                                .admit => self.metrics.recorder().add(.requests_admitted_total, 1),
                                .reject => {
                                    self.metrics.recorder().add(.requests_rejected_total, 1);
                                    self.rejectionEvent(index, "admission_limit");
                                    // Only a bodyless head is a complete request
                                    // boundary. Unread bodies require closure.
                                    try self.respondStatus(index, 503, request.chunked or
                                        (request.content_length orelse 0) > 0);
                                    return;
                                },
                                .close => {
                                    self.metrics.recorder().add(.requests_rejected_total, 1);
                                    self.metrics.recorder().add(.rejection_aborted_total, 1);
                                    self.rejectionEvent(index, "rejection_budget");
                                    try self.forceClose(index);
                                    return;
                                },
                            }
                            if (connection.exchange.receiveHead(request)) |response| {
                                var early = response;
                                early.close = early.close or request.chunked or (request.content_length orelse 0) > 0;
                                try self.startResponse(index, early);
                                return;
                            }
                        } else if (try self.receiveAdminHead(index)) return;
                        self.event(index, .debug, "request_head", null);
                        if (request.expect_continue and (request.chunked or (request.content_length orelse 0) > 0)) {
                            const interim = "HTTP/1.1 100 Continue\r\n\r\n";
                            @memcpy(connection.output_buffer[0..interim.len], interim);
                            connection.output_len = interim.len;
                            connection.output_sent = 0;
                            connection.interim = true;
                            connection.phase = .writing;
                            connection.deadline = @min(connection.deadline, platform.monotonicNs() +
                                @as(u64, self.config.write_timeout_ms) * 1_000_000);
                            self.metrics.recorder().response(100);
                            try self.queueSend(index);
                            return;
                        }
                    },
                    .body => |bytes| if (!connection.admin) {
                        connection.exchange.receiveBody(bytes) catch |err| {
                            try self.reject(index, 413, @errorName(err));
                            return;
                        };
                    },
                    .trailer => {},
                    .end => {
                        if (connection.admin) {
                            try self.respondAdmin(index);
                        } else try self.startResponse(index, connection.exchange.respond(&connection.parser.request));
                        return;
                    },
                }
            }
        }

        fn respondStatus(self: *Self, index: usize, status: u16, close: bool) RunError!void {
            const connection = &self.connections[index];
            const allow = if (connection.admin) "GET, HEAD, OPTIONS" else connection.exchange.allowedMethods();
            const body = http.Response.errorBody(status);
            const fields = [_]http.Header{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "Allow", .value = allow },
            };
            const headers: []const http.Header = if (status == 405) &fields else if (body.len > 0) fields[0..1] else &.{};
            try self.startResponse(index, .{
                .status = status,
                .headers = headers,
                .body = .{ .bytes = body },
                .close = close,
            });
        }

        fn reject(self: *Self, index: usize, status: u16, reason: []const u8) RunError!void {
            const connection = &self.connections[index];
            self.rejectionEvent(index, reason);
            if (connection.permit == null and !connection.admin) {
                self.admission.refill(platform.monotonicNs());
                connection.permit = self.admission.acquireRejection();
                if (connection.permit == .close) {
                    self.metrics.recorder().add(.rejection_aborted_total, 1);
                    try self.forceClose(index);
                    return;
                }
            }
            try self.respondStatus(index, status, true);
        }

        fn receiveAdminHead(self: *Self, index: usize) RunError!bool {
            const connection = &self.connections[index];
            const request = &connection.parser.request;
            if (std.mem.eql(u8, request.method, "OPTIONS")) {
                try self.startResponse(index, .{
                    .status = 204,
                    .headers = &.{.{ .name = "Allow", .value = "GET, HEAD, OPTIONS" }},
                    .close = request.chunked or (request.content_length orelse 0) > 0,
                });
                return true;
            }
            if (!std.mem.eql(u8, request.method, "GET") and !std.mem.eql(u8, request.method, "HEAD")) {
                try self.respondStatus(index, 501, true);
                return true;
            }
            const known = for ([_][]const u8{
                "/metrics",
                "/debug/metrics",
                "/debug/config",
                "/debug/connections",
                "/debug/workers",
                "/healthz",
            }) |path| {
                if (std.mem.eql(u8, request.path, path)) break true;
            } else false;
            if (!known) {
                try self.respondStatus(index, 404, true);
                return true;
            }
            if (std.mem.eql(u8, request.path, "/debug/connections")) {
                _ = self.connectionStart(request.query) catch {
                    try self.respondStatus(index, 400, true);
                    return true;
                };
            } else if (std.mem.eql(u8, request.path, "/debug/workers")) {
                _ = parseStart(request.query, self.config.workers) catch {
                    try self.respondStatus(index, 400, true);
                    return true;
                };
            }
            if (self.draining and std.mem.eql(u8, request.path, "/healthz")) {
                try self.respondStatus(index, 503, true);
                return true;
            }
            const precondition = http.conditions.evaluate(request, .{}, platform.realtimeNs(self.io) / 1_000_000_000) catch {
                try self.respondStatus(index, 400, true);
                return true;
            };
            if (precondition) |status| {
                try self.startResponse(index, .{
                    .status = status,
                    // A 304 length must describe the selected representation,
                    // which has not been generated for these dynamic resources.
                    .body = if (status == 304) .{ .stream = null } else .{ .bytes = http.Response.errorBody(status) },
                    .headers = if (status == 304)
                        &.{.{ .name = "Cache-Control", .value = "no-store" }}
                    else
                        &.{
                            .{ .name = "Cache-Control", .value = "no-store" },
                            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                        },
                    .close = request.chunked or (request.content_length orelse 0) > 0,
                });
                return true;
            }
            return false;
        }

        fn respondAdmin(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            const request = &connection.parser.request;
            var writer = std.Io.Writer.fixed(connection.application_buffer);
            var content_type: []const u8 = "application/json";
            if (std.mem.eql(u8, request.path, "/metrics")) {
                const snapshot = self.aggregateMetrics();
                metrics_format.prometheus.write(&snapshot, &writer) catch {
                    try self.respondStatus(index, 500, true);
                    return;
                };
                content_type = metrics_format.prometheus.content_type;
            } else if (std.mem.eql(u8, request.path, "/debug/metrics")) {
                const snapshot = self.aggregateMetrics();
                metrics_format.json.write(&snapshot, &writer) catch {
                    try self.respondStatus(index, 500, true);
                    return;
                };
                content_type = metrics_format.json.content_type;
            } else if (std.mem.eql(u8, request.path, "/debug/config")) {
                std.json.Stringify.value(self.config, .{}, &writer) catch {
                    try self.respondStatus(index, 500, true);
                    return;
                };
            } else if (std.mem.eql(u8, request.path, "/debug/connections")) {
                try self.inspectConnections(index);
                return;
            } else if (std.mem.eql(u8, request.path, "/debug/workers")) {
                self.writeWorkers(&writer, request.query) catch |err| {
                    try self.respondStatus(index, if (err == error.InvalidQuery) 400 else 500, true);
                    return;
                };
            } else if (std.mem.eql(u8, request.path, "/healthz")) {
                try self.respondStatus(index, if (self.draining or self.shouldStop()) 503 else 200, false);
                return;
            } else {
                try self.respondStatus(index, 404, false);
                return;
            }
            const fields = [_]http.Header{
                .{ .name = "Content-Type", .value = content_type },
                .{ .name = "Cache-Control", .value = "no-store" },
            };
            try self.startResponse(index, .{ .headers = &fields, .body = .{ .bytes = writer.buffered() } });
        }

        fn aggregateMetrics(self: *const Self) Metrics.Snapshot {
            const shared = self.shared orelse return self.metrics.snapshot();
            var result: Metrics.Snapshot = .{};
            for (shared.workers) |*worker| {
                const captured = worker.metrics.snapshot();
                result.merge(&captured);
            }
            return result;
        }

        fn capacity(self: *const Self) usize {
            return self.config.workers * self.config.max_connections + self.config.admin_connections;
        }

        fn parseStart(query: []const u8, limit: usize) error{InvalidQuery}!usize {
            if (query.len == 0) return 0;
            if (!std.mem.startsWith(u8, query, "start=")) return error.InvalidQuery;
            const start = std.fmt.parseInt(usize, query[6..], 10) catch return error.InvalidQuery;
            if (start > limit) return error.InvalidQuery;
            return start;
        }

        fn connectionStart(self: *const Self, query: []const u8) error{InvalidQuery}!usize {
            return parseStart(query, self.capacity());
        }

        fn connectionPage(self: *const Self, start: usize) Page {
            const now = platform.monotonicNs();
            const base = self.worker_id * self.config.max_connections +
                (if (self.worker_id == 0) @as(usize, 0) else self.config.admin_connections);
            var result: Page = .{
                .worker = self.worker_id,
                .capacity = self.capacity(),
            };
            var index = start;
            while (index < self.connections.len and result.len < result.connections.len) : (index += 1) {
                const connection = &self.connections[index];
                if (connection.fd < 0) continue;
                result.connections[result.len] = .{
                    .id = token(.receive, index, connection.generation) & ~@as(u64, 255),
                    .worker = self.worker_id,
                    .admin = connection.admin,
                    .phase = connection.phase,
                    .requests = connection.requests,
                    .request = if (connection.request_started) connection.request_id else null,
                    .permit = connection.permit,
                    .pending = connection.pending,
                    .deadline_remaining_ns = connection.deadline -| now,
                    .elapsed_ns = if (connection.request_started) now - connection.started_ns else 0,
                };
                result.len += 1;
            }
            if (base + index < result.capacity) result.next = base + index;
            return result;
        }

        fn inspectConnections(self: *Self, index: usize) RunError!void {
            const start = self.connectionStart(self.connections[index].parser.request.query) catch {
                try self.respondStatus(index, 400, true);
                return;
            };
            const first_count = self.config.max_connections + self.config.admin_connections;
            if (start < first_count or self.config.workers == 1) {
                const page = self.connectionPage(start);
                try self.respondPage(index, &page);
                return;
            }
            const id = @min(1 + (start - first_count) / self.config.max_connections, self.config.workers - 1);
            const inspection = &self.shared.?.workers[id].inspection;
            if (inspection.phase.load(.acquire) != .idle) {
                try self.respondStatus(index, 503, true);
                return;
            }
            inspection.start = start - first_count - (id - 1) * self.config.max_connections;
            inspection.requester = .{ .index = index, .generation = self.connections[index].generation };
            self.connections[index].phase = .inspecting;
            inspection.phase.store(.requested, .release);
        }

        fn captureInspection(self: *Self) void {
            if (self.inspection.phase.load(.acquire) != .requested) return;
            self.inspection.page = self.connectionPage(self.inspection.start);
            self.inspection.phase.store(.ready, .release);
        }

        fn finishInspections(self: *Self) RunError!void {
            const shared = self.shared orelse return;
            for (shared.workers[1..]) |*worker| {
                const inspection = &worker.inspection;
                if (inspection.phase.load(.acquire) != .ready) continue;
                defer inspection.phase.store(.idle, .release);
                const requester = inspection.requester.?;
                inspection.requester = null;
                const connection = &self.connections[requester.index];
                if (connection.fd < 0 or connection.generation != requester.generation or
                    connection.phase != .inspecting) continue;
                try self.respondPage(requester.index, &inspection.page);
            }
        }

        fn respondPage(self: *Self, index: usize, page: *const Page) RunError!void {
            var writer = std.Io.Writer.fixed(self.connections[index].application_buffer);
            const captured = self.aggregateMetrics();
            std.json.Stringify.value(.{
                .capacity = page.capacity,
                .active = captured.gauge(.connections_active),
                .worker = page.worker,
                .connections = page.connections[0..page.len],
                .next = page.next,
            }, .{}, &writer) catch {
                try self.respondStatus(index, 500, true);
                return;
            };
            try self.startResponse(index, .{
                .headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "Cache-Control", .value = "no-store" },
                },
                .body = .{ .bytes = writer.buffered() },
            });
        }

        fn writeWorkers(self: *const Self, writer: *std.Io.Writer, query: []const u8) (std.Io.Writer.Error || error{InvalidQuery})!void {
            const start = try parseStart(query, self.config.workers);
            const end = @min(start + 32, self.config.workers);
            var json: std.json.Stringify = .{ .writer = writer };
            try json.beginObject();
            try json.objectField("workers");
            try json.beginArray();
            for (self.shared.?.workers[start..end]) |*worker| {
                const captured = worker.metrics.snapshot();
                try json.write(.{
                    .id = worker.worker_id,
                    .thread = worker.thread_id.load(.monotonic),
                    .sq_entries = worker.ring.sq.sqes.len,
                    .cq_entries = worker.ring.cq.cqes.len,
                    .connection_capacity = worker.config.max_connections,
                    .connections_active = captured.gauge(.connections_active),
                    .requests_active = captured.gauge(.requests_active),
                    .requests_admitted_total = captured.counter(.requests_admitted_total),
                    .requests_rejected_total = captured.counter(.requests_rejected_total),
                    .requests_completed_total = captured.counter(.requests_completed_total),
                });
            }
            try json.endArray();
            try json.objectField("next");
            try json.write(if (end < self.config.workers) @as(?usize, end) else null);
            try json.endObject();
        }

        fn startResponse(self: *Self, index: usize, initial: http.Response) RunError!void {
            const connection = &self.connections[index];
            var response = initial;
            if (response.status < 200) {
                self.event(index, .@"error", "invalid_final_status", null);
                try self.forceClose(index);
                return;
            }
            response.close = response.close or self.draining or
                connection.requests + 1 >= self.config.max_requests_per_connection;
            const second = platform.realtimeNs(self.io) / 1_000_000_000;
            if (second != self.date_second) {
                http.Response.formatDate(second, &self.date);
                self.date_second = second;
            }
            var writer = std.Io.Writer.fixed(connection.output_buffer);
            const encoder = response.begin(&writer, &connection.parser.request, &self.date) catch {
                self.event(index, .@"error", "response_invalid", null);
                try self.forceClose(index);
                return;
            };
            connection.output_sent = 0;
            connection.body_sent = 0;
            connection.encoder = encoder;
            connection.streaming = response.body == .stream and encoder.mode != .suppressed;
            connection.body = switch (response.body) {
                .bytes => |bytes| if (encoder.mode == .suppressed) "" else bytes,
                .stream => "",
            };
            connection.response_body_bytes = connection.body.len;
            if (connection.body.len <= connection.output_buffer.len - writer.buffered().len) {
                writer.writeAll(connection.body) catch unreachable;
                connection.body = "";
            }
            connection.output_len = writer.buffered().len;
            connection.close_after_response = encoder.close;
            connection.interim = false;
            connection.response_status = response.status;
            connection.phase = .writing;
            connection.deadline = platform.monotonicNs() + @as(u64, self.config.write_timeout_ms) * 1_000_000;
            self.metrics.recorder().response(response.status);
            try self.queueSend(index);
        }

        fn queueSend(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            std.debug.assert(!connection.send_pending);
            const bytes = if (connection.output_sent < connection.output_len)
                connection.output_buffer[connection.output_sent..connection.output_len]
            else
                connection.body[connection.body_sent..];
            std.debug.assert(bytes.len > 0);
            try self.ensureSubmission();
            const more = !connection.admin and !connection.interim and
                !connection.streaming and !connection.close_after_response and
                connection.body_sent == connection.body.len and bytes.len <= 4096 and
                connection.more_count < 15 and connection.receive_start < connection.receive_end and
                std.mem.indexOf(u8, connection.receive_buffer[connection.receive_start..connection.receive_end], "\r\n\r\n") != null;
            connection.more_pending = more;
            connection.more_count = if (more) connection.more_count + 1 else 0;
            const send_flags = linux.MSG.NOSIGNAL | @as(u32, if (more) linux.MSG.MORE else 0);
            if (connection.output_sent < connection.output_len and connection.body_sent < connection.body.len) {
                connection.send_vectors = .{
                    .{ .base = bytes.ptr, .len = bytes.len },
                    .{
                        .base = connection.body[connection.body_sent..].ptr,
                        .len = connection.body.len - connection.body_sent,
                    },
                };
                connection.send_message = .{
                    .name = null,
                    .namelen = 0,
                    .iov = &connection.send_vectors,
                    .iovlen = 2,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };
                _ = self.ring.sendmsg(token(.send, index, connection.generation), connection.fd, &connection.send_message, send_flags) catch return error.IoUringResources;
            } else {
                _ = self.ring.send(token(.send, index, connection.generation), connection.fd, bytes, send_flags) catch
                    return error.IoUringResources;
            }
            connection.send_pending = true;
            connection.pending += 1;
            self.queued();
        }

        fn fillStream(connection: *Connection) !void {
            var writer = std.Io.Writer.fixed(connection.output_buffer);
            const buffer = connection.application_buffer[0..@min(
                connection.application_buffer.len,
                connection.output_buffer.len - 32,
            )];
            // Bound producer calls as well as bytes. The producer sees the same
            // destination capacity on every call, including near a batch boundary.
            for (0..16) |_| {
                if (writer.unusedCapacityLen() <= 32) break;
                const fragment = if (connection.stream_fragment) |bytes|
                    bytes
                else
                    connection.exchange.produce(buffer);
                if (fragment) |bytes| {
                    if (bytes.len == 0) return error.EmptyStreamFragment;
                    if (writer.buffered().len > 0 and bytes.len > writer.unusedCapacityLen() - 32) {
                        connection.stream_fragment = bytes;
                        break;
                    }
                    connection.stream_fragment = null;
                    try connection.encoder.write(&writer, bytes);
                    connection.response_body_bytes += bytes.len;
                } else {
                    try connection.encoder.end(&writer);
                    connection.streaming = false;
                    break;
                }
            }
            connection.output_sent = 0;
            connection.output_len = writer.buffered().len;
        }

        fn sent(self: *Self, index: usize, result: i32) RunError!void {
            const connection = &self.connections[index];
            if (result <= 0) {
                self.metrics.recorder().add(.io_errors_total, 1);
                try self.forceClose(index);
                return;
            }
            const count: usize = @intCast(result);
            self.metrics.recorder().add(.bytes_sent_total, count);
            const first_ns = if (!connection.interim and !connection.first_byte_recorded)
                platform.monotonicNs()
            else
                null;
            if (!connection.interim and !connection.first_byte_recorded) {
                connection.first_byte_recorded = true;
                if (!connection.admin) self.metrics.recorder().observe(.time_to_first_byte_seconds, first_ns.? - connection.started_ns);
            }
            const head_count = @min(count, connection.output_len - connection.output_sent);
            connection.output_sent += head_count;
            connection.body_sent += count - head_count;
            if (connection.output_sent < connection.output_len or connection.body_sent < connection.body.len) {
                try self.queueSend(index);
                return;
            }
            if (connection.interim) {
                connection.interim = false;
                connection.phase = .reading;
                connection.deadline = platform.monotonicNs() + @as(u64, self.config.body_timeout_ms) * 1_000_000;
                try self.processInput(index);
                return;
            }
            if (connection.streaming) {
                fillStream(connection) catch |err| {
                    if (err == error.EmptyStreamFragment)
                        self.event(index, .@"error", "empty_stream_fragment", null);
                    try self.forceClose(index);
                    return;
                };
                if (connection.output_len > 0) {
                    try self.queueSend(index);
                    return;
                }
            }
            self.metrics.recorder().add(.requests_completed_total, 1);
            connection.request_completed = true;
            const completed_ns = first_ns orelse platform.monotonicNs();
            const duration = completed_ns - connection.started_ns;
            if (connection.admin) {
                self.metrics.recorder().observe(.admin_duration_seconds, duration);
            } else {
                self.metrics.recorder().observe(.request_duration_seconds, duration);
                self.metrics.recorder().observe(if (connection.permit == .admit) .admitted_duration_seconds else .rejected_duration_seconds, duration);
            }
            if (self.config.access_log and (connection.permit != .reject or self.config.verbose)) self.logger.emit(.{
                .timestamp_ns = platform.realtimeNs(self.io),
                .event = "request_complete",
                .connection = token(.receive, index, connection.generation) & ~@as(u64, 255),
                .request = connection.request_id,
                .status = connection.response_status,
                .method = connection.parser.request.method,
                .duration_ns = duration,
                .bytes = connection.response_body_bytes,
            });
            connection.requests += 1;
            if (connection.close_after_response) {
                connection.phase = .drain;
                connection.deadline = completed_ns + @as(u64, self.config.close_timeout_ms) * 1_000_000;
                _ = linux.shutdown(connection.fd, linux.SHUT.WR);
                connection.receive_start = connection.receive_end;
                try self.queueReceive(index);
            } else {
                self.releasePermit(connection);
                self.prepareRequest(connection, completed_ns);
                connection.phase = .reading;
                try self.processInput(index);
            }
        }

        fn releasePermit(self: *Self, connection: *Connection) void {
            if (connection.permit) |permit| self.admission.release(permit);
            connection.permit = null;
        }

        fn forceClose(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            connection.phase = .canceling;
            if (connection.receive_pending and !connection.cancel_receive_pending) {
                try self.ensureSubmission();
                _ = self.ring.cancel(token(.cancel_receive, index, connection.generation), token(.receive, index, connection.generation), 0) catch
                    return error.IoUringResources;
                connection.cancel_receive_pending = true;
                connection.pending += 1;
                self.queued();
            }
            if (connection.send_pending and !connection.cancel_send_pending) {
                try self.ensureSubmission();
                _ = self.ring.cancel(token(.cancel_send, index, connection.generation), token(.send, index, connection.generation), 0) catch
                    return error.IoUringResources;
                connection.cancel_send_pending = true;
                connection.pending += 1;
                self.queued();
            }
            self.finishClose(index);
        }

        fn finishClose(self: *Self, index: usize) void {
            const connection = &self.connections[index];
            if (connection.pending != 0 or connection.fd < 0) return;
            if (connection.request_started and !connection.request_completed) {
                self.metrics.recorder().add(.requests_aborted_total, 1);
                if (!connection.admin) self.metrics.recorder().observe(.aborted_duration_seconds, platform.monotonicNs() - connection.started_ns);
            }
            self.event(index, .debug, "connection_closed", null);
            platform.close(connection.fd);
            connection.fd = -1;
            if (connection.admin) {
                connection.next_free = self.admin_free;
                self.admin_free = index;
            } else {
                connection.next_free = self.public_free;
                self.public_free = index;
            }
            self.releasePermit(connection);
            self.active_connections -= 1;
            const moved = self.active_slots[self.active_connections];
            self.active_slots[connection.active_position] = moved;
            self.connections[moved].active_position = connection.active_position;
            self.metrics.recorder().add(.connections_closed_total, 1);
        }

        fn tick(self: *Self) RunError!void {
            const now = platform.monotonicNs();
            self.captureInspection();
            if (self.worker_id == 0) try self.finishInspections();
            self.admission.refill(now);
            var position = self.active_connections;
            while (position > 0) {
                position -= 1;
                const index = self.active_slots[position];
                const connection = &self.connections[index];
                if (connection.phase == .canceling or now < connection.deadline) continue;
                if (connection.phase == .drain) {
                    try self.forceClose(index);
                    continue;
                }
                if (!connection.request_started) {
                    self.metrics.recorder().add(.connections_idle_closed_total, 1);
                    try self.forceClose(index);
                    continue;
                }
                self.metrics.recorder().add(.request_timeouts_total, 1);
                self.metrics.recorder().add(if (connection.phase == .writing)
                    .write_timeouts_total
                else if (connection.parser.phase == .head)
                    .header_timeouts_total
                else
                    .body_timeouts_total, 1);
                if (connection.phase == .reading and connection.request_started) {
                    if (connection.receive_pending and !connection.cancel_receive_pending) {
                        try self.ensureSubmission();
                        _ = self.ring.cancel(token(.cancel_receive, index, connection.generation), token(.receive, index, connection.generation), 0) catch
                            return error.IoUringResources;
                        connection.cancel_receive_pending = true;
                        connection.pending += 1;
                        self.queued();
                    }
                    try self.reject(index, 408, "deadline");
                } else try self.forceClose(index);
            }
        }

        fn event(self: *Self, index: usize, level: Logger.Level, name: []const u8, reason: ?[]const u8) void {
            if (level == .debug and !self.config.verbose) return;
            const connection = &self.connections[index];
            self.logger.emit(.{
                .timestamp_ns = platform.realtimeNs(self.io),
                .level = level,
                .event = name,
                .connection = token(.receive, index, connection.generation) & ~@as(u64, 255),
                .request = if (connection.request_started) connection.request_id else null,
                .reason = reason,
                .phase = if (self.config.verbose) @tagName(connection.phase) else null,
            });
        }

        fn rejectionEvent(self: *Self, index: usize, reason: []const u8) void {
            self.rejection_events +%= 1;
            if (!self.config.verbose and self.rejection_events % 1024 != 1) return;
            self.event(index, .warn, "request_rejected", reason);
        }

        fn beginShutdown(self: *Self, now: u64) RunError!void {
            self.draining = true;
            self.shutdown_deadline = now + @as(u64, self.config.shutdown_timeout_ms) * 1_000_000;
            self.metrics.set(.draining, 1);
            self.logger.emit(.{ .timestamp_ns = platform.realtimeNs(self.io), .event = "shutdown_started" });
            if (self.accepting) try self.cancelControl(.cancel_accept, .accept);
            if (self.admin_accepting) try self.cancelControl(.cancel_admin, .accept_admin);
            for (self.connections, 0..) |*connection, index| {
                if (connection.fd < 0) continue;
                connection.close_after_response = true;
                if (!connection.request_started) try self.forceClose(index);
            }
        }

        fn cancelControl(self: *Self, kind: Kind, target: Kind) RunError!void {
            try self.ensureSubmission();
            _ = self.ring.cancel(control(kind), control(target), 0) catch return error.IoUringResources;
            self.queued();
        }

        fn stopOperations(self: *Self) RunError!void {
            self.stopping = true;
            for (self.connections, 0..) |connection, index| if (connection.fd >= 0) try self.forceClose(index);
            if (self.ticking) try self.cancelControl(.cancel_tick, .tick);
            if (self.logging) try self.cancelControl(.cancel_log, .log_write);
        }
    };
}

test "embedded application receives normalized routing and preserved request octets" {
    const testing = std.testing;
    const App = struct {
        pub const Exchange = struct {
            pub fn init(_: *@This(), _: []u8) void {}

            pub fn receiveHead(_: *@This(), request: *const http.Request) ?http.Response {
                const bytes = if (std.mem.eql(u8, request.query, "target"))
                    request.target
                else if (std.mem.eql(u8, request.query, "path"))
                    request.path
                else if (std.mem.eql(u8, request.query, "host"))
                    request.getHeader("host") orelse "missing"
                else if (std.mem.eql(u8, request.query, "scheme"))
                    request.scheme orelse "missing"
                else
                    request.authority;
                return .{ .body = .{ .bytes = bytes }, .close = true };
            }

            pub fn receiveBody(_: *@This(), _: []const u8) error{}!void {}

            pub fn respond(_: *@This(), _: *const http.Request) http.Response {
                return .{ .status = 500, .close = true };
            }

            pub fn produce(_: *@This(), _: []u8) ?[]const u8 {
                return null;
            }

            pub fn allowedMethods(_: *const @This()) []const u8 {
                return "GET";
            }
        };
    };
    const TestServer = Worker(App);
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    workers[0].init(testing.allocator, testing.io, .{
        .port = 0,
        .admin_port = 0,
        .max_connections = 16,
        .access_log = false,
    }, &stop, 0, &shared) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer workers[0].deinit();
    workers[0].log_disabled = true;
    const thread = try std.Thread.spawn(.{}, TestServer.workerMain, .{&workers[0]});
    defer {
        stop.store(true, .monotonic);
        thread.join();
    }
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", workers[0].listener.port);
    var authority_buffer: [64]u8 = undefined;
    const authority = try std.fmt.bufPrint(&authority_buffer, "127.0.0.1:{d}", .{workers[0].listener.port});
    const cases = [_][2][]const u8{
        .{ "GET /?authority HTTP/1.0\r\n\r\n", authority },
        .{ "GET /?authority HTTP/1.1\r\nHost:\r\n\r\n", authority },
        .{ "GET /?host HTTP/1.1\r\nHost:\r\n\r\n", "" },
        .{ "GET /?scheme HTTP/1.1\r\nHost: example\r\n\r\n", "http" },
        .{ "GET http://Actual:8080/?authority HTTP/1.1\r\nHost: ignored\r\n\r\n", "Actual:8080" },
        .{ "GET http://Actual:8080/?host HTTP/1.1\r\nHost: ignored\r\n\r\n", "ignored" },
        .{ "GET /x/%2e%2e/%73tream?path HTTP/1.1\r\nHost: example\r\n\r\n", "/stream" },
        .{ "GET /x/%2e%2e/%73tream?target HTTP/1.1\r\nHost: example\r\n\r\n", "/x/%2e%2e/%73tream?target" },
    };
    for (cases) |case| {
        const stream = try address.connect(testing.io, .{ .mode = .stream });
        defer stream.close(testing.io);
        var writer = stream.writer(testing.io, &.{});
        try writer.interface.writeAll(case[0]);
        var buffer: [1024]u8 = undefined;
        var reader = stream.reader(testing.io, &buffer);
        const response = try reader.interface.allocRemaining(testing.allocator, .limited(4096));
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1."));
        try testing.expectEqualStrings("200", response[9..12]);
        const body = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.MissingHead) + 4;
        try testing.expectEqualStrings(case[1], response[body..]);
    }
    try testing.expectEqualStrings("[::1]", defaultAuthority(&authority_buffer, "::1", 80));
    try testing.expectEqualStrings("[::1]:8080", defaultAuthority(&authority_buffer, "::1", 8080));
}

test "fatal completion drains existing receives before returning" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const TestServer = Worker(application);
    const connections = try gpa.alloc(TestServer.Connection, 2);
    defer gpa.free(connections);
    const storage = try gpa.alloc(u8, 32);
    defer gpa.free(storage);
    const slots = try gpa.alloc(Logger.Slot, 2);
    defer gpa.free(slots);
    var ring = linux.IoUring.init(128, 0) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var pair: [2]linux.fd_t = undefined;
    _ = try platform.check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer platform.close(pair[0]);
    defer platform.close(pair[1]);
    const invalid_listener: linux.fd_t = @intCast(try platform.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer platform.close(invalid_listener);
    var stop: std.atomic.Value(bool) = .init(false);
    var active_slots: [2]usize = undefined;
    active_slots[0] = 0;
    var server: TestServer = .{
        .io = std.testing.io,
        .active_slots = &active_slots,
        .config = .{ .max_connections = 1, .admin_connections = 1 },
        .gpa = gpa,
        .ring = ring,
        .listener = .{ .fd = invalid_listener, .port = 0 },
        .admin_listener = .{ .fd = invalid_listener, .port = 0 },
        .connections = connections,
        .storage = storage,
        .log_slots = slots,
        .stop = &stop,
        .active_connections = 1,
        .admin_free = 1,
    };
    server.logger.init(slots, &server.metrics, false);
    server.admission.init(.{}, platform.monotonicNs());
    connections[0] = .{
        .fd = pair[0],
        .generation = 1,
        .receive_buffer = storage,
        .receive_pending = true,
        .pending = 1,
        .deadline = std.math.maxInt(u64),
    };
    connections[1] = .{ .admin = true };
    const receive_token = TestServer.token(.receive, 0, 1);
    _ = try server.ring.recv(receive_token, pair[0], .{ .buffer = storage }, 0);
    server.queued();
    // Keep the regression's failing version safe: release the socket read and
    // collect its CQE before its buffer is returned to the testing allocator.
    defer if (server.pending != 0) {
        _ = linux.shutdown(pair[1], linux.SHUT.WR);
        while (true) {
            const completion = server.ring.copy_cqe() catch unreachable;
            if (completion.user_data == receive_token) break;
        }
    };
    try testing.expectError(error.IoUringOperationUnsupported, server.loop());
    try testing.expectEqual(@as(usize, 0), server.pending);
}

test "fatal cleanup discards unsubmitted entries without waiting for CQEs" {
    const TestServer = Worker(application);
    var ring = linux.IoUring.init(128, 0) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    var server: TestServer = .{
        .io = std.testing.io,
        .config = .{},
        .gpa = std.testing.allocator,
        .ring = ring,
        .listener = .{ .fd = -1, .port = 0 },
        .admin_listener = .{ .fd = -1, .port = 0 },
        .connections = &.{},
        .storage = &.{},
        .log_slots = &.{},
        .stop = &stop,
        .pending = 1,
    };
    _ = try server.ring.nop(TestServer.control(.tick));
    server.quiesce();
    try std.testing.expectEqual(@as(usize, 0), server.pending);
    try std.testing.expectEqual(@as(u32, 0), server.ring.cq_ready());
}

test "fatal cleanup closes accepted descriptors from an abandoned CQ batch" {
    const TestServer = Worker(application);
    const fd: linux.fd_t = @intCast(try platform.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer platform.close(fd);
    var server: TestServer = undefined;
    server.pending = 1;
    server.discardCompletion(.{
        .user_data = TestServer.control(.accept),
        .res = fd,
        .flags = 0,
    });
    try std.testing.expectEqual(@as(usize, 0), server.pending);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
}

test "late canceled receive preserves the response drain" {
    const TestServer = Worker(application);
    var ring = linux.IoUring.init(128, 0) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var pair: [2]linux.fd_t = undefined;
    _ = try platform.check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer platform.close(pair[0]);
    defer platform.close(pair[1]);
    var storage: [32]u8 = undefined;
    var connections = [_]TestServer.Connection{.{
        .fd = pair[0],
        .generation = 1,
        .phase = .drain,
        .receive_buffer = &storage,
    }};
    var stop: std.atomic.Value(bool) = .init(false);
    var active_slots: [1]usize = undefined;
    active_slots[0] = 0;
    var server: TestServer = .{
        .io = std.testing.io,
        .active_slots = &active_slots,
        .config = .{},
        .gpa = std.testing.allocator,
        .ring = ring,
        .listener = .{ .fd = -1, .port = 0 },
        .admin_listener = .{ .fd = -1, .port = 0 },
        .connections = &connections,
        .storage = &storage,
        .log_slots = &.{},
        .stop = &stop,
        .active_connections = 1,
    };
    try server.received(0, -@as(i32, @intFromEnum(linux.E.CANCELED)));
    try std.testing.expectEqual(.drain, connections[0].phase);
    try std.testing.expect(connections[0].receive_pending);
    try std.testing.expectEqual(@as(u64, 0), server.metrics.get(.peer_disconnects_total));
}

test "fatal worker error stops and joins the other event loops" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var workers: [2]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    var config: Config = .{ .workers = 2, .max_connections = 2, .port = 0, .admin_port = 0 };
    workers[0].init(testing.allocator, testing.io, config, &stop, 0, &shared) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer workers[0].deinit();
    config.port = workers[0].listener.port;
    config.admin_port = workers[0].admin_listener.port;
    try workers[1].init(testing.allocator, testing.io, config, &stop, 1, &shared);
    defer workers[1].deinit();
    const invalid_listener: linux.fd_t = @intCast(try platform.check(linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    )));
    platform.close(workers[1].listener.fd);
    workers[1].listener.fd = invalid_listener;
    const thread = try std.Thread.spawn(.{}, TestServer.workerMain, .{&workers[1]});
    workers[0].workerMain();
    thread.join();
    try testing.expect(shared.abort.load(.monotonic));
    try testing.expectEqual(error.IoUringOperationUnsupported, workers[1].failure.?);
    try testing.expectEqual(@as(?RunError, null), workers[0].failure);
    for (&workers) |*worker| try testing.expectEqual(@as(usize, 0), worker.pending);
}

test "unused slots do not invoke application initialization on the setup thread" {
    const testing = std.testing;
    const App = struct {
        var initializations: usize = 0;
        pub const Exchange = struct {
            pub fn init(_: *@This(), _: []u8) void {
                initializations += 1;
            }
        };
    };
    const TestServer = Worker(App);
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    App.initializations = 0;
    workers[0].init(testing.allocator, testing.io, .{ .max_connections = 2, .port = 0, .admin_port = 0 }, &stop, 0, &shared) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer workers[0].deinit();
    try testing.expectEqual(@as(usize, 0), App.initializations);
    workers[0].prepareRequest(&workers[0].connections[0], platform.monotonicNs());
    try testing.expectEqual(@as(usize, 1), App.initializations);
}

test "embedded worker applies automatic admission before filling its connections" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    workers[0].init(testing.allocator, testing.io, .{
        .max_connections = 4,
        .port = 0,
        .admin_port = 0,
    }, &stop, 0, &shared) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer workers[0].deinit();
    const admission = &workers[0].admission;
    const now = platform.monotonicNs();
    for (0..3) |_| try testing.expectEqual(.admit, admission.acquire(now, false));
    try testing.expectEqual(.reject, admission.acquire(now, false));
    try testing.expectEqual(.close, admission.acquire(now, false));
    admission.release(.admit);
    try testing.expectEqual(.admit, admission.acquire(now, false));
    admission.release(.reject);
    for (0..3) |_| admission.release(.admit);
}

test "stream batching preserves producer capacity and a deferred fragment" {
    const testing = std.testing;
    const TestApp = struct {
        pub const Exchange = struct {
            calls: usize = 0,

            pub fn produce(exchange: *@This(), destination: []u8) ?[]const u8 {
                std.debug.assert(destination.len == 64);
                const call = exchange.calls;
                exchange.calls += 1;
                if (call >= 3) return null;
                if (call == 2) return "end";
                @memset(destination[0..50], if (call == 0) 'A' else 'B');
                return destination[0..50];
            }
        };
    };
    const TestServer = Worker(TestApp);
    var output: [96]u8 = undefined;
    var application_buffer: [64]u8 = undefined;
    var connection: TestServer.Connection = .{
        .exchange = .{},
        .output_buffer = &output,
        .application_buffer = &application_buffer,
        .streaming = true,
        .encoder = .{ .mode = .chunked, .close = false },
    };
    try TestServer.fillStream(&connection);
    try testing.expectEqualStrings("32\r\n" ++ "A" ** 50 ++ "\r\n", output[0..connection.output_len]);
    try testing.expectEqual(@as(usize, 2), connection.exchange.calls);
    try testing.expect(connection.stream_fragment != null);
    try TestServer.fillStream(&connection);
    try testing.expectEqualStrings("32\r\n" ++ "B" ** 50 ++ "\r\n3\r\nend\r\n", output[0..connection.output_len]);
    try testing.expectEqual(@as(usize, 3), connection.exchange.calls);
    try TestServer.fillStream(&connection);
    try testing.expectEqualStrings("0\r\n\r\n", output[0..connection.output_len]);
    try testing.expectEqual(@as(usize, 103), connection.response_body_bytes);
    try testing.expect(!connection.streaming);
    try testing.expect(connection.stream_fragment == null);
}

test "stream batching bounds calls and rejects an empty fragment" {
    const TestApp = struct {
        pub const Exchange = struct {
            calls: usize = 0,
            empty: bool = false,

            pub fn produce(exchange: *@This(), destination: []u8) ?[]const u8 {
                _ = destination;
                exchange.calls += 1;
                return if (exchange.empty) "" else "x";
            }
        };
    };
    const TestServer = Worker(TestApp);
    var output: [4096]u8 = undefined;
    var application_buffer: [64]u8 = undefined;
    var connection: TestServer.Connection = .{
        .exchange = .{},
        .output_buffer = &output,
        .application_buffer = &application_buffer,
        .streaming = true,
        .encoder = .{ .mode = .chunked, .close = false },
    };
    try TestServer.fillStream(&connection);
    try std.testing.expectEqual(@as(usize, 16), connection.exchange.calls);
    try std.testing.expectEqualStrings("1\r\nx\r\n" ** 16, output[0..connection.output_len]);
    try std.testing.expect(connection.streaming);
    connection.exchange.empty = true;
    try std.testing.expectError(error.EmptyStreamFragment, TestServer.fillStream(&connection));
}

test "connection storage is retained through every cancellation completion order" {
    const testing = std.testing;
    const TestServer = Worker(application);
    const kinds = [_]TestServer.Kind{
        .receive,
        .send,
        .cancel_receive,
        .cancel_send,
    };
    // Synthetic delivery covers orders a scheduler-dependent socket test cannot force.
    for (kinds, 0..) |first, a| {
        for (kinds, 0..) |second, b| {
            if (a == b) continue;
            for (kinds, 0..) |third, c| {
                if (c == a or c == b) continue;
                const fourth = kinds[6 - a - b - c];
                const fd: linux.fd_t = @intCast(try platform.check(linux.socket(
                    linux.AF.UNIX,
                    linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
                    0,
                )));
                var connections = [_]TestServer.Connection{.{
                    .fd = fd,
                    .generation = std.math.maxInt(u32),
                    .phase = .canceling,
                    .receive_pending = true,
                    .send_pending = true,
                    .cancel_receive_pending = true,
                    .cancel_send_pending = true,
                    .pending = 4,
                    .permit = .admit,
                }};
                defer if (connections[0].fd >= 0) platform.close(connections[0].fd);
                var active_slots = [_]usize{0};
                var stop: std.atomic.Value(bool) = .init(false);
                var server: TestServer = .{
                    .io = std.testing.io,
                    .config = .{},
                    .gpa = testing.allocator,
                    .ring = undefined,
                    .listener = .{ .fd = -1, .port = 0 },
                    .admin_listener = .{ .fd = -1, .port = 0 },
                    .connections = &connections,
                    .active_slots = &active_slots,
                    .storage = &.{},
                    .log_slots = &.{},
                    .stop = &stop,
                    .pending = 4,
                    .active_connections = 1,
                    .admission = .{ .active = 1 },
                };
                for ([_]TestServer.Kind{ first, second, third, fourth }, 0..) |kind, completed| {
                    try server.complete(.{
                        .user_data = TestServer.token(kind, 0, connections[0].generation),
                        .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
                        .flags = 0,
                    });
                    if (completed < 3) {
                        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
                        try testing.expectEqual(@as(?usize, null), server.public_free);
                        try testing.expectEqual(@as(usize, 1), server.admission.active);
                    }
                }
                try testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
                try testing.expectEqual(@as(?usize, 0), server.public_free);
                try testing.expectEqual(@as(usize, 0), server.admission.active);
                try testing.expectEqual(@as(usize, 0), server.pending);
                try testing.expectEqual(@as(usize, 0), server.active_connections);
                try testing.expectEqual(@as(u64, 1), server.metrics.get(.connections_closed_total));
            }
        }
    }
}
