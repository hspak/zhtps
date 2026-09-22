//! Private completion-driven workers with optional bounded application executors.

const std = @import("std");
const linux = std.os.linux;
const platform = @import("../platform.zig");
const http = @import("../http.zig");
const Config = @import("../Config.zig");
const Tls = @import("../Tls.zig");
const Metrics = @import("../Metrics.zig");
const metrics_format = @import("../metrics_format.zig");
const Logger = @import("../Logger.zig");
const Admission = @import("../Admission.zig");
const application = @import("../application.zig");
const ResponseBatch = @import("ResponseBatch.zig");
const BufferPool = @import("BufferPool.zig");
const http2 = @import("http2.zig");
const Http2Allocator = @import("Http2Allocator.zig");

pub const RunError = std.mem.Allocator.Error ||
    std.Thread.SpawnError || platform.Error || Config.Error || Config.Resources.Error || Tls.Error ||
    error{
        IoUringUnavailable,
        IoUringOperationUnsupported,
        IoUringResources,
    };

// The built-in service accepts any syntactically valid authority. An omitted
// HTTP/1.0 authority or empty Host uses this listener-specific default origin.
fn defaultAuthority(buffer: *[64]u8, address: []const u8, port: u16, default_port: u16) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (std.mem.indexOfScalar(u8, address, ':') != null) {
        writer.print("[{s}]", .{address}) catch unreachable;
    } else writer.writeAll(address) catch unreachable;
    if (port != default_port) writer.print(":{d}", .{port}) catch unreachable;
    return writer.buffered();
}

// Inputs come from a parsed request. Keep the raw path/query and replace only
// the authority's port; bracketed IPv6 literals retain their internal colons.
fn writeHttpsLocation(
    writer: *std.Io.Writer,
    authority: []const u8,
    target: []const u8,
    port: u16,
) (std.Io.Writer.Error || error{InvalidTarget})!void {
    var path_query = target;
    if (!std.mem.startsWith(u8, target, "/")) {
        const scheme_end = std.mem.indexOf(u8, target, "://") orelse return error.InvalidTarget;
        const rest = target[scheme_end + 3 ..];
        const path_start = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
        path_query = rest[path_start..];
    }
    const host_end = if (std.mem.startsWith(u8, authority, "["))
        std.mem.indexOfScalar(u8, authority, ']').? + 1
    else
        std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    try writer.writeAll("https://");
    try writer.writeAll(authority[0..host_end]);
    if (port != 443) try writer.print(":{d}", .{port});
    if (path_query.len == 0 or path_query[0] == '?') try writer.writeByte('/');
    try writer.writeAll(path_query);
}

// Only IP listeners supply these addresses. The longest unscoped IPv6 literal
// occupies 39 bytes; formatting omits the peer port and needs no I/O.
fn formatClientIp(buffer: *[39]u8, address: *const linux.sockaddr.storage) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    switch (address.family) {
        linux.AF.INET => {
            const ip: *const linux.sockaddr.in = @ptrCast(address);
            const bytes: [4]u8 = @bitCast(ip.addr);
            writer.print("{d}.{d}.{d}.{d}", .{
                bytes[0],
                bytes[1],
                bytes[2],
                bytes[3],
            }) catch unreachable;
        },
        linux.AF.INET6 => {
            const ip: *const linux.sockaddr.in6 = @ptrCast(address);
            const literal: std.Io.net.Ip6Address.Unresolved = .{
                .bytes = ip.addr,
                .interface_name = null,
            };
            literal.format(&writer) catch unreachable;
        },
        else => unreachable,
    }
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

fn createApplicationEvent() error{IoUringResources}!linux.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.IoUringResources,
    };
}

/// App.Exchange implements init, receiveHead, receiveBody, respond, produce,
/// and allowedMethods, as illustrated by application.Exchange. Direct hooks
/// must be bounded and nonblocking; generated endpoint applications mark their
/// user hooks for isolated execution. Buffers remain owned by each exchange
/// until its response is copied or sent and its hooks return. The server owns
/// no application-global resources.
pub fn Worker(comptime App: type) type {
    return struct {
        const Self = @This();

        pub const RuntimeInit = if (@hasDecl(App, "RuntimeInit")) App.RuntimeInit else void;
        const has_application_metrics = @hasDecl(App, "CustomMetrics");
        const ApplicationMetrics = if (has_application_metrics) App.CustomMetrics else void;
        const isolated_application = if (@hasDecl(App, "isolated")) App.isolated else false;
        const has_response_streams = isolated_application and @hasDecl(App.Exchange, "runStream");
        const ApplicationLane = if (isolated_application) App.Lane else enum { direct };
        // Custom exchanges can retain callbacks and borrowed metadata through
        // send completion. Their storage must not be reset after merely copying.
        const can_batch = App == application;
        const Http2 = http2.Connection(App, Self);

        config: Config,
        io: std.Io,
        shared: ?*Shared = null,
        worker_id: u32 = 0,
        thread_id: std.atomic.Value(u32) = .init(0),
        failure: ?RunError = null,
        worker_cpu: ?u16 = null,
        inspection: Inspection = .{},
        gpa: std.mem.Allocator,
        http2_allocator: Http2Allocator = undefined,
        http2_streams: usize = 0,
        http2_cached: usize = 0,
        free_http2_stream: ?*Http2.Stream = null,
        ring: linux.IoUring,
        listener: platform.Listener,
        admin_listener: platform.Listener,
        redirect_listener: platform.Listener = .{ .fd = -1, .port = 80 },
        connections: []Connection,
        batches: []ResponseBatch = &.{},
        free_batch: ?*ResponseBatch = null,
        active_slots: []usize = &.{},
        // Admin buffers stay reserved; public sets follow accepted sockets.
        storage: []u8,
        connection_buffers: BufferPool = .{},
        buffer_pools: [6]BufferPool = @splat(.{}),
        buffer_bytes_active: usize = 0,
        free_request: ?*Request = null,
        request_cached: usize = 0,
        request_active: usize = 0,
        log_slots: []Logger.Slot,
        metrics: Metrics = .{},
        application_metrics: ApplicationMetrics = if (has_application_metrics) .{} else {},
        logger: Logger = undefined,
        admission: Admission = undefined,
        stop: *const std.atomic.Value(bool),
        application_runtime: RuntimeInit = if (RuntimeInit == void) {} else undefined,
        executor: if (isolated_application) ApplicationExecutor else void =
            if (isolated_application) undefined else {},
        pending: usize = 0,
        accepting: bool = false,
        admin_accepting: bool = false,
        redirect_accepting: bool = false,
        // Each listener has at most one accept in flight. Public peer storage
        // also stays unchanged while waiting_accept waits for a reclaimed slot.
        accept_peers: [3]AcceptPeer = @splat(.{}),
        accept_retry_ns: u64 = 0,
        admin_retry_ns: u64 = 0,
        redirect_retry_ns: u64 = 0,
        ticking: bool = false,
        logging: bool = false,
        application_event_pending: bool = false,
        application_event_fd: linux.fd_t = -1,
        application_event_value: u64 = 0,
        // Descriptors and queued record bytes stay stable until the log CQE.
        log_iovecs: [128]std.posix.iovec_const = undefined,
        log_batch_remaining: usize = 0,
        log_disabled: bool = false,
        draining: bool = false,
        stopping: bool = false,
        shutdown_deadline: u64 = 0,
        shutdown_keepalive_deadline: u64 = 0,
        next_request: u64 = 1,
        rejection_events: u64 = 0,
        tick_interval: linux.kernel_timespec = .{ .sec = 0, .nsec = 10_000_000 },
        active_connections: usize = 0,
        public_free: ?usize = null,
        admin_free: ?usize = null,
        idle_first: ?usize = null,
        idle_last: ?usize = null,
        // One accepted descriptor may wait for a reclaimed slot's final CQE.
        waiting_accept: linux.fd_t = -1,
        waiting_deadline_ns: u64 = 0,
        waiting_reclaim_started: bool = false,
        date: [29]u8 = undefined,
        date_second: u64 = std.math.maxInt(u64),
        public_authority: [64]u8 = undefined,
        public_authority_len: usize = 0,
        admin_authority: [64]u8 = undefined,
        admin_authority_len: usize = 0,

        pub const Shared = struct {
            workers: []Self,
            tls: ?Tls = null,
            abort: std.atomic.Value(bool) = .init(false),
            ready: std.atomic.Value(usize) = .init(0),
            log_owner: std.atomic.Value(u32) = .init(no_log_owner),
            allocator_mutex: std.Io.Mutex = .init,
        };
        pub const Options = struct {
            config: Config = .{},
            stop: *const std.atomic.Value(bool),
            worker_id: u32 = 0,
            shared: *Shared,
        };

        const no_log_owner = std.math.maxInt(u32);

        const Listener = enum {
            public,
            admin,
            redirect,
        };

        const AcceptPeer = struct {
            address: linux.sockaddr.storage = undefined,
            address_len: linux.socklen_t = undefined,
        };

        const Buffer = enum {
            head,
            trailers,
            path,
            receive,
            output,
            application,
        };
        const small_capacities = [_]usize{
            1024,
            512,
            1024,
            16384,
            1024,
            512,
        };
        const buffer_gap = 64;
        const request_cache_limit = 64;

        const Request = struct {
            next: ?*Request = null,
            parser: http.Parser = undefined,
            exchange: App.Exchange = undefined,
        };

        const Inspection = struct {
            phase: std.atomic.Value(enum(u8) {
                idle,
                requested,
                ready,
            }) = .init(.idle),
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
            accept_redirect,
            tick,
            log_write,
            application,
            receive,
            send,
            cancel_receive,
            cancel_send,
            cancel_accept,
            cancel_admin,
            cancel_redirect,
            cancel_tick,
            cancel_log,
            cancel_application,
        };

        const Connection = struct {
            fd: linux.fd_t = -1,
            client_ip: [39]u8 = undefined,
            client_ip_len: u8 = 0,
            tls: ?*Tls.Session = null,
            http2: ?*Http2 = null,
            next_free: ?usize = null,
            idle_previous: ?usize = null,
            idle_next: ?usize = null,
            idle_queued: bool = false,
            idle_since_ns: u64 = 0,
            active_position: usize = 0,
            generation: u32 = 0,
            admin: bool = false,
            redirect: bool = false,
            phase: Phase = .reading,
            // Public requests borrow a worker lease through response cleanup.
            // Admin leases are reserved at initialization and never shared.
            request_lease: ?*Request = null,
            parser: *http.Parser = undefined,
            exchange: *App.Exchange = undefined,
            application_initialized: bool = false,
            // The executor borrows this receive-buffer slice until its completion.
            application_body: if (isolated_application) []const u8 else void =
                if (isolated_application) &.{} else {},
            small_storage: []u8 = &.{},
            small_block: ?*BufferPool.Block = null,
            large_buffers: [6]?*BufferPool.Block = @splat(null),
            receive_buffer: []u8 = undefined,
            batch: if (can_batch) ?*ResponseBatch else void = if (can_batch) null else {},
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
            application_timed_out: bool = false,
            // Zero outside application work; retained across hooks and body ingestion.
            application_deadline_ns: u64 = 0,
            canceled: std.atomic.Value(bool) = .init(false),
            response_stream_buffer: []u8 = &.{},
            response_stream_started: bool = false,
            response_stream_busy: bool = false,
            response_stream_chunk: bool = false,

            const Phase = enum {
                handshake,
                http2,
                reading,
                application,
                inspecting,
                writing,
                tls_shutdown,
                drain,
                canceling,
            };
        };

        const ApplicationExecutor = struct {
            owner: *Self,
            io: std.Io,
            lanes: [std.meta.fields(ApplicationLane).len]LaneQueue,
            task_storage: []Task,
            completions: []Completion,
            completion_mutex: std.Io.Mutex = .init,
            completion_read: usize = 0,
            completion_count: usize = 0,
            threads: []std.Thread,
            started: usize = 0,

            const Stage = enum {
                head,
                body,
                body_response,
                response,
                produce,
            };

            const Task = struct {
                owner: *Self,
                index: usize,
                generation: u32,
                stage: Stage,
                deadline_ns: u64,
                stream: ?*Http2.Stream = null,
            };

            const Completion = struct {
                task: Task,
                response: ?http.Response,
                expired: bool,
            };

            const LaneQueue = struct {
                tasks: []Task,
                read_index: usize = 0,
                count: usize = 0,
                stopping: bool = false,
                mutex: std.Io.Mutex = .init,
                ready: std.Io.Condition = .init,
            };

            const InitOptions = struct {
                owner: *Self,
                completion_capacity: usize,
                worker_count: usize = 1,
            };

            /// Owns fixed queue and thread storage until deinit. Borrows io and
            /// owner; initialization errors release all acquired storage.
            fn init(
                executor: *ApplicationExecutor,
                gpa: std.mem.Allocator,
                io: std.Io,
                options: InitOptions,
            ) RunError!void {
                var task_count: usize = 0;
                var thread_count: usize = 0;
                inline for (std.meta.tags(ApplicationLane)) |lane| {
                    const lane_options = App.laneOptions(lane);
                    if (lane_options.threads == 0 or lane_options.queue == 0 or lane_options.timeout_ms == 0)
                        return error.InvalidLimit;
                    task_count = std.math.add(usize, task_count, lane_options.queue) catch
                        return error.InvalidLimit;
                    thread_count = std.math.add(usize, thread_count, lane_options.threads) catch
                        return error.InvalidLimit;
                }
                task_count = std.math.mul(
                    usize,
                    task_count,
                    options.worker_count,
                ) catch return error.InvalidLimit;
                thread_count = std.math.mul(
                    usize,
                    thread_count,
                    options.worker_count,
                ) catch return error.InvalidLimit;
                const task_storage = try gpa.alloc(Task, task_count);
                errdefer gpa.free(task_storage);
                const completions = try gpa.alloc(Completion, options.completion_capacity);
                errdefer gpa.free(completions);
                const threads = try gpa.alloc(std.Thread, thread_count);
                errdefer gpa.free(threads);
                executor.* = .{
                    .owner = options.owner,
                    .io = io,
                    .lanes = undefined,
                    .task_storage = task_storage,
                    .completions = completions,
                    .threads = threads,
                };
                var task_offset: usize = 0;
                inline for (std.meta.tags(ApplicationLane)) |lane| {
                    const count = App.laneOptions(lane).queue * options.worker_count;
                    executor.lanes[@intFromEnum(lane)] = .{
                        .tasks = task_storage[task_offset..][0..count],
                    };
                    task_offset += count;
                }
            }

            fn deinit(executor: *ApplicationExecutor, gpa: std.mem.Allocator) void {
                std.debug.assert(executor.started == 0);
                gpa.free(executor.threads);
                gpa.free(executor.completions);
                gpa.free(executor.task_storage);
                executor.* = undefined;
            }

            fn start(executor: *ApplicationExecutor) std.Thread.SpawnError!void {
                errdefer executor.stop();
                inline for (std.meta.tags(ApplicationLane)) |lane| {
                    const count = App.laneOptions(lane).threads * executor.owner.shared.?.workers.len;
                    for (0..count) |_| {
                        executor.threads[executor.started] = try std.Thread.spawn(
                            .{},
                            ApplicationExecutor.threadMain,
                            .{ executor, lane },
                        );
                        executor.started += 1;
                    }
                }
            }

            fn stop(executor: *ApplicationExecutor) void {
                for (&executor.lanes) |*lane| {
                    lane.mutex.lockUncancelable(executor.io);
                    lane.stopping = true;
                    lane.ready.broadcast(executor.io);
                    lane.mutex.unlock(executor.io);
                }
                for (executor.threads[0..executor.started]) |thread| thread.join();
                executor.started = 0;
            }

            fn submit(executor: *ApplicationExecutor, lane_id: ApplicationLane, task: Task) bool {
                const lane = &executor.lanes[@intFromEnum(lane_id)];
                lane.mutex.lockUncancelable(executor.io);
                defer lane.mutex.unlock(executor.io);
                if (lane.stopping or lane.count == lane.tasks.len) return false;
                lane.tasks[(lane.read_index + lane.count) % lane.tasks.len] = task;
                lane.count += 1;
                lane.ready.signal(executor.io);
                return true;
            }

            fn takeCompletion(executor: *ApplicationExecutor) ?Completion {
                executor.completion_mutex.lockUncancelable(executor.io);
                defer executor.completion_mutex.unlock(executor.io);
                if (executor.completion_count == 0) return null;
                const completion = executor.completions[executor.completion_read];
                executor.completion_read = (executor.completion_read + 1) % executor.completions.len;
                executor.completion_count -= 1;
                return completion;
            }

            fn threadMain(executor: *ApplicationExecutor, lane_id: ApplicationLane) void {
                while (executor.takeTask(lane_id)) |task| {
                    const started_ns = platform.monotonicNs();
                    const response: ?http.Response = if (started_ns >= task.deadline_ns or
                        (if (task.stream) |stream|
                            stream.canceled.load(.acquire)
                        else
                            task.owner.connections[task.index].canceled.load(.acquire)))
                        null
                    else if (task.stream) |stream| switch (task.stage) {
                        .head => stream.exchange.runHead(&stream.request),
                        .body => if (comptime @hasDecl(App.Exchange, "runBody"))
                            stream.exchange.runBody(
                                &stream.request,
                                stream.storage.body[0..stream.task_body_len],
                            )
                        else
                            unreachable,
                        .response => stream.exchange.respond(&stream.request),
                        .produce => produced: {
                            if (comptime has_response_streams) stream.exchange.runStream(&stream.request);
                            break :produced null;
                        },
                        .body_response => unreachable,
                    } else response: {
                        const connection = &task.owner.connections[task.index];
                        break :response switch (task.stage) {
                            .head => connection.exchange.runHead(&connection.parser.request),
                            .body => if (comptime @hasDecl(App.Exchange, "runBody"))
                                connection.exchange.runBody(
                                    &connection.parser.request,
                                    connection.application_body,
                                )
                            else
                                unreachable,
                            .body_response => if (comptime @hasDecl(
                                App.Exchange,
                                "runBody",
                            )) final_response: {
                                if (connection.exchange.runBody(
                                    &connection.parser.request,
                                    connection.application_body,
                                )) |response|
                                    break :final_response response;
                                // A consumer may block past the absolute deadline. Do not
                                // invoke another application hook after its budget expires.
                                if (platform.monotonicNs() >= task.deadline_ns) break :final_response null;
                                break :final_response connection.exchange.respond(&connection.parser.request);
                            } else unreachable,
                            .response => connection.exchange.respond(&connection.parser.request),
                            .produce => produced: {
                                if (comptime has_response_streams)
                                    connection.exchange.runStream(&connection.parser.request);
                                break :produced null;
                            },
                        };
                    };
                    const expired = started_ns >= task.deadline_ns or
                        platform.monotonicNs() >= task.deadline_ns;
                    const destination = &task.owner.executor;
                    destination.completion_mutex.lockUncancelable(destination.io);
                    std.debug.assert(destination.completion_count < destination.completions.len);
                    const write_index = (destination.completion_read + destination.completion_count) %
                        destination.completions.len;
                    destination.completions[write_index] = .{
                        .task = task,
                        .response = response,
                        .expired = expired,
                    };
                    destination.completion_count += 1;
                    destination.completion_mutex.unlock(destination.io);
                    destination.notify();
                }
            }

            fn notify(executor: *ApplicationExecutor) void {
                const one: u64 = 1;
                while (true) {
                    const result = linux.write(
                        executor.owner.application_event_fd,
                        @ptrCast(&one),
                        @sizeOf(u64),
                    );
                    switch (linux.errno(result)) {
                        .SUCCESS, .AGAIN => return,
                        .INTR => continue,
                        else => {
                            executor.owner.shared.?.abort.store(true, .monotonic);
                            return;
                        },
                    }
                }
            }

            fn takeTask(executor: *ApplicationExecutor, lane_id: ApplicationLane) ?Task {
                const lane = &executor.lanes[@intFromEnum(lane_id)];
                lane.mutex.lockUncancelable(executor.io);
                defer lane.mutex.unlock(executor.io);
                while (lane.count == 0 and !lane.stopping) {
                    lane.ready.waitUncancelable(executor.io, &lane.mutex);
                }
                if (lane.count == 0) return null;
                const task = lane.tasks[lane.read_index];
                lane.read_index = (lane.read_index + 1) % lane.tasks.len;
                lane.count -= 1;
                return task;
            }
        };

        /// Estimates transport-owned storage for startup sizing. Compiled record
        /// sizes and bounded caches are exact; stack, socket, and TLS headroom
        /// are allowances. Application-owned allocations remain outside this model.
        pub fn resourceRequirements(config: Config) Config.Requirements {
            const completion_bytes = if (comptime isolated_application) @sizeOf(ApplicationExecutor.Completion) else 0;
            var requirements: Config.Requirements = .{
                .worker_bytes = @sizeOf(Self) + 1024 * 1024 + 64 * 1024 +
                    64 * (@sizeOf(Request) + storageSize(config, false) + @sizeOf(BufferPool.Block)),
                .connection_bytes = @sizeOf(Connection) + @sizeOf(Request) + @sizeOf(usize) +
                    storageSize(config, false) + @sizeOf(BufferPool.Block) + completion_bytes +
                    256 + 64 * 1024 + @as(u64, if (config.tls != null) 64 * 1024 else 0),
                .admin_bytes = config.admin_connections *| (storageSize(config, true) +
                    @sizeOf(Connection) + @sizeOf(Request) + @sizeOf(usize) + 64 * 1024),
                .stream_bytes = @sizeOf(Http2.Stream) + config.application_bytes +
                    config.header_bytes + config.trailer_bytes + config.response_bytes + 16 * 1024,
                .stream_queue_bytes = completion_bytes,
                .worker_fds = if (isolated_application) 4 else 3,
            };
            if (config.http_redirect) requirements.worker_fds += 1;
            if (config.victoria_logs != null) {
                // Sender, HTTP request, request deadline and final-drain deadline.
                requirements.process_threads = 4;
                requirements.process_fds = 4;
                requirements.process_bytes = @sizeOf(Logger.VictoriaLogs) + 5 * 1024 * 1024;
            }
            if (config.log_fd != null or config.victoria_logs != null)
                requirements.worker_bytes +|= config.log_slots *| @sizeOf(Logger.Slot);
            if (comptime can_batch) requirements.worker_bytes +|= config.response_batches *| @sizeOf(ResponseBatch);
            for (fullCapacities(config)) |size| {
                const cached = @max(8, @min(64, 4 * 1024 * 1024 / size));
                requirements.worker_bytes +|= cached *| (size + @sizeOf(BufferPool.Block));
            }
            if (comptime isolated_application) {
                inline for (std.meta.tags(ApplicationLane)) |lane| {
                    const options = App.laneOptions(lane);
                    requirements.lane_threads +|= options.threads;
                    requirements.worker_bytes +|= options.queue *| @sizeOf(ApplicationExecutor.Task);
                    requirements.worker_bytes +|= options.threads *| (1024 * 1024 + @sizeOf(std.Thread));
                }
            }
            return requirements;
        }

        fn token(kind: Kind, index: usize, generation: u32) u64 {
            return (@as(u64, generation) << 32) | (@as(u64, index) << 8) | @intFromEnum(kind);
        }

        fn control(kind: Kind) u64 {
            return token(kind, 0, 0);
        }

        /// Starts the shared lane pool before any transport thread is pinned.
        /// Worker zero owns it; all worker storage remains live until it stops.
        pub fn startApplications(self: *Self) std.Thread.SpawnError!void {
            std.debug.assert(self.worker_id == 0);
            if (comptime isolated_application) try self.executor.start();
        }

        /// Joins every application hook after transport threads have returned.
        pub fn stopApplications(self: *Self) void {
            std.debug.assert(self.worker_id == 0);
            if (comptime isolated_application) self.executor.stop();
        }

        /// Runs on the owning thread after every worker has initialized. Records
        /// errors in failure and signals shared abort before draining pending I/O.
        pub fn workerMain(self: *Self) void {
            defer self.stopListening();
            // Executors inherit the broad mask before the event loop is pinned.
            // Worker zero runs on the embedding caller and must restore it.
            const original: ?linux.cpu_set_t = if (self.worker_cpu) |cpu| platform.pinCpu(cpu) catch |err| {
                self.failure = err;
                self.shared.?.abort.store(true, .monotonic);
                return;
            } else null;
            defer if (original) |mask| {
                platform.setAffinity(&mask) catch |err| {
                    self.failure = err;
                    self.shared.?.abort.store(true, .monotonic);
                };
            };
            self.thread_id.store(std.Thread.getCurrentId(), .monotonic);
            const shared = self.shared.?;
            _ = shared.ready.fetchAdd(1, .release);
            while (shared.ready.load(.acquire) != shared.workers.len) {
                if (shared.abort.load(.monotonic)) return;
                std.Thread.yield() catch {};
            }
            if (shared.abort.load(.monotonic)) return;
            if (self.worker_id == 0) {
                if (self.config.resources) |resources| self.logger.emit(.{
                    .timestamp_ns = platform.realtimeNs(self.io),
                    .event = "resources_resolved",
                    .fields = &.{
                        .{ .name = "workers", .value = .{ .unsigned = self.config.workers } },
                        .{ .name = "workers_source", .value = .{ .string = @tagName(resources.workers) } },
                        .{ .name = "connections_per_worker", .value = .{ .unsigned = self.config.max_connections } },
                        .{ .name = "connections_source", .value = .{ .string = @tagName(resources.connections) } },
                        .{
                            .name = "large_buffer_bytes_per_worker",
                            .value = .{ .unsigned = self.config.large_buffer_bytes },
                        },
                        .{
                            .name = "large_buffers_automatic",
                            .value = .{ .boolean = resources.large_buffers_automatic },
                        },
                        .{
                            .name = "http2_memory_bytes_per_worker",
                            .value = .{ .unsigned = self.config.http2.memory_bytes },
                        },
                        .{
                            .name = "http2_memory_automatic",
                            .value = .{ .boolean = resources.http2_memory_automatic },
                        },
                        .{
                            .name = "http2_streams_per_worker",
                            .value = .{ .unsigned = self.config.http2.max_streams_per_worker },
                        },
                        .{
                            .name = "http2_streams_automatic",
                            .value = .{ .boolean = resources.http2_streams_automatic },
                        },
                        .{
                            .name = "max_active_per_worker",
                            .value = .{ .unsigned = self.config.admission.max_active.? },
                        },
                        .{
                            .name = "max_rejecting_per_worker",
                            .value = .{ .unsigned = self.config.admission.max_rejecting.? },
                        },
                        .{
                            .name = "burst_per_worker",
                            .value = .{ .unsigned = self.config.admission.burst.? },
                        },
                        .{
                            .name = "threads_per_worker",
                            .value = .{ .unsigned = resources.threads_per_worker },
                        },
                        .{ .name = "memory_budget_bytes", .value = .{ .unsigned = resources.memory_budget_bytes } },
                        .{ .name = "estimated_bytes", .value = .{ .unsigned = resources.estimated_bytes } },
                        .{ .name = "memory_source", .value = .{ .string = @tagName(resources.detected.memory_source) } },
                        .{ .name = "cgroup", .value = .{ .string = @tagName(resources.detected.cgroup) } },
                        .{
                            .name = "placement_source",
                            .value = .{ .string = @tagName(resources.detected.placement) },
                        },
                    },
                });
            }
            // Individual CPU IDs keep placement records bounded even when an
            // explicit mapping contains hundreds of CPUs or long numeric strings.
            if (self.config.resources != null) self.logger.emit(.{
                .timestamp_ns = platform.realtimeNs(self.io),
                .event = "worker_resources_resolved",
                .fields = &.{
                    .{
                        .name = "cpu",
                        .value = if (self.worker_cpu) |cpu| .{ .unsigned = cpu } else .null,
                    },
                    .{ .name = "sq_entries", .value = .{ .unsigned = self.ring.sq.sqes.len } },
                    .{ .name = "cq_entries", .value = .{ .unsigned = self.ring.cq.cqes.len } },
                },
            });
            if (self.worker_id == 0) {
                self.logger.emit(.{
                    .timestamp_ns = platform.realtimeNs(self.io),
                    .event = "listening",
                    .address = self.config.address,
                    .port = self.listener.port,
                });
                if (self.redirect_listener.fd >= 0) self.logger.emit(.{
                    .timestamp_ns = platform.realtimeNs(self.io),
                    .event = "http_redirect_listening",
                    .address = self.config.address,
                    .port = self.redirect_listener.port,
                });
                if (self.admin_listener.fd >= 0) self.logger.emit(.{
                    .timestamp_ns = platform.realtimeNs(self.io),
                    .event = "admin_listening",
                    .address = self.config.admin_address,
                    .port = self.admin_listener.port,
                });
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
        pub fn init(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            options: Options,
        ) RunError!void {
            if (comptime RuntimeInit != void)
                @compileError("this application requires initApplication with its runtime value");
            return self.initApplication(gpa, io, options, {});
        }

        /// Allocates owned ring, listeners, and buffers. Borrows config strings,
        /// io, stop, shared, and application_runtime until deinit; self must stay
        /// at a stable address. Errors release resources without invoking hooks.
        pub fn initApplication(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            options: Options,
            application_runtime: RuntimeInit,
        ) RunError!void {
            const config = options.config;
            const stop = options.stop;
            const worker_id = options.worker_id;
            const shared = options.shared;
            const admission_options = try config.resolveAdmission();
            var cpu_storage: [256]u16 = undefined;
            const cpus = try config.resolveWorkerCpus(&cpu_storage);
            const count = config.max_connections + if (worker_id == 0) config.admin_connections else 0;
            var transferred = false;
            const entries = std.math.ceilPowerOfTwo(usize, 4 * count + 64) catch return error.InvalidLimit;
            if (entries > 32768) return error.InvalidLimit;
            // SQ slots are reusable after submission. The CQ still accommodates
            // every outstanding receive/send/cancel plus control operations.
            var params = std.mem.zeroes(linux.io_uring_params);
            params.flags = linux.IORING_SETUP_CQSIZE | linux.IORING_SETUP_COOP_TASKRUN;
            params.cq_entries = @intCast(entries);
            var ring = linux.IoUring.init_params(
                @intCast(@min(entries, 256)),
                &params,
            ) catch |err| switch (err) {
                error.SystemResources,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                => return error.IoUringResources,
                else => return error.IoUringUnavailable,
            };
            errdefer if (!transferred) ring.deinit();
            // Probe before submitting anything: error cleanup depends on this
            // Linux 6.0 capability even when the SQ/CQ processing path fails.
            try cancelSync(&ring, 0);
            const application_event_fd = if (comptime isolated_application)
                try createApplicationEvent()
            else
                -1;
            errdefer if (!transferred and application_event_fd >= 0) platform.close(application_event_fd);
            const listener = try platform.listen(
                config.address,
                config.port,
                .{
                    .reuse_port = true,
                    .thin_linear_timeouts = config.tcp_retries == .thin_linear,
                },
            );
            errdefer if (!transferred) platform.close(listener.fd);
            if (config.http_redirect and listener.port == config.http_redirect_port)
                return error.InvalidOption;
            const redirect_listener = if (config.http_redirect)
                try platform.listen(config.address, config.http_redirect_port, .{
                    .reuse_port = true,
                    .thin_linear_timeouts = config.tcp_retries == .thin_linear,
                })
            else
                platform.Listener{ .fd = -1, .port = config.http_redirect_port };
            errdefer if (!transferred and redirect_listener.fd >= 0) platform.close(redirect_listener.fd);
            const admin_listener = if (worker_id == 0 and config.admin_connections > 0)
                try platform.listen(config.admin_address, config.admin_port, .{ .backlog = 32 })
            else
                platform.Listener{ .fd = -1, .port = config.admin_port };
            errdefer if (!transferred and admin_listener.fd >= 0) platform.close(admin_listener.fd);
            const connections = try gpa.alloc(Connection, count);
            errdefer if (!transferred) gpa.free(connections);
            const batch_count = if (can_batch and admission_options.max_active >= 4)
                @min(config.response_batches, config.max_connections)
            else
                0;
            const batches = try gpa.alloc(ResponseBatch, batch_count);
            errdefer if (!transferred) gpa.free(batches);
            const active_slots = try gpa.alloc(usize, count);
            errdefer if (!transferred) gpa.free(active_slots);
            const public_stride = storageSize(config, false);
            const admin_stride = storageSize(config, true);
            const admin_bytes = std.math.mul(
                usize,
                count - config.max_connections,
                admin_stride,
            ) catch
                return error.InvalidLimit;
            const storage = try gpa.alloc(u8, admin_bytes);
            errdefer if (!transferred) gpa.free(storage);
            const log_slots = try gpa.alloc(Logger.Slot, if (config.log_fd != null) config.log_slots else 0);
            errdefer if (!transferred) gpa.free(log_slots);
            var executor: if (isolated_application) ApplicationExecutor else void = undefined;
            if (comptime isolated_application) try executor.init(
                gpa,
                io,
                .{
                    .owner = self,
                    .completion_capacity = config.max_connections + config.http2.max_streams_per_worker,
                    .worker_count = if (worker_id == 0) config.workers else 0,
                },
            );
            errdefer if (!transferred and isolated_application) executor.deinit(gpa);
            self.* = .{
                .config = config,
                .io = io,
                .shared = shared,
                .worker_id = worker_id,
                .worker_cpu = if (cpus.len == 0) null else cpus[worker_id],
                .public_free = 0,
                .admin_free = if (worker_id == 0 and config.admin_connections > 0)
                    config.max_connections
                else
                    null,
                .gpa = gpa,
                .http2_allocator = .{
                    .gpa = gpa,
                    .io = io,
                    .mutex = &shared.allocator_mutex,
                    .limit = config.http2.memory_bytes,
                },
                .ring = ring,
                .listener = listener,
                .admin_listener = admin_listener,
                .redirect_listener = redirect_listener,
                .connections = connections,
                .batches = batches,
                .active_slots = active_slots,
                .storage = storage,
                .connection_buffers = .{ .size = public_stride },
                .log_slots = log_slots,
                .stop = stop,
                .application_runtime = application_runtime,
                .executor = executor,
                .application_event_fd = application_event_fd,
            };
            for (batches) |*batch| {
                batch.* = .{ .next = self.free_batch };
                self.free_batch = batch;
            }
            // From here, self owns every resource; its ring is destroyed before
            // freeing any buffer that might still be referenced by the kernel.
            transferred = true;
            self.public_authority_len = defaultAuthority(
                &self.public_authority,
                config.address,
                listener.port,
                if (config.tls != null) 443 else 80,
            ).len;
            if (admin_listener.fd >= 0)
                self.admin_authority_len = defaultAuthority(
                    &self.admin_authority,
                    config.admin_address,
                    admin_listener.port,
                    80,
                ).len;
            self.logger.init(log_slots, &self.metrics, config.verbose);
            self.logger.worker = worker_id;
            self.logger.enabled = config.log_fd != null;
            self.admission.init(admission_options, platform.monotonicNs());
            for (&self.buffer_pools, fullCapacities(config)) |*pool, size| pool.size = size;
            for (connections, 0..) |*connection, index| {
                const admin = index >= config.max_connections;
                connection.* = .{
                    .admin = admin,
                    .small_storage = if (admin)
                        storage[(index - config.max_connections) * admin_stride ..][0..admin_stride]
                    else
                        &.{},
                    .next_free = if (index + 1 == config.max_connections or index + 1 == count)
                        null
                    else
                        index + 1,
                };
                if (admin) self.assignConnectionBuffers(connection);
            }
            errdefer self.deinit();
            for (0..@min(config.max_connections, BufferPool.cache_limit)) |_| {
                const block = try self.createBuffer(&self.connection_buffers);
                const retained = self.connection_buffers.put(block);
                std.debug.assert(retained);
            }
            for (0..@min(config.max_connections, request_cache_limit)) |_| {
                const request = try self.createRequest();
                request.next = self.free_request;
                self.free_request = request;
                self.request_cached += 1;
            }
            for (connections[config.max_connections..]) |*connection| {
                const request = try self.createRequest();
                connection.request_lease = request;
                connection.parser = &request.parser;
                connection.exchange = &request.exchange;
                self.initParser(connection);
            }
            self.updateConnectionBufferMetrics();
            self.updateRequestMetrics();
        }

        fn createRequest(self: *Self) std.mem.Allocator.Error!*Request {
            if (self.shared) |shared| shared.allocator_mutex.lockUncancelable(self.io);
            defer if (self.shared) |shared| shared.allocator_mutex.unlock(self.io);
            const request = try self.gpa.create(Request);
            request.next = null;
            return request;
        }

        fn destroyRequest(self: *Self, request: *Request) void {
            if (self.shared) |shared| shared.allocator_mutex.lockUncancelable(self.io);
            defer if (self.shared) |shared| shared.allocator_mutex.unlock(self.io);
            self.gpa.destroy(request);
        }

        fn initParser(self: *Self, connection: *Connection) void {
            connection.parser.init(
                self.smallBuffer(connection, .head),
                self.smallBuffer(connection, .trailers),
                .{
                    .max_body_bytes = self.config.max_body_bytes,
                    .max_chunk_framing_bytes = self.config.max_chunk_framing_bytes,
                },
            );
        }

        fn acquireRequest(self: *Self, connection: *Connection) bool {
            if (connection.request_lease != null) return true;
            std.debug.assert(!connection.admin);
            const request = if (self.free_request) |request| cached: {
                self.free_request = request.next;
                self.request_cached -= 1;
                break :cached request;
            } else allocated: {
                const request = self.createRequest() catch {
                    self.metrics.recorder().add(.request_storage_exhaustions_total, 1);
                    return false;
                };
                self.metrics.recorder().add(.request_storage_allocations_total, 1);
                break :allocated request;
            };
            connection.request_lease = request;
            connection.parser = &request.parser;
            connection.exchange = &request.exchange;
            self.initParser(connection);
            self.request_active += 1;
            self.updateRequestMetrics();
            return true;
        }

        fn releaseRequest(self: *Self, connection: *Connection) void {
            if (connection.admin) return;
            const request = connection.request_lease orelse return;
            std.debug.assert(!connection.application_initialized);
            connection.request_lease = null;
            connection.parser = undefined;
            connection.exchange = undefined;
            self.request_active -= 1;
            if (self.request_cached < request_cache_limit) {
                request.next = self.free_request;
                self.free_request = request;
                self.request_cached += 1;
            } else self.destroyRequest(request);
            self.updateRequestMetrics();
        }

        fn updateRequestMetrics(self: *Self) void {
            self.metrics.set(.request_storage_active, self.request_active);
            self.metrics.set(.request_storage_cached, self.request_cached);
        }

        fn fullCapacities(config: Config) [6]usize {
            return .{
                config.header_bytes,
                config.trailer_bytes,
                (http.Parser.Limits{}).max_target_bytes,
                config.receive_bytes,
                config.response_bytes,
                config.application_bytes,
            };
        }

        fn storageSize(config: Config, admin: bool) usize {
            // Preserve distinct cache sets for buffer starts and an odd-line stride.
            var size: usize = 7 * buffer_gap;
            for (fullCapacities(config), small_capacities) |full, small|
                size += if (admin) full else @min(full, small);
            return size;
        }

        fn smallBuffer(self: *const Self, connection: *const Connection, kind: Buffer) []u8 {
            var offset: usize = 0;
            for (
                fullCapacities(self.config),
                small_capacities,
                0..,
            ) |full, small, index| {
                const size = if (connection.admin) full else @min(full, small);
                if (index == @intFromEnum(kind)) return connection.small_storage[offset..][0..size];
                offset += size + buffer_gap;
            }
            unreachable;
        }

        fn assignConnectionBuffers(self: *Self, connection: *Connection) void {
            connection.path_buffer = self.smallBuffer(connection, .path);
            connection.receive_buffer = self.smallBuffer(connection, .receive);
            connection.output_buffer = self.smallBuffer(connection, .output);
            connection.application_buffer = self.smallBuffer(connection, .application);
        }

        fn acquireConnectionBuffers(self: *Self, connection: *Connection) bool {
            if (connection.admin) return true;
            std.debug.assert(connection.small_block == null and connection.small_storage.len == 0);
            const block = self.connection_buffers.take() orelse allocated: {
                const block = self.createBuffer(&self.connection_buffers) catch {
                    self.metrics.recorder().add(.connection_buffer_exhaustions_total, 1);
                    return false;
                };
                self.metrics.recorder().add(.connection_buffer_allocations_total, 1);
                break :allocated block;
            };
            connection.small_block = block;
            connection.small_storage = block.bytes;
            self.assignConnectionBuffers(connection);
            self.updateConnectionBufferMetrics();
            return true;
        }

        fn releaseConnectionBuffers(self: *Self, connection: *Connection) void {
            const block = connection.small_block orelse return;
            // Deinit destroys the ring first; fatal cleanup can leave stale
            // per-connection completion counts after all kernel access has ended.
            std.debug.assert(connection.request_lease == null);
            std.debug.assert(!connection.application_initialized);
            if (!self.connection_buffers.put(block)) self.destroyBuffer(block);
            connection.small_block = null;
            connection.small_storage = &.{};
            connection.path_buffer = undefined;
            connection.receive_buffer = undefined;
            connection.output_buffer = undefined;
            connection.application_buffer = undefined;
            self.updateConnectionBufferMetrics();
        }

        fn updateConnectionBufferMetrics(self: *Self) void {
            const pool = &self.connection_buffers;
            self.metrics.set(.connection_buffer_bytes_active, pool.borrowed * pool.size);
            self.metrics.set(.connection_buffer_bytes_cached, pool.cached * pool.size);
        }

        fn bufferSlice(connection: *Connection, kind: Buffer) *[]u8 {
            return switch (kind) {
                .head => &connection.parser.head_storage,
                .trailers => &connection.parser.trailer_storage,
                .path => &connection.path_buffer,
                .receive => &connection.receive_buffer,
                .output => &connection.output_buffer,
                .application => &connection.application_buffer,
            };
        }

        fn createBuffer(self: *Self, pool: *BufferPool) std.mem.Allocator.Error!*BufferPool.Block {
            if (self.shared) |shared| shared.allocator_mutex.lockUncancelable(self.io);
            defer if (self.shared) |shared| shared.allocator_mutex.unlock(self.io);
            return pool.create(self.gpa);
        }

        fn destroyBuffer(self: *Self, block: *BufferPool.Block) void {
            if (self.shared) |shared| shared.allocator_mutex.lockUncancelable(self.io);
            defer if (self.shared) |shared| shared.allocator_mutex.unlock(self.io);
            BufferPool.destroy(self.gpa, block);
        }

        fn allocateResponseStream(self: *Self, size: usize) std.mem.Allocator.Error![]u8 {
            if (size > self.config.large_buffer_bytes - self.buffer_bytes_active)
                return error.OutOfMemory;
            if (self.shared) |shared| shared.allocator_mutex.lockUncancelable(self.io);
            defer if (self.shared) |shared| shared.allocator_mutex.unlock(self.io);
            const bytes = try self.gpa.alloc(u8, size);
            self.buffer_bytes_active += size;
            self.updateBufferMetrics();
            return bytes;
        }

        fn freeResponseStream(self: *Self, connection: *Connection) void {
            if (connection.response_stream_buffer.len == 0) return;
            if (self.shared) |shared| shared.allocator_mutex.lockUncancelable(self.io);
            defer if (self.shared) |shared| shared.allocator_mutex.unlock(self.io);
            self.buffer_bytes_active -= connection.response_stream_buffer.len;
            self.gpa.free(connection.response_stream_buffer);
            connection.response_stream_buffer = &.{};
            self.updateBufferMetrics();
        }

        fn ensureBuffer(self: *Self, connection: *Connection, kind: Buffer) bool {
            const index = @intFromEnum(kind);
            const pool = &self.buffer_pools[index];
            const destination = bufferSlice(connection, kind);
            if (destination.len >= pool.size) return true;
            if (pool.size > self.config.large_buffer_bytes - self.buffer_bytes_active) return false;
            const block = pool.take() orelse allocated: {
                const block = self.createBuffer(pool) catch return false;
                self.metrics.recorder().add(.buffer_allocations_total, 1);
                break :allocated block;
            };
            std.debug.assert(connection.large_buffers[index] == null);
            switch (kind) {
                .head => {
                    std.debug.assert(connection.parser.phase == .head);
                    @memcpy(
                        block.bytes[0..connection.parser.head_len],
                        destination.*[0..connection.parser.head_len],
                    );
                },
                .receive => {
                    std.debug.assert(!connection.receive_pending);
                    @memcpy(
                        block.bytes[0..connection.receive_end],
                        destination.*[0..connection.receive_end],
                    );
                },
                .trailers => std.debug.assert(connection.parser.trailer_count == 0),
                .application => std.debug.assert(!connection.application_initialized),
                .path, .output => {},
            }
            destination.* = block.bytes;
            connection.large_buffers[index] = block;
            self.buffer_bytes_active += pool.size;
            self.updateBufferMetrics();
            return true;
        }

        fn releaseBuffers(self: *Self, connection: *Connection, closing: bool) void {
            var released = false;
            inline for (std.meta.tags(Buffer)) |kind| {
                const index = @intFromEnum(kind);
                if (connection.large_buffers[index]) |block| release: {
                    if (kind == .receive and !closing and
                        (connection.receive_pending or connection.receive_start < connection.receive_end))
                        break :release;
                    const pool = &self.buffer_pools[index];
                    self.buffer_bytes_active -= block.bytes.len;
                    if (!pool.put(block)) self.destroyBuffer(block);
                    connection.large_buffers[index] = null;
                    bufferSlice(connection, kind).* = self.smallBuffer(connection, kind);
                    if (kind == .receive) {
                        connection.receive_start = 0;
                        connection.receive_end = 0;
                    }
                    released = true;
                }
            }
            if (released) self.updateBufferMetrics();
        }

        fn updateBufferMetrics(self: *Self) void {
            self.metrics.set(.buffer_bytes_active, self.buffer_bytes_active);
            var cached: usize = 0;
            for (self.buffer_pools) |pool| cached += pool.cached * pool.size;
            self.metrics.set(.buffer_bytes_cached, cached);
        }

        fn bufferUnavailable(self: *Self, index: usize) RunError!void {
            self.metrics.recorder().add(.buffer_exhaustions_total, 1);
            try self.reject(index, 503, "buffer_budget");
        }

        /// Releases worker-owned resources. Asserts all I/O has completed; the
        /// owning event-loop thread must have returned before this call.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.pending == 0);
            // On fatal ring errors, application threads have been joined by
            // Server before deinit even if their completions were not dispatched.
            for (self.connections) |*connection| if (connection.http2) |session| {
                var item = session.streams;
                while (item) |stream| : (item = stream.next) stream.busy = false;
                self.releaseHttp2(connection);
            };
            Http2.releaseCache(self.http2_allocator.allocator(), self);
            if (comptime isolated_application) self.executor.deinit(self.gpa);
            self.ring.deinit();
            if (self.waiting_accept >= 0) platform.close(self.waiting_accept);
            for (self.connections) |*connection| {
                if (connection.fd >= 0) {
                    connection.response_stream_busy = false;
                    if (comptime can_batch) self.abortBatch(connection);
                    self.releaseApplication(connection);
                    self.releaseBuffers(connection, true);
                    platform.close(connection.fd);
                }
                self.releaseTls(connection);
                if (connection.request_lease) |request| {
                    self.destroyRequest(request);
                    connection.request_lease = null;
                }
                self.releaseConnectionBuffers(connection);
            }
            while (self.free_request) |request| {
                self.free_request = request.next;
                self.destroyRequest(request);
            }
            for (&self.buffer_pools) |*pool| pool.deinit(self.gpa);
            self.connection_buffers.deinit(self.gpa);
            platform.close(self.listener.fd);
            if (self.redirect_listener.fd >= 0) platform.close(self.redirect_listener.fd);
            if (self.admin_listener.fd >= 0) platform.close(self.admin_listener.fd);
            if (self.application_event_fd >= 0) platform.close(self.application_event_fd);
            self.gpa.free(self.log_slots);
            self.gpa.free(self.storage);
            self.gpa.free(self.active_slots);
            self.gpa.free(self.batches);
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

        fn queueApplicationEvent(self: *Self) RunError!void {
            if (comptime !isolated_application) comptime unreachable;
            try self.ensureSubmission();
            _ = self.ring.read(
                control(.application),
                self.application_event_fd,
                .{ .buffer = std.mem.asBytes(&self.application_event_value) },
                0,
            ) catch return error.IoUringResources;
            self.application_event_pending = true;
            self.queued();
        }

        fn loop(self: *Self) RunError!void {
            errdefer {
                if (self.shared) |shared| shared.abort.store(true, .monotonic);
                for (self.connections) |*connection| {
                    connection.canceled.store(true, .release);
                    if (connection.http2) |session| session.abort();
                    if (comptime has_response_streams) {
                        if (connection.response_stream_started) connection.exchange.response_stream.cancel();
                    }
                }
                self.quiesce();
            }
            var completions: [256]linux.io_uring_cqe = undefined;
            while (true) {
                const begin_ns = platform.monotonicNs();
                if (self.shouldStop() and !self.draining) try self.beginShutdown(begin_ns);
                if (!self.stopping) {
                    if (!self.draining) {
                        try self.queueAccept(.public);
                        if (self.redirect_listener.fd >= 0) try self.queueAccept(.redirect);
                        if (self.admin_listener.fd >= 0) try self.queueAccept(.admin);
                    }
                    if (!self.ticking) {
                        try self.ensureSubmission();
                        _ = self.ring.timeout(control(.tick), &self.tick_interval, 0, 0) catch
                            return error.IoUringResources;
                        self.ticking = true;
                        self.queued();
                    }
                    if (comptime isolated_application) {
                        if (!self.application_event_pending) try self.queueApplicationEvent();
                    }
                    try self.queueLog();
                }
                self.metrics.set(.io_pending, self.pending);
                self.metrics.set(.connections_active, self.active_connections);
                self.metrics.set(.requests_active, self.admission.active);
                self.metrics.set(.rejections_active, self.admission.rejecting);
                self.metrics.set(.http2_streams_active, self.http2_streams);
                self.metrics.set(.http2_streams_cached, self.http2_cached);
                self.metrics.set(.http2_bytes_allocated, self.http2_allocator.used);
                if (self.pending == 0) break;
                self.metrics.recorder().observe(
                    .event_loop_duration_seconds,
                    platform.monotonicNs() - begin_ns,
                );
                _ = self.ring.submit() catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return error.IoUringResources,
                };
                const n = self.ring.copy_cqes(
                    completions[0..self.config.completion_budget],
                    1,
                ) catch |err| switch (err) {
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
                    (platform.monotonicNs() >= self.shutdown_deadline and !self.hasApplicationWork())))
                    try self.stopOperations();
            }
        }

        fn discardCompletion(self: *Self, completion: linux.io_uring_cqe) void {
            std.debug.assert(self.pending > 0);
            self.pending -= 1;
            const kind: Kind = @enumFromInt(@as(u8, @truncate(completion.user_data)));
            if ((kind == .accept or kind == .accept_admin or kind == .accept_redirect) and completion.res >= 0)
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
                .accept_redirect,
                .tick,
                .log_write,
                .application,
                .cancel_accept,
                .cancel_admin,
                .cancel_redirect,
                .cancel_tick,
                .cancel_log,
                .cancel_application,
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

        fn queueAccept(self: *Self, listener: Listener) RunError!void {
            if (self.shouldStop()) return;
            const admin = listener == .admin;
            const accepting = switch (listener) {
                .public => &self.accepting,
                .admin => &self.admin_accepting,
                .redirect => &self.redirect_accepting,
            };
            if (accepting.*) return;
            if (listener == .redirect and self.waiting_accept >= 0) return;
            if (listener == .public and self.waiting_accept >= 0) {
                const now = platform.monotonicNs();
                if (now >= self.waiting_deadline_ns) {
                    platform.close(self.waiting_accept);
                    self.waiting_accept = -1;
                    self.metrics.recorder().add(.connections_refused_total, 1);
                    self.metrics.recorder().add(.connection_reclaim_timeouts_total, 1);
                    return;
                }
                // Finish dispatching the previous CQ batch before deciding an
                // idle connection has no newly observed request to protect.
                if (self.public_free == null and !self.waiting_reclaim_started) {
                    if (self.idleCandidate(now)) |index| {
                        self.waiting_reclaim_started = true;
                        self.metrics.recorder().add(.connections_reclaimed_total, 1);
                        try self.forceClose(index);
                    }
                }
                if (self.public_free != null) {
                    const fd = self.waiting_accept;
                    self.waiting_accept = -1;
                    try self.acceptConnection(fd, .public);
                }
                return;
            }
            const retry_ns = switch (listener) {
                .public => self.accept_retry_ns,
                .admin => self.admin_retry_ns,
                .redirect => self.redirect_retry_ns,
            };
            if (retry_ns != 0 and platform.monotonicNs() < retry_ns) return;
            if (self.freeSlot(admin) == null and
                (listener != .public or self.idleCandidate(platform.monotonicNs()) == null)) return;
            const kind: Kind = switch (listener) {
                .public => .accept,
                .admin => .accept_admin,
                .redirect => .accept_redirect,
            };
            const fd = switch (listener) {
                .public => self.listener.fd,
                .admin => self.admin_listener.fd,
                .redirect => self.redirect_listener.fd,
            };
            try self.ensureSubmission();
            const peer = &self.accept_peers[@intFromEnum(listener)];
            peer.address_len = @sizeOf(@TypeOf(peer.address));
            _ = self.ring.accept(
                control(kind),
                fd,
                if (self.config.access_log) @ptrCast(&peer.address) else null,
                if (self.config.access_log) &peer.address_len else null,
                linux.SOCK.CLOEXEC,
            ) catch return error.IoUringResources;
            accepting.* = true;
            self.queued();
        }

        fn idleCandidate(self: *const Self, now: u64) ?usize {
            if (self.config.idle_reclaim_ms == 0) return null;
            const index = self.idle_first orelse return null;
            const connection = &self.connections[index];
            if (now -| connection.idle_since_ns < @as(u64, self.config.idle_reclaim_ms) * 1_000_000)
                return null;
            return index;
        }

        fn queueIdle(self: *Self, index: usize) void {
            if (self.config.idle_reclaim_ms == 0) return;
            const connection = &self.connections[index];
            if (connection.admin or connection.idle_queued or connection.phase != .reading or
                connection.request_started or connection.requests == 0) return;
            std.debug.assert(!hasBatch(connection) and !connection.application_initialized);
            connection.idle_previous = self.idle_last;
            connection.idle_next = null;
            connection.idle_since_ns = platform.monotonicNs();
            connection.idle_queued = true;
            if (self.idle_last) |previous| {
                self.connections[previous].idle_next = index;
            } else self.idle_first = index;
            self.idle_last = index;
        }

        fn removeIdle(self: *Self, index: usize) void {
            const connection = &self.connections[index];
            if (!connection.idle_queued) return;
            if (connection.idle_previous) |previous| {
                self.connections[previous].idle_next = connection.idle_next;
            } else self.idle_first = connection.idle_next;
            if (connection.idle_next) |next| {
                self.connections[next].idle_previous = connection.idle_previous;
            } else self.idle_last = connection.idle_previous;
            connection.idle_previous = null;
            connection.idle_next = null;
            connection.idle_queued = false;
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
                    shared.log_owner.cmpxchgStrong(
                        no_log_owner,
                        self.worker_id,
                        .acquire,
                        .monotonic,
                    ) != null) return;
            }
            try self.ensureSubmission();
            // Keep the selected prefix fixed across short writes so a worker
            // cannot extend its log ownership indefinitely as records arrive.
            if (self.log_batch_remaining == 0) {
                // Pipe writes must fit PIPE_BUF so cancellation cannot leave a
                // partial JSON record before another worker or the final drain.
                const batch_limit: usize = if (self.config.victoria_logs != null) 2 else self.log_iovecs.len;
                self.log_batch_remaining = @min(self.logger.count, batch_limit);
            }
            for (self.log_iovecs[0..self.log_batch_remaining], 0..) |*vector, index| {
                const slot = self.logger.peekAt(index).?;
                vector.* = .{ .base = slot.bytes[slot.sent..].ptr, .len = slot.len - slot.sent };
            }
            const sqe = self.ring.writev(
                control(.log_write),
                log_fd,
                self.log_iovecs[0..self.log_batch_remaining],
                std.math.maxInt(u64),
            ) catch
                return error.IoUringResources;
            sqe.flags |= linux.IOSQE_ASYNC;
            self.logging = true;
            self.queued();
        }

        fn releaseLog(self: *Self) void {
            if (self.shared) |shared| {
                _ = shared.log_owner.cmpxchgStrong(
                    self.worker_id,
                    no_log_owner,
                    .release,
                    .monotonic,
                );
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
                .connection = if (completion.user_data >> 32 != 0) completion.user_data & ~@as(
                    u64,
                    255,
                ) else null,
                .result = completion.res,
            });
            switch (kind) {
                .accept, .accept_admin, .accept_redirect => {
                    const listener: Listener = switch (kind) {
                        .accept => .public,
                        .accept_admin => .admin,
                        .accept_redirect => .redirect,
                        else => unreachable, // This prong handles only accept completions.
                    };
                    const retry_ns = switch (listener) {
                        .public => retry: {
                            self.accepting = false;
                            break :retry &self.accept_retry_ns;
                        },
                        .admin => retry: {
                            self.admin_accepting = false;
                            break :retry &self.admin_retry_ns;
                        },
                        .redirect => retry: {
                            self.redirect_accepting = false;
                            break :retry &self.redirect_retry_ns;
                        },
                    };
                    if (completion.res < 0) {
                        if (completion.res == -@as(i32, @intFromEnum(linux.E.CANCELED))) return;
                        // Shutting down a listener can finish its pending accept
                        // with EINVAL before the cancellation reaches the kernel.
                        if (self.draining and
                            completion.res == -@as(i32, @intFromEnum(linux.E.INVAL))) return;
                        if (completion.res == -@as(i32, @intFromEnum(linux.E.INVAL)) or
                            completion.res == -@as(i32, @intFromEnum(linux.E.NOSYS)) or
                            completion.res == -@as(i32, @intFromEnum(linux.E.OPNOTSUPP)))
                            return error.IoUringOperationUnsupported;
                        self.metrics.recorder().add(.io_errors_total, 1);
                        // Descriptor/memory exhaustion must not become a loop
                        // of immediately failing accepts that consumes the CPU.
                        const retry = platform.monotonicNs() + 100_000_000;
                        retry_ns.* = retry;
                        self.logger.emit(.{
                            .timestamp_ns = platform.realtimeNs(self.io),
                            .level = .warn,
                            .event = "accept_error",
                            .operation = @tagName(kind),
                            .result = completion.res,
                        });
                        return;
                    }
                    retry_ns.* = 0;
                    try self.acceptConnection(completion.res, listener);
                },
                .tick => {
                    self.ticking = false;
                    if (!self.stopping) try self.tick();
                },
                .application => {
                    self.application_event_pending = false;
                    if (completion.res < 0 and
                        completion.res != -@as(i32, @intFromEnum(linux.E.CANCELED)))
                        return error.IoUringResources;
                    if (!self.stopping) try self.finishApplications();
                },
                .log_write => {
                    self.logging = false;
                    if (self.config.victoria_logs != null and completion.res == -@as(i32, @intFromEnum(linux.E.CANCELED))) {
                        // Atomic pipe writes leave their records untouched on
                        // cancellation; the sender drains these after workers join.
                        self.releaseLog();
                        return;
                    }
                    if (completion.res <= 0) {
                        self.metrics.add(.log_write_errors_total, 1);
                        self.log_disabled = true;
                        self.releaseLog();
                        while (self.logger.peek() != null) self.logger.consume();
                    } else {
                        self.log_batch_remaining -= self.logger.consumeBytes(@intCast(completion.res));
                        if (self.log_batch_remaining == 0) self.releaseLog();
                    }
                },
                .cancel_accept,
                .cancel_admin,
                .cancel_redirect,
                .cancel_tick,
                .cancel_log,
                .cancel_application,
                => {},
                .receive,
                .send,
                .cancel_receive,
                .cancel_send,
                => {
                    const index: usize = @intCast((completion.user_data >> 8) & 0xffffff);
                    const generation: u32 = @truncate(completion.user_data >> 32);
                    const connection = &self.connections[index];
                    std.debug.assert(connection.fd >= 0 and connection.generation == generation);
                    std.debug.assert(connection.pending > 0);
                    connection.pending -= 1;
                    switch (kind) {
                        .receive => {
                            connection.receive_pending = false;
                            if (connection.phase != .canceling) {
                                if (connection.http2 != null) {
                                    try self.completedHttp2(index, completion.res, false);
                                } else if (connection.tls != null and connection.phase != .drain) {
                                    try self.receivedTls(index, completion.res);
                                } else try self.received(index, completion.res);
                            }
                        },
                        .send => {
                            connection.send_pending = false;
                            if (connection.phase != .canceling) {
                                if (connection.http2 != null) {
                                    try self.completedHttp2(index, completion.res, true);
                                } else if (connection.tls != null) {
                                    try self.sentTls(index, completion.res);
                                } else try self.sent(index, completion.res);
                            }
                        },
                        .cancel_receive => connection.cancel_receive_pending = false,
                        .cancel_send => connection.cancel_send_pending = false,
                        else => unreachable,
                    }
                    if (connection.phase == .canceling) self.finishClose(index);
                },
            }
        }

        fn acceptConnection(self: *Self, fd: linux.fd_t, listener: Listener) RunError!void {
            const admin = listener == .admin;
            if (self.draining or self.shouldStop()) {
                platform.close(fd);
                return;
            }
            const index = self.freeSlot(admin) orelse {
                if (listener == .public and self.config.idle_reclaim_ms != 0 and self.waiting_accept < 0) {
                    self.waiting_accept = fd;
                    self.waiting_deadline_ns = platform.monotonicNs() +
                        @as(u64, self.config.close_timeout_ms) * 1_000_000;
                    self.waiting_reclaim_started = false;
                    return;
                }
                platform.close(fd);
                self.metrics.recorder().add(.connections_refused_total, 1);
                return;
            };
            platform.setOption(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1) catch {
                platform.close(fd);
                self.metrics.recorder().add(.io_errors_total, 1);
                return;
            };
            const connection = &self.connections[index];
            if (!self.acquireConnectionBuffers(connection)) {
                platform.close(fd);
                self.metrics.recorder().add(.connections_refused_total, 1);
                self.accept_retry_ns = platform.monotonicNs() + 100_000_000;
                self.redirect_retry_ns = self.accept_retry_ns;
                return;
            }
            if (admin) self.admin_free = connection.next_free else self.public_free = connection.next_free;
            connection.next_free = null;
            connection.fd = fd;
            connection.redirect = listener == .redirect;
            connection.client_ip_len = if (self.config.access_log) @intCast(formatClientIp(
                &connection.client_ip,
                &self.accept_peers[@intFromEnum(listener)].address,
            ).len) else 0;
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
            if (listener == .public and self.config.tls != null) {
                connection.tls = self.createTls() catch |err| {
                    self.metrics.recorder().add(.tls_errors_total, 1);
                    self.event(index, .warn, "tls_error", @errorName(err));
                    try self.forceClose(index);
                    return;
                };
                connection.phase = .handshake;
                connection.deadline = platform.monotonicNs() +
                    @as(u64, self.config.tls.?.handshake_timeout_ms) * 1_000_000;
                try self.advanceTls(index);
                return;
            }
            try self.queueReceive(index);
        }

        fn createTls(self: *Self) Tls.Error!*Tls.Session {
            const shared = self.shared.?;
            shared.allocator_mutex.lockUncancelable(self.io);
            defer shared.allocator_mutex.unlock(self.io);
            const session = try self.gpa.create(Tls.Session);
            errdefer self.gpa.destroy(session);
            try session.init(&shared.tls.?);
            return session;
        }

        fn releaseTls(self: *Self, connection: *Connection) void {
            const session = connection.tls orelse return;
            session.deinit();
            if (self.shared) |shared| shared.allocator_mutex.lockUncancelable(self.io);
            defer if (self.shared) |shared| shared.allocator_mutex.unlock(self.io);
            self.gpa.destroy(session);
            connection.tls = null;
        }

        fn advanceTls(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            const session = connection.tls.?;
            std.debug.assert(!connection.receive_pending and !connection.send_pending);
            const operation = std.meta.activeTag(session.operation);
            const step = session.advance() catch |err| {
                self.metrics.recorder().add(.tls_errors_total, 1);
                self.event(index, .debug, "tls_error", @errorName(err));
                try self.forceClose(index);
                return;
            };
            switch (step) {
                .receive => |buffer| {
                    try self.ensureSubmission();
                    _ = self.ring.recv(
                        token(.receive, index, connection.generation),
                        connection.fd,
                        .{ .buffer = buffer },
                        0,
                    ) catch return error.IoUringResources;
                    connection.receive_pending = true;
                    connection.pending += 1;
                    self.queued();
                },
                .send => |bytes| {
                    try self.ensureSubmission();
                    _ = self.ring.send(
                        token(.send, index, connection.generation),
                        connection.fd,
                        bytes,
                        linux.MSG.NOSIGNAL,
                    ) catch return error.IoUringResources;
                    connection.send_pending = true;
                    connection.pending += 1;
                    self.queued();
                },
                .complete => |count| switch (operation) {
                    .handshake => {
                        self.metrics.recorder().add(.tls_handshakes_total, 1);
                        if (session.reused()) self.metrics.recorder().add(.tls_sessions_reused_total, 1);
                        if (session.isHttp2()) {
                            const gpa = self.http2_allocator.allocator();
                            const h2 = gpa.create(Http2) catch return self.forceClose(index);
                            h2.init(self, index, gpa) catch {
                                gpa.destroy(h2);
                                return self.forceClose(index);
                            };
                            connection.http2 = h2;
                            connection.phase = .http2;
                            try self.pumpHttp2(index);
                            return;
                        }
                        connection.phase = .reading;
                        connection.deadline = platform.monotonicNs() +
                            @as(u64, self.config.header_timeout_ms) * 1_000_000;
                        try self.queueReceive(index);
                    },
                    .read => {
                        if (count == 0 and !connection.request_started) {
                            try self.drainConnection(index, platform.monotonicNs());
                        } else try self.received(index, @intCast(count));
                    },
                    .write => try self.sent(index, @intCast(count)),
                    .shutdown => try self.beginTcpDrain(index),
                    .idle => unreachable,
                },
            }
        }

        /// Internal executor entry point for a stream that owns its borrowed
        /// metadata and body until finishApplications consumes the completion.
        pub fn submitHttp2(
            self: *Self,
            index: usize,
            stream: *Http2.Stream,
            stage: http2.Stage,
        ) bool {
            if (comptime !isolated_application) comptime unreachable;
            const connection = &self.connections[index];
            if (!self.shared.?.workers[0].executor.submit(stream.exchange.lane(), .{
                .owner = self,
                .index = index,
                .generation = connection.generation,
                .stage = switch (stage) {
                    .head => .head,
                    .body => .body,
                    .response => .response,
                    .produce => .produce,
                },
                .deadline_ns = stream.application_deadline,
                .stream = stream,
            })) {
                self.metrics.recorder().add(.application_queue_rejections_total, 1);
                return false;
            }
            stream.busy = true;
            connection.pending += 1;
            return true;
        }

        fn releaseHttp2(self: *Self, connection: *Connection) void {
            const session = connection.http2 orelse return;
            session.deinit();
            self.http2_allocator.allocator().destroy(session);
            connection.http2 = null;
        }

        /// Records a stream once, after its application hooks have returned.
        pub fn recordHttp2(self: *Self, index: usize, stream: *Http2.Stream, completed: bool) void {
            const duration = platform.monotonicNs() - stream.started_ns;
            self.metrics.recorder().observe(if (!completed)
                .aborted_duration_seconds
            else if (stream.permit == .admit)
                .admitted_duration_seconds
            else
                .rejected_duration_seconds, duration);
            if (!self.config.access_log or (stream.permit == .reject and !self.config.verbose)) return;
            if (comptime @hasDecl(App.Exchange, "takeAccessDrops")) {
                if (stream.initialized) self.metrics.add(
                    .log_dropped_total,
                    stream.exchange.takeAccessDrops(),
                );
            }
            self.logger.emit(.{
                .timestamp_ns = platform.realtimeNs(self.io),
                .event = if (completed) "request_complete" else "request_aborted",
                .connection = token(
                    .receive,
                    index,
                    self.connections[index].generation,
                ) & ~@as(u64, 255),
                .client_ip = self.connections[index].client_ip[0..self.connections[index].client_ip_len],
                .user_agent = stream.request.getHeader("user-agent"),
                .status = if (stream.response) |response| response.status else null,
                .method = stream.request.method,
                .duration_ns = duration,
                .bytes = stream.produced,
                .phase = "http2",
                .route = if (@hasDecl(App.Exchange, "routeName") and stream.initialized)
                    stream.exchange.routeName()
                else
                    null,
                .fields = if (@hasDecl(App.Exchange, "accessFields") and stream.initialized)
                    stream.exchange.accessFields()
                else
                    &.{},
            });
        }

        fn completedHttp2(self: *Self, index: usize, result: i32, sending: bool) RunError!void {
            if (result <= 0) return self.forceClose(index);
            const session = self.connections[index].http2.?;
            const count: usize = @intCast(result);
            if (sending) {
                session.outgoing_start += count;
            } else {
                session.incoming_start = 0;
                session.incoming_end = count;
            }
            self.metrics.recorder().add(if (sending) .bytes_sent_total else .bytes_received_total, count);
            try self.pumpHttp2(index);
        }

        fn pumpHttp2(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            const session = connection.http2.?;
            const tls = connection.tls.?;
            const now = platform.monotonicNs();
            const second = platform.realtimeNs(self.io) / 1_000_000_000;
            if (second != self.date_second) {
                http.Response.formatDate(second, &self.date);
                self.date_second = second;
            }
            if ((self.draining and now >= self.shutdown_deadline) or
                (connection.send_pending and now >= session.send_deadline)) return self.forceClose(index);
            if (session.count == 0 and now >= session.idle_deadline)
                session.shutdown() catch return self.forceClose(index);
            // Socket operations borrow only external buffers. SSL/BIO and nghttp2
            // remain confined to this thread even with both operations in flight.
            for (0..64) |_| {
                var progress = false;
                if (!connection.receive_pending and session.incoming_start < session.incoming_end) {
                    const consumed = tls.feedCiphertext(
                        session.incoming[session.incoming_start..session.incoming_end],
                    );
                    session.incoming_start += consumed;
                    progress = consumed != 0;
                }
                if (session.closing) {
                    if (connection.send_pending) break;
                    switch (tls.advance() catch return self.forceClose(index)) {
                        .send => |bytes| {
                            @memcpy(session.outgoing[0..bytes.len], bytes);
                            session.outgoing_start = 0;
                            session.outgoing_end = bytes.len;
                            tls.sent(bytes.len);
                        },
                        .receive => {},
                        .complete => return self.forceClose(index),
                    }
                    break;
                }
                session.drive() catch return self.forceClose(index);
                if (!session.write_retry) {
                    if (tls.readPlaintext(&session.plaintext) catch return self.forceClose(index)) |count| {
                        if (count == 0) return self.forceClose(index);
                        const consumed = session.engine.receive(session.plaintext[0..count]) catch
                            return self.forceClose(index);
                        if (consumed != count) return self.forceClose(index);
                        progress = true;
                        session.drive() catch return self.forceClose(index);
                    }
                    if (session.pending_plaintext.len == 0)
                        session.pending_plaintext = session.output() catch return self.forceClose(index);
                }
                if (session.pending_plaintext.len != 0) {
                    const bytes = session.pending_plaintext[0..@min(
                        session.pending_plaintext.len,
                        16 * 1024,
                    )];
                    if (session.write_retry or tls.canWritePlaintext(bytes.len)) {
                        if (tls.writePlaintext(bytes) catch return self.forceClose(index)) |count| {
                            session.pending_plaintext = session.pending_plaintext[count..];
                            session.write_retry = false;
                            progress = true;
                        } else session.write_retry = true;
                    }
                }
                if (!connection.send_pending and session.outgoing_start == session.outgoing_end) {
                    session.outgoing_start = 0;
                    session.outgoing_end = tls.drainCiphertext(&session.outgoing);
                    progress = progress or session.outgoing_end != 0;
                }
                if (!progress) break;
            }
            if (!connection.send_pending and session.outgoing_start < session.outgoing_end) {
                try self.ensureSubmission();
                _ = self.ring.send(
                    token(.send, index, connection.generation),
                    connection.fd,
                    session.outgoing[session.outgoing_start..session.outgoing_end],
                    linux.MSG.NOSIGNAL,
                ) catch return error.IoUringResources;
                connection.send_pending = true;
                connection.pending += 1;
                session.send_deadline = now + @as(u64, self.config.write_timeout_ms) * 1_000_000;
                self.queued();
            }
            if (!session.closing and !connection.send_pending and session.pending_plaintext.len == 0 and
                session.pending_frame.len == 0 and
                (!session.engine.wantsRead() or (session.count == 0 and session.draining)))
            {
                // A terminal protocol error stops engine input even with live
                // streams. Cancel them after flushing GOAWAY; their ordinary
                // deadlines must not retain a connection that cannot progress.
                // Graceful GOAWAY keeps engine input enabled for accepted streams.
                if (session.count != 0) session.abort();
                session.closing = true;
                tls.start(.shutdown);
                return self.pumpHttp2(index);
            }
            if (!connection.receive_pending and session.incoming_start == session.incoming_end) {
                try self.ensureSubmission();
                _ = self.ring.recv(
                    token(.receive, index, connection.generation),
                    connection.fd,
                    .{ .buffer = &session.incoming },
                    0,
                ) catch return error.IoUringResources;
                connection.receive_pending = true;
                connection.pending += 1;
                self.queued();
            }
        }

        fn receivedTls(self: *Self, index: usize, result: i32) RunError!void {
            const connection = &self.connections[index];
            const session = connection.tls.?;
            if (result > 0) session.received(@intCast(result));
            if (result <= 0 and result != -@as(i32, @intFromEnum(linux.E.CANCELED))) {
                self.metrics.recorder().add(.peer_disconnects_total, 1);
                try self.forceClose(index);
                return;
            }
            if (connection.phase == .tls_shutdown and session.operation == .read) {
                session.start(.shutdown);
            } else if (connection.phase == .writing and session.operation == .read) {
                // A request deadline canceled a receive before producing a 408.
                try self.queueSend(index);
                return;
            }
            try self.advanceTls(index);
        }

        fn sentTls(self: *Self, index: usize, result: i32) RunError!void {
            if (result <= 0) {
                self.metrics.recorder().add(.io_errors_total, 1);
                try self.forceClose(index);
                return;
            }
            const connection = &self.connections[index];
            const session = connection.tls.?;
            session.sent(@intCast(result));
            if (connection.phase == .tls_shutdown and session.operation == .read) {
                session.start(.shutdown);
            } else if (connection.phase == .writing and session.operation == .read) {
                try self.queueSend(index);
                return;
            }
            try self.advanceTls(index);
        }

        fn prepareRequest(self: *Self, connection: *Connection, now: u64) void {
            self.releaseBuffers(connection, false);
            connection.application_initialized = false;
            if (connection.receive_start == connection.receive_end) self.releaseRequest(connection);
            if (connection.request_lease != null) self.initParser(connection);
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
            if (comptime isolated_application) connection.application_body = &.{};
            connection.close_after_response = false;
            connection.interim = false;
            connection.application_timed_out = false;
            connection.application_deadline_ns = 0;
            connection.canceled.store(false, .release);
            connection.response_stream_started = false;
            connection.response_stream_busy = false;
            connection.response_stream_chunk = false;
            connection.deadline = now + @as(u64, self.config.idle_timeout_ms) * 1_000_000;
        }

        fn initExchange(self: *Self, connection: *Connection) void {
            std.debug.assert(!connection.application_initialized);
            if (comptime @hasDecl(App.Exchange, "initApplication")) {
                connection.exchange.initApplication(connection.application_buffer, self.application_runtime);
            } else connection.exchange.init(connection.application_buffer);
            if (comptime @hasDecl(App.Exchange, "setCancellation"))
                connection.exchange.setCancellation(&connection.canceled);
            connection.application_initialized = true;
        }

        fn queueReceive(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            if (comptime can_batch) {
                if (connection.batch != null) {
                    try self.queueBatch(index);
                    return;
                }
            }
            if (connection.more_pending) {
                // A fragmented next request must not hold an earlier response.
                const enabled: c_int = 1;
                if (linux.errno(linux.setsockopt(
                    connection.fd,
                    linux.IPPROTO.TCP,
                    linux.TCP.NODELAY,
                    @ptrCast(&enabled),
                    @sizeOf(c_int),
                )) != .SUCCESS) {
                    try self.forceClose(index);
                    return;
                }
                connection.more_pending = false;
                connection.more_count = 0;
            }
            if (connection.receive_pending) return;
            std.debug.assert(
                connection.receive_start == connection.receive_end or connection.phase == .drain,
            );
            self.queueIdle(index);
            connection.receive_start = 0;
            connection.receive_end = 0;
            if (connection.tls) |session| {
                if (connection.phase != .drain) {
                    session.start(.{ .read = connection.receive_buffer });
                    try self.advanceTls(index);
                    return;
                }
            }
            try self.ensureSubmission();
            _ = self.ring.recv(
                token(.receive, index, connection.generation),
                connection.fd,
                .{
                    .buffer = connection.receive_buffer,
                },
                0,
            ) catch return error.IoUringResources;
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
                if (!connection.request_started and connection.receive_start == connection.receive_end) {
                    try self.queueReceive(index);
                    return;
                }
                if (!self.acquireRequest(connection)) {
                    try self.forceClose(index);
                    return;
                }
                if (!connection.request_started and connection.receive_start < connection.receive_end) {
                    const now = platform.monotonicNs();
                    if (self.draining and now >= self.shutdown_keepalive_deadline) {
                        if (comptime can_batch) {
                            if (hasBatch(connection)) {
                                try self.queueBatch(index);
                                return;
                            }
                        }
                        try self.drainConnection(index, now);
                        return;
                    }
                    self.removeIdle(index);
                    connection.request_started = true;
                    connection.started_ns = now;
                    connection.deadline = connection.started_ns + @as(
                        u64,
                        self.config.header_timeout_ms,
                    ) * 1_000_000;
                    connection.request_id = self.next_request;
                    self.next_request +%= 1;
                    self.metrics.recorder().add(.requests_total, 1);
                }
                // A request already started, or observed in the bounded final
                // keepalive window, still competes for the ordinary budgets.
                const draining = self.draining and
                    connection.started_ns >= self.shutdown_keepalive_deadline;
                if (!connection.admin and connection.request_started and connection.parser.phase == .head and
                    self.admission.exhausted(draining))
                {
                    self.admission.refill(platform.monotonicNs());
                    if (self.admission.exhausted(draining)) {
                        if (comptime can_batch) {
                            if (connection.batch != null) {
                                // Complete earlier admitted responses before the
                                // next request exhausts the close-only budget.
                                try self.queueBatch(index);
                                return;
                            }
                        }
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
                var input = connection.receive_buffer[connection.receive_start..connection.receive_end];
                if (connection.parser.phase == .head and input.len != 0) {
                    if (connection.parser.head_len == connection.parser.head_storage.len) {
                        if (connection.parser.head_storage.len == self.config.header_bytes) {
                            self.metrics.recorder().add(.protocol_errors_total, 1);
                            try self.reject(index, 431, "HeadersTooLarge");
                            return;
                        }
                        if (!self.ensureBuffer(connection, .head)) return self.bufferUnavailable(index);
                    }
                    // Stop at storage capacity before feed declares a protocol error;
                    // a later loop can grow an incomplete head without moving parsed slices.
                    input = input[0..@min(
                        input.len,
                        connection.parser.head_storage.len - connection.parser.head_len,
                    )];
                }
                const step = connection.parser.feed(input) catch |err| {
                    self.metrics.recorder().add(.protocol_errors_total, 1);
                    try self.reject(index, http.Parser.status(err), @errorName(err));
                    return;
                };
                connection.receive_start += step.consumed;
                switch (step.event) {
                    .need_input => {
                        if (connection.receive_start < connection.receive_end) continue;
                        try self.queueReceive(index);
                        return;
                    },
                    .head => |request| {
                        const now = platform.monotonicNs();
                        self.metrics.recorder().observe(
                            .header_duration_seconds,
                            now - connection.started_ns,
                        );
                        connection.deadline = now + @as(u64, self.config.body_timeout_ms) * 1_000_000;
                        if (request.scheme) |scheme| {
                            if (!http.syntax.eql(scheme, if (connection.tls != null) "https" else "http")) {
                                try self.reject(index, 421, "target_scheme");
                                return;
                            }
                        }
                        // Raw target/headers keep their original octets. Only the
                        // routing view is canonicalized, in separate stable storage.
                        if (request.path.len > connection.path_buffer.len and !self.ensureBuffer(
                            connection,
                            .path,
                        ))
                            return self.bufferUnavailable(index);
                        connection.parser.request.path = http.path.normalize(
                            connection.path_buffer,
                            request.path,
                        ) catch {
                            try self.reject(index, 400, "target_path");
                            return;
                        };
                        if (request.scheme == null and !std.mem.eql(
                            u8,
                            request.method,
                            "CONNECT",
                        )) {
                            connection.parser.request.scheme =
                                if (connection.tls != null) "https" else "http";
                            if (request.authority.len == 0) {
                                connection.parser.request.authority = if (connection.admin)
                                    self.admin_authority[0..self.admin_authority_len]
                                else
                                    self.public_authority[0..self.public_authority_len];
                            }
                        }
                        if (!connection.admin) {
                            const decision = self.admission.acquire(now, draining);
                            connection.permit = decision;
                            switch (decision) {
                                .admit => self.metrics.recorder().add(.requests_admitted_total, 1),
                                .reject => {
                                    self.metrics.recorder().add(.requests_rejected_total, 1);
                                    self.rejectionEvent(index, "admission_limit");
                                    // Only a bodyless head is a complete request
                                    // boundary. Unread bodies require closure.
                                    try self.respondStatus(
                                        index,
                                        503,
                                        request.chunked or (request.content_length orelse 0) > 0,
                                    );
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
                            if (connection.redirect) {
                                try self.redirectHttp(index);
                                return;
                            }
                            // Rejected heads never consume body-storage leases.
                            // Admin buffers already have their full capacity.
                            if (request.chunked) {
                                if (!self.ensureBuffer(connection, .trailers) or !self.ensureBuffer(connection, .receive))
                                    return self.bufferUnavailable(index);
                            } else if ((request.content_length orelse 0) > connection.receive_buffer.len) {
                                if (!self.ensureBuffer(
                                    connection,
                                    .receive,
                                )) return self.bufferUnavailable(index);
                            }
                            if (App != application or request.chunked or
                                (request.content_length orelse 0) > connection.application_buffer.len)
                            {
                                if (!self.ensureBuffer(
                                    connection,
                                    .application,
                                )) return self.bufferUnavailable(index);
                            }
                            self.initExchange(connection);
                            if (comptime @hasDecl(App.Exchange, "setRequestRuntime")) {
                                connection.exchange.setRequestRuntime(
                                    &self.application_metrics,
                                    self.io,
                                    token(.receive, index, connection.generation) & ~@as(u64, 255),
                                    connection.request_id,
                                );
                            }
                            const early_response = if (comptime isolated_application)
                                connection.exchange.prepareHead(request)
                            else
                                connection.exchange.receiveHead(request);
                            if (comptime !isolated_application and @hasDecl(App.Exchange, "flushLogs"))
                                connection.exchange.flushLogs(&self.logger);
                            if (early_response) |response| {
                                var early = response;
                                early.close = early.close or request.chunked or
                                    (request.content_length orelse 0) > 0;
                                try self.startResponse(index, early);
                                return;
                            }
                            if (comptime isolated_application) {
                                const inline_head = if (comptime @hasDecl(App.Exchange, "canRunHeadInline"))
                                    connection.exchange.canRunHeadInline()
                                else
                                    false;
                                if (inline_head) {
                                    self.beginApplicationDeadline(connection);
                                    connection.deadline = @min(
                                        connection.deadline,
                                        connection.application_deadline_ns,
                                    );
                                    if (connection.exchange.runHead(request)) |response| {
                                        var early = response;
                                        early.close = early.close or request.chunked or
                                            (request.content_length orelse 0) > 0;
                                        try self.startResponse(index, early);
                                        return;
                                    }
                                } else {
                                    if (!self.submitApplication(index, .head)) {
                                        try self.respondStatus(
                                            index,
                                            503,
                                            request.chunked or (request.content_length orelse 0) > 0,
                                        );
                                    }
                                    return;
                                }
                            }
                        } else if (try self.receiveAdminHead(index)) return;
                        try self.continueAfterHead(index);
                        if (connection.phase != .reading) return;
                    },
                    .body => |bytes| if (!connection.admin) {
                        if (comptime isolated_application and @hasDecl(App.Exchange, "streamsBody")) {
                            if (connection.exchange.streamsBody()) {
                                connection.application_body = bytes;
                                const stage: ApplicationExecutor.Stage = if (connection.parser.phase == .ending) final_stage: {
                                    // Fixed-length framing is complete. Keep the final
                                    // consumer and handler on the same application thread.
                                    const end = connection.parser.feed("") catch unreachable;
                                    std.debug.assert(end.event == .end and end.consumed == 0);
                                    break :final_stage .body_response;
                                } else .body;
                                if (!self.submitApplication(index, stage)) {
                                    connection.application_body = &.{};
                                    try self.respondStatus(index, 503, true);
                                }
                                return;
                            }
                        }
                        connection.exchange.receiveBody(bytes) catch |err| {
                            try self.reject(index, 413, @errorName(err));
                            return;
                        };
                    },
                    .trailer => {},
                    .end => {
                        if (connection.admin) {
                            try self.respondAdmin(index);
                        } else if (comptime isolated_application) {
                            if (!self.submitApplication(index, .response))
                                try self.respondStatus(index, 503, false);
                        } else {
                            const response = connection.exchange.respond(&connection.parser.request);
                            if (comptime @hasDecl(
                                App.Exchange,
                                "flushLogs",
                            )) connection.exchange.flushLogs(&self.logger);
                            try self.startResponse(index, response);
                        }
                        return;
                    },
                }
            }
        }

        fn beginApplicationDeadline(self: *Self, connection: *Connection) void {
            _ = self;
            if (connection.application_deadline_ns != 0) return;
            connection.application_deadline_ns = platform.monotonicNs() +
                @as(u64, App.laneOptions(connection.exchange.lane()).timeout_ms) * 1_000_000;
        }

        fn submitApplication(self: *Self, index: usize, stage: ApplicationExecutor.Stage) bool {
            if (comptime !isolated_application) comptime unreachable;
            const connection = &self.connections[index];
            connection.phase = .application;
            connection.application_timed_out = false;
            const lane = connection.exchange.lane();
            self.beginApplicationDeadline(connection);
            const deadline_ns = connection.application_deadline_ns;
            connection.deadline = deadline_ns;
            if (self.shared.?.workers[0].executor.submit(lane, .{
                .owner = self,
                .index = index,
                .generation = connection.generation,
                .stage = stage,
                .deadline_ns = deadline_ns,
            })) return true;
            self.metrics.recorder().add(.application_queue_rejections_total, 1);
            connection.phase = .reading;
            return false;
        }

        fn finishApplications(self: *Self) RunError!void {
            if (comptime !isolated_application) return;
            while (self.executor.takeCompletion()) |completion| {
                const index = completion.task.index;
                const connection = &self.connections[index];
                if (completion.task.stream) |stream| {
                    std.debug.assert(connection.generation == completion.task.generation);
                    connection.pending -= 1;
                    const session = connection.http2.?;
                    session.complete(
                        stream,
                        switch (completion.task.stage) {
                            .head => .head,
                            .body => .body,
                            .response => .response,
                            .produce => .produce,
                            .body_response => unreachable,
                        },
                        completion.response,
                        completion.expired,
                    ) catch {
                        try self.forceClose(index);
                        continue;
                    };
                    if (connection.phase == .canceling) {
                        self.finishClose(index);
                    } else try self.pumpHttp2(index);
                    continue;
                }
                if (completion.task.stage == .produce) {
                    if (comptime has_response_streams) {
                        std.debug.assert(connection.generation == completion.task.generation);
                        connection.response_stream_busy = false;
                        connection.pending -= 1;
                        connection.exchange.flushLogs(&self.logger);
                        if (completion.expired) self.timeoutApplication(connection);
                        if (connection.phase == .canceling or connection.application_timed_out) {
                            try self.forceClose(index);
                        } else try self.pumpResponseStream(index);
                    }
                    continue;
                }
                if (connection.generation != completion.task.generation or
                    connection.phase != .application)
                    continue;
                if (comptime @hasDecl(App.Exchange, "flushLogs")) connection.exchange.flushLogs(&self.logger);
                if (completion.expired) self.timeoutApplication(connection);
                if (connection.application_timed_out) {
                    try self.forceClose(index);
                    continue;
                }
                switch (completion.task.stage) {
                    .head => if (completion.response) |response| {
                        var early = response;
                        const request = &connection.parser.request;
                        early.close = early.close or request.chunked or (request.content_length orelse 0) > 0;
                        try self.startResponse(index, early);
                    } else {
                        connection.phase = .reading;
                        connection.deadline = @min(
                            connection.application_deadline_ns,
                            platform.monotonicNs() +
                                @as(u64, self.config.body_timeout_ms) * 1_000_000,
                        );
                        try self.continueAfterHead(index);
                        if (connection.phase == .reading) try self.processInput(index);
                    },
                    .body => {
                        connection.application_body = &.{};
                        if (completion.response) |response| {
                            try self.startResponse(index, response);
                        } else {
                            connection.phase = .reading;
                            connection.deadline = @min(
                                connection.application_deadline_ns,
                                platform.monotonicNs() +
                                    @as(u64, self.config.body_timeout_ms) * 1_000_000,
                            );
                            try self.processInput(index);
                        }
                    },
                    .body_response => {
                        connection.application_body = &.{};
                        try self.startResponse(index, completion.response.?);
                    },
                    .response => try self.startResponse(index, completion.response.?),
                    .produce => unreachable,
                }
            }
            // Publications wake the same eventfd as executor completions. A
            // producer can publish many times before its sole task completes.
            var position = self.active_connections;
            while (position > 0) {
                position -= 1;
                const index = self.active_slots[position];
                const connection = &self.connections[index];
                if (connection.phase == .http2) {
                    try self.pumpHttp2(index);
                } else if (comptime has_response_streams) {
                    if (connection.phase == .writing and connection.response_stream_started)
                        try self.pumpResponseStream(index);
                }
            }
        }

        fn continueAfterHead(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            const request = &connection.parser.request;
            self.event(index, .debug, "request_head", null);
            if (!request.expect_continue or (!request.chunked and (request.content_length orelse 0) == 0))
                return;
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
        }

        fn redirectHttp(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            const request = &connection.parser.request;
            // No application is dispatched. Location is copied
            // into the output buffer synchronously before startResponse returns.
            var writer: std.Io.Writer = .fixed(connection.application_buffer);
            writeHttpsLocation(&writer, request.authority, request.target, self.listener.port) catch |err| {
                switch (err) {
                    error.InvalidTarget => return self.reject(index, 400, "redirect_target"),
                    error.WriteFailed => {
                        if (!self.ensureBuffer(connection, .application)) return self.bufferUnavailable(index);
                        writer = .fixed(connection.application_buffer);
                        writeHttpsLocation(&writer, request.authority, request.target, self.listener.port) catch
                            return self.reject(index, 414, "redirect_target");
                    },
                }
            };
            try self.startResponse(index, .{
                .status = 308,
                .headers = &.{.{ .name = "Location", .value = writer.buffered() }},
                // An early redirect never consumes an upload or sends 100 Continue.
                .close = request.hasBody(),
            });
        }

        fn respondStatus(self: *Self, index: usize, status: u16, close: bool) RunError!void {
            const connection = &self.connections[index];
            const allow = if (connection.admin)
                "GET, HEAD, OPTIONS"
            else if (status == 405 and connection.application_initialized)
                connection.exchange.allowedMethods()
            else
                "";
            const body = http.Response.errorBody(status);
            const fields = [_]http.Header{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "Allow", .value = allow },
            };
            const headers: []const http.Header = if (status == 405)
                &fields
            else if (body.len > 0)
                fields[0..1]
            else
                &.{};
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
                    if (comptime can_batch) {
                        if (hasBatch(connection)) {
                            // The invalid parser cannot resume after this flush.
                            // Its close decision outlives the preceding responses.
                            try self.queueBatch(index);
                            return;
                        }
                    }
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
            const precondition = http.conditions.evaluate(
                request,
                .{},
                platform.realtimeNs(self.io) / 1_000_000_000,
            ) catch {
                try self.respondStatus(index, 400, true);
                return true;
            };
            if (precondition) |status| {
                try self.startResponse(index, .{
                    .status = status,
                    // A 304 length must describe the selected representation,
                    // which has not been generated for these dynamic resources.
                    .body = if (status == 304)
                        .{ .stream = null }
                    else
                        .{ .bytes = http.Response.errorBody(status) },
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
            var writer: std.Io.Writer = .fixed(connection.application_buffer);
            var content_type: []const u8 = "application/json";
            if (std.mem.eql(u8, request.path, "/metrics")) {
                const snapshot = self.aggregateMetrics();
                metrics_format.prometheus.write(&snapshot, &writer) catch {
                    try self.respondStatus(index, 500, true);
                    return;
                };
                if (comptime has_application_metrics) {
                    const application_snapshot = self.aggregateApplicationMetrics();
                    ApplicationMetrics.writePrometheus(
                        &application_snapshot,
                        &writer,
                        App.metrics_namespace,
                    ) catch {
                        try self.respondStatus(index, 500, true);
                        return;
                    };
                }
                content_type = metrics_format.prometheus.content_type;
            } else if (std.mem.eql(u8, request.path, "/debug/metrics")) {
                const snapshot = self.aggregateMetrics();
                var json: std.json.Stringify = .{ .writer = &writer };
                json.beginObject() catch {
                    try self.respondStatus(index, 500, true);
                    return;
                };
                metrics_format.json.writeFields(&snapshot, &json) catch {
                    try self.respondStatus(index, 500, true);
                    return;
                };
                if (comptime has_application_metrics) {
                    const application_snapshot = self.aggregateApplicationMetrics();
                    json.objectField("application") catch {
                        try self.respondStatus(index, 500, true);
                        return;
                    };
                    ApplicationMetrics.writeJson(&application_snapshot, &json) catch {
                        try self.respondStatus(index, 500, true);
                        return;
                    };
                }
                json.endObject() catch {
                    try self.respondStatus(index, 500, true);
                    return;
                };
                writer.writeByte('\n') catch {
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
                    try self.respondStatus(
                        index,
                        if (err == error.InvalidQuery) 400 else 500,
                        true,
                    );
                    return;
                };
            } else if (std.mem.eql(u8, request.path, "/healthz")) {
                try self.respondStatus(
                    index,
                    if (self.draining or self.shouldStop()) 503 else 200,
                    false,
                );
                return;
            } else {
                try self.respondStatus(index, 404, false);
                return;
            }
            const fields = [_]http.Header{
                .{ .name = "Content-Type", .value = content_type },
                .{ .name = "Cache-Control", .value = "no-store" },
            };
            try self.startResponse(
                index,
                .{ .headers = &fields, .body = .{ .bytes = writer.buffered() } },
            );
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

        fn aggregateApplicationMetrics(self: *const Self) ApplicationMetrics.Snapshot {
            if (comptime !has_application_metrics) comptime unreachable;
            const shared = self.shared orelse return self.application_metrics.snapshot();
            var result: ApplicationMetrics.Snapshot = .{};
            for (shared.workers) |*worker| {
                const captured = worker.application_metrics.snapshot();
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
            const id = @min(
                1 + (start - first_count) / self.config.max_connections,
                self.config.workers - 1,
            );
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
            var writer: std.Io.Writer = .fixed(self.connections[index].application_buffer);
            const captured = self.aggregateMetrics();
            std.json.Stringify.value(
                .{
                    .capacity = page.capacity,
                    .active = captured.gauge(.connections_active),
                    .worker = page.worker,
                    .connections = page.connections[0..page.len],
                    .next = page.next,
                },
                .{},
                &writer,
            ) catch {
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

        fn writeWorkers(
            self: *const Self,
            writer: *std.Io.Writer,
            query: []const u8,
        ) (std.Io.Writer.Error || error{InvalidQuery})!void {
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
                    .cpu = worker.worker_cpu,
                    .sq_entries = worker.ring.sq.sqes.len,
                    .cq_entries = worker.ring.cq.cqes.len,
                    .response_batch_capacity = worker.batches.len,
                    .large_buffer_budget = worker.config.large_buffer_bytes,
                    .buffer_bytes_active = captured.gauge(.buffer_bytes_active),
                    .buffer_bytes_cached = captured.gauge(.buffer_bytes_cached),
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
            response.close = response.close or self.draining or self.shouldStop() or
                connection.requests + 1 >= self.config.max_requests_per_connection;
            const second = platform.realtimeNs(self.io) / 1_000_000_000;
            if (second != self.date_second) {
                http.Response.formatDate(second, &self.date);
                self.date_second = second;
            }
            if (response.body == .stream and !self.ensureBuffer(connection, .output))
                return self.bufferUnavailable(index);
            var writer: std.Io.Writer = .fixed(connection.output_buffer);
            const encoder = response.begin(
                &writer,
                &connection.parser.request,
                &self.date,
            ) catch |err| retry: {
                if (err == error.WriteFailed and connection.output_buffer.len < self.config.response_bytes) {
                    if (!self.ensureBuffer(connection, .output)) return self.bufferUnavailable(index);
                    writer = .fixed(connection.output_buffer);
                    break :retry response.begin(
                        &writer,
                        &connection.parser.request,
                        &self.date,
                    ) catch {
                        self.event(index, .@"error", "response_invalid", null);
                        try self.forceClose(index);
                        return;
                    };
                }
                self.event(index, .@"error", "response_invalid", null);
                try self.forceClose(index);
                return;
            };
            connection.output_sent = 0;
            connection.body_sent = 0;
            connection.encoder = encoder;
            connection.streaming = response.body == .stream and encoder.mode != .suppressed;
            if (comptime has_response_streams) {
                if (connection.streaming) {
                    if (connection.exchange.response_producer == null) return self.forceClose(index);
                    self.beginApplicationDeadline(connection);
                    connection.response_stream_buffer = self.allocateResponseStream(
                        connection.output_buffer.len - 32,
                    ) catch
                        return self.bufferUnavailable(index);
                    connection.exchange.response_stream.init(
                        connection.response_stream_buffer,
                        self.io,
                        self.application_event_fd,
                        &connection.canceled,
                    );
                } else connection.application_deadline_ns = 0;
            } else connection.application_deadline_ns = 0;
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
            if (comptime has_response_streams) {
                if (connection.streaming)
                    connection.deadline = @min(connection.deadline, connection.application_deadline_ns);
            }
            self.metrics.recorder().response(response.status);
            try self.queueSend(index);
        }

        fn hasBatch(connection: *const Connection) bool {
            if (comptime !can_batch) return false;
            return connection.batch != null;
        }

        fn aggregate(self: *Self, index: usize) RunError!bool {
            const connection = &self.connections[index];
            if (self.batches.len == 0) return false;
            const count = if (connection.batch) |batch| batch.count else 0;
            const room = if (connection.batch) |batch| batch.remainingCapacity() else 4096;
            if (count == 0 and self.admission.options.max_active < 4 * self.active_connections)
                return false;
            const more_input = connection.receive_start < connection.receive_end and
                std.mem.indexOf(
                    u8,
                    connection.receive_buffer[connection.receive_start..connection.receive_end],
                    "\r\n\r\n",
                ) != null;
            const method = connection.parser.request.method;
            const user_agent = if (self.config.access_log)
                connection.parser.request.getHeader("user-agent")
            else
                null;
            const user_agent_len = if (user_agent) |header| header.len else 0;
            if (connection.admin or connection.interim or connection.streaming or
                connection.close_after_response or connection.first_byte_recorded or
                connection.permit != .admit or connection.body.len != 0 or connection.output_sent != 0 or
                connection.output_len > room or user_agent_len > room - connection.output_len or
                connection.response_body_bytes > 4096 or
                method.len > 8 or count == 16 or (!more_input and count == 0))
            {
                if (count == 0) return false;
                try self.queueBatch(index);
                return true;
            }
            if (connection.batch == null) {
                const batch = self.free_batch orelse {
                    self.metrics.recorder().add(.response_batch_fallbacks_total, 1);
                    return false;
                };
                self.free_batch = batch.next;
                batch.* = .{ .deadline = connection.deadline };
                connection.batch = batch;
            }
            const batch = connection.batch.?;
            var response: ResponseBatch.Response = .{
                .started_ns = connection.started_ns,
                .body_bytes = @intCast(connection.response_body_bytes),
                .status = connection.response_status,
            };
            if (self.config.access_log) {
                @memcpy(response.method[0..method.len], method);
                response.method_len = @intCast(method.len);
            }
            batch.append(connection.output_buffer[0..connection.output_len], response, user_agent);
            connection.permit = null;
            connection.requests += 1;
            // Only the built-in exchange takes this path. All response bytes and
            // log metadata are owned by the batch before its parser is reset.
            self.prepareRequest(connection, platform.monotonicNs());
            connection.phase = .reading;
            if (more_input and batch.count < batch.responses.len and batch.remainingCapacity() >= 256 and
                self.admission.active + self.active_connections < self.admission.options.max_active)
            {
                try self.processInput(index);
            } else try self.queueBatch(index);
            return true;
        }

        fn queueBatch(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            const batch = connection.batch.?;
            std.debug.assert(batch.len > batch.sent and !connection.send_pending);
            const first = !batch.sending;
            if (first) {
                std.debug.assert(connection.phase == .reading or connection.phase == .writing);
                batch.resume_response = connection.phase == .writing;
                batch.resume_deadline = connection.deadline;
                // Preserve packet coalescing when admission pressure splits a
                // pipeline, but flush at the ordinary path's 16-response bound.
                batch.send_more = connection.tls == null and !batch.resume_response and !self.draining and
                    connection.permit != .close and
                    batch.count + connection.more_count < 16 and
                    connection.receive_start < connection.receive_end and
                    std.mem.indexOf(
                        u8,
                        connection.receive_buffer[connection.receive_start..connection.receive_end],
                        "\r\n\r\n",
                    ) != null;
                connection.more_pending = batch.send_more;
                connection.more_count = if (batch.send_more) connection.more_count + batch.count else 0;
                batch.sending = true;
                connection.phase = .writing;
                connection.deadline = batch.deadline;
            }
            if (first) {
                self.metrics.recorder().add(.response_batches_total, 1);
                self.metrics.recorder().add(.responses_batched_total, batch.count);
            }
            if (connection.tls) |session| {
                session.start(.{ .write = batch.bytes[batch.sent..batch.len] });
                try self.advanceTls(index);
                return;
            }
            try self.ensureSubmission();
            const flags = linux.MSG.NOSIGNAL | @as(u32, if (batch.send_more) linux.MSG.MORE else 0);
            _ = self.ring.send(
                token(.send, index, connection.generation),
                connection.fd,
                batch.bytes[batch.sent..batch.len],
                flags,
            ) catch return error.IoUringResources;
            connection.send_pending = true;
            connection.pending += 1;
            self.queued();
        }

        fn sentBatch(self: *Self, index: usize, result: i32) RunError!void {
            const connection = &self.connections[index];
            const batch = connection.batch.?;
            if (result <= 0) {
                self.metrics.recorder().add(.io_errors_total, 1);
                try self.forceClose(index);
                return;
            }
            const count: u16 = @intCast(result);
            std.debug.assert(count <= batch.len - batch.sent);
            self.metrics.recorder().add(.bytes_sent_total, count);
            const previous = batch.sent;
            batch.sent += count;
            const now = platform.monotonicNs();
            while (batch.completed < batch.count) {
                const response = &batch.responses[batch.completed];
                const begin = if (batch.completed == 0) 0 else batch.responses[batch.completed - 1].end;
                if (previous <= begin and batch.sent > begin)
                    self.metrics.recorder().observe(.time_to_first_byte_seconds, now - response.started_ns);
                if (batch.sent < response.end) break;
                const duration = now - response.started_ns;
                self.metrics.recorder().add(.requests_completed_total, 1);
                self.metrics.recorder().observe(.request_duration_seconds, duration);
                self.metrics.recorder().observe(.admitted_duration_seconds, duration);
                if (self.config.access_log) self.logger.emit(.{
                    .timestamp_ns = platform.realtimeNs(self.io),
                    .event = "request_complete",
                    .connection = token(.receive, index, connection.generation) & ~@as(u64, 255),
                    .client_ip = connection.client_ip[0..connection.client_ip_len],
                    .user_agent = if (response.user_agent) |header|
                        batch.bytes[header.start..][0..header.len]
                    else
                        null,
                    .status = response.status,
                    .method = response.method[0..response.method_len],
                    .duration_ns = duration,
                    .bytes = response.body_bytes,
                });
                self.admission.release(.admit);
                batch.completed += 1;
            }
            if (batch.sent < batch.len) {
                try self.queueBatch(index);
                return;
            }
            const resume_response = batch.resume_response;
            const resume_deadline = batch.resume_deadline;
            self.releaseBatch(connection);
            connection.deadline = resume_deadline;
            if (resume_response) {
                connection.phase = .writing;
                try self.queueSend(index);
            } else if (connection.permit == .close or (self.draining and !connection.request_started)) {
                try self.drainConnection(index, now);
            } else {
                connection.phase = .reading;
                if (!connection.request_started)
                    connection.deadline = now + @as(u64, self.config.idle_timeout_ms) * 1_000_000;
                try self.processInput(index);
            }
        }

        fn releaseBatch(self: *Self, connection: *Connection) void {
            const batch = connection.batch.?;
            std.debug.assert(batch.completed == batch.count);
            batch.next = self.free_batch;
            self.free_batch = batch;
            connection.batch = null;
        }

        fn abortBatch(self: *Self, connection: *Connection) void {
            const batch = connection.batch orelse return;
            const now = platform.monotonicNs();
            for (batch.responses[batch.completed..batch.count]) |response| {
                self.admission.release(.admit);
                self.metrics.recorder().add(.requests_aborted_total, 1);
                self.metrics.recorder().observe(.aborted_duration_seconds, now - response.started_ns);
            }
            batch.completed = batch.count;
            self.releaseBatch(connection);
        }

        fn queueSend(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            if (connection.tls != null and
                (connection.receive_pending or connection.send_pending)) return;
            std.debug.assert(!connection.send_pending);
            if (comptime can_batch) {
                if (try self.aggregate(index)) return;
            }
            const bytes = if (connection.output_sent < connection.output_len)
                connection.output_buffer[connection.output_sent..connection.output_len]
            else
                connection.body[connection.body_sent..];
            std.debug.assert(bytes.len > 0);
            if (connection.tls) |session| {
                session.start(.{ .write = bytes[0..@min(bytes.len, 16 * 1024)] });
                try self.advanceTls(index);
                return;
            }
            const more = !connection.admin and !connection.interim and
                !connection.streaming and !connection.close_after_response and
                connection.body_sent == connection.body.len and bytes.len <= 4096 and
                connection.more_count < 15 and connection.receive_start < connection.receive_end and
                std.mem.indexOf(
                    u8,
                    connection.receive_buffer[connection.receive_start..connection.receive_end],
                    "\r\n\r\n",
                ) != null;
            connection.more_pending = more;
            connection.more_count = if (more) connection.more_count + 1 else 0;
            const send_flags = linux.MSG.NOSIGNAL | @as(u32, if (more) linux.MSG.MORE else 0);
            const vector = connection.output_sent < connection.output_len and
                connection.body_sent < connection.body.len;
            if (vector) {
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
            }
            try self.ensureSubmission();
            if (vector) {
                _ = self.ring.sendmsg(
                    token(.send, index, connection.generation),
                    connection.fd,
                    &connection.send_message,
                    send_flags,
                ) catch return error.IoUringResources;
            } else {
                _ = self.ring.send(
                    token(.send, index, connection.generation),
                    connection.fd,
                    bytes,
                    send_flags,
                ) catch
                    return error.IoUringResources;
            }
            connection.send_pending = true;
            connection.pending += 1;
            self.queued();
        }

        fn startResponseStream(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            if (!self.shared.?.workers[0].executor.submit(connection.exchange.lane(), .{
                .owner = self,
                .index = index,
                .generation = connection.generation,
                .stage = .produce,
                .deadline_ns = connection.application_deadline_ns,
            })) {
                self.metrics.recorder().add(.application_queue_rejections_total, 1);
                return self.forceClose(index);
            }
            connection.response_stream_started = true;
            connection.response_stream_busy = true;
            connection.pending += 1;
            connection.deadline = connection.application_deadline_ns;
        }

        fn pumpResponseStream(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            if (connection.send_pending or connection.output_sent < connection.output_len or
                connection.response_stream_chunk) return;
            const stream = &connection.exchange.response_stream;
            var writer: std.Io.Writer = .fixed(connection.output_buffer);
            switch (stream.publication.load(.acquire)) {
                .writing => return,
                .ready => {
                    const bytes = stream.writer.buffer[0..stream.published_len];
                    connection.encoder.write(&writer, bytes) catch return self.forceClose(index);
                    connection.response_body_bytes += bytes.len;
                    connection.response_stream_chunk = true;
                },
                .finished => {
                    // Cleanup and observability borrow producer-owned fields.
                    if (connection.response_stream_busy) return;
                    connection.encoder.end(&writer) catch return self.forceClose(index);
                    connection.streaming = false;
                    connection.response_stream_started = false;
                },
                .failed => return self.forceClose(index),
            }
            connection.output_sent = 0;
            connection.output_len = writer.buffered().len;
            if (connection.output_len == 0) return self.finishResponse(index, null);
            connection.deadline = @min(connection.application_deadline_ns, platform.monotonicNs() +
                @as(u64, self.config.write_timeout_ms) * 1_000_000);
            try self.queueSend(index);
        }

        fn fillStream(connection: *Connection) !void {
            var writer: std.Io.Writer = .fixed(connection.output_buffer);
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
            if (comptime can_batch) {
                if (connection.batch) |batch| {
                    if (batch.sending) return self.sentBatch(index, result);
                }
            }
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
                if (!connection.admin) self.metrics.recorder().observe(
                    .time_to_first_byte_seconds,
                    first_ns.? - connection.started_ns,
                );
            }
            const head_count = @min(count, connection.output_len - connection.output_sent);
            connection.output_sent += head_count;
            connection.body_sent += count - head_count;
            if (connection.output_sent < connection.output_len or
                connection.body_sent < connection.body.len)
            {
                try self.queueSend(index);
                return;
            }
            if (connection.interim) {
                connection.interim = false;
                connection.phase = .reading;
                connection.deadline = platform.monotonicNs() + @as(
                    u64,
                    self.config.body_timeout_ms,
                ) * 1_000_000;
                if (connection.application_deadline_ns != 0)
                    connection.deadline = @min(connection.deadline, connection.application_deadline_ns);
                try self.processInput(index);
                return;
            }
            if (connection.streaming) {
                if (comptime has_response_streams) {
                    if (connection.canceled.load(.acquire)) return self.forceClose(index);
                    if (!connection.response_stream_started) return self.startResponseStream(index);
                    if (connection.response_stream_chunk) {
                        connection.response_stream_chunk = false;
                        connection.exchange.response_stream.consume();
                    }
                    connection.deadline = connection.application_deadline_ns;
                    return self.pumpResponseStream(index);
                } else fillStream(connection) catch |err| {
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
            try self.finishResponse(index, first_ns);
        }

        fn finishResponse(self: *Self, index: usize, first_ns: ?u64) RunError!void {
            const connection = &self.connections[index];
            self.metrics.recorder().add(.requests_completed_total, 1);
            connection.request_completed = true;
            const completed_ns = first_ns orelse platform.monotonicNs();
            const duration = completed_ns - connection.started_ns;
            if (connection.admin) {
                self.metrics.recorder().observe(.admin_duration_seconds, duration);
            } else {
                self.metrics.recorder().observe(.request_duration_seconds, duration);
                self.metrics.recorder().observe(
                    if (connection.permit == .admit)
                        .admitted_duration_seconds
                    else
                        .rejected_duration_seconds,
                    duration,
                );
            }
            if (self.config.access_log and (connection.permit != .reject or self.config.verbose)) {
                if (@hasDecl(App.Exchange, "takeAccessDrops") and connection.application_initialized) {
                    self.metrics.add(
                        .log_dropped_total,
                        connection.exchange.takeAccessDrops(),
                    );
                }
                self.logger.emit(.{
                    .timestamp_ns = platform.realtimeNs(self.io),
                    .event = "request_complete",
                    .connection = token(.receive, index, connection.generation) & ~@as(u64, 255),
                    .client_ip = connection.client_ip[0..connection.client_ip_len],
                    .user_agent = connection.parser.request.getHeader("user-agent"),
                    .status = connection.response_status,
                    .method = connection.parser.request.method,
                    .duration_ns = duration,
                    .bytes = connection.response_body_bytes,
                    .route = if (@hasDecl(App.Exchange, "routeName") and connection.application_initialized)
                        connection.exchange.routeName()
                    else
                        null,
                    .fields = if (@hasDecl(
                        App.Exchange,
                        "accessFields",
                    ) and connection.application_initialized)
                        connection.exchange.accessFields()
                    else
                        &.{},
                });
            }
            connection.requests += 1;
            self.releaseApplication(connection);
            if (connection.close_after_response) {
                try self.drainConnection(index, completed_ns);
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

        fn releaseApplication(self: *Self, connection: *Connection) void {
            if (connection.admin or !connection.application_initialized) return;
            std.debug.assert(!connection.response_stream_busy);
            self.freeResponseStream(connection);
            if (comptime @hasDecl(App.Exchange, "releaseApplication")) {
                connection.exchange.releaseApplication(&connection.parser.request);
                connection.exchange.flushLogs(&self.logger);
            }
            connection.application_initialized = false;
        }

        fn forceClose(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            connection.canceled.store(true, .release);
            if (comptime has_response_streams) {
                if (connection.response_stream_started) connection.exchange.response_stream.cancel();
            }
            self.removeIdle(index);
            if (connection.http2) |session| session.abort();
            connection.phase = .canceling;
            if (connection.receive_pending and !connection.cancel_receive_pending) {
                try self.ensureSubmission();
                _ = self.ring.cancel(
                    token(.cancel_receive, index, connection.generation),
                    token(.receive, index, connection.generation),
                    0,
                ) catch
                    return error.IoUringResources;
                connection.cancel_receive_pending = true;
                connection.pending += 1;
                self.queued();
            }
            if (connection.send_pending and !connection.cancel_send_pending) {
                try self.ensureSubmission();
                _ = self.ring.cancel(
                    token(.cancel_send, index, connection.generation),
                    token(.send, index, connection.generation),
                    0,
                ) catch
                    return error.IoUringResources;
                connection.cancel_send_pending = true;
                connection.pending += 1;
                self.queued();
            }
            self.finishClose(index);
        }

        fn drainConnection(self: *Self, index: usize, now: u64) RunError!void {
            const connection = &self.connections[index];
            self.removeIdle(index);
            connection.phase = .drain;
            connection.deadline = now + @as(u64, self.config.close_timeout_ms) * 1_000_000;
            if (self.draining) connection.deadline = @min(connection.deadline, self.shutdown_deadline);
            if (connection.tls) |session| {
                connection.phase = .tls_shutdown;
                if (connection.send_pending) return;
                if (connection.receive_pending) {
                    if (!connection.cancel_receive_pending) {
                        try self.ensureSubmission();
                        _ = self.ring.cancel(
                            token(.cancel_receive, index, connection.generation),
                            token(.receive, index, connection.generation),
                            0,
                        ) catch return error.IoUringResources;
                        connection.cancel_receive_pending = true;
                        connection.pending += 1;
                        self.queued();
                    }
                    return;
                }
                session.start(.shutdown);
                try self.advanceTls(index);
                return;
            }
            try self.beginTcpDrain(index);
        }

        fn beginTcpDrain(self: *Self, index: usize) RunError!void {
            const connection = &self.connections[index];
            connection.phase = .drain;
            // Deliver FIN before discarding late input, avoiding a reset that
            // can erase an already sent response from the client's receive queue.
            _ = linux.shutdown(connection.fd, linux.SHUT.WR);
            connection.receive_start = connection.receive_end;
            try self.queueReceive(index);
        }

        fn finishClose(self: *Self, index: usize) void {
            const connection = &self.connections[index];
            if (connection.pending != 0 or connection.fd < 0) return;
            self.releaseHttp2(connection);
            if (comptime can_batch) self.abortBatch(connection);
            self.releaseApplication(connection);
            if (connection.request_started and !connection.request_completed) {
                self.metrics.recorder().add(.requests_aborted_total, 1);
                if (!connection.admin) self.metrics.recorder().observe(
                    .aborted_duration_seconds,
                    platform.monotonicNs() - connection.started_ns,
                );
            }
            self.event(index, .debug, "connection_closed", null);
            self.releaseBuffers(connection, true);
            self.releaseRequest(connection);
            self.releaseConnectionBuffers(connection);
            self.releaseTls(connection);
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
            try self.finishApplications();
            self.captureInspection();
            if (self.worker_id == 0) try self.finishInspections();
            self.admission.refill(now);
            var position = self.active_connections;
            while (position > 0) {
                position -= 1;
                const index = self.active_slots[position];
                const connection = &self.connections[index];
                if (connection.phase == .http2) {
                    try self.pumpHttp2(index);
                    continue;
                }
                if (connection.response_stream_started and self.draining and now >= self.shutdown_deadline) {
                    try self.forceClose(index);
                    continue;
                }
                if (connection.response_stream_started and connection.phase != .canceling) {
                    // Detect resets while an application waits without output.
                    // Do not treat a peer's write half-close as cancellation.
                    var socket_poll: [1]linux.pollfd = .{.{
                        .fd = connection.fd,
                        .events = 0,
                        .revents = 0,
                    }};
                    _ = linux.poll(&socket_poll, 1, 0);
                    if (socket_poll[0].revents & (linux.POLL.ERR | linux.POLL.HUP) != 0) {
                        self.metrics.recorder().add(.peer_disconnects_total, 1);
                        try self.forceClose(index);
                        continue;
                    }
                }
                if (connection.phase == .canceling or now < connection.deadline) continue;
                if (connection.phase == .handshake) {
                    self.metrics.recorder().add(.tls_handshake_timeouts_total, 1);
                    try self.forceClose(index);
                    continue;
                }
                if (connection.phase == .drain or connection.phase == .tls_shutdown) {
                    try self.forceClose(index);
                    continue;
                }
                if (!connection.request_started and !hasBatch(connection)) {
                    self.metrics.recorder().add(.connections_idle_closed_total, 1);
                    if (self.draining and !connection.admin and connection.requests > 0) {
                        try self.drainConnection(index, now);
                    } else try self.forceClose(index);
                    continue;
                }
                if (connection.phase == .application) {
                    self.timeoutApplication(connection);
                    continue;
                }
                if (has_response_streams and connection.streaming and
                    now >= connection.application_deadline_ns)
                {
                    self.timeoutApplication(connection);
                    try self.forceClose(index);
                    continue;
                }
                if (connection.phase == .reading and connection.application_deadline_ns != 0 and
                    now >= connection.application_deadline_ns)
                {
                    self.timeoutApplication(connection);
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
                        _ = self.ring.cancel(
                            token(.cancel_receive, index, connection.generation),
                            token(.receive, index, connection.generation),
                            0,
                        ) catch
                            return error.IoUringResources;
                        connection.cancel_receive_pending = true;
                        connection.pending += 1;
                        self.queued();
                    }
                    try self.reject(index, 408, "deadline");
                } else try self.forceClose(index);
            }
        }

        fn timeoutApplication(self: *Self, connection: *Connection) void {
            if (connection.application_timed_out) return;
            connection.canceled.store(true, .release);
            if (comptime has_response_streams) {
                if (connection.response_stream_started) connection.exchange.response_stream.cancel();
            }
            connection.application_timed_out = true;
            connection.deadline = std.math.maxInt(u64);
            self.metrics.recorder().add(.request_timeouts_total, 1);
            self.metrics.recorder().add(.application_timeouts_total, 1);
            _ = linux.shutdown(connection.fd, linux.SHUT.RDWR);
        }

        fn hasApplicationWork(self: *const Self) bool {
            if (comptime !isolated_application) return false;
            for (self.active_slots[0..self.active_connections]) |index| {
                if (self.connections[index].http2) |session| {
                    var item = session.streams;
                    while (item) |stream| : (item = stream.next) if (stream.busy) return true;
                }
                if (self.connections[index].phase == .application or
                    self.connections[index].response_stream_busy) return true;
            }
            return false;
        }

        fn event(
            self: *Self,
            index: usize,
            level: Logger.Level,
            name: []const u8,
            reason: ?[]const u8,
        ) void {
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

        fn stopListening(self: *Self) void {
            // Canceling accepts alone leaves the TCP backlog open. shutdown
            // also rejects queued connections, even while an accept holds a
            // reference. Keep descriptors until deinit so unsubmitted SQEs
            // cannot target a reused descriptor.
            _ = linux.shutdown(self.listener.fd, linux.SHUT.RDWR);
            if (self.redirect_listener.fd >= 0)
                _ = linux.shutdown(self.redirect_listener.fd, linux.SHUT.RDWR);
            if (self.admin_listener.fd >= 0)
                _ = linux.shutdown(self.admin_listener.fd, linux.SHUT.RDWR);
        }

        fn beginShutdown(self: *Self, now: u64) RunError!void {
            self.draining = true;
            self.stopListening();
            if (self.waiting_accept >= 0) {
                platform.close(self.waiting_accept);
                self.waiting_accept = -1;
            }
            self.shutdown_deadline = now + @as(u64, self.config.shutdown_timeout_ms) * 1_000_000;
            self.shutdown_keepalive_deadline = now + @as(u64, @min(
                self.config.shutdown_keepalive_ms,
                self.config.shutdown_timeout_ms,
            )) * 1_000_000;
            self.metrics.set(.draining, 1);
            self.logger.emit(.{ .timestamp_ns = platform.realtimeNs(self.io), .event = "shutdown_started" });
            if (self.accepting) try self.cancelControl(.cancel_accept, .accept);
            if (self.admin_accepting) try self.cancelControl(.cancel_admin, .accept_admin);
            if (self.redirect_accepting) try self.cancelControl(.cancel_redirect, .accept_redirect);
            for (self.connections, 0..) |*connection, index| {
                if (connection.fd < 0) continue;
                if (connection.http2) |session| {
                    session.shutdown() catch {
                        try self.forceClose(index);
                        continue;
                    };
                    try self.pumpHttp2(index);
                    continue;
                }
                connection.close_after_response = true;
                if (connection.phase != .reading or connection.request_started or hasBatch(connection))
                    continue;
                if (!connection.admin and connection.requests > 0 and
                    self.config.shutdown_keepalive_ms != 0)
                {
                    // Retain pending receives so a concurrent client reuse gets
                    // a final response advertising Connection: close.
                    connection.deadline = @min(connection.deadline, self.shutdown_keepalive_deadline);
                } else try self.forceClose(index);
            }
        }

        fn cancelControl(self: *Self, kind: Kind, target: Kind) RunError!void {
            try self.ensureSubmission();
            _ = self.ring.cancel(
                control(kind),
                control(target),
                0,
            ) catch return error.IoUringResources;
            self.queued();
        }

        fn stopOperations(self: *Self) RunError!void {
            self.stopping = true;
            for (
                self.connections,
                0..,
            ) |connection, index| if (connection.fd >= 0) try self.forceClose(index);
            if (self.ticking) try self.cancelControl(.cancel_tick, .tick);
            if (self.logging) try self.cancelControl(.cancel_log, .log_write);
            if (self.application_event_pending)
                try self.cancelControl(.cancel_application, .application);
        }
    };
}

test {
    _ = http2;
}

test "HTTPS redirect omits the default port and preserves IPv6 brackets" {
    const testing = std.testing;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeHttpsLocation(&writer, "example.test:8080", "/path?", 443);
    try testing.expectEqualStrings("https://example.test/path?", writer.buffered());
    writer = .fixed(&buffer);
    try writeHttpsLocation(&writer, "[2001:db8::1]:80", "http://[2001:db8::1]:80", 443);
    try testing.expectEqualStrings("https://[2001:db8::1]/", writer.buffered());
}

test "stop observed before the next loop rejects an already completed accept" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    const server = &workers[0];
    server.init(
        testing.allocator,
        testing.io,
        .{
            .config = .{
                .port = 0,
                .admin_connections = 0,
                .max_connections = 1,
                .log_fd = null,
            },
            .stop = &stop,
            .worker_id = 0,
            .shared = &shared,
        },
    ) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit();
    defer server.quiesce();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", server.listener.port);
    const client = try address.connect(testing.io, .{ .mode = .stream });
    defer client.close(testing.io);
    const accepted: linux.fd_t = @intCast(try platform.check(linux.accept4(
        server.listener.fd,
        null,
        null,
        linux.SOCK.CLOEXEC,
    )));
    // Model a signal between CQ collection and dispatch. acceptConnection owns
    // the accepted descriptor on every path, including shutdown rejection.
    stop.store(true, .monotonic);
    try server.acceptConnection(accepted, .public);
    try testing.expectEqual(@as(usize, 0), server.active_connections);
    try server.queueAccept(.public);
    try testing.expectEqual(@as(usize, 0), server.pending);
}

test "embedded application receives normalized routing and preserved request octets" {
    const testing = std.testing;
    const app = struct {
        pub const Exchange = struct {
            pub fn init(_: *Exchange, _: []u8) void {}

            pub fn receiveHead(_: *Exchange, request: *const http.Request) ?http.Response {
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

            pub fn receiveBody(_: *Exchange, _: []const u8) error{}!void {}

            pub fn respond(_: *Exchange, _: *const http.Request) http.Response {
                return .{ .status = 500, .close = true };
            }

            pub fn produce(_: *Exchange, _: []u8) ?[]const u8 {
                return null;
            }

            pub fn allowedMethods(_: *const Exchange) []const u8 {
                return "GET";
            }
        };
    };
    const TestServer = Worker(app);
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    workers[0].init(
        testing.allocator,
        testing.io,
        .{
            .config = .{
                .port = 0,
                .admin_port = 0,
                .max_connections = 16,
                .access_log = false,
            },
            .stop = &stop,
            .worker_id = 0,
            .shared = &shared,
        },
    ) catch |err| switch (err) {
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
    const authority = try std.fmt.bufPrint(
        &authority_buffer,
        "127.0.0.1:{d}",
        .{workers[0].listener.port},
    );
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
        const body = (std.mem.indexOf(
            u8,
            response,
            "\r\n\r\n",
        ) orelse return error.MissingHead) + 4;
        try testing.expectEqualStrings(case[1], response[body..]);
    }
    try testing.expectEqualStrings("[::1]", defaultAuthority(&authority_buffer, "::1", 80, 80));
    try testing.expectEqualStrings(
        "[::1]:8080",
        defaultAuthority(&authority_buffer, "::1", 8080, 80),
    );
    try testing.expectEqualStrings("[::1]", defaultAuthority(&authority_buffer, "::1", 443, 443));
    try testing.expectEqualStrings("[::1]:80", defaultAuthority(&authority_buffer, "::1", 80, 443));
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
    _ = try platform.check(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &pair,
    ));
    defer platform.close(pair[0]);
    defer platform.close(pair[1]);
    const invalid_listener: linux.fd_t = @intCast(try platform.check(linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    )));
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
    const fd: linux.fd_t = @intCast(try platform.check(linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    )));
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
    _ = try platform.check(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &pair,
    ));
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
    var config: Config = .{
        .workers = 2,
        .max_connections = 2,
        .port = 0,
        .admin_port = 0,
    };
    workers[0].init(
        testing.allocator,
        testing.io,
        .{
            .config = config,
            .stop = &stop,
            .worker_id = 0,
            .shared = &shared,
        },
    ) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer workers[0].deinit();
    config.port = workers[0].listener.port;
    config.admin_port = workers[0].admin_listener.port;
    try workers[1].init(
        testing.allocator,
        testing.io,
        .{
            .config = config,
            .stop = &stop,
            .worker_id = 1,
            .shared = &shared,
        },
    );
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

test "worker retry policy applies to public listeners and preserves admin defaults" {
    const testing = std.testing;
    const TestServer = Worker(application);
    for ([_]Config.TcpRetries{ .system, .thin_linear }) |mode| {
        var workers: [1]TestServer = undefined;
        var shared: TestServer.Shared = .{ .workers = &workers };
        var stop: std.atomic.Value(bool) = .init(false);
        workers[0].init(
            testing.allocator,
            testing.io,
            .{
                .config = .{
                    .tcp_retries = mode,
                    .max_connections = 2,
                    .admin_connections = 1,
                    .port = 0,
                    .admin_port = 0,
                    .log_fd = null,
                },
                .stop = &stop,
                .worker_id = 0,
                .shared = &shared,
            },
        ) catch |err| switch (err) {
            error.IoUringUnavailable => return error.SkipZigTest,
            else => return err,
        };
        defer workers[0].deinit();
        for ([_]platform.Listener{ workers[0].listener, workers[0].admin_listener }, 0..) |listener, index| {
            var enabled: i32 = -1;
            var size: linux.socklen_t = @sizeOf(i32);
            _ = try platform.check(linux.getsockopt(
                listener.fd,
                linux.IPPROTO.TCP,
                linux.TCP.THIN_LINEAR_TIMEOUTS,
                std.mem.asBytes(&enabled),
                &size,
            ));
            const expected: i32 = if (index == 0 and mode == .thin_linear) 1 else 0;
            try testing.expectEqual(expected, enabled);
        }
    }
}

test "unused and idle slots defer application initialization until request dispatch" {
    const testing = std.testing;
    const app = struct {
        var initializations: usize = 0;
        pub const Exchange = struct {
            pub fn init(_: *Exchange, _: []u8) void {
                initializations += 1;
            }
        };
    };
    const TestServer = Worker(app);
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    app.initializations = 0;
    workers[0].init(
        testing.allocator,
        testing.io,
        .{
            .config = .{
                .max_connections = 2,
                .port = 0,
                .admin_port = 0,
            },
            .stop = &stop,
            .worker_id = 0,
            .shared = &shared,
        },
    ) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer workers[0].deinit();
    try testing.expectEqual(@as(usize, 0), app.initializations);
    try testing.expect(workers[0].acquireConnectionBuffers(&workers[0].connections[0]));
    workers[0].prepareRequest(&workers[0].connections[0], platform.monotonicNs());
    try testing.expectEqual(@as(usize, 0), app.initializations);
    try testing.expect(workers[0].connections[0].request_lease == null);
    try testing.expect(workers[0].acquireRequest(&workers[0].connections[0]));
    workers[0].initExchange(&workers[0].connections[0]);
    defer workers[0].releaseApplication(&workers[0].connections[0]);
    try testing.expectEqual(@as(usize, 1), app.initializations);
}

test "embedded worker applies automatic admission before filling its connections" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    workers[0].init(
        testing.allocator,
        testing.io,
        .{
            .config = .{
                .max_connections = 4,
                .port = 0,
                .admin_port = 0,
            },
            .stop = &stop,
            .worker_id = 0,
            .shared = &shared,
        },
    ) catch |err| switch (err) {
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

test "connection buffer allocation failure closes only the public socket and recovers" {
    const testing = std.testing;
    const client = struct {
        fn request(port: u16, bytes: []const u8) ![]u8 {
            const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
            const stream = try address.connect(std.testing.io, .{ .mode = .stream });
            defer stream.close(std.testing.io);
            var writer = stream.writer(std.testing.io, &.{});
            try writer.interface.writeAll(bytes);
            var buffer: [2048]u8 = undefined;
            var reader = stream.reader(std.testing.io, &buffer);
            return reader.interface.allocRemaining(std.testing.allocator, .limited(65536));
        }
    };
    const TestServer = Worker(application);
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    workers[0].init(
        failing.allocator(),
        testing.io,
        .{
            .config = .{
                .max_connections = 65,
                .admin_connections = 1,
                .port = 0,
                .admin_port = 0,
                .access_log = false,
            },
            .stop = &stop,
            .worker_id = 0,
            .shared = &shared,
        },
    ) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer workers[0].deinit();
    workers[0].log_disabled = true;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const thread = try std.Thread.spawn(.{}, TestServer.workerMain, .{&workers[0]});
    defer {
        stop.store(true, .monotonic);
        thread.join();
    }
    var held: [64]std.Io.net.Stream = undefined;
    var held_count: usize = 0;
    defer for (held[0..held_count]) |stream| stream.close(testing.io);
    const public_address = try std.Io.net.IpAddress.parse("127.0.0.1", workers[0].listener.port);
    for (&held) |*stream| {
        stream.* = try public_address.connect(testing.io, .{ .mode = .stream });
        held_count += 1;
    }
    const refused = try client.request(workers[0].listener.port, "");
    defer testing.allocator.free(refused);
    try testing.expectEqual(@as(usize, 0), refused.len);
    const admin = try client.request(
        workers[0].admin_listener.port,
        "GET /debug/metrics HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    );
    defer testing.allocator.free(admin);
    try testing.expect(std.mem.startsWith(u8, admin, "HTTP/1.1 200 "));
    try testing.expectEqual(
        @as(u64, 1),
        workers[0].metrics.get(.connection_buffer_exhaustions_total),
    );
    shared.allocator_mutex.lockUncancelable(testing.io);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    shared.allocator_mutex.unlock(testing.io);
    const recovered = try client.request(
        workers[0].listener.port,
        "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    );
    defer testing.allocator.free(recovered);
    try testing.expect(std.mem.startsWith(u8, recovered, "HTTP/1.1 200 "));
    const body = (std.mem.indexOf(u8, recovered, "\r\n\r\n") orelse return error.MissingHead) + 4;
    try testing.expectEqualStrings("ZHTPS\n", recovered[body..]);
}

test "request cache exhaustion preserves admin storage and recovers after release" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var workers: [1]TestServer = undefined;
    var shared: TestServer.Shared = .{ .workers = &workers };
    var stop: std.atomic.Value(bool) = .init(false);
    workers[0].init(
        failing.allocator(),
        testing.io,
        .{
            .config = .{
                .max_connections = 65,
                .admin_connections = 1,
                .port = 0,
                .admin_port = 0,
            },
            .stop = &stop,
            .worker_id = 0,
            .shared = &shared,
        },
    ) catch |err| switch (err) {
        error.IoUringUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer workers[0].deinit();
    const worker = &workers[0];
    const admin_request = worker.connections[65].request_lease.?;
    for (worker.connections[0..65]) |*connection|
        try testing.expect(worker.acquireConnectionBuffers(connection));
    for (worker.connections[0..64]) |*connection|
        try testing.expect(worker.acquireRequest(connection));
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expect(!worker.acquireRequest(&worker.connections[64]));
    try testing.expectEqual(@as(u64, 1), worker.metrics.get(.request_storage_exhaustions_total));
    try testing.expectEqual(admin_request, worker.connections[65].request_lease.?);
    worker.releaseRequest(&worker.connections[0]);
    try testing.expect(worker.acquireRequest(&worker.connections[64]));
    try testing.expectEqual(
        @intFromPtr(worker.smallBuffer(&worker.connections[64], .head).ptr),
        @intFromPtr(worker.connections[64].parser.head_storage.ptr),
    );
    try testing.expectEqual(@as(usize, 64), worker.request_active);
}

test "stream batching preserves producer capacity and a deferred fragment" {
    const testing = std.testing;
    const test_app = struct {
        pub const Exchange = struct {
            calls: usize = 0,

            pub fn produce(exchange: *Exchange, destination: []u8) ?[]const u8 {
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
    const TestServer = Worker(test_app);
    var output: [96]u8 = undefined;
    var application_buffer: [64]u8 = undefined;
    var exchange: test_app.Exchange = .{};
    var connection: TestServer.Connection = .{
        .exchange = &exchange,
        .output_buffer = &output,
        .application_buffer = &application_buffer,
        .streaming = true,
        .encoder = .{ .mode = .chunked, .close = false },
    };
    try TestServer.fillStream(&connection);
    try testing.expectEqualStrings(
        "32\r\n" ++ "A" ** 50 ++ "\r\n",
        output[0..connection.output_len],
    );
    try testing.expectEqual(@as(usize, 2), connection.exchange.calls);
    try testing.expect(connection.stream_fragment != null);
    try TestServer.fillStream(&connection);
    try testing.expectEqualStrings(
        "32\r\n" ++ "B" ** 50 ++ "\r\n3\r\nend\r\n",
        output[0..connection.output_len],
    );
    try testing.expectEqual(@as(usize, 3), connection.exchange.calls);
    try TestServer.fillStream(&connection);
    try testing.expectEqualStrings("0\r\n\r\n", output[0..connection.output_len]);
    try testing.expectEqual(@as(usize, 103), connection.response_body_bytes);
    try testing.expect(!connection.streaming);
    try testing.expect(connection.stream_fragment == null);
}

test "stream batching bounds calls and rejects an empty fragment" {
    const test_app = struct {
        pub const Exchange = struct {
            calls: usize = 0,
            empty: bool = false,
            pub fn produce(exchange: *Exchange, destination: []u8) ?[]const u8 {
                _ = destination;
                exchange.calls += 1;
                return if (exchange.empty) "" else "x";
            }
        };
    };
    const TestServer = Worker(test_app);
    var output: [4096]u8 = undefined;
    var application_buffer: [64]u8 = undefined;
    var exchange: test_app.Exchange = .{};
    var connection: TestServer.Connection = .{
        .exchange = &exchange,
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
                for ([_]TestServer.Kind{
                    first,
                    second,
                    third,
                    fourth,
                }, 0..) |kind, completed| {
                    try server.complete(.{
                        .user_data = TestServer.token(kind, 0, connections[0].generation),
                        .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
                        .flags = 0,
                    });
                    if (completed < 3) {
                        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(
                            fd,
                            linux.F.GETFD,
                            0,
                        )));
                        try testing.expectEqual(@as(?usize, null), server.public_free);
                        try testing.expectEqual(@as(usize, 1), server.admission.active);
                    }
                }
                try testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(
                    fd,
                    linux.F.GETFD,
                    0,
                )));
                try testing.expectEqual(@as(?usize, 0), server.public_free);
                try testing.expectEqual(@as(usize, 0), server.admission.active);
                try testing.expectEqual(@as(usize, 0), server.pending);
                try testing.expectEqual(@as(usize, 0), server.active_connections);
                try testing.expectEqual(@as(u64, 1), server.metrics.get(.connections_closed_total));
            }
        }
    }
}

test "short response aggregates coalesce until the bounded pipeline flush" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var ring = linux.IoUring.init(128, 0) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var input = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".*;
    var batch: ResponseBatch = .{ .len = 100, .count = 2 };
    var connections = [_]TestServer.Connection{.{
        .fd = -1,
        .batch = &batch,
        .receive_buffer = &input,
        .receive_end = input.len,
    }};
    var stop: std.atomic.Value(bool) = .init(false);
    var instance: TestServer = .{
        .io = testing.io,
        .config = .{},
        .gpa = testing.allocator,
        .ring = ring,
        .listener = .{ .fd = -1, .port = 0 },
        .admin_listener = .{ .fd = -1, .port = 0 },
        .connections = &connections,
        .storage = &.{},
        .log_slots = &.{},
        .stop = &stop,
    };
    // Inspect submissions before executing them: TCP packet timing cannot
    // reliably distinguish MSG_MORE from autocorking in a wire test.
    try instance.queueBatch(0);
    try testing.expect(instance.ring.sq.sqes[0].rw_flags & linux.MSG.MORE != 0);
    try testing.expect(connections[0].more_pending);

    connections[0].send_pending = false;
    batch.sent = 25;
    try instance.queueBatch(0);
    try testing.expect(instance.ring.sq.sqes[1].rw_flags & linux.MSG.MORE != 0);

    connections[0].send_pending = false;
    connections[0].phase = .reading;
    connections[0].more_count = 14;
    batch = .{ .len = 100, .count = 2 };
    try instance.queueBatch(0);
    try testing.expectEqual(@as(u32, 0), instance.ring.sq.sqes[2].rw_flags & linux.MSG.MORE);
    try testing.expect(!connections[0].more_pending);

    connections[0].send_pending = false;
    connections[0].phase = .reading;
    connections[0].receive_start = input.len;
    batch = .{ .len = 100, .count = 2 };
    try instance.queueBatch(0);
    try testing.expectEqual(@as(u32, 0), instance.ring.sq.sqes[3].rw_flags & linux.MSG.MORE);
}

test "response batch cancellation retains pool storage until both completions" {
    const testing = std.testing;
    const TestServer = Worker(application);
    for ([_]bool{ false, true }) |cancel_first| {
        const fd: linux.fd_t = @intCast(try platform.check(linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
            0,
        )));
        var batch: ResponseBatch = .{};
        for (0..2) |_| batch.append("pending", .{
            .started_ns = platform.monotonicNs(),
            .body_bytes = 7,
            .status = 200,
        }, null);
        batch.sending = true;
        var connections = [_]TestServer.Connection{.{
            .fd = fd,
            .phase = .canceling,
            .send_pending = true,
            .cancel_send_pending = true,
            .pending = 2,
            .batch = &batch,
        }};
        defer if (connections[0].fd >= 0) platform.close(connections[0].fd);
        var active_slots = [_]usize{0};
        var stop: std.atomic.Value(bool) = .init(false);
        var instance: TestServer = .{
            .io = testing.io,
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
            .pending = 2,
            .active_connections = 1,
            .admission = .{ .active = 2 },
        };
        const order: [2]TestServer.Kind = if (cancel_first) .{
            .cancel_send,
            .send,
        } else .{
            .send,
            .cancel_send,
        };
        for (order, 0..) |kind, completed| {
            try instance.complete(.{
                .user_data = TestServer.token(kind, 0, 0),
                .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
                .flags = 0,
            });
            if (completed == 0) {
                try testing.expect(instance.free_batch == null);
                try testing.expectEqual(@as(usize, 2), instance.admission.active);
                try testing.expectEqualStrings("pendingpending", batch.bytes[0..batch.len]);
                try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(
                    fd,
                    linux.F.GETFD,
                    0,
                )));
            }
        }
        try testing.expect(instance.free_batch == &batch);
        try testing.expect(connections[0].batch == null);
        try testing.expectEqual(@as(usize, 0), instance.admission.active);
        try testing.expectEqual(@as(u64, 2), instance.metrics.get(.requests_aborted_total));
        try testing.expectEqual(@as(u64, 0), instance.metrics.get(.requests_completed_total));
    }
}

test "response batch partial sends complete and log each response exactly once" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var ring = linux.IoUring.init(128, 0) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    const fd: linux.fd_t = @intCast(try platform.check(linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    )));
    defer platform.close(fd);
    var input: [64]u8 = undefined;
    var batch: ResponseBatch = .{};
    batch.append("FIRST123", .{
        .started_ns = platform.monotonicNs(),
        .body_bytes = 6,
        .status = 200,
        .method = "GETxxxxx".*,
        .method_len = 3,
    }, "first");
    batch.append("SECOND45", .{
        .started_ns = platform.monotonicNs(),
        .body_bytes = 0,
        .status = 204,
        .method = "OPTIONSx".*,
        .method_len = 7,
    }, "second");
    batch.sending = true;
    var connections = [_]TestServer.Connection{.{
        .fd = fd,
        .phase = .writing,
        .batch = &batch,
        .receive_buffer = &input,
    }};
    var slots: [4]Logger.Slot = undefined;
    var stop: std.atomic.Value(bool) = .init(false);
    var instance: TestServer = .{
        .io = testing.io,
        .config = .{},
        .gpa = testing.allocator,
        .ring = ring,
        .listener = .{ .fd = -1, .port = 0 },
        .admin_listener = .{ .fd = -1, .port = 0 },
        .connections = &connections,
        .storage = &.{},
        .log_slots = &slots,
        .stop = &stop,
        .admission = .{ .active = 2 },
        .draining = true,
    };
    instance.logger.init(&slots, &instance.metrics, false);
    const results = [_]struct {
        bytes: i32,
        completed: u64,
        first_bytes: u64,
    }{
        .{
            .bytes = 5,
            .completed = 0,
            .first_bytes = 1,
        },
        .{
            .bytes = 3,
            .completed = 1,
            .first_bytes = 1,
        },
        .{
            .bytes = 2,
            .completed = 1,
            .first_bytes = 2,
        },
        .{
            .bytes = 6,
            .completed = 2,
            .first_bytes = 2,
        },
    };
    for (results) |result| {
        connections[0].send_pending = false;
        try instance.sentBatch(0, result.bytes);
        try testing.expectEqual(result.completed, instance.metrics.get(.requests_completed_total));
        try testing.expectEqual(2 - result.completed, instance.admission.active);
        const captured = instance.metrics.snapshot();
        var first_bytes: u64 = 0;
        for (captured.histogram(.time_to_first_byte_seconds).buckets) |bucket| first_bytes += bucket;
        try testing.expectEqual(result.first_bytes, first_bytes);
        try testing.expectEqual(result.completed, instance.logger.count);
    }
    try testing.expect(instance.free_batch == &batch);
    try testing.expectEqual(.drain, connections[0].phase);
    try testing.expect(connections[0].receive_pending);
    for ([_][]const u8{ "GET", "OPTIONS" }, 0..) |method, index| {
        const slot = instance.logger.peekAt(index).?;
        const record = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            slot.bytes[0..slot.len],
            .{},
        );
        defer record.deinit();
        try testing.expectEqualStrings(method, record.value.object.get("method").?.string);
        try testing.expect(!record.value.object.contains("request"));
        try testing.expectEqualStrings(
            if (index == 0) "first" else "second",
            record.value.object.get("user_agent").?.string,
        );
    }
}

test "response batch exhaustion submits the original response without borrowing storage" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var ring = linux.IoUring.init(128, 0) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var input = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".*;
    var output = "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nZHTPS\n".*;
    var connections = [_]TestServer.Connection{.{
        .fd = -1,
        .phase = .writing,
        .permit = .admit,
        .receive_buffer = &input,
        .receive_end = input.len,
        .output_buffer = &output,
        .output_len = output.len,
    }};
    var parser: http.Parser = undefined;
    parser.request = .{ .method = "GET" };
    connections[0].parser = &parser;
    var batches = [_]ResponseBatch{.{}};
    var stop: std.atomic.Value(bool) = .init(false);
    var instance: TestServer = .{
        .io = testing.io,
        .config = .{},
        .gpa = testing.allocator,
        .ring = ring,
        .listener = .{ .fd = -1, .port = 0 },
        .admin_listener = .{ .fd = -1, .port = 0 },
        .connections = &connections,
        .batches = &batches,
        .storage = &.{},
        .log_slots = &.{},
        .stop = &stop,
        .active_connections = 1,
        .admission = .{ .options = .{ .max_active = 8 }, .active = 1 },
    };
    try instance.queueSend(0);
    try testing.expect(connections[0].batch == null);
    try testing.expectEqual(.admit, connections[0].permit.?);
    try testing.expectEqual(@as(usize, 1), instance.admission.active);
    try testing.expectEqual(@intFromPtr(&output), instance.ring.sq.sqes[0].addr);
    try testing.expectEqual(output.len, instance.ring.sq.sqes[0].len);
    try testing.expectEqual(@as(u64, 1), instance.metrics.get(.response_batch_fallbacks_total));
    try testing.expectEqual(@as(u64, 0), instance.metrics.get(.responses_batched_total));
}

test "response batch expires at the oldest write deadline after parser reset" {
    const testing = std.testing;
    const TestServer = Worker(application);
    var ring = linux.IoUring.init(128, 0) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    const fd: linux.fd_t = @intCast(try platform.check(linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    )));
    defer platform.close(fd);
    var batch: ResponseBatch = .{
        .len = 8,
        .count = 1,
        .deadline = 1,
    };
    var connections = [_]TestServer.Connection{.{
        .fd = fd,
        .phase = .reading,
        .batch = &batch,
        .deadline = std.math.maxInt(u64),
    }};
    var active_slots = [_]usize{0};
    var stop: std.atomic.Value(bool) = .init(false);
    var instance: TestServer = .{
        .io = testing.io,
        .config = .{},
        .gpa = testing.allocator,
        .ring = ring,
        .listener = .{ .fd = -1, .port = 0 },
        .admin_listener = .{ .fd = -1, .port = 0 },
        .connections = &connections,
        .active_slots = &active_slots,
        .active_connections = 1,
        .storage = &.{},
        .log_slots = &.{},
        .stop = &stop,
        .admission = .{ .active = 1 },
    };
    try instance.queueBatch(0);
    try testing.expectEqual(@as(u64, 1), connections[0].deadline);
    try testing.expect(!connections[0].request_started);
    try instance.tick();
    try testing.expectEqual(@as(u64, 1), instance.metrics.get(.write_timeouts_total));
    try testing.expectEqual(@as(u64, 0), instance.metrics.get(.connections_idle_closed_total));
    try testing.expectEqual(.canceling, connections[0].phase);
    try testing.expect(connections[0].cancel_send_pending);
    try testing.expect(instance.free_batch == null);
    try testing.expectEqual(@as(usize, 1), instance.admission.active);
}
