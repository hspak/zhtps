//! Wire regressions for generated applications through the public library API.

const std = @import("std");
const zhtps = @import("zhtps");
const log = std.log.scoped(.embedded_endpoints);

// The caller frees the captured response with std.testing.allocator.
fn request(comptime Spec: type, bytes: []const u8) ![]const u8 {
    return requestWithOptions(
        Spec,
        .{},
        bytes,
    );
}

// The caller frees the captured response with std.testing.allocator.
fn requestWithOptions(
    comptime Spec: type,
    options: zhtps.Application(Spec).Server.Options,
    bytes: []const u8,
) ![]const u8 {
    const App = zhtps.Application(Spec);
    const Serving = struct {
        const Self = @This();

        server: *App.Server,

        fn run(serving: *Self) void {
            serving.server.serve() catch @panic("test server stopped unexpectedly");
        }
    };
    const testing = std.testing;
    var server: App.Server = undefined;
    try server.init(
        testing.allocator,
        testing.io,
        .{
            .port = 0,
            .admin_connections = 0,
            .max_connections = 4,
            .log_fd = null,
        },
        options,
    );
    defer server.deinit();
    var serving: Serving = .{ .server = &server };
    const thread = try std.Thread.spawn(
        .{},
        Serving.run,
        .{&serving},
    );
    defer {
        server.requestStop();
        thread.join();
    }
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", server.port());
    const stream = try address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    var writer = stream.writer(testing.io, &.{});
    try writer.interface.writeAll(bytes);
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(testing.io, &buffer);
    return reader.interface.allocRemaining(testing.allocator, .limited(64 * 1024));
}

const api = struct {
    const C = zhtps.Call(@This());
    fn respond(call: *C) zhtps.EndpointError!zhtps.http.Response {
        return call.text(.ok, call.route_name);
    }
    fn invalid(_: *C) zhtps.EndpointError!?zhtps.http.Response {
        return error.InvalidInput;
    }
    fn query(call: *C) zhtps.EndpointError!zhtps.http.Response {
        return call.json(.ok, .{
            .name = try call.query("name"),
            .q = try call.query("q"),
        });
    }
    pub const routes = .{
        zhtps.get("/items/:id", respond),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/items/new",
            .name = "static",
            .handler = respond,
        }),
        zhtps.endpoint(.{
            .method = .post,
            .path = "/items/:id",
            .handler = respond,
        }),
        zhtps.endpoint(.{
            .method = .get,
            .path = "/invalid",
            .before = &.{invalid},
            .handler = respond,
        }),
        zhtps.get("/query", query),
    };
};

test "generated error responses retain headers and preserve keep alive" {
    const bytes = try request(api, "GET /missing HTTP/1.1\r\nHost: example\r\n\r\n" ++
        "PUT /items/1 HTTP/1.1\r\nHost: example\r\n\r\n" ++
        "GET /items/1 HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "HTTP/1.1 404",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "HTTP/1.1 405",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "Allow: GET, HEAD, OPTIONS, POST\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "HTTP/1.1 200",
    ) != null);
}

test "generated OPTIONS retains Allow and supports the server target" {
    const bytes = try request(api, "OPTIONS /items/1 HTTP/1.1\r\nHost: example\r\n\r\n" ++
        "OPTIONS * HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(
        u8,
        bytes,
        "HTTP/1.1 204",
    ));
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(
            u8,
            bytes,
            "Allow: GET, HEAD, OPTIONS, POST\r\n",
        ),
    );
}

test "middleware InvalidInput is a client error" {
    const bytes = try request(
        api,
        "GET /invalid HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "HTTP/1.1 400",
    ));
}

test "literal routes win over parameters even for method rejection" {
    const bytes = try request(api, "GET /items/new HTTP/1.1\r\nHost: example\r\n\r\n" ++
        "POST /items/new HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "\r\n\r\nstaticHTTP/1.1 405",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "Allow: GET, HEAD, OPTIONS\r\n",
    ) != null);
}

test "query lookup decodes names plus and percent without changing duplicates" {
    const bytes = try request(
        api,
        "GET /query?na%6De=alice&name=bob&q=hello+world%2B HTTP/1.1\r\n" ++
            "Host: example\r\nConnection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.endsWith(
        u8,
        bytes,
        "{\"name\":\"alice\",\"q\":\"hello world+\"}",
    ));
}

test "lane deadline covers middleware and handler together" {
    const timed = struct {
        const C = zhtps.Call(@This());
        pub const HandlerError = zhtps.EndpointError || error{Canceled};
        pub const lanes = .{ .api = .{ .timeout_ms = 100 } };
        fn before(call: *C) HandlerError!?zhtps.http.Response {
            try call.io.sleep(.fromMilliseconds(70), .awake);
            return null;
        }
        fn respond(call: *C) HandlerError!zhtps.http.Response {
            try call.io.sleep(.fromMilliseconds(70), .awake);
            return call.text(.ok, "finished");
        }
        pub const routes = .{zhtps.endpoint(.{
            .method = .get,
            .path = "/",
            .before = &.{before},
            .handler = respond,
        })};
    };
    const bytes = try request(
        timed,
        "GET / HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "explicit HEAD wins and OPTIONS runs shared middleware before generating" {
    const methods = struct {
        const C = zhtps.Call(@This());
        fn get(call: *C) zhtps.EndpointError!zhtps.http.Response {
            return call.text(.ok, "get");
        }
        fn head(call: *C) zhtps.EndpointError!zhtps.http.Response {
            return call.text(.accepted, "representation");
        }
        fn auth(call: *C) zhtps.EndpointError!?zhtps.http.Response {
            if (call.header("Authorization") == null) return .{
                .status = 401,
                .headers = &.{.{ .name = "WWW-Authenticate", .value = "Bearer" }},
            };
            return null;
        }
        fn cors(call: *C) zhtps.EndpointError!?zhtps.http.Response {
            if (std.mem.eql(
                u8,
                call.request.method,
                "OPTIONS",
            ) and call.header("Origin") != null) {
                return .{
                    .status = 204,
                    .headers = &.{
                        .{ .name = "Access-Control-Allow-Origin", .value = "https://example.test" },
                        .{ .name = "Access-Control-Allow-Methods", .value = "GET, HEAD, OPTIONS" },
                    },
                };
            }
            return null;
        }
        pub const routes = .{zhtps.group(.{
            .prefix = "/v1",
            .before = .{auth},
            .routes = .{zhtps.group(.{
                .prefix = "/",
                .before = .{cors},
                .routes = .{
                    zhtps.get("/items/:id", get),
                    zhtps.endpoint(.{
                        .method = .head,
                        .path = "/items/:id",
                        .handler = head,
                    }),
                },
            })},
        })};
    };
    const bytes = try request(methods, "OPTIONS /v1/items/1 HTTP/1.1\r\nHost: example\r\n" ++
        "Origin: https://example.test\r\n\r\n" ++
        "OPTIONS /v1/items/1 HTTP/1.1\r\nHost: example\r\nAuthorization: bearer token\r\n\r\n" ++
        "OPTIONS /v1/items/1 HTTP/1.1\r\nHost: example\r\nAuthorization: bearer token\r\n" ++
        "Origin: https://example.test\r\n\r\n" ++
        "HEAD /v1/items/1 HTTP/1.1\r\nHost: example\r\nAuthorization: bearer token\r\n" ++
        "Connection: close\r\n\r\n");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "HTTP/1.1 401",
    ));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(
        u8,
        bytes,
        "HTTP/1.1 204",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "Allow: GET, HEAD, OPTIONS\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "Access-Control-Allow-Origin: https://example.test\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "HTTP/1.1 202 Accepted\r\n",
    ) != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        bytes,
        "\r\n\r\n",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "representation",
    ) == null);
}

test "request release frees owned locals on completion early response body abort and timeout" {
    const owned = struct {
        const C = zhtps.Call(@This());
        pub const HandlerError = zhtps.EndpointError || error{Canceled};
        pub const Services = struct {
            acquired: std.atomic.Value(usize) = .init(0),
            released: std.atomic.Value(usize) = .init(0),
        };
        pub const Local = struct { buffer: ?[]u8 = null };
        pub const lanes = .{ .api = .{ .timeout_ms = 50 } };
        fn acquire(call: *C) HandlerError!?zhtps.http.Response {
            // release owns this allocation once stored, including early responses and aborts.
            call.local.buffer = try std.testing.allocator.dupe(u8, "owned");
            _ = call.services.acquired.fetchAdd(1, .monotonic);
            if (call.header("Early") != null) return call.text(.forbidden, call.local.buffer.?);
            return null;
        }
        fn respond(call: *C) HandlerError!zhtps.http.Response {
            if (call.header("Slow") != null) try call.io.sleep(.fromMilliseconds(100), .awake);
            return call.text(.ok, call.local.buffer.?);
        }
        pub fn release(call: *C) void {
            const buffer = call.local.buffer orelse
                @panic("release ran twice or before acquisition");
            std.testing.allocator.free(buffer);
            call.local.buffer = null;
            _ = call.services.released.fetchAdd(1, .monotonic);
        }
        pub const routes = .{zhtps.endpoint(.{
            .method = .post,
            .path = "/",
            .handler = respond,
            .before = &.{acquire},
            .body = .bytes,
            .max_body_bytes = 4,
        })};
    };
    var services: owned.Services = .{};
    const cases = [_][]const u8{
        "POST / HTTP/1.1\r\nHost: example\r\n\r\n" ++
            "POST / HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: example\r\nEarly: yes\r\nConnection: close\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: example\r\nTransfer-Encoding: chunked\r\n" ++
            "Connection: close\r\n\r\n5\r\n12345\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: example\r\nSlow: yes\r\nConnection: close\r\n\r\n",
        // An incomplete body reaches the application deadline without a running hook.
        "POST / HTTP/1.1\r\nHost: example\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
    };
    for (cases, 0..) |bytes, index| {
        const result = try requestWithOptions(
            owned,
            .{ .services = &services },
            bytes,
        );
        defer std.testing.allocator.free(result);
        if (index == 0)
            try std.testing.expectEqual(@as(usize, 2), std.mem.count(
                u8,
                result,
                "\r\n\r\nowned",
            ));
        if (index == 1) try std.testing.expect(std.mem.startsWith(
            u8,
            result,
            "HTTP/1.1 403",
        ));
        if (index == 2) try std.testing.expect(std.mem.startsWith(
            u8,
            result,
            "HTTP/1.1 413",
        ));
        if (index >= 3) try std.testing.expectEqual(@as(usize, 0), result.len);
        try std.testing.expectEqual(
            services.acquired.load(.monotonic),
            services.released.load(.monotonic),
        );
    }
    try std.testing.expectEqual(@as(usize, 6), services.released.load(.monotonic));
}

test "response helpers serve redirects empty responses and body boundary scratch" {
    const responses = struct {
        const C = zhtps.Call(@This());
        fn respond(call: *C) zhtps.EndpointError!zhtps.http.Response {
            if (call.header("Empty") != null) return call.empty(.no_content);
            if (call.header("Redirect") != null) return call.redirect(.see_other, "/new-location");
            return call.json(.ok, .{ .bytes = call.bodyBytes().len });
        }
        pub const routes = .{zhtps.endpoint(.{
            .method = .post,
            .path = "/",
            .handler = respond,
            .body = .bytes,
            .max_body_bytes = 8,
        })};
    };
    const result = try request(
        responses,
        "POST / HTTP/1.1\r\nHost: example\r\nEmpty: yes\r\n\r\n" ++
            "POST / HTTP/1.1\r\nHost: example\r\nRedirect: yes\r\n\r\n" ++
            "POST / HTTP/1.1\r\nHost: example\r\nContent-Length: 8\r\n" ++
            "Connection: close\r\n\r\n12345678",
    );
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.startsWith(
        u8,
        result,
        "HTTP/1.1 204",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        result,
        "HTTP/1.1 303 See Other\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result,
        "Location: /new-location\r\n",
    ) != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        result,
        "{\"bytes\":8}",
    ));
}

test "sixty four declared routes compile and dispatch the last route" {
    const Many = struct {
        fn respond(call: *zhtps.Call(@This())) zhtps.EndpointError!zhtps.http.Response {
            return call.text(.ok, call.route_name);
        }
        pub const routes = routes: {
            var entries: [64]@TypeOf(zhtps.get("/", respond)) = undefined;
            for (&entries, 0..) |*entry, index| {
                entry.* = zhtps.get(std.fmt.comptimePrint("/many/{d}", .{index}), respond);
            }
            break :routes entries;
        };
    };
    const bytes = try request(
        Many,
        "GET /many/63 HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.endsWith(
        u8,
        bytes,
        "\r\n\r\n/many/63",
    ));
}

test "memory regression rejects wrapping allocation counts over HTTP" {
    const spec = struct {
        fn allocate(call: *zhtps.Call(@This())) zhtps.EndpointError!zhtps.http.Response {
            const allocator = call.scratch.allocator();
            _ = try allocator.alloc(u8, 8);
            const count = try call.queryInt(usize, "count") orelse return error.InvalidInput;
            _ = try allocator.alloc(u8, count);
            return call.empty(.no_content);
        }
        pub const routes = .{zhtps.get("/", allocate)};
    };
    const wire = std.fmt.comptimePrint(
        "GET /?count={d} HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n",
        .{std.math.maxInt(usize)},
    );
    const bytes = try request(spec, wire);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "HTTP/1.1 500",
    ));
}

test "memory regression rejects deeply nested JSON input over HTTP" {
    const spec = struct {
        const Node = struct { next: ?*@This() = null };

        fn echo(call: *zhtps.Call(@This())) zhtps.EndpointError!zhtps.http.Response {
            return call.json(.ok, try call.bodyJson(Node));
        }
        pub const routes = .{zhtps.endpoint(.{
            .method = .post,
            .path = "/",
            .handler = echo,
            .body = .json,
        })};
    };
    const body = "{\"next\":" ** 257 ++ "null" ++ "}" ** 257;
    const wire = std.fmt.comptimePrint(
        "POST / HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}" ++
            "POST / HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 2\r\nConnection: close\r\n\r\n{{}}",
        .{ body.len, body },
    );
    const bytes = try request(spec, wire);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "HTTP/1.1 400",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "HTTP/1.1 200",
    ) != null);
}

test "memory regression rejects deeply nested JSON output over HTTP" {
    const spec = struct {
        const Node = struct { next: ?*@This() = null };

        fn respond(call: *zhtps.Call(@This())) zhtps.EndpointError!zhtps.http.Response {
            var nodes: [257]Node = @splat(.{});
            for (nodes[0 .. nodes.len - 1], nodes[1..]) |*node, *next| node.next = next;
            return call.json(.ok, nodes[0]);
        }
        pub const routes = .{zhtps.get("/", respond)};
    };
    const bytes = try request(spec, "GET / HTTP/1.1\r\nHost: local\r\n" ++
        "Connection: close\r\n\r\n");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "HTTP/1.1 500",
    ));
}

test "memory regression preserves handler scratch during cleanup over HTTP" {
    const spec = struct {
        const C = zhtps.Call(@This());
        pub const Services = struct { intact: bool = false };
        pub const Local = struct { retained: []const u8 = "" };

        fn respond(call: *C) zhtps.EndpointError!zhtps.http.Response {
            call.local.retained = try call.scratch.allocator().dupe(u8, "retained");
            return call.text(.ok, call.local.retained);
        }
        pub fn release(call: *C) void {
            _ = call.query("overwrite") catch return;
            call.services.intact = std.mem.eql(
                u8,
                call.local.retained,
                "retained",
            );
        }
        pub const routes = .{zhtps.get("/", respond)};
    };
    var services: spec.Services = .{};
    const bytes = try requestWithOptions(
        spec,
        .{ .services = &services },
        "GET /?overwrite=%58%58%58%58%58%58%58%58 HTTP/1.1\r\nHost: local\r\n" ++
            "Connection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.endsWith(
        u8,
        bytes,
        "retained",
    ));
    try std.testing.expect(services.intact);
}

test "memory regression retains allocator handles across hooks over HTTP" {
    const spec = struct {
        const C = zhtps.Call(@This());
        pub const Services = struct { intact: bool = false };
        pub const Local = struct {
            head_allocator: ?std.mem.Allocator = null,
            handler_allocator: ?std.mem.Allocator = null,
            head_bytes: []const u8 = "",
            handler_bytes: []const u8 = "",
        };

        fn retain(call: *C) zhtps.EndpointError!?zhtps.http.Response {
            const allocator = call.scratch.allocator();
            if (isHookLocal(allocator, call)) return error.InvalidInput;
            call.local.head_allocator = allocator;
            call.local.head_bytes = try allocator.dupe(u8, "head");
            return null;
        }
        fn respond(call: *C) zhtps.EndpointError!zhtps.http.Response {
            const allocator = call.scratch.allocator();
            if (isHookLocal(allocator, call)) return error.InvalidInput;
            _ = try call.local.head_allocator.?.dupe(u8, "later head allocation");
            call.local.handler_allocator = allocator;
            call.local.handler_bytes = try allocator.dupe(u8, "handler");
            return call.text(.ok, call.bodyBytes());
        }
        pub fn release(call: *C) void {
            const allocator = call.local.handler_allocator orelse return;
            _ = allocator.dupe(u8, "cleanup") catch return;
            _ = call.local.head_allocator.?.dupe(u8, "head cleanup") catch return;
            _ = call.query("overwrite") catch return;
            call.services.intact = std.mem.eql(
                u8,
                call.local.head_bytes,
                "head",
            ) and
                std.mem.eql(
                    u8,
                    call.local.handler_bytes,
                    "handler",
                ) and
                std.mem.eql(
                    u8,
                    call.bodyBytes(),
                    "body",
                );
        }
        fn isHookLocal(allocator: std.mem.Allocator, call: *C) bool {
            const address = @intFromPtr(allocator.ptr);
            const begin = @intFromPtr(call);
            // Check the address while Call is alive before retaining the handle.
            return address >= begin and address - begin < @sizeOf(C);
        }
        pub const routes = .{zhtps.endpoint(.{
            .method = .post,
            .path = "/",
            .handler = respond,
            .before = &.{retain},
            .body = .bytes,
        })};
    };
    var services: spec.Services = .{};
    const bytes = try requestWithOptions(
        spec,
        .{ .services = &services },
        "POST /?overwrite=%58%58%58%58%58%58%58%58 HTTP/1.1\r\nHost: local\r\n" ++
            "Content-Length: 4\r\nConnection: close\r\n\r\nbody",
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "HTTP/1.1 200",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        bytes,
        "body",
    ));
    try std.testing.expect(services.intact);
}

test "request scratch survives a running handler deadline and is reclaimed after cleanup" {
    const spec = struct {
        const C = zhtps.Call(@This());
        pub const HandlerError = zhtps.EndpointError || std.Io.Cancelable;
        pub const Services = struct {
            finished: bool = false,
            intact: bool = false,
            releases: usize = 0,
        };
        pub const Local = struct {
            list: ?std.array_list.Managed(u8) = null,
        };
        pub const lanes = .{ .api = .{ .timeout_ms = 50 } };

        fn respond(call: *C) HandlerError!zhtps.http.Response {
            const allocator = call.scratch.allocator();
            const address = @intFromPtr(allocator.ptr);
            const begin = @intFromPtr(call);
            if (address >= begin and address - begin < @sizeOf(C)) return error.InvalidInput;
            call.local.list = .init(allocator);
            try call.local.list.?.appendSlice("retained");
            try call.io.sleep(.fromMilliseconds(150), .awake);
            // Force growth after the deadline while this hook still owns storage.
            try call.local.list.?.ensureTotalCapacity(4096);
            call.services.finished = true;
            return call.text(.ok, call.local.list.?.items);
        }
        pub fn release(call: *C) void {
            call.services.releases += 1;
            if (!call.services.finished) return;
            const list = if (call.local.list) |*list| list else return;
            _ = call.query("decode") catch return;
            // The allocator stored inside the managed list must outlive respond.
            list.appendSlice(" cleanup") catch return;
            call.services.intact = std.mem.eql(
                u8,
                list.items,
                "retained cleanup",
            );
            list.deinit();
        }
        pub const routes = .{zhtps.get("/", respond)};
    };
    var services: spec.Services = .{};
    const bytes = try requestWithOptions(
        spec,
        .{ .services = &services },
        "GET /?decode=%58%58%58%58%58%58%58%58 HTTP/1.1\r\nHost: local\r\n" ++
            "Connection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
    try std.testing.expect(services.intact);
    try std.testing.expectEqual(@as(usize, 1), services.releases);
}
