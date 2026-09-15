//! Owned server lifecycle, independent of command-line arguments and process signals.

const std = @import("std");
const Config = @import("Config.zig");
const Tls = @import("Tls.zig");
const platform = @import("platform.zig");
const builtin_application = @import("application.zig");
const worker = @import("server/worker.zig");
const log = std.log.scoped(.server);

pub const InitError = worker.RunError;
pub const RunError = InitError || std.Thread.SpawnError || error{AlreadyServed};

/// App.Exchange implements the low-level hooks illustrated by application.Exchange.
/// Direct hooks must be bounded and nonblocking; generated endpoint applications
/// instead use shared bounded executors. Hooks for different connections may run
/// concurrently even when they share a connection or transport owner.
/// The server owns connection and stream storage, but no application-global resources.
pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();
        const Worker = worker.Worker(App);

        gpa: std.mem.Allocator,
        shared: *Worker.Shared,
        threads: []std.Thread,
        automatic_mapping: []u8,
        phase: enum {
            ready,
            serving,
            finished,
        } = .ready,

        /// Binds every listener and allocates worker storage without starting threads.
        /// The allocator, io, configuration strings, and log descriptor are borrowed
        /// until deinit. io must support concurrent wall-clock reads during serve.
        /// On error all acquired resources are released; self remains undefined.
        /// On success the value may move, but must not be copied or mutated directly.
        /// Call deinit even if serve is never called.
        pub fn init(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            config: Config,
        ) InitError!void {
            if (comptime Worker.RuntimeInit != void)
                @compileError("this application requires initApplication with its runtime value");
            return self.initInner(
                gpa,
                io,
                config,
                {},
            );
        }

        /// Binds every listener and allocates worker storage without starting threads.
        /// The allocator, io, configuration strings, log descriptor, and application
        /// runtime value are borrowed until deinit. io must support concurrent
        /// wall-clock reads during serve. On error all acquired resources are
        /// released; self remains undefined. On success the value may move, but
        /// must not be copied or mutated directly. Call deinit even if never served.
        pub fn initApplication(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            config: Config,
            application: Worker.RuntimeInit,
        ) InitError!void {
            return self.initInner(
                gpa,
                io,
                config,
                application,
            );
        }

        fn initInner(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            config: Config,
            application: Worker.RuntimeInit,
        ) InitError!void {
            self.* = undefined;
            try config.validate();
            var detected = try Config.Resources.detect(gpa, io);
            if (config.worker_cpus.len == 0) try detected.detectPlacement(io, config.address);
            const automatic_mapping = try gpa.alloc(u8, 1280);
            errdefer gpa.free(automatic_mapping);
            var resolved = try config.resolveResources(
                &detected,
                Worker.resourceRequirements(config),
                automatic_mapping,
            );
            const shared = try gpa.create(Worker.Shared);
            errdefer gpa.destroy(shared);
            const workers = try gpa.alloc(Worker, resolved.workers);
            errdefer gpa.free(workers);
            const threads = try gpa.alloc(std.Thread, resolved.workers - 1);
            errdefer gpa.free(threads);
            shared.* = .{ .workers = workers };
            if (resolved.tls) |options| {
                var tls: Tls = undefined;
                try tls.init(gpa, options);
                shared.tls = tls;
            }
            errdefer if (shared.tls) |*tls| tls.deinit();
            var initialized: usize = 0;
            errdefer for (0..initialized) |offset| workers[initialized - 1 - offset].deinit();
            for (workers, 0..) |*item, id| {
                try item.initApplication(
                    gpa,
                    io,
                    .{
                        .config = resolved,
                        .stop = &shared.abort,
                        .worker_id = @intCast(id),
                        .shared = shared,
                    },
                    application,
                );
                initialized += 1;
                if (id == 0) {
                    resolved.port = item.listener.port;
                    resolved.admin_port = item.admin_listener.port;
                    item.config = resolved;
                }
            }
            self.* = .{
                .gpa = gpa,
                .shared = shared,
                .threads = threads,
                .automatic_mapping = automatic_mapping,
            };
        }

        /// Returns the bound public port, including the kernel-selected port when
        /// configuration requested zero. Available as soon as init succeeds.
        pub fn port(self: *const Self) u16 {
            return self.shared.workers[0].listener.port;
        }

        /// Returns the bound admin port, or null when admin_connections is zero.
        /// Available as soon as init succeeds.
        pub fn adminPort(self: *const Self) ?u16 {
            const listener = self.shared.workers[0].admin_listener;
            return if (listener.fd >= 0) listener.port else null;
        }

        /// Runs the event loops until requestStop or a worker error. The calling
        /// thread runs worker zero; other workers are joined before returning,
        /// including on errors. Request and buffer cache misses and eviction can call
        /// the supplied allocator from worker threads, serialized across workers.
        /// Callers must synchronize any concurrent external use of that allocator.
        /// Each worker preallocates up to 64 public connection buffer sets and
        /// request leases, and reserves admin storage. Further simultaneous
        /// connections or requests may allocate.
        /// Call at most once per initialization, from one thread. The value must
        /// stay at the same address until serve returns. A second call returns
        /// AlreadyServed. A stop requested before this call is honored.
        /// Explicit worker placement is restricted to this thread's allowed CPUs;
        /// its original affinity is restored before return, including on error.
        pub fn serve(self: *Self) RunError!void {
            if (self.phase != .ready) return error.AlreadyServed;
            self.phase = .serving;
            defer self.phase = .finished;
            const workers = self.shared.workers;
            // Validate before spawning: children inherit this mask, and an
            // explicit mapping must never widen a taskset/cpuset restriction.
            if (workers[0].config.worker_cpus.len != 0) {
                const allowed = try platform.getAffinity();
                for (workers) |item| {
                    if (!platform.cpuAllowed(&allowed, item.worker_cpu.?)) return error.CpuUnavailable;
                }
            }
            try workers[0].startApplications();
            defer workers[0].stopApplications();
            var started: usize = 0;
            defer {
                self.shared.abort.store(true, .monotonic);
                for (self.threads[0..started]) |thread| thread.join();
            }
            for (self.threads, workers[1..]) |*thread, *item| {
                thread.* = try std.Thread.spawn(
                    .{},
                    Worker.workerMain,
                    .{item},
                );
                started += 1;
            }
            workers[0].workerMain();
            for (self.threads[0..started]) |thread| thread.join();
            started = 0;
            for (workers) |item| if (item.failure) |err| return err;
        }

        /// Requests graceful shutdown without waiting. Safe to call repeatedly
        /// from another thread after init and before deinit. shutdown_timeout_ms
        /// limits the grace period; application hooks must still return before
        /// their storage can be released, so serve can wait beyond that deadline.
        pub fn requestStop(self: *const Self) void {
            self.shared.abort.store(true, .monotonic);
        }

        /// Releases owned listeners, rings, and storage. Asserts serve is not
        /// running. The caller must join any thread it used to invoke serve first.
        /// Borrowed io, descriptors, and application resources remain caller-owned.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.phase != .serving);
            const workers = self.shared.workers;
            for (0..workers.len) |offset| workers[workers.len - 1 - offset].deinit();
            if (self.shared.tls) |*tls| tls.deinit();
            self.gpa.free(self.threads);
            self.gpa.free(self.shared.workers);
            self.gpa.destroy(self.shared);
            self.gpa.free(self.automatic_mapping);
            self.* = undefined;
        }

        /// Initializes, serves, and releases a server using a caller-owned stop
        /// flag. Borrows all inputs until return. Setting stop to true requests
        /// graceful shutdown; this function never installs process signal handlers.
        /// The calling thread uses the allocator; io must support concurrent reads.
        pub fn run(
            gpa: std.mem.Allocator,
            io: std.Io,
            config: Config,
            stop: *const std.atomic.Value(bool),
        ) RunError!void {
            var instance: Self = undefined;
            try instance.init(
                gpa,
                io,
                config,
            );
            defer instance.deinit();
            for (instance.shared.workers) |*item| item.stop = stop;
            try instance.serve();
        }
    };
}

test {
    _ = worker;
}

test "worker placement restores caller affinity after stop and loop error" {
    const testing = std.testing;
    const original = try platform.getAffinity();
    var cpu: usize = 0;
    while (!platform.cpuAllowed(&original, cpu)) : (cpu += 1) {}
    var buffer: [16]u8 = undefined;
    const mapping = try std.fmt.bufPrint(
        &buffer,
        "{d}",
        .{cpu},
    );
    for ([_]bool{ false, true }) |fail_loop| {
        var instance: Server(builtin_application) = undefined;
        instance.init(
            testing.allocator,
            testing.io,
            .{
                .port = 0,
                .admin_connections = 0,
                .max_connections = 2,
                .log_fd = null,
                .worker_cpus = mapping,
            },
        ) catch |err| switch (err) {
            error.IoUringUnavailable => return error.SkipZigTest,
            else => return err,
        };
        defer instance.deinit();
        if (fail_loop) {
            const invalid_listener: platform.linux.fd_t = @intCast(try platform.check(platform.linux.socket(
                platform.linux.AF.UNIX,
                platform.linux.SOCK.STREAM | platform.linux.SOCK.CLOEXEC,
                0,
            )));
            const listener = &instance.shared.workers[0].listener;
            platform.close(listener.fd);
            listener.fd = invalid_listener;
            try testing.expectError(error.IoUringOperationUnsupported, instance.serve());
        } else {
            instance.requestStop();
            try instance.serve();
        }
        try testing.expectEqual(original, try platform.getAffinity());
    }
}
