//! Stream-owned HTTP/2 exchanges. Only the transport worker touches the engine;
//! executor tasks borrow one stream until their completion has been consumed.

const std = @import("std");
const http = @import("../http.zig");
const protocol = @import("../http2.zig");
const platform = @import("../platform.zig");
const Admission = @import("../Admission.zig");
const Config = @import("../Config.zig");
const Metrics = @import("../Metrics.zig");
const application = @import("../application.zig");
const log = std.log.scoped(.server_http2);

pub const Stage = enum {
    head,
    body,
    response,
    produce,
};

/// Binds stream ownership and protocol callbacks to one transport worker and application.
pub fn Connection(comptime App: type, comptime Owner: type) type {
    return struct {
        const Self = @This();
        const isolated = if (@hasDecl(App, "isolated")) App.isolated else false;
        const has_response_streams = isolated and @hasDecl(App.Exchange, "runStream");
        const window = 65535;

        owner: *Owner,
        index: usize,
        gpa: std.mem.Allocator,
        engine: protocol.Session(Self) = undefined,
        streams: ?*Stream = null,
        count: usize = 0,
        last_id: i32 = 0,
        accepted: u32 = 0,
        draining: bool = false,
        closing: bool = false,
        incoming: [18 * 1024]u8 = undefined,
        incoming_start: usize = 0,
        incoming_end: usize = 0,
        outgoing: [18 * 1024]u8 = undefined,
        outgoing_start: usize = 0,
        outgoing_end: usize = 0,
        plaintext: [16 * 1024]u8 = undefined,
        plaintext_output: [16 * 1024]u8 = undefined,
        // Engine output remains borrowed until copied; transport plaintext stays
        // unchanged across SSL_write retries independently of later engine calls.
        pending_frame: []const u8 = &.{},
        pending_plaintext: []const u8 = &.{},
        write_retry: bool = false,
        idle_deadline: u64 = 0,
        send_deadline: u64 = 0,

        pub const Stream = struct {
            next: ?*Stream = null,
            id: i32,
            request_id: u64,
            request: http.Request = .{ .version = .http_2 },
            exchange: App.Exchange = undefined,
            storage: Storage = .{},
            head_buffer: [1024]u8 = undefined,
            path_buffer: [256]u8 = undefined,
            output_buffer: [256]u8 = undefined,
            field_buffer: [16]http.Header = undefined,
            field_count: usize = 0,
            trailer_count: usize = 0,
            head_len: usize = 0,
            trailer_len: usize = 0,
            trailers: bool = false,
            head_ready: bool = false,
            initialized: bool = false,
            head_done: bool = false,
            ended: bool = false,
            closed: bool = false,
            close_code: u32 = 0,
            busy: bool = false,
            canceled: std.atomic.Value(bool) = .init(false),
            body_len: usize = 0,
            task_body_len: usize = 0,
            body_received: u64 = 0,
            response: ?http.Response = null,
            response_offset: usize = 0,
            produced: u64 = 0,
            fragment: []const u8 = &.{},
            producer_done: bool = false,
            response_stream_started: bool = false,
            response_deferred: bool = false,
            publication_offset: usize = 0,
            response_write_deadline: u64 = 0,
            permit: ?Admission.Decision = null,
            started_ns: u64,
            deadline: u64,
            application_deadline: u64 = 0,

            const Storage = struct {
                head: []u8 = &.{},
                trailers: []u8 = &.{},
                path: []u8 = &.{},
                application: []u8 = &.{},
                output: []u8 = &.{},
                body: []u8 = &.{},
                fields: []http.Header = &.{},
                trailer_fields: []http.Header = &.{},

                fn deinit(storage: *Storage, gpa: std.mem.Allocator) void {
                    gpa.free(storage.trailer_fields);
                    gpa.free(storage.trailers);
                    gpa.free(storage.body);
                    gpa.free(storage.output);
                    gpa.free(storage.application);
                    gpa.free(storage.path);
                    gpa.free(storage.fields);
                    gpa.free(storage.head);
                    storage.* = undefined;
                }
            };

            fn headBytes(stream: *Stream) []u8 {
                return if (stream.storage.head.len == 0) &stream.head_buffer else stream.storage.head;
            }

            fn pathBytes(stream: *Stream) []u8 {
                return if (stream.storage.path.len == 0) &stream.path_buffer else stream.storage.path;
            }

            fn outputBytes(stream: *Stream) []u8 {
                return if (stream.storage.output.len == 0) &stream.output_buffer else stream.storage.output;
            }

            fn fields(stream: *Stream) []http.Header {
                return if (stream.storage.fields.len == 0) &stream.field_buffer else stream.storage.fields;
            }
        };

        /// Owns all streams and engine allocations. Remains at a stable address.
        pub fn init(
            self: *Self,
            owner: *Owner,
            index: usize,
            gpa: std.mem.Allocator,
        ) protocol.Error!void {
            self.* = .{
                .owner = owner,
                .index = index,
                .gpa = gpa,
            };
            self.idle_deadline = platform.monotonicNs() +
                @as(u64, owner.config.header_timeout_ms) * 1_000_000;
            try self.engine.init(
                gpa,
                self,
                .{
                    .streams = owner.config.http2.max_streams,
                    .header_bytes = @intCast(owner.config.header_bytes),
                    .stream_window = window,
                },
            );
        }

        /// All application tasks and socket operations must have completed first.
        pub fn deinit(self: *Self) void {
            self.engine.deinit();
            while (self.streams) |stream| {
                std.debug.assert(!stream.busy);
                self.streams = stream.next;
                self.destroy(stream);
            }
            self.* = undefined;
        }

        fn find(self: *Self, id: i32) ?*Stream {
            var item = self.streams;
            while (item) |stream| : (item = stream.next) if (stream.id == id) return stream;
            return null;
        }

        /// Starts a stream or its trailer block; protocol callbacks run only on the owning worker.
        pub fn begin(
            self: *Self,
            id: i32,
            trailers: bool,
        ) protocol.Error!void {
            if (trailers) {
                const stream = self.find(id) orelse return error.Protocol;
                if (stream.trailers) return error.Protocol;
                stream.trailers = true;
                return;
            }
            const config = self.owner.config;
            if (self.draining or self.accepted >= config.max_requests_per_connection or
                self.count >= config.http2.max_streams or
                self.owner.http2_streams >= config.http2.max_streams_per_worker)
                return error.RefusedStream;
            const stream = try self.acquire();
            const storage = stream.storage;
            const now = platform.monotonicNs();
            stream.* = .{
                .id = id,
                .request_id = self.owner.next_request,
                .storage = storage,
                .started_ns = now,
                .deadline = now + @as(u64, config.header_timeout_ms) * 1_000_000,
                .next = self.streams,
            };
            self.streams = stream;
            self.owner.next_request +%= 1;
            self.owner.http2_streams += 1;
            self.count += 1;
            self.last_id = id;
            self.accepted += 1;
            self.owner.metrics.recorder().add(.requests_total, 1);
        }

        fn acquire(self: *Self) std.mem.Allocator.Error!*Stream {
            if (self.owner.free_http2_stream) |stream| {
                self.owner.free_http2_stream = stream.next;
                self.owner.http2_cached -= 1;
                return stream;
            }
            const stream = try self.gpa.create(Stream);
            stream.storage = .{};
            return stream;
        }

        /// Release the bounded worker cache after all connections are gone.
        pub fn releaseCache(gpa: std.mem.Allocator, owner: *Owner) void {
            while (owner.free_http2_stream) |stream| {
                owner.free_http2_stream = stream.next;
                owner.http2_cached -= 1;
                stream.storage.deinit(gpa);
                gpa.destroy(stream);
            }
        }

        fn growBytes(
            self: *Self,
            owned: *[]u8,
            previous: []const u8,
            capacity: usize,
        ) std.mem.Allocator.Error!void {
            const next = try self.gpa.alloc(u8, capacity);
            @memcpy(next[0..previous.len], previous);
            self.gpa.free(owned.*);
            owned.* = next;
        }

        fn relocated(
            previous: []const u8,
            next: []const u8,
            bytes: []const u8,
        ) []const u8 {
            const base = @intFromPtr(previous.ptr);
            const address = @intFromPtr(bytes.ptr);
            if (bytes.len == 0 or address < base or address - base >= previous.len) return bytes;
            const offset = address - base;
            std.debug.assert(bytes.len <= previous.len - offset);
            return next[offset..][0..bytes.len];
        }

        fn reserveHead(
            self: *Self,
            stream: *Stream,
            extra: usize,
        ) protocol.Error!void {
            const maximum = 2 * self.owner.config.header_bytes;
            if (extra > maximum - stream.head_len) return error.HeaderListTooLarge;
            const previous = stream.headBytes();
            const needed = stream.head_len + extra;
            if (needed <= previous.len) return;
            // Only unpublished request metadata can move. Executor borrowers start
            // after headComplete, and trailers have separate backing storage.
            std.debug.assert(!stream.head_ready and !stream.busy);
            try self.growBytes(
                &stream.storage.head,
                previous[0..stream.head_len],
                @min(maximum, @max(needed, previous.len * 2)),
            );
            const next = stream.headBytes();
            const used = previous[0..stream.head_len];
            for (stream.fields()[0..stream.field_count]) |*field| {
                field.name = relocated(
                    used,
                    next,
                    field.name,
                );
                field.value = relocated(
                    used,
                    next,
                    field.value,
                );
            }
            stream.request.method = relocated(
                used,
                next,
                stream.request.method,
            );
            stream.request.target = relocated(
                used,
                next,
                stream.request.target,
            );
            stream.request.authority = relocated(
                used,
                next,
                stream.request.authority,
            );
            if (stream.request.scheme) |scheme| stream.request.scheme = relocated(
                used,
                next,
                scheme,
            );
        }

        fn reserveTrailers(
            self: *Self,
            stream: *Stream,
            extra: usize,
        ) protocol.Error!void {
            const maximum = self.owner.config.trailer_bytes;
            if (extra > maximum - stream.trailer_len) return error.HeaderListTooLarge;
            const previous = stream.storage.trailers;
            const needed = stream.trailer_len + extra;
            if (needed <= previous.len) return;
            try self.growBytes(
                &stream.storage.trailers,
                previous[0..stream.trailer_len],
                @min(maximum, @max(needed, @max(512, previous.len * 2))),
            );
            for (stream.storage.trailer_fields[0..stream.trailer_count]) |*field| {
                field.name = relocated(
                    previous[0..stream.trailer_len],
                    stream.storage.trailers,
                    field.name,
                );
                field.value = relocated(
                    previous[0..stream.trailer_len],
                    stream.storage.trailers,
                    field.value,
                );
            }
        }

        fn reserveFields(self: *Self, stream: *Stream) protocol.Error!void {
            const count = if (stream.trailers) stream.trailer_count else stream.field_count;
            if (count == 128) return error.Protocol;
            const previous = if (stream.trailers) stream.storage.trailer_fields else stream.fields();
            if (count < previous.len) return;
            const next = try self.gpa.alloc(http.Header, @min(128, @max(8, previous.len * 2)));
            @memcpy(next[0..count], previous[0..count]);
            const owned = if (stream.trailers) &stream.storage.trailer_fields else &stream.storage.fields;
            self.gpa.free(owned.*);
            owned.* = next;
        }

        fn reserveOutput(
            self: *Self,
            stream: *Stream,
            needed: usize,
            used: usize,
        ) std.mem.Allocator.Error!void {
            std.debug.assert(needed <= self.owner.config.response_bytes);
            const previous = stream.outputBytes();
            if (needed <= previous.len) return;
            std.debug.assert(!stream.busy);
            try self.growBytes(
                &stream.storage.output,
                previous[0..used],
                @min(self.owner.config.response_bytes, @max(needed, previous.len * 2)),
            );
        }

        /// Copies a decoded field into bounded stream storage; retains no borrowed input bytes.
        pub fn header(
            self: *Self,
            id: i32,
            name: []const u8,
            value: []const u8,
        ) protocol.Error!void {
            const stream = self.find(id) orelse return error.Protocol;
            if (stream.closed) return;
            if (stream.trailers) {
                try self.reserveTrailers(stream, name.len + value.len);
            } else try self.reserveHead(stream, name.len + value.len);
            const storage = if (stream.trailers) stream.storage.trailers else stream.headBytes();
            const used = if (stream.trailers) &stream.trailer_len else &stream.head_len;
            if (name.len + value.len > storage.len - used.*) return error.HeaderListTooLarge;
            const key = storage[used.*..][0..name.len];
            @memcpy(key, name);
            used.* += name.len;
            const text = storage[used.*..][0..value.len];
            @memcpy(text, value);
            used.* += value.len;
            if (stream.trailers) {
                if (name[0] == ':' or stream.request.forbidsTrailer(name)) return error.Protocol;
                try self.reserveFields(stream);
                stream.storage.trailer_fields[stream.trailer_count] = .{ .name = key, .value = text };
                stream.trailer_count += 1;
            } else if (std.mem.eql(
                u8,
                name,
                ":method",
            )) {
                stream.request.method = text;
            } else if (std.mem.eql(
                u8,
                name,
                ":path",
            )) {
                stream.request.target = text;
            } else if (std.mem.eql(
                u8,
                name,
                ":authority",
            )) {
                stream.request.authority = text;
            } else if (std.mem.eql(
                u8,
                name,
                ":scheme",
            )) {
                stream.request.scheme = text;
            } else {
                if (name[0] == ':') return error.Protocol;
                try self.reserveFields(stream);
                stream.fields()[stream.field_count] = .{ .name = key, .value = text };
                stream.field_count += 1;
                if (std.mem.eql(
                    u8,
                    name,
                    "content-length",
                )) {
                    stream.request.content_length = std.fmt.parseInt(
                        u64,
                        text,
                        10,
                    ) catch return error.Protocol;
                }
            }
        }

        /// Completes a head or trailer block and dispatches eligible application work.
        pub fn headComplete(
            self: *Self,
            id: i32,
            trailers: bool,
            ended: bool,
        ) protocol.Error!void {
            const stream = self.find(id) orelse return;
            if (trailers) {
                if (!ended) return error.Protocol;
                return;
            }
            // RFC 9113 permits split Cookie fields; generic application APIs
            // receive the joined value required when leaving HTTP/2 framing.
            var first_cookie: ?usize = null;
            var cookie_len: usize = 0;
            var cookie_count: usize = 0;
            for (stream.fields()[0..stream.field_count], 0..) |field, index| {
                if (!std.mem.eql(
                    u8,
                    field.name,
                    "cookie",
                )) continue;
                if (first_cookie == null) first_cookie = index;
                cookie_len += field.value.len;
                cookie_count += 1;
            }
            if (cookie_count > 1) {
                cookie_len += (cookie_count - 1) * 2;
                try self.reserveHead(stream, cookie_len);
                const joined = stream.headBytes()[stream.head_len..][0..cookie_len];
                var writer: std.Io.Writer = .fixed(joined);
                var count: usize = 0;
                var seen: usize = 0;
                for (stream.fields()[0..stream.field_count]) |field| {
                    if (std.mem.eql(
                        u8,
                        field.name,
                        "cookie",
                    )) {
                        if (seen != 0) writer.writeAll("; ") catch unreachable;
                        writer.writeAll(field.value) catch unreachable;
                        seen += 1;
                        if (seen > 1) continue;
                    }
                    stream.fields()[count] = field;
                    count += 1;
                }
                stream.fields()[first_cookie.?].value = joined;
                stream.field_count = count;
                stream.head_len += joined.len;
            }
            stream.request.headers = stream.fields()[0..stream.field_count];
            stream.request.body_follows = !ended;
            stream.head_ready = true;
        }

        /// Buffers or dispatches input under stream flow control; retains no borrowed input bytes.
        pub fn body(
            self: *Self,
            id: i32,
            bytes: []const u8,
        ) protocol.Error!void {
            try self.engine.consumeConnection(bytes.len);
            const stream = self.find(id) orelse return;
            if (stream.closed or stream.response != null) {
                try self.engine.consumeStream(id, bytes.len);
                return;
            }
            if (bytes.len > self.owner.config.max_body_bytes - stream.body_received) {
                if (stream.busy) {
                    try self.reset(stream);
                } else try self.status(stream, 413);
                return;
            }
            stream.body_received += bytes.len;
            if (stream.storage.body.len == 0) stream.storage.body = try self.gpa.alloc(u8, window);
            if (bytes.len > stream.storage.body.len - stream.body_len) return error.Protocol;
            @memcpy(stream.storage.body[stream.body_len..][0..bytes.len], bytes);
            stream.body_len += bytes.len;
        }

        /// Marks request input complete and dispatches work once any running body hook finishes.
        pub fn end(self: *Self, id: i32) protocol.Error!void {
            const stream = self.find(id) orelse return;
            stream.ended = true;
        }

        /// Marks a stream closed and cancels work; storage survives until borrowed tasks finish.
        pub fn closed(
            self: *Self,
            id: i32,
            code: u32,
        ) void {
            const stream = self.find(id) orelse return;
            stream.closed = true;
            stream.close_code = code;
            stream.canceled.store(true, .release);
            if (comptime has_response_streams) {
                if (stream.response_stream_started) stream.exchange.response_stream.cancel();
            }
        }

        /// Records response completion after the engine serializes END_STREAM.
        pub fn responseEnd(self: *Self, id: i32) protocol.Error!void {
            const stream = self.find(id) orelse return;
            if (!stream.ended) try self.engine.finishInput(id);
        }

        /// Cancels every live stream; running tasks retain storage until their completions arrive.
        pub fn abort(self: *Self) void {
            var item = self.streams;
            while (item) |stream| : (item = stream.next) {
                stream.closed = true;
                stream.close_code = 8;
                stream.canceled.store(true, .release);
                if (comptime has_response_streams) {
                    if (stream.response_stream_started) stream.exchange.response_stream.cancel();
                }
            }
        }

        /// Begins graceful shutdown with GOAWAY while allowing accepted streams to finish.
        pub fn shutdown(self: *Self) protocol.Error!void {
            if (self.draining) return;
            self.draining = true;
            try self.engine.shutdown(self.last_id);
        }

        /// Batches bounded engine output into one TLS record. The result borrows
        /// transport storage until the next call, including across socket I/O.
        pub fn output(self: *Self) protocol.Error![]const u8 {
            var used: usize = 0;
            for (0..64) |_| {
                if (self.pending_frame.len == 0) self.pending_frame = try self.engine.output();
                if (self.pending_frame.len == 0) break;
                const count = @min(self.pending_frame.len, self.plaintext_output.len - used);
                @memcpy(self.plaintext_output[used..][0..count], self.pending_frame[0..count]);
                used += count;
                self.pending_frame = self.pending_frame[count..];
                if (used == self.plaintext_output.len) break;
            }
            return self.plaintext_output[0..used];
        }

        fn reset(self: *Self, stream: *Stream) protocol.Error!void {
            stream.canceled.store(true, .release);
            if (comptime has_response_streams) {
                if (stream.response_stream_started) stream.exchange.response_stream.cancel();
            }
            try self.engine.reset(stream.id);
            stream.closed = true;
            stream.close_code = 8;
        }

        /// Advances ready streams outside nghttp2 callbacks. No request metadata
        /// or borrowed body prefix is changed while its executor task is running.
        pub fn drive(self: *Self) protocol.Error!void {
            const now = platform.monotonicNs();
            var link = &self.streams;
            while (link.*) |stream| {
                if (comptime has_response_streams) {
                    if (!stream.closed and stream.response_stream_started) {
                        const publication = stream.exchange.response_stream.publication.load(.acquire);
                        if (publication == .ready and stream.response_write_deadline == 0) {
                            stream.response_write_deadline = now +
                                @as(u64, self.owner.config.write_timeout_ms) * 1_000_000;
                        }
                        stream.deadline = if (stream.response_write_deadline == 0)
                            stream.application_deadline
                        else
                            @min(stream.application_deadline, stream.response_write_deadline);
                    }
                }
                if (!stream.closed and now >= stream.deadline) {
                    self.owner.metrics.recorder().add(.request_timeouts_total, 1);
                    self.owner.metrics.recorder().add(if (stream.application_deadline != 0 and
                        now >= stream.application_deadline)
                        .application_timeouts_total
                    else if (stream.response != null)
                        .write_timeouts_total
                    else if (!stream.head_ready)
                        .header_timeouts_total
                    else
                        .body_timeouts_total, 1);
                    try self.reset(stream);
                }
                if (stream.closed) {
                    if (!stream.busy) {
                        link.* = stream.next;
                        self.destroy(stream);
                        continue;
                    }
                } else if (!stream.busy and stream.response == null and stream.head_ready) {
                    try self.advance(stream);
                } else if (comptime has_response_streams) {
                    if (stream.response_stream_started) {
                        const publication = stream.exchange.response_stream.publication.load(.acquire);
                        if (publication == .failed) {
                            try self.reset(stream);
                        } else if (stream.response_deferred and
                            (publication == .ready or (publication == .finished and !stream.busy)))
                        {
                            stream.response_deferred = false;
                            try self.engine.resumeBody(stream.id);
                        }
                    }
                }
                link = &stream.next;
            }
            if (self.accepted >= self.owner.config.max_requests_per_connection) try self.shutdown();
        }

        fn advance(self: *Self, stream: *Stream) protocol.Error!void {
            const request = &stream.request;
            const config = self.owner.config;
            if (!stream.initialized) {
                if (std.mem.eql(
                    u8,
                    request.method,
                    "CONNECT",
                )) return self.status(stream, 501);
                if (!http.syntax.eql(request.scheme orelse "", "https")) return self.status(stream, 421);
                if (request.authority.len == 0) request.authority = request.getHeader("host") orelse "";
                if (!http.syntax.isAuthority(
                    request.authority,
                    false,
                    false,
                )) return self.status(stream, 400);
                if (request.getHeader("host")) |host| {
                    if (!http.syntax.eql(host, request.authority)) return self.status(stream, 400);
                }
                const target = request.target;
                if (target.len == 0 or target.len > 8192 or
                    !http.syntax.isUriComponent(target, true)) return self.status(stream, 400);
                const question = std.mem.indexOfScalar(
                    u8,
                    target,
                    '?',
                );
                const path = target[0 .. question orelse target.len];
                if (path[0] != '/' and !(std.mem.eql(
                    u8,
                    path,
                    "*",
                ) and
                    std.mem.eql(
                        u8,
                        request.method,
                        "OPTIONS",
                    ))) return self.status(stream, 400);
                if (path.len > stream.pathBytes().len)
                    try self.growBytes(
                        &stream.storage.path,
                        &.{},
                        path.len,
                    );
                request.path = http.path.normalize(
                    stream.pathBytes(),
                    path,
                ) catch return self.status(
                    stream,
                    400,
                );
                if (question) |at| request.query = target[at + 1 ..];
                if (request.getHeader("expect")) |expect| {
                    if (!http.syntax.eql(expect, "100-continue")) return self.status(stream, 417);
                    request.expect_continue = !stream.ended;
                }
                if (request.content_length) |len| if (len > config.max_body_bytes) return self.status(
                    stream,
                    413,
                );
                stream.permit = self.owner.admission.acquire(platform.monotonicNs(), false);
                switch (stream.permit.?) {
                    .admit => self.owner.metrics.recorder().add(.requests_admitted_total, 1),
                    .reject => {
                        self.owner.metrics.recorder().add(.requests_rejected_total, 1);
                        return self.status(stream, 503);
                    },
                    .close => return self.reset(stream),
                }
                if (stream.storage.application.len == 0)
                    stream.storage.application = try self.gpa.alloc(u8, config.application_bytes);
                if (comptime @hasDecl(App.Exchange, "initApplication")) {
                    stream.exchange.initApplication(
                        stream.storage.application,
                        self.owner.application_runtime,
                    );
                } else stream.exchange.init(stream.storage.application);
                stream.initialized = true;
                if (comptime @hasDecl(App.Exchange, "setCancellation"))
                    stream.exchange.setCancellation(&stream.canceled);
                if (comptime @hasDecl(App.Exchange, "setRequestRuntime")) stream.exchange.setRequestRuntime(
                    &self.owner.application_metrics,
                    self.owner.io,
                    (@as(u64, self.owner.connections[self.index].generation) << 32) | (self.index << 8),
                    stream.request_id,
                );
                stream.deadline = platform.monotonicNs() + @as(u64, config.body_timeout_ms) * 1_000_000;
                const early = if (comptime isolated)
                    stream.exchange.prepareHead(request)
                else
                    stream.exchange.receiveHead(request);
                if (early) |response| return self.respond(stream, response);
                if (comptime isolated) {
                    stream.application_deadline = platform.monotonicNs() +
                        @as(u64, App.laneOptions(stream.exchange.lane()).timeout_ms) * 1_000_000;
                    stream.deadline = @min(stream.deadline, stream.application_deadline);
                    const inline_head = if (comptime @hasDecl(App.Exchange, "canRunHeadInline"))
                        stream.exchange.canRunHeadInline()
                    else
                        false;
                    if (!inline_head) return self.submit(stream, .head);
                    if (stream.exchange.runHead(request)) |response| return self.respond(stream, response);
                }
                stream.head_done = true;
                if (request.expect_continue) try self.engine.inform(stream.id);
            }
            if (!stream.head_done) return;
            if (stream.body_len != 0) {
                if (comptime isolated and @hasDecl(App.Exchange, "streamsBody")) {
                    if (stream.exchange.streamsBody()) {
                        stream.task_body_len = stream.body_len;
                        return self.submit(stream, .body);
                    }
                }
                stream.exchange.receiveBody(stream.storage.body[0..stream.body_len]) catch
                    return self.status(stream, 413);
                try self.engine.consumeStream(stream.id, stream.body_len);
                stream.body_len = 0;
            }
            if (!stream.ended) return;
            request.trailers = stream.storage.trailer_fields[0..stream.trailer_count];
            if (comptime isolated) return self.submit(stream, .response);
            try self.respond(stream, stream.exchange.respond(request));
        }

        fn submit(
            self: *Self,
            stream: *Stream,
            stage: Stage,
        ) protocol.Error!void {
            if (!self.owner.submitHttp2(
                self.index,
                stream,
                stage,
            )) try self.status(stream, 503);
        }

        /// Completes the sole task borrowing this stream. A reset or timeout
        /// suppresses its result without freeing storage beneath a running hook.
        pub fn complete(
            self: *Self,
            stream: *Stream,
            stage: Stage,
            response: ?http.Response,
            expired: bool,
        ) protocol.Error!void {
            std.debug.assert(stream.busy);
            stream.busy = false;
            if (comptime @hasDecl(App.Exchange, "flushLogs"))
                stream.exchange.flushLogs(&self.owner.logger);
            if (stream.closed) return;
            if (expired) {
                self.owner.metrics.recorder().add(.request_timeouts_total, 1);
                self.owner.metrics.recorder().add(.application_timeouts_total, 1);
                return self.reset(stream);
            }
            if (response) |result| return self.respond(stream, result);
            switch (stage) {
                .head => {
                    stream.head_done = true;
                    if (stream.request.expect_continue) try self.engine.inform(stream.id);
                },
                .body => {
                    const consumed = stream.task_body_len;
                    std.mem.copyForwards(
                        u8,
                        stream.storage.body,
                        stream.storage.body[consumed..stream.body_len],
                    );
                    stream.body_len -= consumed;
                    stream.task_body_len = 0;
                    try self.engine.consumeStream(stream.id, consumed);
                },
                .response => unreachable,
                .produce => {},
            }
        }

        fn status(
            self: *Self,
            stream: *Stream,
            code: u16,
        ) protocol.Error!void {
            if (stream.permit == null) {
                self.owner.admission.refill(platform.monotonicNs());
                stream.permit = self.owner.admission.acquireRejection();
                self.owner.metrics.recorder().add(.requests_rejected_total, 1);
                if (stream.permit == .close) return self.reset(stream);
            }
            try self.respond(stream, .{
                .status = code,
                .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
                .body = .{ .bytes = http.Response.errorBody(code) },
            });
        }

        fn respond(
            self: *Self,
            stream: *Stream,
            response: http.Response,
        ) protocol.Error!void {
            if (response.status < 200) return self.reset(stream);
            const plan = response.framing(&stream.request) catch return self.reset(stream);
            const has_body = !plan.suppressed and switch (response.body) {
                .bytes => |bytes| bytes.len != 0,
                .stream => true,
            };
            if (has_body and response.body == .stream)
                try self.reserveOutput(
                    stream,
                    self.owner.config.response_bytes,
                    0,
                );
            var fields: [63]http.Header = undefined;
            fields[0] = .{ .name = "date", .value = &self.owner.date };
            var count: usize = 1;
            var length_buffer: [20]u8 = undefined;
            const length_text = if (plan.content_length) |len|
                std.fmt.bufPrint(
                    &length_buffer,
                    "{d}",
                    .{len},
                ) catch unreachable
            else
                "";
            if (plan.content_length != null) {
                fields[count] = .{ .name = "content-length", .value = length_text };
                count += 1;
            }
            // Preserve the former HTTP/1 serialization buffer limit arithmetically,
            // including filtered fields, while submitting HTTP/2 metadata directly.
            const fixed_bytes = "HTTP/1.1 000 \r\nDate: \r\n\r\n".len + self.owner.date.len +
                http.Response.reason(response.status).len +
                @as(
                    usize,
                    if (response.close or !stream.request.keep_alive) "Connection: close\r\n".len else 0,
                ) +
                (if (plan.content_length != null)
                    "Content-Length: \r\n".len + length_text.len
                else if (!plan.suppressed)
                    "Transfer-Encoding: chunked\r\n".len
                else
                    @as(usize, 0));
            if (fixed_bytes > self.owner.config.response_bytes) return self.reset(stream);
            var budget = self.owner.config.response_bytes - fixed_bytes;
            var names_used: usize = 0;
            for (response.headers) |field| {
                if (field.name.len > budget) return self.reset(stream);
                budget -= field.name.len;
                if (field.value.len > budget) return self.reset(stream);
                budget -= field.value.len;
                if (budget < 4) return self.reset(stream);
                budget -= 4;
                if (http.syntax.eql(field.name, "keep-alive") or http.syntax.eql(field.name, "upgrade") or
                    http.syntax.eql(field.name, "proxy-connection")) continue;
                if (count == fields.len) return self.reset(stream);
                const name = lowercase: {
                    for (field.name) |byte| {
                        if (!std.ascii.isUpper(byte)) continue;
                        const previous = stream.outputBytes();
                        try self.reserveOutput(
                            stream,
                            names_used + field.name.len,
                            names_used,
                        );
                        const names = stream.outputBytes();
                        if (previous.ptr != names.ptr) {
                            for (fields[0..count]) |*prior|
                                prior.name = relocated(
                                    previous[0..names_used],
                                    names,
                                    prior.name,
                                );
                        }
                        const lower = names[names_used..][0..field.name.len];
                        _ = std.ascii.lowerString(lower, field.name);
                        names_used += field.name.len;
                        break :lowercase lower;
                    }
                    break :lowercase field.name;
                };
                fields[count] = .{ .name = name, .value = http.syntax.trim(field.value) };
                count += 1;
            }
            stream.response = response;
            stream.deadline = platform.monotonicNs() + @as(
                u64,
                self.owner.config.write_timeout_ms,
            ) * 1_000_000;
            try self.engine.respond(
                stream.id,
                response.status,
                fields[0..count],
                has_body,
            );
            self.owner.metrics.recorder().response(response.status);
            if (stream.body_len != 0) {
                try self.engine.consumeStream(stream.id, stream.body_len);
                stream.body_len = 0;
            }
            if (comptime @hasDecl(App.Exchange, "flushLogs")) {
                if (stream.initialized) stream.exchange.flushLogs(&self.owner.logger);
            }
            if (comptime has_response_streams) {
                if (has_body and response.body == .stream) {
                    if (stream.exchange.response_producer == null) return self.reset(stream);
                    stream.exchange.response_stream.init(
                        stream.outputBytes(),
                        self.owner.io,
                        self.owner.application_event_fd,
                        &stream.canceled,
                    );
                    stream.deadline = stream.application_deadline;
                    if (!self.owner.submitHttp2(
                        self.index,
                        stream,
                        .produce,
                    )) return self.reset(stream);
                    stream.response_stream_started = true;
                } else stream.application_deadline = 0;
            }
        }

        /// Copies available response bytes into destination; null defers and zero ends output.
        pub fn produce(
            self: *Self,
            id: i32,
            destination: []u8,
        ) protocol.Error!?usize {
            const stream = self.find(id) orelse return error.Protocol;
            const response = stream.response orelse return null;
            if (stream.closed) return error.Protocol;
            const count = switch (response.body) {
                .bytes => |bytes| result: {
                    const count = @min(destination.len, bytes.len - stream.response_offset);
                    @memcpy(destination[0..count], bytes[stream.response_offset..][0..count]);
                    stream.response_offset += count;
                    break :result count;
                },
                .stream => |length| result: {
                    if (comptime has_response_streams) {
                        const source = &stream.exchange.response_stream;
                        switch (source.publication.load(.acquire)) {
                            .writing => {
                                stream.response_deferred = true;
                                return null;
                            },
                            .ready => {
                                const bytes = source.writer.buffer[0..source.published_len];
                                const count = @min(destination.len, bytes.len - stream.publication_offset);
                                if (length) |len| if (count > len - stream.produced) return error.Protocol;
                                @memcpy(destination[0..count], bytes[stream.publication_offset..][0..count]);
                                stream.publication_offset += count;
                                if (stream.publication_offset == bytes.len) {
                                    stream.publication_offset = 0;
                                    stream.response_write_deadline = 0;
                                    source.consume();
                                }
                                break :result count;
                            },
                            .finished => {
                                if (stream.busy) {
                                    stream.response_deferred = true;
                                    return null;
                                }
                                if (length) |len| if (stream.produced != len) return error.Protocol;
                                break :result 0;
                            },
                            .failed => return error.Protocol,
                        }
                    } else {
                        if (stream.fragment.len == 0 and !stream.producer_done) {
                            if (stream.exchange.produce(stream.outputBytes())) |fragment| {
                                if (fragment.len == 0) return error.Protocol;
                                stream.fragment = fragment;
                            } else stream.producer_done = true;
                        }
                        const count = @min(destination.len, stream.fragment.len);
                        if (length) |len| {
                            if (count > len - stream.produced or (count == 0 and stream.produced != len))
                                return error.Protocol;
                        }
                        @memcpy(destination[0..count], stream.fragment[0..count]);
                        stream.fragment = stream.fragment[count..];
                        break :result count;
                    }
                },
            };
            stream.produced += count;
            return count;
        }

        /// Reports whether the last produced fragment also completes this stream body.
        pub fn producedEnd(self: *Self, id: i32) bool {
            const stream = self.find(id) orelse return false;
            return switch (stream.response.?.body) {
                .bytes => |bytes| stream.response_offset == bytes.len,
                .stream => false,
            };
        }

        fn destroy(self: *Self, stream: *Stream) void {
            const completed = stream.closed and stream.close_code == 0 and stream.response != null;
            self.owner.metrics.recorder().add(
                if (completed) .requests_completed_total else .requests_aborted_total,
                1,
            );
            self.owner.metrics.recorder().observe(
                .request_duration_seconds,
                platform.monotonicNs() - stream.started_ns,
            );
            self.owner.recordHttp2(
                self.index,
                stream,
                completed,
            );
            if (comptime @hasDecl(App.Exchange, "releaseApplication")) {
                if (stream.initialized) {
                    stream.exchange.releaseApplication(&stream.request);
                    stream.exchange.flushLogs(&self.owner.logger);
                }
            }
            if (stream.permit) |permit| self.owner.admission.release(permit);
            self.owner.http2_streams -= 1;
            self.count -= 1;
            self.idle_deadline = platform.monotonicNs() + @as(
                u64,
                self.owner.config.idle_timeout_ms,
            ) * 1_000_000;
            // Reuse storage only after hooks, framing callbacks and borrowed
            // response bytes are done. Cached bytes remain charged to the budget.
            if (self.owner.http2_cached < 64) {
                stream.next = self.owner.free_http2_stream;
                self.owner.free_http2_stream = stream;
                self.owner.http2_cached += 1;
                return;
            }
            stream.storage.deinit(self.gpa);
            self.gpa.destroy(stream);
        }
    };
}

const TestOwner = struct {
    config: Config = .{},
    metrics: Metrics = .{},
    admission: Admission = undefined,
    next_request: u64 = 1,
    http2_streams: usize = 0,
    http2_cached: usize = 0,
    free_http2_stream: ?*Connection(application, TestOwner).Stream = null,
    date: [29]u8 = undefined,

    pub fn recordHttp2(
        _: *TestOwner,
        _: usize,
        _: anytype,
        _: bool,
    ) void {}
};

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var owner: TestOwner = .{};
    defer Connection(application, TestOwner).releaseCache(gpa, &owner);
    owner.admission.init(try owner.config.resolveAdmission(), platform.monotonicNs());
    http.Response.formatDate(0, &owner.date);
    var session: Connection(application, TestOwner) = undefined;
    try session.init(
        &owner,
        0,
        gpa,
    );
    defer session.deinit();
    const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
    _ = try session.engine.receive(preface);
    const headers = "\x83\x87\x04\x05/echo\x01\x09localhost";
    var frame: [9]u8 = .{
        0,
        0,
        headers.len,
        1,
        4,
        0,
        0,
        0,
        1,
    };
    _ = try session.engine.receive(&frame);
    _ = try session.engine.receive(headers);
    try session.drive();
    frame = .{
        0,
        0,
        5,
        0,
        1,
        0,
        0,
        0,
        1,
    };
    _ = try session.engine.receive(&frame);
    _ = try session.engine.receive("hello");
    try session.drive();
    var received: usize = 0;
    while (true) {
        const bytes = try session.engine.output();
        if (bytes.len == 0) break;
        if (bytes[3] == 0) {
            received += bytes.len - 9;
            if (bytes.len > 9) try std.testing.expectEqualStrings("hello", bytes[9..]);
        }
    }
    try session.drive();
    try std.testing.expectEqual(@as(usize, 5), received);
    try std.testing.expectEqual(@as(usize, 0), owner.http2_streams);
    try std.testing.expectEqual(@as(usize, 0), owner.admission.active);
}

fn writeTestString(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len < 127) {
        try writer.writeByte(@intCast(bytes.len));
    } else {
        try writer.writeByte(127);
        var remaining = bytes.len - 127;
        while (remaining >= 128) : (remaining >>= 7)
            try writer.writeByte(@as(u8, @intCast(remaining & 127)) | 128);
        try writer.writeByte(@intCast(remaining));
    }
    try writer.writeAll(bytes);
}

fn writeTestField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: []const u8,
) !void {
    try writer.writeByte(0);
    try writeTestString(writer, name);
    try writeTestString(writer, value);
}

fn storageGrowthScenario(gpa: std.mem.Allocator) !void {
    const Session = Connection(application, TestOwner);
    var owner: TestOwner = .{};
    defer Session.releaseCache(gpa, &owner);
    owner.admission.init(try owner.config.resolveAdmission(), platform.monotonicNs());
    http.Response.formatDate(0, &owner.date);
    var session: Session = undefined;
    try session.init(
        &owner,
        0,
        gpa,
    );
    defer session.deinit();
    _ = try session.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
        "\x00\x00\x00\x04\x00\x00\x00\x00\x00");

    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.writeAll("\x83\x87");
    try writeTestField(
        &writer,
        ":path",
        "/" ++ "x" ** 300 ++ "/../echo",
    );
    try writeTestField(
        &writer,
        ":authority",
        "localhost",
    );
    try writeTestField(
        &writer,
        "cookie",
        "a" ** 120,
    );
    try writeTestField(
        &writer,
        "cookie",
        "b" ** 120,
    );
    for (0..40) |_| try writeTestField(
        &writer,
        "x-growth",
        "v" ** 120,
    );
    var frame: [9]u8 = .{
        0,
        0,
        0,
        1,
        4,
        0,
        0,
        0,
        1,
    };
    std.mem.writeInt(
        u24,
        frame[0..3],
        @intCast(writer.end),
        .big,
    );
    _ = try session.engine.receive(&frame);
    _ = try session.engine.receive(writer.buffered());
    try session.drive();
    const request = &session.streams.?.request;
    try std.testing.expectEqualStrings("/echo", request.path);
    try std.testing.expectEqualStrings("a" ** 120 ++ "; " ++ "b" ** 120, request.getHeader("cookie").?);
    try std.testing.expectEqual(@as(usize, 41), request.headers.len);

    _ = try session.engine.receive("\x00\x00\x05\x00\x00\x00\x00\x00\x01hello");
    writer = .fixed(&buffer);
    for (0..40) |_| try writeTestField(
        &writer,
        "x-result",
        "t" ** 120,
    );
    frame[4] = 5;
    std.mem.writeInt(
        u24,
        frame[0..3],
        @intCast(writer.end),
        .big,
    );
    _ = try session.engine.receive(&frame);
    _ = try session.engine.receive(writer.buffered());
    try session.drive();
    try std.testing.expectEqual(@as(usize, 40), request.trailers.len);
    for (request.trailers) |field| {
        try std.testing.expectEqualStrings("x-result", field.name);
        try std.testing.expectEqualStrings("t" ** 120, field.value);
    }
    var received: usize = 0;
    while (true) {
        const bytes = try session.engine.output();
        if (bytes.len == 0) break;
        if (bytes[3] == 0) {
            received += bytes.len - 9;
            if (bytes.len > 9) try std.testing.expectEqualStrings("hello", bytes[9..]);
        }
    }
    try session.drive();
    try std.testing.expectEqual(@as(usize, 5), received);
    try std.testing.expectEqual(@as(usize, 0), owner.http2_streams);
    try std.testing.expectEqual(@as(usize, 0), owner.admission.active);
}

test "http2 stream storage and body ingestion unwind every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationScenario,
        .{},
    );
}

test "http2 metadata growth unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        storageGrowthScenario,
        .{},
    );
}
