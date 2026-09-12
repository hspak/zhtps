//! Compile-time endpoint routing over the low-level application exchange contract.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const Logger = @import("Logger.zig");
const ServerMetrics = @import("Metrics.zig");
const platform = @import("platform.zig");
const custom_metrics = @import("endpoint/metrics.zig");
const routing = @import("endpoint/routing.zig");
const endpoint_server = @import("endpoint/server.zig");
const Scratch = @import("endpoint/Scratch.zig");
const bounded_json = @import("endpoint/json.zig");
const log = std.log.scoped(.endpoint);

/// Errors available to every endpoint. InvalidInput becomes a 400 response;
/// allocation failures, excessive output depth and application errors become 500.
pub const EndpointError = JsonError || InputError;

/// Response serialization exceeds scratch capacity or the JSON nesting limit.
pub const JsonError = bounded_json.WriteError;

/// Maximum nested objects and arrays accepted by bodyJson and emitted by json.
pub const max_json_depth = bounded_json.max_depth;

/// A missing or malformed required input, including integer overflow.
pub const InputError = error{InvalidInput};

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
    reset_content = 205,
    partial_content = 206,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    temporary_redirect = 307,
    permanent_redirect = 308,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    request_timeout = 408,
    conflict = 409,
    length_required = 411,
    precondition_failed = 412,
    content_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    misdirected_request = 421,
    unprocessable_content = 422,
    too_many_requests = 429,
    request_header_fields_too_large = 431,
    internal_server_error = 500,
    not_implemented = 501,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
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

    /// Sets copied metadata on the eventual request_complete record. Replaces
    /// existing names; an unsupported or oversized update preserves the old value.
    pub fn put(access: *Access, comptime name: []const u8, value: anytype) void {
        var next: Access = .{};
        for (access.fields()) |field| {
            if (std.mem.eql(u8, field.name, name)) continue;
            next.copyAttribute(field);
        }
        if (next.len == next.attributes.len) {
            access.dropped += 1;
            return;
        }
        const owned_name = next.copyString(name) orelse {
            access.dropped += 1;
            return;
        };
        const converted = accessValue(&next, value) orelse {
            access.dropped += 1;
            return;
        };
        next.attributes[next.len] = .{ .name = owned_name, .value = converted };
        next.len += 1;
        const dropped = access.dropped;
        access.reset();
        access.dropped = dropped;
        // Recopy rather than moving slices that point into next's inline storage.
        for (next.fields()) |field| access.copyAttribute(field);
    }

    fn copyAttribute(access: *Access, field: Logger.Attribute) void {
        var owned = field;
        owned.name = access.copyString(field.name).?;
        if (field.value == .string)
            owned.value = .{ .string = access.copyString(field.value.string).? };
        access.attributes[access.len] = owned;
        access.len += 1;
    }

    /// Borrows metadata until the next put or reset. Do not move access while borrowed.
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

/// The Call pointer is valid only during its hook. Scratch allocator handles and
/// request allocations remain valid through cleanup. Do not move or reset scratch,
/// or use it concurrently; the exchange reclaims its storage after cleanup ends.
pub fn Call(comptime Api: type) type {
    return struct {
        const Self = @This();

        pub const Specification = Api;
        pub const Services = if (@hasDecl(Api, "Services")) Api.Services else void;
        pub const Local = if (@hasDecl(Api, "Local")) Api.Local else struct {};
        pub const MetricDefinition = if (@hasDecl(Api, "Metrics")) Api.Metrics else void;
        pub const Metrics = custom_metrics.Metrics(MetricDefinition);
        pub const HandlerError = HandlerErrors(Api);

        request: *const http.Request,
        body_bytes: []const u8,
        parameters: []const Parameter,
        scratch: *Scratch,
        local: *Local,
        services: if (Services == void) void else *Services,
        metrics: *Metrics,
        access: *Access,
        logs: *PendingLogs,
        io: std.Io,
        connection_id: u64,
        request_id: u64,
        route_name: []const u8,
        allowed_methods: []const u8,

        /// Borrows the first matching header, ignoring name case; null means absent.
        pub fn header(call: *const Self, name: []const u8) ?[]const u8 {
            return call.request.getHeader(name);
        }

        /// Borrows a named segment of the normalized path, or null when absent.
        pub fn param(call: *const Self, name: []const u8) ?[]const u8 {
            for (call.parameters) |item| {
                if (std.mem.eql(u8, item.name, name)) return item.value;
            }
            return null;
        }

        /// Parses a required decimal parameter; missing, malformed or overflowing
        /// input returns InvalidInput.
        pub fn paramInt(call: *const Self, comptime T: type, name: []const u8) InputError!T {
            const value = call.param(name) orelse return error.InvalidInput;
            return std.fmt.parseInt(T, value, 10) catch error.InvalidInput;
        }

        /// Returns the first matching form-encoded query value. Names and values
        /// percent-decode and '+' means space. The result borrows request storage
        /// or scratch through cleanup. Returns null when absent, and an
        /// empty slice for a present name with no value. Empty pairs are ignored.
        pub fn query(call: *Self, name: []const u8) Allocator.Error!?[]const u8 {
            var pairs = std.mem.splitScalar(u8, call.request.query, '&');
            while (pairs.next()) |pair| {
                if (pair.len == 0) continue;
                const equals = std.mem.indexOfScalar(u8, pair, '=');
                const candidate = pair[0 .. equals orelse pair.len];
                if (!queryNameMatches(candidate, name)) continue;
                const encoded = if (equals) |at| pair[at + 1 ..] else "";
                if (std.mem.indexOfAny(u8, encoded, "%+") == null) return encoded;
                const destination = try call.scratch.allocator().alloc(u8, encoded.len);
                @memcpy(destination, encoded);
                for (destination) |*byte| if (byte.* == '+') {
                    byte.* = ' ';
                };
                return std.Uri.percentDecodeInPlace(destination);
            }
            return null;
        }

        /// Parses the first matching query value as a decimal integer, or returns
        /// null when absent. Malformed or overflowing input returns InvalidInput.
        pub fn queryInt(
            call: *Self,
            comptime T: type,
            name: []const u8,
        ) EndpointError!?T {
            const value = try call.query(name) orelse return null;
            return std.fmt.parseInt(T, value, 10) catch error.InvalidInput;
        }

        /// Borrows the buffered body through cleanup. Head middleware
        /// runs before body ingestion and sees an empty slice.
        pub fn bodyBytes(call: *const Self) []const u8 {
            return call.body_bytes;
        }

        /// Parses buffered JSON into T using remaining scratch. Strings may borrow
        /// the body or scratch through cleanup. The .json route policy
        /// checks media type; this call performs syntax and schema validation.
        /// Input deeper than max_json_depth returns InvalidInput before parsing.
        pub fn bodyJson(call: *Self, comptime T: type) EndpointError!T {
            bounded_json.checkDepth(call.body_bytes) catch return error.InvalidInput;
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

        /// Borrows bytes through response completion. Do not pass handler-stack
        /// buffers. Asserts that bodyless statuses receive an empty slice.
        pub fn text(_: *Self, status: Status, bytes: []const u8) http.Response {
            std.debug.assert(!bodyless(status) or bytes.len == 0);
            return .{
                .status = @intFromEnum(status),
                .headers = &.{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }},
                .body = .{ .bytes = bytes },
            };
        }

        /// Copies bytes into request scratch, so handler-stack buffers are safe.
        /// Asserts that bodyless statuses receive an empty slice.
        pub fn textCopy(call: *Self, status: Status, bytes: []const u8) Allocator.Error!http.Response {
            std.debug.assert(!bodyless(status) or bytes.len == 0);
            return call.text(status, try call.scratch.allocator().dupe(u8, bytes));
        }

        /// Uses no scratch and borrows no payload; valid for bodyless statuses.
        pub fn empty(_: *Self, status: Status) http.Response {
            return .{ .status = @intFromEnum(status) };
        }

        /// Copies Location into scratch retained through response completion.
        /// Only redirect statuses are accepted; the response has an empty body.
        pub fn redirect(
            call: *Self,
            comptime status: Status,
            location: []const u8,
        ) Allocator.Error!http.Response {
            switch (status) {
                .moved_permanently,
                .found,
                .see_other,
                .temporary_redirect,
                .permanent_redirect,
                => {},
                else => @compileError("redirect requires a redirect status"),
            }
            const saved = call.scratch.end_index;
            const headers = try call.scratch.allocator().alloc(http.Header, 1);
            errdefer call.scratch.end_index = saved;
            headers[0] = .{
                .name = "Location",
                .value = try call.scratch.allocator().dupe(u8, location),
            };
            return .{ .status = @intFromEnum(status), .headers = headers };
        }

        /// Serializes into scratch retained through response completion. Bodyless
        /// statuses are rejected at compile time; use empty for those responses.
        /// Excessive nesting returns JsonTooDeep; neither failure consumes scratch.
        pub fn json(
            call: *Self,
            comptime status: Status,
            value: anytype,
        ) JsonError!http.Response {
            if (comptime bodyless(status))
                @compileError("JSON responses require a status with content; use empty");
            const start = call.scratch.end_index;
            const bytes = try bounded_json.write(call.scratch.buffer[start..], value);
            call.scratch.end_index += bytes.len;
            return .{
                .status = @intFromEnum(status),
                .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                .body = .{ .bytes = bytes },
            };
        }

        /// Returns monotonic nanoseconds for elapsed-time measurements, not wall time.
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

/// Compile-time metadata whose handler, middleware and lane belong to Api.
pub fn Route(comptime Api: type) type {
    return struct {
        pub const Specification = Api;
        pub const Lane = LaneEnum(Api);
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
pub fn endpoint(comptime options: anytype) Route(HandlerApi(options.handler)) {
    comptime routing.validateOptions(@TypeOf(options), &.{
        "name",
        "method",
        "path",
        "handler",
        "before",
        "body",
        "max_body_bytes",
        "lane",
    });
    const Api = HandlerApi(options.handler);
    const R = Route(Api);
    comptime routing.validatePath(options.path);
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
    if (body != .none and max_body_bytes == 0)
        @compileError("body endpoints need a nonzero max_body_bytes");
    if (body == .none and max_body_bytes != 0)
        @compileError("bodyless endpoints must have max_body_bytes = 0");
    return .{
        .name = if (@hasField(@TypeOf(options), "name")) options.name else options.path,
        .method = options.method,
        .path = options.path,
        .handler = handler,
        .before = before,
        .body = body,
        .max_body_bytes = max_body_bytes,
        .lane = if (@hasField(@TypeOf(options), "lane"))
            options.lane
        else
            std.enums.values(R.Lane)[0],
    };
}

/// Declares a bodyless GET route with its path as the access-log route name.
pub fn get(comptime path: []const u8, comptime handler: anytype) Route(HandlerApi(handler)) {
    return endpoint(.{
        .method = .get,
        .path = path,
        .handler = handler,
    });
}

/// Preserves heterogeneous route and middleware tuples until Application flattens them.
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
    GroupApi(options.routes),
    @TypeOf(options.routes),
    if (@hasField(@TypeOf(options), "before")) @TypeOf(options.before) else @TypeOf(.{}),
) {
    comptime routing.validateOptions(@TypeOf(options), &.{
        "prefix",
        "routes",
        "before",
    });
    comptime routing.validatePrefix(options.prefix);
    const Api = EntryApi(options.routes[0]);
    inline for (options.routes) |entry| {
        if (EntryApi(entry) != Api)
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
            _ = routes;
            if (@hasDecl(Api, "lanes")) {
                for (std.meta.fields(@TypeOf(Api.lanes))) |field| {
                    routing.validateOptions(@TypeOf(@field(Api.lanes, field.name)), &.{
                        "threads",
                        "queue",
                        "timeout_ms",
                    });
                }
            }
            custom_metrics.validateNamespace(metrics_namespace);
            if (@hasDecl(Api, "release")) {
                const release: *const fn (*Call(Api)) void = Api.release;
                _ = release;
            }
        }

        pub const routes = routing.compileRoutes(Api, Route(Api));

        pub const Services = if (@hasDecl(Api, "Services")) Api.Services else void;
        pub const RuntimeInit = if (Services == void) void else *Services;
        pub const CustomMetrics = Call(Api).Metrics;
        pub const Lane = Route(Api).Lane;
        pub const isolated = true;
        pub const metrics_namespace = if (@hasDecl(Api, "metrics_namespace"))
            Api.metrics_namespace
        else
            "application";
        pub const head_scratch_bytes = headScratchBytes(Api);
        pub const Exchange = RoutedExchange(Api);
        pub const Server = endpoint_server.Server(Self);

        pub const LaneOptions = struct {
            threads: usize = 1,
            queue: usize = 64,
            timeout_ms: u32 = 100,
        };

        /// Resolves declared lane settings, filling omitted fields with bounded defaults.
        pub fn laneOptions(lane: Lane) LaneOptions {
            if (comptime !@hasDecl(Api, "lanes")) return .{};
            inline for (std.meta.fields(@TypeOf(Api.lanes))) |field| {
                if (lane == @field(Lane, field.name)) {
                    const options = @field(Api.lanes, field.name);
                    return .{
                        .threads = if (comptime @hasField(@TypeOf(options), "threads"))
                            options.threads
                        else
                            1,
                        .queue = if (comptime @hasField(@TypeOf(options), "queue"))
                            options.queue
                        else
                            64,
                        .timeout_ms = if (comptime @hasField(@TypeOf(options), "timeout_ms"))
                            options.timeout_ms
                        else
                            100,
                    };
                }
            }
            unreachable;
        }
    };
}

fn RoutedExchange(comptime Api: type) type {
    return struct {
        const Self = @This();
        const C = Call(Api);
        const R = Route(Api);
        const Local = C.Local;
        const RuntimeInit = if (C.Services == void) void else *C.Services;

        storage: []u8,
        used: usize = 0,
        head_scratch: [headScratchBytes(Api)]u8 = undefined,
        head_allocator: Scratch = .{},
        scratch: ?Scratch = null,
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
        generated_headers: [2]http.Header = undefined,
        automatic_status: ?u16 = null,
        release_pending: bool = false,
        unexpected_error: ?C.HandlerError = null,

        pub const BodyError = error{BodyTooLarge};

        /// Borrows storage and optional services for the connection's lifetime.
        /// No allocation is performed and the caller retains ownership. Keep the
        /// exchange at a stable address from the first hook through cleanup.
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

        /// Routes and runs head middleware synchronously. Null accepts body ingestion;
        /// any response borrows exchange storage until completion or cleanup.
        pub fn receiveHead(exchange: *Self, request: *const http.Request) ?http.Response {
            if (exchange.prepareHead(request)) |response| return response;
            return exchange.runHead(request);
        }

        /// Performs bounded generated routing and protocol policy without
        /// invoking user middleware.
        pub fn prepareHead(exchange: *Self, request: *const http.Request) ?http.Response {
            exchange.used = 0;
            exchange.head_allocator.init(&exchange.head_scratch);
            exchange.scratch = null;
            exchange.selected = null;
            exchange.parameter_count = 0;
            exchange.middleware_count = 0;
            exchange.allow_len = 0;
            exchange.local = .{};
            exchange.access.reset();
            exchange.logs.reset();
            exchange.automatic_status = null;
            exchange.unexpected_error = null;
            if (!implementedMethod(request.method)) return exchange.failure(501, hasBody(request));
            if (std.mem.eql(u8, request.method, "OPTIONS") and std.mem.eql(u8, request.path, "*")) {
                for (Application(Api).routes) |route| exchange.addAllowed(route.method);
                exchange.addAllowedText("OPTIONS");
                return exchange.optionsResponse(request);
            }
            exchange.find(request);
            if (exchange.selected == null) return exchange.failure(404, hasBody(request));
            const route = exchange.selected.?;
            if (exchange.automatic_status != null) return null;
            if (route.body == .none and (request.chunked or (request.content_length orelse 0) > 0))
                return exchange.failure(400, true);
            if (request.content_length) |length| {
                if (length > route.max_body_bytes or length > exchange.storage.len)
                    return exchange.failure(413, true);
            }
            if (route.body == .json and hasBody(request)) {
                const content_type = request.getHeader("Content-Type") orelse
                    return exchange.failure(415, true);
                const semicolon = std.mem.indexOfScalar(u8, content_type, ';') orelse
                    content_type.len;
                const media_type = std.mem.trim(u8, content_type[0..semicolon], " \t");
                if (!http.syntax.eql(media_type, "application/json"))
                    return exchange.failure(415, true);
            }
            return null;
        }

        /// Runs after prepareHead accepts a routed request. Null accepts body ingestion;
        /// an early response may borrow head scratch until completion or cleanup.
        pub fn runHead(exchange: *Self, request: *const http.Request) ?http.Response {
            exchange.release_pending = true;
            var request_call = exchange.makeCall(
                request,
                &exchange.head_allocator,
            );
            for (exchange.middleware[0..exchange.middleware_count]) |middleware| {
                const early = middleware(&request_call) catch |err|
                    return exchange.handlerFailure(err, hasBody(request));
                if (early) |response| return response;
            }
            if (exchange.automatic_status) |status| {
                return if (status == 204)
                    exchange.optionsResponse(request)
                else
                    exchange.failure(status, hasBody(request));
            }
            return null;
        }

        /// Calls optional Api.release(*Call(Api)) once, after hooks and borrowed
        /// response bytes are no longer in use. It runs on the transport thread
        /// and must be bounded, nonblocking and infallible, including on aborts.
        /// Reclaims request allocations after cleanup; a timeout alone does not
        /// permit this call while a hook or outstanding I/O still uses storage.
        pub fn releaseApplication(exchange: *Self, request: *const http.Request) void {
            if (!exchange.release_pending) return;
            exchange.release_pending = false;
            if (comptime @hasDecl(Api, "release")) {
                var request_call = exchange.makeCall(request, exchange.bodyScratch());
                Api.release(&request_call);
            }
            exchange.head_allocator.init(&exchange.head_scratch);
            exchange.scratch = null;
            exchange.used = 0;
            exchange.local = .{};
        }

        /// Asserts that routing selected a resource before executor submission.
        pub fn lane(exchange: *const Self) R.Lane {
            return exchange.selected.?.lane;
        }

        /// Copies a chunk into borrowed connection storage. An oversized chunk leaves
        /// the buffered body unchanged; call only after head middleware accepts it.
        pub fn receiveBody(exchange: *Self, bytes: []const u8) BodyError!void {
            std.debug.assert(exchange.scratch == null);
            const route = exchange.selected orelse return error.BodyTooLarge;
            if (bytes.len > route.max_body_bytes - exchange.used or
                bytes.len > exchange.storage.len - exchange.used)
            {
                @branchHint(.cold);
                return error.BodyTooLarge;
            }
            @memcpy(exchange.storage[exchange.used..][0..bytes.len], bytes);
            exchange.used += bytes.len;
        }

        /// Invokes the selected handler after body ingestion, mapping errors to HTTP.
        /// Response slices remain borrowed until completion or cleanup.
        pub fn respond(exchange: *Self, request: *const http.Request) http.Response {
            const route = exchange.selected orelse return exchange.failure(404, true);
            var request_call = exchange.makeCall(request, exchange.bodyScratch());
            return route.handler(&request_call) catch |err| exchange.handlerFailure(err, false);
        }

        /// Generated endpoints do not support streaming; null ends production.
        pub fn produce(_: *Self, _: []u8) ?[]const u8 {
            return null;
        }

        /// Borrows the resource's Allow value until routing the next request.
        pub fn allowedMethods(exchange: *const Self) []const u8 {
            return exchange.allow[0..exchange.allow_len];
        }

        /// Returns the static route name, or null when no resource was selected.
        pub fn routeName(exchange: *const Self) ?[]const u8 {
            return if (exchange.selected) |route| route.name else null;
        }

        /// Borrows metadata until its next mutation or request reset.
        pub fn accessFields(exchange: *const Self) []const Logger.Attribute {
            return exchange.access.fields();
        }

        /// Returns and clears the count of metadata updates dropped since the last read.
        pub fn takeAccessDrops(exchange: *Self) usize {
            const dropped = exchange.access.dropped;
            exchange.access.dropped = 0;
            return dropped;
        }

        /// Copies pending records into the bounded logger queue and clears them.
        /// Call on the transport thread with no application hook running.
        pub fn flushLogs(exchange: *Self, logger: *Logger) void {
            if (exchange.unexpected_error) |err| {
                logger.emit(.{
                    .timestamp_ns = platform.realtimeNs(exchange.io),
                    .level = .@"error",
                    .event = "application_error",
                    .connection = exchange.connection_id,
                    .request = exchange.request_id,
                    .route = exchange.routeName(),
                    .reason = @errorName(err),
                });
                exchange.unexpected_error = null;
            }
            exchange.logs.flush(
                logger,
                exchange.connection_id,
                exchange.request_id,
                exchange.routeName(),
            );
        }

        fn bodyScratch(exchange: *Self) *Scratch {
            // Freeze the body/scratch boundary on first use, including cleanup
            // after middleware or body ingestion fails before the handler runs.
            if (exchange.scratch == null) {
                exchange.scratch = .{};
                exchange.scratch.?.init(exchange.storage[exchange.used..]);
            }
            return &exchange.scratch.?;
        }

        fn makeCall(exchange: *Self, request: *const http.Request, scratch: *Scratch) C {
            const route_name = if (exchange.selected) |route| route.name else "unmatched";
            return .{
                .request = request,
                .body_bytes = exchange.storage[0..exchange.used],
                .parameters = exchange.parameters[0..exchange.parameter_count],
                .scratch = scratch,
                .local = &exchange.local,
                .services = exchange.services,
                .metrics = exchange.metrics,
                .access = &exchange.access,
                .logs = &exchange.logs,
                .io = exchange.io,
                .connection_id = exchange.connection_id,
                .request_id = exchange.request_id,
                .route_name = route_name,
                .allowed_methods = exchange.allowedMethods(),
            };
        }

        fn find(exchange: *Self, request: *const http.Request) void {
            const routes = &Application(Api).routes;
            var resource: ?R = null;
            for (routes) |route| {
                if (!routing.matches(request.path, route.path)) continue;
                if (resource == null or routing.moreSpecific(route.path, resource.?.path))
                    resource = route;
            }
            const matched = resource orelse return;
            var fallback: ?R = null;
            for (routes) |route| {
                if (!routing.samePattern(route.path, matched.path)) continue;
                exchange.addAllowed(route.method);
                if (std.mem.eql(u8, request.method, route.method.text())) exchange.selected = route;
                if (route.method == .get and std.mem.eql(u8, request.method, "HEAD"))
                    fallback = route;
            }
            if (exchange.selected == null) exchange.selected = fallback;
            if (exchange.selected == null) {
                exchange.selected = matched;
                exchange.automatic_status = if (std.mem.eql(u8, request.method, "OPTIONS"))
                    204
                else
                    405;
            }
            const selected = exchange.selected.?;
            const matched_path = exchange.matchPath(request.path, selected.path);
            std.debug.assert(matched_path);
            for (selected.before) |middleware| exchange.appendMiddleware(middleware);
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
            std.debug.assert(separator.len + text.len <= exchange.allow.len - exchange.allow_len);
            @memcpy(exchange.allow[exchange.allow_len..][0..separator.len], separator);
            exchange.allow_len += separator.len;
            @memcpy(exchange.allow[exchange.allow_len..][0..text.len], text);
            exchange.allow_len += text.len;
        }

        fn appendMiddleware(exchange: *Self, middleware: R.Middleware) void {
            std.debug.assert(exchange.middleware_count < exchange.middleware.len);
            exchange.middleware[exchange.middleware_count] = middleware;
            exchange.middleware_count += 1;
        }

        fn failure(exchange: *Self, status: u16, close: bool) http.Response {
            @branchHint(.cold);
            exchange.generated_headers = .{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "Allow", .value = exchange.allow[0..exchange.allow_len] },
            };
            return .{
                .status = status,
                .headers = exchange.generated_headers[0..if (status == 405) @as(usize, 2) else 1],
                .body = .{ .bytes = http.Response.errorBody(status) },
                .close = close,
            };
        }

        fn optionsResponse(exchange: *Self, request: *const http.Request) http.Response {
            exchange.generated_headers[0] = .{
                .name = "Allow",
                .value = exchange.allowedMethods(),
            };
            return .{
                .status = 204,
                .headers = exchange.generated_headers[0..1],
                .close = hasBody(request),
            };
        }

        fn handlerFailure(exchange: *Self, err: C.HandlerError, close: bool) http.Response {
            @branchHint(.cold);
            if (err == error.InvalidInput) return exchange.failure(400, close);
            // This is the HTTP boundary: retain allocation and application errors
            // for logging, then send a generic response without exposing details.
            exchange.unexpected_error = err;
            return exchange.failure(500, close);
        }
    };
}

fn HandlerApi(comptime handler: anytype) type {
    const T = @TypeOf(handler);
    const Function = if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one)
        @typeInfo(T).pointer.child
    else
        T;
    if (@typeInfo(Function) != .@"fn")
        @compileError("endpoint handler must be a function or function pointer");
    const info = @typeInfo(Function).@"fn";
    if (info.params.len != 1) @compileError("endpoint handlers take one *zhtps.Call argument");
    const Pointer = info.params[0].type orelse
        @compileError("endpoint handler argument must have a concrete type");
    const pointer = @typeInfo(Pointer);
    if (pointer != .pointer or pointer.pointer.size != .one)
        @compileError("endpoint handlers take one *zhtps.Call argument");
    const C = pointer.pointer.child;
    if (!@hasDecl(C, "Specification"))
        @compileError("endpoint handler argument must be *zhtps.Call(Api)");
    return C.Specification;
}

fn EntryApi(comptime entry: anytype) type {
    const Entry = @TypeOf(entry);
    if (!@hasDecl(Entry, "Specification"))
        @compileError("endpoint group contains an invalid entry");
    return Entry.Specification;
}

fn GroupApi(comptime routes: anytype) type {
    if (routes.len == 0) @compileError("an endpoint group cannot be empty");
    return EntryApi(routes[0]);
}

fn LaneEnum(comptime Api: type) type {
    if (!@hasDecl(Api, "lanes")) return enum { default };
    if (std.meta.fields(@TypeOf(Api.lanes)).len == 0)
        @compileError("an application must declare at least one lane");
    return std.meta.FieldEnum(@TypeOf(Api.lanes));
}

fn hasBody(request: *const http.Request) bool {
    return request.chunked or (request.content_length orelse 0) > 0;
}

fn bodyless(status: Status) bool {
    return status == .no_content or status == .reset_content or status == .not_modified;
}

fn queryNameMatches(encoded: []const u8, name: []const u8) bool {
    var index: usize = 0;
    for (name) |expected| {
        if (index == encoded.len) return false;
        var byte = encoded[index];
        index += 1;
        if (byte == '+') {
            byte = ' ';
        } else if (byte == '%') {
            if (encoded.len - index < 2) return false;
            const high = std.fmt.charToDigit(encoded[index], 16) catch return false;
            const low = std.fmt.charToDigit(encoded[index + 1], 16) catch return false;
            byte = high * 16 + low;
            index += 2;
        }
        if (byte != expected) return false;
    }
    return index == encoded.len;
}

fn implementedMethod(request_method: []const u8) bool {
    inline for (std.meta.tags(Method)) |method| {
        if (std.mem.eql(u8, request_method, method.text())) return true;
    }
    return false;
}

fn headScratchBytes(comptime Api: type) usize {
    const size = if (@hasDecl(Api, "head_scratch_bytes")) Api.head_scratch_bytes else 1024;
    if (size > 64 * 1024) @compileError("endpoint head scratch cannot exceed 64 KiB");
    return size;
}

fn HandlerErrors(comptime Api: type) type {
    const ErrorSet = if (@hasDecl(Api, "HandlerError")) Api.HandlerError else EndpointError;
    const info = @typeInfo(ErrorSet);
    if (info != .error_set) @compileError("Api.HandlerError must be an error set");
    if (info.error_set == null) @compileError("Api.HandlerError must be a closed error set");
    for (@typeInfo(EndpointError).error_set.?) |required| {
        const found = found: {
            for (info.error_set.?) |item| {
                if (std.mem.eql(u8, item.name, required.name)) break :found true;
            }
            break :found false;
        };
        if (!found) @compileError("Api.HandlerError must include zhtps.EndpointError");
    }
    return ErrorSet;
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
        .@"enum", .enum_literal => accessValue(access, @tagName(value)),
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
    var server_metrics: ServerMetrics = .{};
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

test "access updates reclaim strings preserve old values on overflow and accept enum literals" {
    var access: Access = .{};
    access.put("role", .admin);
    for (0..100) |_| access.put("name", "a name that is repeatedly replaced");
    try std.testing.expectEqual(@as(usize, 2), access.fields().len);
    try std.testing.expectEqual(@as(usize, 0), access.dropped);
    try std.testing.expectEqualStrings("admin", access.fields()[0].value.string);
    access.put("name", @as([]const u8, &@as([512]u8, @splat('x'))));
    try std.testing.expectEqual(@as(usize, 1), access.dropped);
    try std.testing.expectEqualStrings(
        "a name that is repeatedly replaced",
        access.fields()[1].value.string,
    );
    inline for (.{
        "a",
        "b",
        "c",
        "d",
        "e",
        "f",
    }) |key| access.put(key, 1);
    access.put("name", "updated at capacity");
    try std.testing.expectEqual(@as(usize, 8), access.fields().len);
    try std.testing.expectEqualStrings("updated at capacity", access.fields()[7].value.string);
}

test "explicit OPTIONS sees all resource methods regardless of declaration order" {
    const Api = struct {
        fn respond(call: *Call(@This())) EndpointError!http.Response {
            return call.text(.ok, "ok");
        }
        pub const routes = .{
            endpoint(.{
                .method = .options,
                .path = "/",
                .handler = respond,
            }),
            get("/", respond),
            endpoint(.{
                .method = .post,
                .path = "/",
                .handler = respond,
            }),
        };
    };
    var storage: [256]u8 = undefined;
    var exchange: Application(Api).Exchange = undefined;
    exchange.initApplication(&storage, {});
    const request: http.Request = .{ .method = "OPTIONS", .path = "/" };
    try std.testing.expect(exchange.receiveHead(&request) == null);
    const response = exchange.respond(&request);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("OPTIONS, GET, HEAD, POST", exchange.allowedMethods());
}

test "unexpected handler and middleware errors retain their names in structured logs" {
    const Api = struct {
        pub const HandlerError = EndpointError || error{ServiceUnavailable};
        fn before(_: *Call(@This())) HandlerError!?http.Response {
            return error.ServiceUnavailable;
        }
        fn respond(_: *Call(@This())) HandlerError!http.Response {
            return error.ServiceUnavailable;
        }
        pub const routes = .{
            get("/handler", respond),
            endpoint(.{
                .method = .get,
                .path = "/middleware",
                .handler = respond,
                .before = &.{before},
            }),
        };
    };
    var storage: [256]u8 = undefined;
    var exchange: Application(Api).Exchange = undefined;
    exchange.initApplication(&storage, {});
    var application_metrics: Application(Api).CustomMetrics = .{};
    exchange.setRequestRuntime(&application_metrics, std.testing.io, 1, 2);
    var server_metrics: ServerMetrics = .{};
    var slots: [2]Logger.Slot = undefined;
    var logger: Logger = undefined;
    logger.init(&slots, &server_metrics, false);
    for ([_][]const u8{ "/handler", "/middleware" }) |path| {
        const request: http.Request = .{ .method = "GET", .path = path };
        const response = exchange.receiveHead(&request) orelse exchange.respond(&request);
        try std.testing.expectEqual(@as(u16, 500), response.status);
        exchange.flushLogs(&logger);
        const record = logger.peek().?;
        const bytes = record.bytes[0..record.len];
        try std.testing.expect(std.mem.indexOf(
            u8,
            bytes,
            "\"event\":\"application_error\"",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            bytes,
            "\"reason\":\"ServiceUnavailable\"",
        ) != null);
        _ = logger.consumeBytes(record.len);
    }
}

test "empty query pairs do not match an empty name" {
    const Api = struct {
        fn respond(call: *Call(@This())) EndpointError!http.Response {
            return call.text(.ok, try call.query("") orelse "missing");
        }
        pub const routes = .{get("/", respond)};
    };
    var storage: [256]u8 = undefined;
    var exchange: Application(Api).Exchange = undefined;
    exchange.initApplication(&storage, {});
    const cases = [_][2][]const u8{
        .{ "", "missing" },
        .{ "&&", "missing" },
        .{ "&&=first&=second", "first" },
    };
    for (cases) |case| {
        const request: http.Request = .{
            .method = "GET",
            .path = "/",
            .query = case[0],
        };
        try std.testing.expect(exchange.receiveHead(&request) == null);
        const response = exchange.respond(&request);
        try std.testing.expectEqualStrings(case[1], response.body.bytes);
    }
}

test "response helpers preserve prior allocations and roll back failed serialization" {
    const Api = struct {
        const Node = struct { next: ?*@This() = null };
        fn respond(call: *Call(@This())) !http.Response {
            var source = "original".*;
            const response = try call.textCopy(.ok, &source);
            @memset(&source, 'x');
            var node: Node = .{};
            node.next = &node;
            const saved = call.scratch.end_index;
            try std.testing.expectError(error.JsonTooDeep, call.json(.ok, node));
            try std.testing.expectEqual(saved, call.scratch.end_index);
            try std.testing.expectError(error.OutOfMemory, call.json(.ok, "x" ** 4096));
            try std.testing.expectEqual(saved, call.scratch.end_index);
            try std.testing.expectError(error.OutOfMemory, call.redirect(.see_other, "x" ** 4096));
            try std.testing.expectEqual(saved, call.scratch.end_index);
            const next = try call.json(.ok, .{ .ok = true });
            try std.testing.expectEqualStrings("{\"ok\":true}", next.body.bytes);
            return response;
        }
        pub const HandlerError = EndpointError || error{
            TestUnexpectedResult,
            TestExpectedError,
            TestExpectedEqual,
            TestUnexpectedError,
        };
        pub const routes = .{get("/", respond)};
    };
    var storage: [2048]u8 = undefined;
    var exchange: Application(Api).Exchange = undefined;
    exchange.initApplication(&storage, {});
    const request: http.Request = .{ .method = "GET", .path = "/" };
    try std.testing.expect(exchange.receiveHead(&request) == null);
    const response = exchange.respond(&request);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("original", response.body.bytes);
    exchange.releaseApplication(&request);
}

test "scratch exhaustion preserves cleanup inputs and reclaims the next request budget" {
    const Api = struct {
        const C = Call(@This());
        pub const Services = struct { releases: usize = 0, intact: bool = true };
        pub const Local = struct { retained: []const u8 = "" };
        fn respond(call: *C) EndpointError!http.Response {
            const gpa = call.scratch.allocator();
            const bytes = try gpa.alloc(u8, call.scratch.buffer.len);
            @memset(bytes, 'x');
            call.local.retained = bytes;
            return call.text(.ok, bytes);
        }
        pub fn release(call: *C) void {
            if (call.query("decode")) |_| {
                call.services.intact = false;
            } else |err| {
                call.services.intact = call.services.intact and err == error.OutOfMemory and
                    std.mem.eql(u8, call.local.retained, "x" ** 64) and
                    std.mem.eql(u8, call.bodyBytes(), "body");
            }
            call.services.releases += 1;
        }
        pub const routes = .{endpoint(.{
            .method = .post,
            .path = "/",
            .handler = respond,
            .body = .bytes,
        })};
    };
    var storage: [68]u8 = undefined;
    var services: Api.Services = .{};
    var exchange: Application(Api).Exchange = undefined;
    exchange.initApplication(&storage, &services);
    const request: http.Request = .{
        .method = "POST",
        .path = "/",
        .query = "decode=%58",
        .content_length = 4,
    };
    for (0..2) |_| {
        try std.testing.expect(exchange.receiveHead(&request) == null);
        try exchange.receiveBody("body");
        const response = exchange.respond(&request);
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqualStrings("x" ** 64, response.body.bytes);
        exchange.releaseApplication(&request);
        exchange.releaseApplication(&request);
    }
    try std.testing.expect(services.intact);
    try std.testing.expectEqual(@as(usize, 2), services.releases);
}
