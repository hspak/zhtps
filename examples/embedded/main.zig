//! A separate Zig project importing ZHTPS, with process lifetime owned by the host.

const std = @import("std");
const zhtps = @import("zhtps");

const Serving = struct {
    server: *zhtps.DefaultServer,
    failure: ?zhtps.RunError = null,
    fn run(serving: *Serving) void {
        serving.server.serve() catch |err| {
            serving.failure = err;
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var server: zhtps.DefaultServer = undefined;
    try server.init(
        init.gpa,
        init.io,
        .{
            .port = 8080,
            .admin_connections = 0,
            .log_fd = null,
        },
    );
    defer server.deinit();

    var serving: Serving = .{ .server = &server };
    {
        const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
        defer {
            server.requestStop();
            thread.join();
        }
        try std.Io.File.stdout().writeStreamingAll(
            init.io,
            "Serving http://127.0.0.1:8080/; press Enter to stop.\n",
        );
        var buffer: [1024]u8 = undefined;
        var reader = std.Io.File.stdin().reader(init.io, &buffer);
        _ = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
    }
    if (serving.failure) |err| return err;
}

fn request(gpa: std.mem.Allocator, port: u16, bytes: []const u8) ![]u8 {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(bytes);
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    return reader.interface.allocRemaining(gpa, .limited(16 * 1024));
}

const endpoint_api = struct {
    const ApiCall = zhtps.Call(endpoint_api);

    pub const Services = struct {
        greeting: []const u8,
        slow_started: std.atomic.Value(bool) = .init(false),
        timeout_started: std.atomic.Value(bool) = .init(false),
        timeout_executions: std.atomic.Value(u64) = .init(0),
    };

    pub const Local = struct {
        authenticated: bool = false,
    };

    pub const metrics = struct {
        pub const Counter = enum { greetings_total };
    };

    pub const HandlerError = zhtps.EndpointError || error{Canceled};

    pub const metrics_namespace = "embedded";
    pub const lanes = .{
        .api = .{
            .threads = 1,
            .queue = 2,
            .timeout_ms = 1000,
        },
        .slow = .{
            .threads = 1,
            .queue = 1,
            .timeout_ms = 1000,
        },
        .timeout = .{
            .threads = 1,
            .queue = 1,
            .timeout_ms = 50,
        },
    };

    fn authenticate(call: *ApiCall) !?zhtps.http.Response {
        if (call.header("Authorization") == null)
            return .{
                .status = 401,
                .headers = &.{
                    .{ .name = "WWW-Authenticate", .value = "Bearer" },
                    .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                },
                .body = .{ .bytes = "authorization required\n" },
            };
        call.local.authenticated = true;
        call.access.put("authenticated", true);
        return null;
    }

    fn greet(call: *ApiCall) !zhtps.http.Response {
        std.debug.assert(call.local.authenticated);
        const id = try call.paramInt(u32, "id");
        const input = try call.bodyJson(struct { name: []const u8 });
        call.metrics.add(.greetings_total, 1);
        call.log(.info, "greeting_created", .{ .id = id });
        return try call.json(.created, .{
            .id = id,
            .name = input.name,
            .greeting = call.services.greeting,
        });
    }

    fn fast(call: *ApiCall) !zhtps.http.Response {
        return call.text(.ok, "fast\n");
    }

    fn slow(call: *ApiCall) !zhtps.http.Response {
        call.services.slow_started.store(true, .release);
        try call.io.sleep(.fromMilliseconds(500), .awake);
        return call.text(.ok, "slow\n");
    }

    fn timeout(call: *ApiCall) !zhtps.http.Response {
        _ = call.services.timeout_executions.fetchAdd(1, .monotonic);
        call.services.timeout_started.store(true, .release);
        try call.io.sleep(.fromMilliseconds(150), .awake);
        return call.text(.ok, "late\n");
    }

    pub const routes = .{
        zhtps.group(.{
            .prefix = "/v1",
            .before = .{authenticate},
            .routes = .{
                zhtps.endpoint(.{
                    .name = "greet",
                    .method = .post,
                    .path = "/greetings/:id",
                    .handler = greet,
                    .body = .json,
                    .max_body_bytes = 1024,
                    .lane = .api,
                }),
            },
        }),
        zhtps.endpoint(.{
            .name = "fast",
            .method = .get,
            .path = "/fast",
            .handler = fast,
            .lane = .api,
        }),
        zhtps.endpoint(.{
            .name = "slow",
            .method = .get,
            .path = "/slow",
            .handler = slow,
            .lane = .slow,
        }),
        zhtps.endpoint(.{
            .name = "timeout",
            .method = .get,
            .path = "/timeout",
            .handler = timeout,
            .lane = .timeout,
        }),
    };
};

const EndpointApp = zhtps.Application(endpoint_api);

const EndpointServing = struct {
    server: *EndpointApp.Server,
    failure: ?zhtps.RunError = null,
    fn run(serving: *EndpointServing) void {
        serving.server.serve() catch |err| {
            serving.failure = err;
        };
    }
};

const BackgroundRequest = struct {
    port: u16,
    bytes: []const u8,
    response: ?[]u8 = null,
    failed: bool = false,
    fn run(background: *BackgroundRequest) void {
        background.response = request(
            std.testing.allocator,
            background.port,
            background.bytes,
        ) catch {
            background.failed = true;
            return;
        };
    }
};

test "dependency serves HTTP with multiple workers and caller-controlled shutdown" {
    const testing = std.testing;
    var server: zhtps.DefaultServer = undefined;
    try server.init(
        testing.allocator,
        testing.io,
        .{
            .port = 0,
            .workers = 2,
            .max_connections = 4,
            .admin_connections = 0,
            .admin_address = "unused when admin is disabled",
            .log_fd = null,
        },
    );
    defer server.deinit();
    try testing.expect(server.port() != 0);
    try testing.expectEqual(@as(?u16, null), server.adminPort());

    var serving: Serving = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    {
        defer {
            server.requestStop();
            server.requestStop();
            thread.join();
        }
        const root = try request(
            testing.allocator,
            server.port(),
            "GET / HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
        );
        defer testing.allocator.free(root);
        try testing.expect(std.mem.startsWith(u8, root, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.endsWith(u8, root, "\r\n\r\nZHTPS\n"));
        const echo = try request(
            testing.allocator,
            server.port(),
            "POST /echo HTTP/1.1\r\nHost: example\r\nContent-Length: 13\r\n" ++
                "Connection: close\r\n\r\nfrom consumer",
        );
        defer testing.allocator.free(echo);
        try testing.expect(std.mem.startsWith(u8, echo, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.endsWith(u8, echo, "\r\n\r\nfrom consumer"));
    }
    try testing.expectEqual(@as(?zhtps.RunError, null), serving.failure);
    try testing.expectError(error.AlreadyServed, server.serve());
}

test "dependency worker placement leaves endpoint executors on the inherited mask" {
    const testing = std.testing;
    const original = try zhtps.platform.getAffinity();
    if (zhtps.platform.linux.CPU_COUNT(original) < 2) return error.SkipZigTest;
    var cpu: usize = 0;
    while (!zhtps.platform.cpuAllowed(&original, cpu)) : (cpu += 1) {}
    var mapping_buffer: [16]u8 = undefined;
    const mapping = try std.fmt.bufPrint(&mapping_buffer, "{d}", .{cpu});
    const api = struct {
        const ApiCall = zhtps.Call(@This());

        pub const HandlerError = zhtps.EndpointError || zhtps.platform.Error;
        pub const routes = .{zhtps.get("/", check)};

        fn check(call: *ApiCall) HandlerError!zhtps.http.Response {
            return call.json(.ok, try zhtps.platform.getAffinity());
        }
    };
    const App = zhtps.Application(api);
    const Host = struct {
        server: *App.Server,
        failure: ?zhtps.RunError = null,
        fn run(host: *@This()) void {
            host.server.serve() catch |err| {
                host.failure = err;
            };
        }
    };
    var server: App.Server = undefined;
    try server.init(
        testing.allocator,
        testing.io,
        .{
            .port = 0,
            .max_connections = 2,
            .admin_connections = 0,
            .log_fd = null,
            .worker_cpus = mapping,
        },
        .{},
    );
    defer server.deinit();
    var host: Host = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Host.run, .{&host});
    {
        defer {
            server.requestStop();
            thread.join();
        }
        const response = try request(
            testing.allocator,
            server.port(),
            "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        );
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
        const boundary = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
        const mask = try std.json.parseFromSlice(
            zhtps.platform.linux.cpu_set_t,
            testing.allocator,
            response[boundary..],
            .{},
        );
        defer mask.deinit();
        try testing.expectEqual(original, mask.value);
    }
    try testing.expectEqual(@as(?zhtps.RunError, null), host.failure);
}

test "dependency automatically sizes generated executors within inherited affinity" {
    const testing = std.testing;
    const original = try zhtps.platform.getAffinity();
    var cpu: usize = 0;
    while (!zhtps.platform.cpuAllowed(&original, cpu)) : (cpu += 1) {}
    _ = try zhtps.platform.pinCpu(cpu);
    defer zhtps.platform.setAffinity(&original) catch unreachable;
    var services: endpoint_api.Services = .{ .greeting = "hello" };
    var server: EndpointApp.Server = undefined;
    try server.init(testing.allocator, testing.io, .{
        .port = 0,
        .admin_port = 0,
        .log_fd = null,
    }, .{ .services = &services });
    defer server.deinit();
    var serving: EndpointServing = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, EndpointServing.run, .{&serving});
    defer {
        server.requestStop();
        thread.join();
    }
    const response = try request(
        testing.allocator,
        server.adminPort().?,
        "GET /debug/config HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n",
    );
    defer testing.allocator.free(response);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    const boundary = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
    const config = try std.json.parseFromSlice(zhtps.Config, testing.allocator, response[boundary..], .{});
    defer config.deinit();
    try testing.expectEqual(@as(usize, 1), config.value.workers);
    try testing.expectEqual(@as(usize, 4), config.value.resources.?.threads_per_worker);
    try testing.expectEqual(@as(usize, 1), config.value.resources.?.detected.allowed_cpus);
}

test "dependency serves generated endpoints with middleware services and metrics" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const log_file = try temporary.dir.createFile(
        testing.io,
        "endpoint-events.jsonl",
        .{ .read = true },
    );
    defer log_file.close(testing.io);
    var services: endpoint_api.Services = .{ .greeting = "hello" };
    var server: EndpointApp.Server = undefined;
    try server.init(
        testing.allocator,
        testing.io,
        .{
            .port = 0,
            .admin_port = 0,
            // This queue-expiry scenario requires one thread in each declared lane.
            .workers = 1,
            .max_connections = 4,
            .admin_connections = 1,
            .log_fd = log_file.handle,
        },
        .{ .services = &services },
    );
    defer server.deinit();

    var serving: EndpointServing = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, EndpointServing.run, .{&serving});
    defer {
        server.requestStop();
        thread.join();
    }

    // The declared body is intentionally incomplete: head middleware must reject
    // before waiting for it.
    const unauthorized = try request(
        testing.allocator,
        server.port(),
        "POST /v1/greetings/7 HTTP/1.1\r\nHost: example\r\n" ++
            "Content-Type: application/json\r\nContent-Length: 16\r\n" ++
            "Connection: close\r\n\r\n{\"name\":\"zig\"}",
    );
    defer testing.allocator.free(unauthorized);
    try testing.expect(std.mem.startsWith(u8, unauthorized, "HTTP/1.1 401 Unauthorized\r\n"));

    const response = try request(
        testing.allocator,
        server.port(),
        "POST /v1/greetings/7 HTTP/1.1\r\nHost: example\r\n" ++
            "Authorization: bearer test\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 14\r\nConnection: close\r\n\r\n{\"name\":\"zig\"}",
    );
    defer testing.allocator.free(response);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.endsWith(
        u8,
        response,
        "\r\n\r\n{\"id\":7,\"name\":\"zig\",\"greeting\":\"hello\"}",
    ));

    var slow_request: BackgroundRequest = .{
        .port = server.port(),
        .bytes = "GET /slow HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
    };
    const slow_thread = try std.Thread.spawn(.{}, BackgroundRequest.run, .{&slow_request});
    while (!services.slow_started.load(.acquire)) std.Thread.yield() catch {};
    const fast_started = zhtps.platform.monotonicNs();
    const fast_response = try request(
        testing.allocator,
        server.port(),
        "GET /fast HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
    );
    const fast_duration = zhtps.platform.monotonicNs() - fast_started;
    defer testing.allocator.free(fast_response);
    try testing.expect(std.mem.startsWith(u8, fast_response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(fast_duration < 300 * std.time.ns_per_ms);
    slow_thread.join();
    try testing.expect(!slow_request.failed);
    defer testing.allocator.free(slow_request.response.?);
    try testing.expect(std.mem.startsWith(u8, slow_request.response.?, "HTTP/1.1 200 OK\r\n"));

    var first_timeout: BackgroundRequest = .{
        .port = server.port(),
        .bytes = "GET /timeout HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
    };
    const first_timeout_thread = try std.Thread.spawn(
        .{},
        BackgroundRequest.run,
        .{&first_timeout},
    );
    while (!services.timeout_started.load(.acquire)) std.Thread.yield() catch {};
    var queued_timeout: BackgroundRequest = .{
        .port = server.port(),
        .bytes = "GET /timeout HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
    };
    const queued_timeout_thread = std.Thread.spawn(
        .{},
        BackgroundRequest.run,
        .{&queued_timeout},
    ) catch |err| {
        first_timeout_thread.join();
        return err;
    };
    first_timeout_thread.join();
    queued_timeout_thread.join();
    if (first_timeout.response) |bytes| testing.allocator.free(bytes);
    if (queued_timeout.response) |bytes| testing.allocator.free(bytes);
    try testing.io.sleep(.fromMilliseconds(200), .awake);
    try testing.expectEqual(@as(u64, 1), services.timeout_executions.load(.monotonic));

    const after_timeout = try request(
        testing.allocator,
        server.port(),
        "GET /fast HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
    );
    defer testing.allocator.free(after_timeout);
    try testing.expect(std.mem.startsWith(u8, after_timeout, "HTTP/1.1 200 OK\r\n"));

    const metrics = try request(
        testing.allocator,
        server.adminPort().?,
        "GET /metrics HTTP/1.1\r\nHost: admin\r\nConnection: close\r\n\r\n",
    );
    defer testing.allocator.free(metrics);
    try testing.expect(std.mem.indexOf(u8, metrics, "embedded_greetings_total 1\n") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        metrics,
        "zhtps_application_timeouts_total 2\n",
    ) != null);

    const metrics_json = try request(
        testing.allocator,
        server.adminPort().?,
        "GET /debug/metrics HTTP/1.1\r\nHost: admin\r\nConnection: close\r\n\r\n",
    );
    defer testing.allocator.free(metrics_json);
    try testing.expect(std.mem.indexOf(
        u8,
        metrics_json,
        "\"application\":{\"counters\":{\"greetings_total\":1}",
    ) != null);

    var log_buffer: [32 * 1024]u8 = undefined;
    const log_deadline = zhtps.platform.monotonicNs() + std.time.ns_per_s;
    var observed_logs = false;
    while (zhtps.platform.monotonicNs() < log_deadline) {
        const log_len = try log_file.readPositionalAll(testing.io, &log_buffer, 0);
        const log_bytes = log_buffer[0..log_len];
        observed_logs = std.mem.indexOf(u8, log_bytes, "\"event\":\"greeting_created\"") != null and
            std.mem.indexOf(u8, log_bytes, "\"route\":\"greet\",\"fields\":{\"id\":7}") != null and
            std.mem.indexOf(u8, log_bytes, "\"event\":\"request_complete\"") != null and
            std.mem.indexOf(
                u8,
                log_bytes,
                "\"route\":\"greet\",\"fields\":{\"authenticated\":true}",
            ) != null;
        if (observed_logs) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(observed_logs);
    try testing.expectEqual(@as(?zhtps.RunError, null), serving.failure);
}

test "dependency releases both listeners without serving and honors an early stop" {
    const testing = std.testing;
    var public_port: u16 = undefined;
    var admin_port: u16 = undefined;
    {
        var server: zhtps.DefaultServer = undefined;
        try server.init(
            testing.allocator,
            testing.io,
            .{
                .port = 0,
                .admin_port = 0,
                .max_connections = 2,
                .log_fd = null,
            },
        );
        defer server.deinit();
        public_port = server.port();
        admin_port = server.adminPort().?;
        try testing.expect(public_port != admin_port);
    }
    var server: zhtps.DefaultServer = undefined;
    try server.init(
        testing.allocator,
        testing.io,
        .{
            .port = public_port,
            .admin_port = admin_port,
            .workers = 2,
            .max_connections = 2,
            .log_fd = null,
        },
    );
    defer server.deinit();
    server.requestStop();
    try server.serve();
    try testing.expectError(error.AlreadyServed, server.serve());
}

test "dependency unwinds every startup allocation failure" {
    const fixture = struct {
        fn initialize(gpa: std.mem.Allocator) !void {
            var server: zhtps.DefaultServer = undefined;
            try server.init(
                gpa,
                std.testing.io,
                .{
                    .port = 0,
                    .admin_port = 0,
                    .workers = 2,
                    .max_connections = 1,
                    .admin_connections = 1,
                    .log_slots = 1,
                },
            );
            defer server.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixture.initialize, .{});
}

test "dependency returns startup errors and releases a partially bound listener" {
    const testing = std.testing;
    var server: zhtps.DefaultServer = undefined;
    try testing.expectError(error.InvalidLimit, server.init(
        testing.allocator,
        testing.io,
        .{
            .workers = 0,
        },
    ));
    const reserved = try zhtps.platform.listen("127.0.0.1", 0, .{});
    zhtps.platform.close(reserved.fd);
    try testing.expectError(error.InvalidAddress, server.init(
        testing.allocator,
        testing.io,
        .{
            .port = reserved.port,
            .admin_address = "invalid address",
            .max_connections = 1,
        },
    ));
    const rebound = try zhtps.platform.listen("127.0.0.1", reserved.port, .{});
    defer zhtps.platform.close(rebound.fd);
}

test "dependency writes JSON to a borrowed log file and leaves it open" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(testing.io, "events.jsonl", .{ .read = true });
    defer file.close(testing.io);
    {
        var server: zhtps.DefaultServer = undefined;
        try server.init(
            testing.allocator,
            testing.io,
            .{
                .port = 0,
                .max_connections = 2,
                .admin_connections = 0,
                .log_fd = file.handle,
            },
        );
        defer server.deinit();
        var serving: Serving = .{ .server = &server };
        const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
        {
            defer {
                server.requestStop();
                thread.join();
            }
            const response = try request(
                testing.allocator,
                server.port(),
                "GET / HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
            );
            defer testing.allocator.free(response);
            try testing.expect(std.mem.endsWith(u8, response, "\r\n\r\nZHTPS\n"));
        }
        try testing.expectEqual(@as(?zhtps.RunError, null), serving.failure);
    }
    var buffer: [8192]u8 = undefined;
    const len = try file.readPositionalAll(testing.io, &buffer, 0);
    var lines = std.mem.tokenizeScalar(u8, buffer[0..len], '\n');
    var listening = false;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        if (std.mem.eql(
            u8,
            parsed.value.object.get("event").?.string,
            "listening",
        )) listening = true;
    }
    try testing.expect(listening);
}

test {
    _ = @import("endpoints.zig");
}

test "dependency aggregates without allocating after server initialization" {
    const testing = std.testing;
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var server: zhtps.DefaultServer = undefined;
    try server.init(
        failing.allocator(),
        testing.io,
        .{
            .port = 0,
            .admin_port = 0,
            .max_connections = 64,
            .admin_connections = 1,
            .response_batches = 1,
            .admission = .{ .max_active = 64 },
            .log_fd = null,
        },
    );
    defer server.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var serving: Serving = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    {
        defer {
            server.requestStop();
            thread.join();
        }
        const pipeline = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" ** 32 ++
            "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        const response = try request(testing.allocator, server.port(), pipeline);
        defer testing.allocator.free(response);
        try testing.expectEqual(@as(usize, 33), std.mem.count(u8, response, "HTTP/1.1 200 OK\r\n"));
        const metrics_response = try request(
            testing.allocator,
            server.adminPort().?,
            "GET /debug/metrics HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        );
        defer testing.allocator.free(metrics_response);
        const boundary = std.mem.indexOf(u8, metrics_response, "\r\n\r\n").? + 4;
        const captured = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            metrics_response[boundary..],
            .{},
        );
        defer captured.deinit();
        const counters = captured.value.object.get("counters").?.object;
        try testing.expect(counters.get("responses_batched_total").?.integer > 0);
    }
    try testing.expectEqual(@as(?zhtps.RunError, null), serving.failure);
    try testing.expect(!failing.has_induced_failure);
}

test "dependency preserves custom cleanup and access metadata with batching configured" {
    const testing = std.testing;
    const api = struct {
        const ApiCall = zhtps.Call(@This());

        pub const Services = struct { releases: std.atomic.Value(usize) = .init(0) };
        pub const Local = struct { tag: []u8 = &.{} };
        pub const routes = .{zhtps.endpoint(.{
            .name = "tag",
            .method = .get,
            .path = "/",
            .handler = respond,
        })};

        fn respond(call: *ApiCall) zhtps.EndpointError!zhtps.http.Response {
            call.local.tag = try call.scratch.allocator().dupe(u8, call.header("X-Tag").?);
            call.access.put("tag", call.local.tag);
            return call.text(.ok, call.local.tag);
        }

        pub fn release(call: *ApiCall) void {
            @memset(call.local.tag, '!');
            _ = call.services.releases.fetchAdd(1, .monotonic);
        }
    };
    const App = zhtps.Application(api);
    const Host = struct {
        const Self = @This();
        server: *App.Server,
        failure: ?zhtps.RunError = null,

        fn run(host: *Self) void {
            host.server.serve() catch |err| {
                host.failure = err;
            };
        }
    };
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(testing.io, "custom.jsonl", .{ .read = true });
    defer file.close(testing.io);
    var services: api.Services = .{};
    var server: App.Server = undefined;
    try server.init(
        testing.allocator,
        testing.io,
        .{
            .port = 0,
            .admin_port = 0,
            .max_connections = 64,
            .admin_connections = 1,
            .response_batches = 8,
            .admission = .{ .max_active = 64 },
            .log_fd = file.handle,
        },
        .{ .services = &services },
    );
    defer server.deinit();
    var host: Host = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Host.run, .{&host});
    {
        defer {
            server.requestStop();
            thread.join();
        }
        const response = try request(
            testing.allocator,
            server.port(),
            "GET / HTTP/1.1\r\nHost: localhost\r\nX-Tag: first\r\n\r\n" ++
                "GET / HTTP/1.1\r\nHost: localhost\r\nX-Tag: second\r\nConnection: close\r\n\r\n",
        );
        defer testing.allocator.free(response);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, response, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.indexOf(u8, response, "\r\n\r\nfirstHTTP/1.1") != null);
        try testing.expect(std.mem.endsWith(u8, response, "\r\n\r\nsecond"));
        const inspection = try request(
            testing.allocator,
            server.adminPort().?,
            "GET /debug/workers HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        );
        defer testing.allocator.free(inspection);
        const boundary = std.mem.indexOf(u8, inspection, "\r\n\r\n").? + 4;
        const captured = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            inspection[boundary..],
            .{},
        );
        defer captured.deinit();
        const worker = captured.value.object.get("workers").?.array.items[0].object;
        try testing.expectEqual(@as(i64, 0), worker.get("response_batch_capacity").?.integer);
    }
    try testing.expectEqual(@as(?zhtps.RunError, null), host.failure);
    try testing.expectEqual(@as(usize, 2), services.releases.load(.monotonic));
    var buffer: [8192]u8 = undefined;
    const len = try file.readPositionalAll(testing.io, &buffer, 0);
    var lines = std.mem.tokenizeScalar(u8, buffer[0..len], '\n');
    const expected = [_][]const u8{ "first", "second" };
    var count: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        const record = parsed.value.object;
        if (!std.mem.eql(u8, record.get("event").?.string, "request_complete")) continue;
        if (record.get("route") == null) continue;
        try testing.expect(count < expected.len);
        try testing.expectEqualStrings(
            expected[count],
            record.get("fields").?.object.get("tag").?.string,
        );
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "dependency unwinds response batch pool allocation failures" {
    const harness = struct {
        fn exercise(gpa: std.mem.Allocator) !void {
            var server: zhtps.DefaultServer = undefined;
            try server.init(
                gpa,
                std.testing.io,
                .{
                    .port = 0,
                    .admin_connections = 0,
                    .max_connections = 8,
                    .admission = .{ .max_active = 8 },
                    .response_batches = 2,
                    .log_fd = null,
                },
            );
            defer server.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, harness.exercise, .{});
}
