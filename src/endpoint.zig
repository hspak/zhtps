//! Compile-time endpoint routing over the low-level application exchange contract.

const std = @import("std");
const http = @import("http.zig");
const Logger = @import("Logger.zig");
const platform = @import("platform.zig");
const custom_metrics = @import("endpoint/metrics.zig");
const log = std.log.scoped(.endpoint);

/// Errors available to every endpoint. InvalidInput becomes a 400 response;
/// allocation failures and application-specific errors become 500 responses.
pub const EndpointError = std.mem.Allocator.Error || error{InvalidInput};

pub const Method = enum {
    delete,
    get,
    head,
    options,
    patch,
    post,
    put,

    pub fn text(method: Method) []const u8 {
        return switch (method) {
            .delete => "DELETE",
            .get => "GET",
            .head => "HEAD",
            .options => "OPTIONS",
            .patch => "PATCH",
            .post => "POST",
            .put => "PUT",
        };
    }
};

pub const Status = enum(u16) {
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    conflict = 409,
    content_too_large = 413,
    unsupported_media_type = 415,
    unprocessable_content = 422,
    too_many_requests = 429,
    internal_server_error = 500,
    not_implemented = 501,
    service_unavailable = 503,
};

pub const Body = enum {
    none,
    bytes,
    json,
};

pub const Parameter = struct {
    name: []const u8,
    value: []const u8,
};

pub const Access = struct {
    attributes: [8]Logger.Attribute = undefined,
    len: usize = 0,
    string_storage: [512]u8 = undefined,
    string_used: usize = 0,
    dropped: usize = 0,

    pub fn reset(access: *Access) void {
        access.len = 0;
        access.string_used = 0;
        access.dropped = 0;
    }

    /// Adds bounded metadata to the eventual request_complete record. Names
    /// and string values are copied; unsupported or oversized fields are dropped.
    pub fn put(access: *Access, comptime name: []const u8, value: anytype) void {
        if (access.len == access.attributes.len) {
            access.dropped += 1;
            return;
        }
        const saved = access.string_used;
        const owned_name = access.copyString(name) orelse {
            access.dropped += 1;
            return;
        };
        const converted = accessValue(access, value) orelse {
            access.string_used = saved;
            access.dropped += 1;
            return;
        };
        access.attributes[access.len] = .{ .name = owned_name, .value = converted };
        access.len += 1;
    }

    pub fn fields(access: *const Access) []const Logger.Attribute {
        return access.attributes[0..access.len];
    }

    fn copyString(access: *Access, value: []const u8) ?[]const u8 {
        if (value.len > access.string_storage.len - access.string_used) return null;
        const destination = access.string_storage[access.string_used..][0..value.len];
        @memcpy(destination, value);
        access.string_used += value.len;
        return destination;
    }
};

const PendingLogs = struct {
    records: [4]Record = undefined,
    len: usize = 0,
    dropped: usize = 0,

    const Record = struct {
        timestamp_ns: u64,
        level: Logger.Level,
        event_storage: [128]u8 = undefined,
        event_len: usize = 0,
        fields: Access = .{},
    };

    fn reset(logs: *PendingLogs) void {
        logs.len = 0;
        logs.dropped = 0;
    }

    fn add(
        logs: *PendingLogs,
        timestamp_ns: u64,
        level: Logger.Level,
        event: []const u8,
        values: anytype,
    ) void {
        if (logs.len == logs.records.len or event.len > logs.records[0].event_storage.len) {
            logs.dropped += 1;
            return;
        }
        const record = &logs.records[logs.len];
        record.* = .{ .timestamp_ns = timestamp_ns, .level = level };
        @memcpy(record.event_storage[0..event.len], event);
        record.event_len = event.len;
        record.fields.reset();
        const info = @typeInfo(@TypeOf(values));
        if (info != .@"struct") @compileError("structured log fields must be a struct literal");
        inline for (info.@"struct".fields) |field| {
            record.fields.put(field.name, @field(values, field.name));
        }
        logs.len += 1;
    }

    fn flush(
        logs: *PendingLogs,
        logger: *Logger,
        connection_id: u64,
        request_id: u64,
        route_name: ?[]const u8,
    ) void {
        var dropped = logs.dropped;
        for (logs.records[0..logs.len]) |*record| dropped += record.fields.dropped;
        if (dropped > 0) logger.metrics.add(.log_dropped_total, dropped);
        for (logs.records[0..logs.len]) |*record| logger.emit(.{
            .timestamp_ns = record.timestamp_ns,
            .level = record.level,
            .event = record.event_storage[0..record.event_len],
            .connection = connection_id,
            .request = request_id,
            .route = route_name,
            .fields = record.fields.fields(),
        });
        logs.reset();
    }
};

/// Request capabilities for handlers declared by `Api`. Values borrow their
/// connection and remain valid only until the response finishes.
pub fn Call(comptime Api: type) type {
    return struct {
        const Self = @This();

        pub const Specification = Api;
        pub const Services = if (@hasDecl(Api, "Services")) Api.Services else void;
        pub const Local = if (@hasDecl(Api, "Local")) Api.Local else struct {};
        pub const MetricDefinition = if (@hasDecl(Api, "Metrics")) Api.Metrics else void;
        pub const Metrics = custom_metrics.Metrics(MetricDefinition);
        pub const HandlerError = endpointHandlerError(Api);

        request: *const http.Request,
        body_bytes: []const u8,
        parameters: []const Parameter,
        scratch: std.heap.FixedBufferAllocator,
        local: *Local,
        services: if (Services == void) void else *Services,
        metrics: *Metrics,
        access: *Access,
        logs: *PendingLogs,
        io: std.Io,
        connection_id: u64,
        request_id: u64,
        route_name: []const u8,

        pub fn header(call: *const Self, name: []const u8) ?[]const u8 {
            return call.request.getHeader(name);
        }

        pub fn param(call: *const Self, name: []const u8) ?[]const u8 {
            for (call.parameters) |item| {
                if (std.mem.eql(u8, item.name, name)) return item.value;
            }
            return null;
        }

        pub fn paramInt(call: *const Self, comptime T: type, name: []const u8) error{InvalidInput}!T {
            const value = call.param(name) orelse return error.InvalidInput;
            return std.fmt.parseInt(T, value, 10) catch error.InvalidInput;
        }

        /// Returns the first query value with this name. The returned value
        /// borrows request storage or request-local scratch until response completion.
        pub fn query(call: *Self, name: []const u8) error{OutOfMemory}!?[]const u8 {
            var pairs = std.mem.splitScalar(u8, call.request.query, '&');
            while (pairs.next()) |pair| {
                const equals = std.mem.indexOfScalar(u8, pair, '=');
                const candidate = pair[0 .. equals orelse pair.len];
                if (!std.mem.eql(u8, candidate, name)) continue;
                const encoded = if (equals) |at| pair[at + 1 ..] else "";
                if (std.mem.indexOfScalar(u8, encoded, '%') == null) return encoded;
                const destination = call.scratch.allocator().alloc(u8, encoded.len) catch
                    return error.OutOfMemory;
                @memcpy(destination, encoded);
                return std.Uri.percentDecodeInPlace(destination);
            }
            return null;
        }

        pub fn queryInt(
            call: *Self,
            comptime T: type,
            name: []const u8,
        ) error{ InvalidInput, OutOfMemory }!?T {
            const value = try call.query(name) orelse return null;
            return std.fmt.parseInt(T, value, 10) catch error.InvalidInput;
        }

        pub fn bodyBytes(call: *const Self) []const u8 {
            return call.body_bytes;
        }

        pub fn bodyJson(call: *Self, comptime T: type) error{ InvalidInput, OutOfMemory }!T {
            return std.json.parseFromSliceLeaky(
                T,
                call.scratch.allocator(),
                call.body_bytes,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidInput,
            };
        }

        pub fn text(_: *Self, status: Status, bytes: []const u8) http.Response {
            return .{
                .status = @intFromEnum(status),
                .headers = &.{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }},
                .body = .{ .bytes = bytes },
            };
        }

        pub fn json(call: *Self, status: Status, value: anytype) error{OutOfMemory}!http.Response {
            const start = call.scratch.end_index;
            var writer = std.Io.Writer.fixed(call.scratch.buffer[start..]);
            std.json.Stringify.value(value, .{}, &writer) catch return error.OutOfMemory;
            call.scratch.end_index += writer.buffered().len;
            return .{
                .status = @intFromEnum(status),
                .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                .body = .{ .bytes = call.scratch.buffer[start..call.scratch.end_index] },
            };
        }

        pub fn monotonicNow(_: *const Self) u64 {
            return platform.monotonicNs();
        }

        /// Emits through the server's bounded structured-log queue. Oversized
        /// records and records emitted while the queue is full are dropped.
        pub fn log(call: *Self, level: Logger.Level, event: []const u8, fields: anytype) void {
            call.logs.add(platform.realtimeNs(call.io), level, event, fields);
        }
    };
}

pub fn Route(comptime Api: type) type {
    return struct {
        pub const Specification = Api;
        pub const Lane = if (@hasDecl(Api, "lanes"))
            std.meta.FieldEnum(@TypeOf(Api.lanes))
        else
            enum { default };
        pub const Handler = *const fn (*Call(Api)) Call(Api).HandlerError!http.Response;
        pub const Middleware = *const fn (*Call(Api)) Call(Api).HandlerError!?http.Response;

        name: []const u8,
        method: Method,
        path: []const u8,
        handler: Handler,
        before: []const Middleware = &.{},
        body: Body = .none,
        max_body_bytes: usize = 0,
        lane: Lane = std.enums.values(Lane)[0],
    };
}

/// Declares one compile-time route. The handler determines its API specification.
pub fn endpoint(comptime options: anytype) Route(handlerApi(options.handler)) {
    const Api = handlerApi(options.handler);
    const R = Route(Api);
    validatePath(options.path);
    const handler: R.Handler = options.handler;
    const before: []const R.Middleware = if (@hasField(@TypeOf(options), "before"))
        options.before
    else
        &.{};
    const body: Body = if (@hasField(@TypeOf(options), "body")) options.body else .none;
    const max_body_bytes: usize = if (@hasField(@TypeOf(options), "max_body_bytes"))
        options.max_body_bytes
    else if (body == .none)
        0
    else
        64 * 1024;
    if (body != .none and max_body_bytes == 0) @compileError("body endpoints need a nonzero max_body_bytes");
    return .{
        .name = if (@hasField(@TypeOf(options), "name")) options.name else options.path,
        .method = options.method,
        .path = options.path,
        .handler = handler,
        .before = before,
        .body = body,
        .max_body_bytes = max_body_bytes,
        .lane = if (@hasField(@TypeOf(options), "lane")) options.lane else std.enums.values(R.Lane)[0],
    };
}

/// Declares a bodyless GET route with its path as the access-log route name.
pub fn get(comptime path: []const u8, comptime handler: anytype) Route(handlerApi(handler)) {
    return endpoint(.{ .method = .get, .path = path, .handler = handler });
}

pub fn Group(comptime Api: type, comptime Routes: type, comptime Before: type) type {
    return struct {
        pub const Specification = Api;

        prefix: []const u8,
        routes: Routes,
        before: Before,
    };
}

/// Applies a path prefix and ordered head middleware to nested routes.
pub fn group(comptime options: anytype) Group(
    entryApi(options.routes[0]),
    @TypeOf(options.routes),
    if (@hasField(@TypeOf(options), "before")) @TypeOf(options.before) else @TypeOf(.{}),
) {
    if (options.routes.len == 0) @compileError("an endpoint group cannot be empty");
    validatePrefix(options.prefix);
    const Api = entryApi(options.routes[0]);
    inline for (options.routes) |entry| {
        if (entryApi(entry) != Api)
            @compileError("all grouped endpoints must use the same API specification");
    }
    return .{
        .prefix = options.prefix,
        .routes = options.routes,
        .before = if (@hasField(@TypeOf(options), "before")) options.before else .{},
    };
}

/// Generates an isolated routed application and its owned server façade.
pub fn Application(comptime Api: type) type {
    return struct {
        const Self = @This();

        comptime {
            validateRoutes(Api);
        }

        pub const Services = if (@hasDecl(Api, "Services")) Api.Services else void;
        pub const RuntimeInit = if (Services == void) void else *Services;
        pub const CustomMetrics = Call(Api).Metrics;
        pub const Lane = Route(Api).Lane;
        pub const isolated = true;
        pub const metrics_namespace = if (@hasDecl(Api, "metrics_namespace"))
            Api.metrics_namespace
        else
            "application";
        pub const head_scratch_bytes = endpointHeadScratchBytes(Api);
        pub const Exchange = EndpointExchange(Api);

        pub const LaneOptions = struct {
            threads: usize = 1,
            queue: usize = 64,
            timeout_ms: u32 = 100,
        };

        pub fn laneOptions(lane: Lane) LaneOptions {
            if (!@hasDecl(Api, "lanes")) return .{};
            inline for (std.meta.fields(@TypeOf(Api.lanes))) |field| {
                if (lane == @field(Lane, field.name)) {
                    const options = @field(Api.lanes, field.name);
                    return .{
                        .threads = if (@hasField(@TypeOf(options), "threads")) options.threads else 1,
                        .queue = if (@hasField(@TypeOf(options), "queue")) options.queue else 64,
                        .timeout_ms = if (@hasField(@TypeOf(options), "timeout_ms"))
                            options.timeout_ms
                        else
                            100,
                    };
                }
            }
            unreachable;
        }

        pub const Server = @import("endpoint/server.zig").Server(Self);
    };
}

fn EndpointExchange(comptime Api: type) type {
    return struct {
        const Self = @This();
        const C = Call(Api);
        const R = Route(Api);
        const Local = C.Local;
        const RuntimeInit = if (C.Services == void) void else *C.Services;

        storage: []u8,
        used: usize = 0,
        head_scratch: [endpointHeadScratchBytes(Api)]u8 = undefined,
        head_scratch_used: usize = 0,
        selected: ?R = null,
        parameters: [8]Parameter = undefined,
        parameter_count: usize = 0,
        middleware: [16]R.Middleware = undefined,
        middleware_count: usize = 0,
        local: Local = .{},
        services: if (C.Services == void) void else *C.Services,
        allow: [64]u8 = undefined,
        allow_len: usize = 0,
        metrics: *C.Metrics = undefined,
        io: std.Io = undefined,
        connection_id: u64 = 0,
        request_id: u64 = 0,
        access: Access = .{},
        logs: PendingLogs = .{},

        pub const BodyError = error{BodyTooLarge};

        pub fn initApplication(exchange: *Self, storage: []u8, runtime: RuntimeInit) void {
            exchange.* = .{
                .storage = storage,
                .services = runtime,
            };
        }

        /// Supplies worker-owned observability capabilities after routing
        /// metadata is stable and before any application hook runs.
        pub fn setRequestRuntime(
            exchange: *Self,
            metrics: *C.Metrics,
            io: std.Io,
            connection_id: u64,
            request_id: u64,
        ) void {
            exchange.metrics = metrics;
            exchange.io = io;
            exchange.connection_id = connection_id;
            exchange.request_id = request_id;
        }

        pub fn receiveHead(exchange: *Self, request: *const http.Request) ?http.Response {
            if (exchange.prepareHead(request)) |response| return response;
            return exchange.runHead(request);
        }

        /// Performs bounded generated routing and protocol policy without
        /// invoking user middleware.
        pub fn prepareHead(exchange: *Self, request: *const http.Request) ?http.Response {
            exchange.used = 0;
            exchange.head_scratch_used = 0;
            exchange.selected = null;
            exchange.parameter_count = 0;
            exchange.middleware_count = 0;
            exchange.allow_len = 0;
            exchange.local = .{};
            exchange.access.reset();
            exchange.logs.reset();
            if (!implementedMethod(request.method)) return exchange.failure(501, true);
            exchange.find(Api.routes, request, 0);
            if (exchange.allow_len == 0) return exchange.failure(404, true);
            if (std.mem.eql(u8, request.method, "OPTIONS") and
                (exchange.selected == null or exchange.selected.?.method != .options))
            {
                return .{
                    .status = 204,
                    .headers = &.{.{ .name = "Allow", .value = exchange.allow[0..exchange.allow_len] }},
                    .close = request.chunked or (request.content_length orelse 0) > 0,
                };
            }
            const route = exchange.selected orelse return exchange.failure(405, true);
            if (route.body == .none and (request.chunked or (request.content_length orelse 0) > 0))
                return exchange.failure(400, true);
            if (request.content_length) |length| {
                if (length > route.max_body_bytes or length > exchange.storage.len)
                    return exchange.failure(413, true);
            }
            if (route.body == .json and (request.chunked or (request.content_length orelse 0) > 0)) {
                const content_type = request.getHeader("Content-Type") orelse
                    return exchange.failure(415, true);
                const semicolon = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
                const media_type = std.mem.trim(u8, content_type[0..semicolon], " \t");
                if (!http.syntax.eql(media_type, "application/json"))
                    return exchange.failure(415, true);
            }
            return null;
        }

        pub fn runHead(exchange: *Self, request: *const http.Request) ?http.Response {
            var request_call = exchange.makeCall(
                request,
                exchange.head_scratch[exchange.head_scratch_used..],
            );
            defer exchange.head_scratch_used += request_call.scratch.end_index;
            for (exchange.middleware[0..exchange.middleware_count]) |middleware| {
                if (middleware(&request_call) catch return exchange.failure(500, true)) |response|
                    return response;
            }
            return null;
        }

        pub fn lane(exchange: *const Self) R.Lane {
            return exchange.selected.?.lane;
        }

        pub fn receiveBody(exchange: *Self, bytes: []const u8) BodyError!void {
            const route = exchange.selected orelse return error.BodyTooLarge;
            if (bytes.len > route.max_body_bytes - exchange.used or
                bytes.len > exchange.storage.len - exchange.used)
                return error.BodyTooLarge;
            @memcpy(exchange.storage[exchange.used..][0..bytes.len], bytes);
            exchange.used += bytes.len;
        }

        pub fn respond(exchange: *Self, request: *const http.Request) http.Response {
            const route = exchange.selected orelse return exchange.failure(404, true);
            var request_call = exchange.makeCall(request, exchange.storage[exchange.used..]);
            return route.handler(&request_call) catch |err| switch (err) {
                error.InvalidInput => exchange.failure(400, false),
                else => exchange.failure(500, false),
            };
        }

        pub fn produce(_: *Self, _: []u8) ?[]const u8 {
            return null;
        }

        pub fn allowedMethods(exchange: *const Self) []const u8 {
            return exchange.allow[0..exchange.allow_len];
        }

        pub fn routeName(exchange: *const Self) ?[]const u8 {
            return if (exchange.selected) |route| route.name else null;
        }

        pub fn accessFields(exchange: *const Self) []const Logger.Attribute {
            return exchange.access.fields();
        }

        pub fn takeAccessDrops(exchange: *Self) usize {
            const dropped = exchange.access.dropped;
            exchange.access.dropped = 0;
            return dropped;
        }

        pub fn flushLogs(exchange: *Self, logger: *Logger) void {
            exchange.logs.flush(
                logger,
                exchange.connection_id,
                exchange.request_id,
                exchange.routeName(),
            );
        }

        fn makeCall(exchange: *Self, request: *const http.Request, scratch: []u8) C {
            const route_name = if (exchange.selected) |route| route.name else "unmatched";
            return .{
                .request = request,
                .body_bytes = exchange.storage[0..exchange.used],
                .parameters = exchange.parameters[0..exchange.parameter_count],
                .scratch = .init(scratch),
                .local = &exchange.local,
                .services = exchange.services,
                .metrics = exchange.metrics,
                .access = &exchange.access,
                .logs = &exchange.logs,
                .io = exchange.io,
                .connection_id = exchange.connection_id,
                .request_id = exchange.request_id,
                .route_name = route_name,
            };
        }

        fn find(exchange: *Self, comptime entries: anytype, request: *const http.Request, base: usize) void {
            inline for (entries) |entry| {
                const Entry = @TypeOf(entry);
                if (exchange.selected != null) {
                    // The first exact method match wins.
                } else if (@hasField(Entry, "handler")) {
                    const old_parameter_count = exchange.parameter_count;
                    if (exchange.matchPath(request.path[base..], entry.path)) {
                        exchange.addAllowed(entry.method);
                        if (exchange.selected == null and methodMatches(entry.method, request.method)) {
                            exchange.selected = entry;
                            inline for (entry.before) |middleware| exchange.appendMiddleware(middleware);
                        } else exchange.parameter_count = old_parameter_count;
                    }
                } else {
                    if (matchPrefix(request.path, base, entry.prefix)) |next| {
                        const old_middleware_count = exchange.middleware_count;
                        inline for (entry.before) |middleware| exchange.appendMiddleware(middleware);
                        exchange.find(entry.routes, request, next);
                        if (exchange.selected == null) exchange.middleware_count = old_middleware_count;
                    }
                }
            }
        }

        fn matchPath(exchange: *Self, path: []const u8, pattern: []const u8) bool {
            const old_count = exchange.parameter_count;
            var path_segments = std.mem.splitScalar(u8, path, '/');
            var pattern_segments = std.mem.splitScalar(u8, pattern, '/');
            while (true) {
                const actual = path_segments.next();
                const expected = pattern_segments.next();
                if (actual == null or expected == null) {
                    if (actual == null and expected == null) return true;
                    exchange.parameter_count = old_count;
                    return false;
                }
                if (expected.?.len > 0 and expected.?[0] == ':') {
                    if (actual.?.len == 0 or exchange.parameter_count == exchange.parameters.len) {
                        exchange.parameter_count = old_count;
                        return false;
                    }
                    exchange.parameters[exchange.parameter_count] = .{
                        .name = expected.?[1..],
                        .value = actual.?,
                    };
                    exchange.parameter_count += 1;
                } else if (!std.mem.eql(u8, actual.?, expected.?)) {
                    exchange.parameter_count = old_count;
                    return false;
                }
            }
        }

        fn addAllowed(exchange: *Self, method: Method) void {
            exchange.addAllowedText(method.text());
            if (method == .get) exchange.addAllowedText("HEAD");
            exchange.addAllowedText("OPTIONS");
        }

        fn addAllowedText(exchange: *Self, text: []const u8) void {
            var methods = std.mem.splitSequence(u8, exchange.allow[0..exchange.allow_len], ", ");
            while (methods.next()) |item| if (std.mem.eql(u8, item, text)) return;
            const separator = if (exchange.allow_len == 0) "" else ", ";
            if (separator.len + text.len > exchange.allow.len - exchange.allow_len) return;
            @memcpy(exchange.allow[exchange.allow_len..][0..separator.len], separator);
            exchange.allow_len += separator.len;
            @memcpy(exchange.allow[exchange.allow_len..][0..text.len], text);
            exchange.allow_len += text.len;
        }

        fn appendMiddleware(exchange: *Self, middleware: R.Middleware) void {
            if (exchange.middleware_count == exchange.middleware.len) unreachable;
            exchange.middleware[exchange.middleware_count] = middleware;
            exchange.middleware_count += 1;
        }

        fn failure(exchange: *Self, status: u16, close: bool) http.Response {
            const allow_header = [_]http.Header{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "Allow", .value = exchange.allow[0..exchange.allow_len] },
            };
            return .{
                .status = status,
                .headers = allow_header[0..if (status == 405) @as(usize, 2) else 1],
                .body = .{ .bytes = http.Response.errorBody(status) },
                .close = close,
            };
        }
    };
}

fn handlerApi(comptime handler: anytype) type {
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    if (info.params.len != 1) @compileError("endpoint handlers take one *zhtps.Call argument");
    const Pointer = info.params[0].type orelse
        @compileError("endpoint handler argument must have a concrete type");
    const pointer = @typeInfo(Pointer);
    if (pointer != .pointer or pointer.pointer.size != .one)
        @compileError("endpoint handlers take one *zhtps.Call argument");
    const C = pointer.pointer.child;
    if (!@hasDecl(C, "Specification")) @compileError("endpoint handler argument must be *zhtps.Call(Api)");
    return C.Specification;
}

fn entryApi(comptime entry: anytype) type {
    const Entry = @TypeOf(entry);
    if (!@hasDecl(Entry, "Specification")) @compileError("endpoint group contains an invalid entry");
    return Entry.Specification;
}

fn validatePath(comptime path: []const u8) void {
    if (path.len == 0 or path[0] != '/') @compileError("endpoint paths must begin with '/'");
    var names: [8][]const u8 = undefined;
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or segment[0] != ':') continue;
        if (segment.len == 1) @compileError("path parameter names cannot be empty");
        if (count == names.len) @compileError("an endpoint path has more than eight parameters");
        for (names[0..count]) |name| {
            if (std.mem.eql(u8, name, segment[1..])) @compileError("path parameter names must be unique");
        }
        names[count] = segment[1..];
        count += 1;
    }
}

fn validatePrefix(comptime prefix: []const u8) void {
    if (prefix.len == 0 or prefix[0] != '/') @compileError("endpoint group prefixes must begin with '/'");
    if (prefix.len > 1 and prefix[prefix.len - 1] == '/')
        @compileError("endpoint group prefixes must not end with '/'");
}

fn matchPrefix(path: []const u8, base: usize, prefix: []const u8) ?usize {
    if (std.mem.eql(u8, prefix, "/")) return base;
    const rest = path[base..];
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    if (rest.len != prefix.len and rest[prefix.len] != '/') return null;
    return base + prefix.len;
}

fn methodMatches(method: Method, request_method: []const u8) bool {
    return std.mem.eql(u8, request_method, method.text()) or
        (method == .get and std.mem.eql(u8, request_method, "HEAD"));
}

fn implementedMethod(request_method: []const u8) bool {
    inline for (std.meta.tags(Method)) |method| {
        if (std.mem.eql(u8, request_method, method.text())) return true;
    }
    return false;
}

fn endpointHeadScratchBytes(comptime Api: type) usize {
    const size = if (@hasDecl(Api, "head_scratch_bytes")) Api.head_scratch_bytes else 1024;
    if (size > 64 * 1024) @compileError("endpoint head scratch cannot exceed 64 KiB");
    return size;
}

fn endpointHandlerError(comptime Api: type) type {
    const ErrorSet = if (@hasDecl(Api, "HandlerError")) Api.HandlerError else EndpointError;
    const info = @typeInfo(ErrorSet);
    if (info != .error_set) @compileError("Api.HandlerError must be an error set");
    if (info.error_set == null) @compileError("Api.HandlerError must be a closed error set");
    var has_invalid_input = false;
    var has_out_of_memory = false;
    for (info.error_set.?) |item| {
        if (std.mem.eql(u8, item.name, "InvalidInput")) has_invalid_input = true;
        if (std.mem.eql(u8, item.name, "OutOfMemory")) has_out_of_memory = true;
    }
    if (!has_invalid_input or !has_out_of_memory)
        @compileError("Api.HandlerError must include zhtps.EndpointError");
    return ErrorSet;
}

fn validateRoutes(comptime Api: type) void {
    const count = routeCount(Api.routes);
    var signatures: [count]struct { method: Method, path: []const u8 } = undefined;
    var index: usize = 0;
    collectRoutes(Api, Api.routes, "", &signatures, &index, 0);
    for (signatures, 0..) |left, left_index| {
        for (signatures[left_index + 1 ..]) |right| {
            if (!std.mem.eql(u8, left.path, right.path)) continue;
            if (left.method == right.method or
                (left.method == .get and right.method == .head) or
                (left.method == .head and right.method == .get))
                @compileError("duplicate endpoint method and path");
        }
    }
}

fn routeCount(comptime entries: anytype) usize {
    var count: usize = 0;
    inline for (entries) |entry| {
        if (@hasField(@TypeOf(entry), "handler")) {
            count += 1;
        } else count += routeCount(entry.routes);
    }
    return count;
}

fn collectRoutes(
    comptime Api: type,
    comptime entries: anytype,
    comptime prefix: []const u8,
    signatures: anytype,
    index: *usize,
    middleware_count: usize,
) void {
    inline for (entries) |entry| {
        if (entryApi(entry) != Api) @compileError("all endpoints must use the application API specification");
        if (@hasField(@TypeOf(entry), "handler")) {
            if (middleware_count + entry.before.len > 16)
                @compileError("an endpoint has more than sixteen middleware functions");
            signatures[index.*] = .{
                .method = entry.method,
                .path = std.fmt.comptimePrint("{s}{s}", .{ prefix, entry.path }),
            };
            index.* += 1;
        } else {
            collectRoutes(
                Api,
                entry.routes,
                joinPrefix(prefix, entry.prefix),
                signatures,
                index,
                middleware_count + entry.before.len,
            );
        }
    }
}

fn joinPrefix(comptime prefix: []const u8, comptime suffix: []const u8) []const u8 {
    if (std.mem.eql(u8, suffix, "/")) return prefix;
    return std.fmt.comptimePrint("{s}{s}", .{ prefix, suffix });
}

fn accessValue(access: *Access, value: anytype) ?Logger.Attribute.Value {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .bool => .{ .boolean = value },
        .comptime_int => if (value < std.math.minInt(i64) or value > std.math.maxInt(u64))
            null
        else if (value < 0)
            .{ .signed = value }
        else
            .{ .unsigned = value },
        .int => |info| if (info.signedness == .signed)
            if (std.math.cast(i64, value)) |number| .{ .signed = number } else null
        else if (std.math.cast(u64, value)) |number|
            .{ .unsigned = number }
        else
            null,
        .comptime_float => number: {
            if (value > std.math.floatMax(f64) or value < -std.math.floatMax(f64))
                break :number null;
            const converted: f64 = @floatCast(value);
            if (!std.math.isFinite(converted)) break :number null;
            break :number .{ .float = converted };
        },
        .float => |info| number: {
            if (info.bits > 64 or !std.math.isFinite(value)) break :number null;
            break :number .{ .float = @floatCast(value) };
        },
        .null => .null,
        .optional => if (value) |item| accessValue(access, item) else .null,
        .@"enum" => accessValue(access, @tagName(value)),
        .pointer => |pointer| string: {
            if (pointer.size == .slice and pointer.child == u8) {
                const owned = access.copyString(value) orelse return null;
                break :string .{ .string = owned };
            }
            if (pointer.size == .one and @typeInfo(pointer.child) == .array and
                @typeInfo(pointer.child).array.child == u8)
            {
                const owned = access.copyString(value) orelse return null;
                break :string .{ .string = owned };
            }
            return null;
        },
        else => null,
    };
}

test "endpoint application routes parameters middleware query and json bodies" {
    const Api = struct {
        const Spec = @This();
        const ApiCall = Call(Spec);

        pub const Local = struct {
            authenticated: bool = false,
        };

        pub const HandlerError = EndpointError || error{NotAuthenticated};

        pub const Metrics = struct {
            pub const Counter = enum { widgets_created_total };
        };

        pub const metrics_namespace = "test_app";

        fn authenticate(call: *ApiCall) !?http.Response {
            call.local.authenticated = true;
            return null;
        }

        fn create(call: *ApiCall) !http.Response {
            if (!call.local.authenticated) return error.NotAuthenticated;
            const id = try call.paramInt(u32, "widget_id");
            const notify = try call.query("notify");
            const input = try call.bodyJson(struct { name: []const u8 });
            call.metrics.add(.widgets_created_total, 1);
            call.access.put("widget_id", id);
            call.log(.info, "widget_created", .{ .widget_id = id });
            return try call.json(.created, .{
                .id = id,
                .name = input.name,
                .notify = notify,
            });
        }

        pub const routes = .{
            group(.{
                .prefix = "/v1",
                .before = .{authenticate},
                .routes = .{
                    endpoint(.{
                        .name = "create_widget",
                        .method = .post,
                        .path = "/widgets/:widget_id",
                        .handler = create,
                        .body = .json,
                        .max_body_bytes = 1024,
                    }),
                },
            }),
        };
    };
    const App = Application(Api);
    var storage: [4096]u8 = undefined;
    var exchange: App.Exchange = undefined;
    exchange.initApplication(&storage, {});
    var slots: [2]Logger.Slot = undefined;
    var server_metrics: @import("Metrics.zig") = .{};
    var logger: Logger = undefined;
    logger.init(&slots, &server_metrics, false);
    var application_metrics: App.CustomMetrics = .{};
    exchange.setRequestRuntime(&application_metrics, std.testing.io, 7, 9);
    const request: http.Request = .{
        .method = "POST",
        .path = "/v1/widgets/42",
        .query = "notify=yes",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json; charset=utf-8" }},
        .content_length = 17,
    };
    try std.testing.expect(exchange.receiveHead(&request) == null);
    try exchange.receiveBody("{\"name\":\"sample\"}");
    const response = exchange.respond(&request);
    exchange.flushLogs(&logger);
    try std.testing.expectEqual(@as(u16, 201), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body.bytes, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.bytes, "\"notify\":\"yes\"") != null);
    try std.testing.expectEqual(@as(u64, 1), application_metrics.snapshot().counters[0]);
    try std.testing.expectEqual(@as(usize, 1), exchange.accessFields().len);
    const logged = logger.peek().?;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        logged.bytes[0..logged.len],
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("widget_created", parsed.value.object.get("event").?.string);
    try std.testing.expectEqual(
        @as(i64, 42),
        parsed.value.object.get("fields").?.object.get("widget_id").?.integer,
    );
}

test "structured attributes drop values outside the log representation" {
    var access: Access = .{};
    access.put("integer", std.math.maxInt(u128));
    access.put("float", std.math.nan(f64));
    try std.testing.expectEqual(@as(usize, 0), access.fields().len);
    try std.testing.expectEqual(@as(usize, 2), access.dropped);
}

test "endpoint application reports not found method and media type failures" {
    const Api = struct {
        const ApiCall = Call(@This());

        fn create(_: *ApiCall) !http.Response {
            return .{};
        }

        pub const routes = .{
            endpoint(.{
                .method = .post,
                .path = "/items",
                .handler = create,
                .body = .json,
                .max_body_bytes = 8,
            }),
        };
    };
    const App = Application(Api);
    var storage: [32]u8 = undefined;
    var exchange: App.Exchange = undefined;
    exchange.initApplication(&storage, {});
    try std.testing.expectEqual(@as(u16, 404), exchange.receiveHead(&.{
        .method = "GET",
        .path = "/missing",
    }).?.status);
    try std.testing.expectEqual(@as(u16, 405), exchange.receiveHead(&.{
        .method = "GET",
        .path = "/items",
    }).?.status);
    try std.testing.expectEqualStrings("POST, OPTIONS", exchange.allowedMethods());
    try std.testing.expectEqual(@as(u16, 415), exchange.receiveHead(&.{
        .method = "POST",
        .path = "/items",
        .content_length = 2,
    }).?.status);
    try std.testing.expectEqual(@as(u16, 413), exchange.receiveHead(&.{
        .method = "POST",
        .path = "/items",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .content_length = 9,
    }).?.status);
    try std.testing.expectEqual(@as(u16, 501), exchange.receiveHead(&.{
        .method = "TRACE",
        .path = "/items",
    }).?.status);
}

test "middleware scratch survives body ingestion" {
    const Api = struct {
        const Spec = @This();
        const ApiCall = Call(Spec);

        pub const Local = struct {
            query: []const u8 = "",
        };

        fn captureQuery(call: *ApiCall) EndpointError!?http.Response {
            call.local.query = try call.query("name") orelse return error.InvalidInput;
            return null;
        }

        fn respond(call: *ApiCall) EndpointError!http.Response {
            _ = try call.bodyJson(struct { body: []const u8 });
            return call.text(.ok, call.local.query);
        }

        pub const routes = .{
            endpoint(.{
                .method = .post,
                .path = "/scratch",
                .handler = respond,
                .before = &.{captureQuery},
                .body = .json,
                .max_body_bytes = 64,
            }),
        };
    };
    const App = Application(Api);
    var storage: [256]u8 = undefined;
    var exchange: App.Exchange = undefined;
    exchange.initApplication(&storage, {});
    const request: http.Request = .{
        .method = "POST",
        .path = "/scratch",
        .query = "name=before%20body",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .content_length = 16,
    };
    try std.testing.expect(exchange.receiveHead(&request) == null);
    try exchange.receiveBody("{\"body\":\"input\"}");
    const response = exchange.respond(&request);
    try std.testing.expectEqualStrings("before body", response.body.bytes);
}
