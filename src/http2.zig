//! Socket-independent HTTP/2 sessions. The transport worker owns all calls;
//! application streams and asynchronous I/O buffers remain owned by the caller.

const std = @import("std");
const http = @import("http.zig");
const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});

pub const Error = std.mem.Allocator.Error || error{
    Protocol,
    InvalidOperation,
    HeaderListTooLarge,
    RefusedStream,
};

pub const Limits = struct {
    streams: u32 = 100,
    header_bytes: u32 = 16 * 1024,
    stream_window: u32 = 64 * 1024,
    session_bytes: usize = 1024 * 1024,
};

/// Handler methods run synchronously on the session owner. They must not reenter
/// receive/output or retain borrowed header/body slices. begin, header, head, body and
/// end return Error!void; closed(id, code) releases stream resources. produce(id,
/// destination) returns Error!?usize: null defers, zero finishes, positive emits
/// bytes. The handler must bound its own stream storage independently of nghttp2.
/// Optional headComplete(id, trailers, ended) replaces head; responseEnd(id)
/// observes serialized END_STREAM, and producedEnd(id) can end a nonempty DATA
/// frame without an extra empty frame. These callbacks also run on the owner.
pub fn Session(comptime Handler: type) type {
    return struct {
        const Self = @This();

        handle: *c.nghttp2_session = undefined,
        handler: *Handler = undefined,
        limits: Limits = .{},
        header_bytes: usize = 0,
        callback_error: ?Error = null,
        memory: Memory = undefined,

        /// Storage must stay at this address until deinit. Owns nghttp2 resources,
        /// not the handler. Advertised limits apply before peer SETTINGS ACK too.
        /// Errors release acquired resources; call deinit only after success.
        pub fn init(
            self: *Self,
            gpa: std.mem.Allocator,
            handler: *Handler,
            limits: Limits,
        ) Error!void {
            if (limits.streams == 0 or limits.header_bytes == 0 or
                limits.stream_window > std.math.maxInt(i32)) return error.InvalidOperation;
            self.* = .{
                .handler = handler,
                .limits = limits,
                .memory = .{
                    .gpa = gpa,
                    .limit = limits.session_bytes,
                },
            };
            var callbacks: ?*c.nghttp2_session_callbacks = null;
            try check(c.nghttp2_session_callbacks_new(&callbacks));
            defer c.nghttp2_session_callbacks_del(callbacks);
            c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, begin);
            c.nghttp2_session_callbacks_set_on_header_callback(callbacks, header);
            c.nghttp2_session_callbacks_set_on_invalid_header_callback(callbacks, invalidHeader);
            c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, body);
            c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, frame);
            c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, closed);
            c.nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, sent);
            var options: ?*c.nghttp2_option = null;
            try check(c.nghttp2_option_new(&options));
            defer c.nghttp2_option_del(options);
            c.nghttp2_option_set_no_auto_window_update(options, 1);
            c.nghttp2_option_set_max_continuations(options, 8);
            c.nghttp2_option_set_max_outbound_ack(options, 128);
            c.nghttp2_option_set_stream_reset_rate_limit(options, 100, 10);
            var memory = self.memory.callbacks();
            var handle: ?*c.nghttp2_session = null;
            try check(c.nghttp2_session_server_new3(&handle, callbacks, self, options, &memory));
            errdefer c.nghttp2_session_del(handle);
            self.handle = handle.?;
            const settings = [_]c.nghttp2_settings_entry{
                .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = limits.streams },
                .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = limits.header_bytes },
                .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = limits.stream_window },
            };
            try check(c.nghttp2_submit_settings(self.handle, 0, &settings, settings.len));
        }

        /// Caller releases remaining application streams separately on connection
        /// teardown: nghttp2_session_del does not invoke closed callbacks.
        pub fn deinit(self: *Self) void {
            c.nghttp2_session_del(self.handle);
            std.debug.assert(self.memory.used == 0);
            self.* = undefined;
        }

        /// Consumes plaintext, including the initial client preface. Negative
        /// engine outcomes are connection-fatal; never retry after an error.
        pub fn receive(self: *Self, bytes: []const u8) Error!usize {
            const count = c.nghttp2_session_mem_recv2(self.handle, bytes.ptr, bytes.len);
            if (count < 0) return self.callback_error orelse mapped(count);
            return @intCast(count);
        }

        /// Borrowed until the next output call or deinit. Copy into transport-owned
        /// storage before asynchronous writes; do not request unbounded queued output.
        pub fn output(self: *Self) Error![]const u8 {
            var bytes: [*c]const u8 = null;
            const count = c.nghttp2_session_mem_send2(self.handle, &bytes);
            if (count < 0) return self.callback_error orelse mapped(count);
            return if (count == 0) &.{} else bytes[0..@intCast(count)];
        }

        /// Credit body bytes only after the application consumes them, not merely
        /// after receiving them. Updates both connection and stream windows.
        pub fn consume(self: *Self, id: i32, count: usize) Error!void {
            try check(c.nghttp2_session_consume(self.handle, id, count));
        }

        /// Separately credit bounded connection buffering and application
        /// consumption, so one stalled stream does not consume all connection credit.
        pub fn consumeConnection(self: *Self, count: usize) Error!void {
            try check(c.nghttp2_session_consume_connection(self.handle, count));
        }

        /// Credits stream buffering only after the application consumes count bytes.
        pub fn consumeStream(self: *Self, id: i32, count: usize) Error!void {
            try check(c.nghttp2_session_consume_stream(self.handle, id, count));
        }

        /// Reports whether the engine still accepts input, including protocol shutdown traffic.
        pub fn wantsRead(self: *const Self) bool {
            return c.nghttp2_session_want_read(self.handle) != 0;
        }

        /// Queues a 100 Continue header block without ending the stream.
        pub fn inform(self: *Self, id: i32) Error!void {
            var status = field(":status", "100");
            try check(c.nghttp2_submit_headers(self.handle, 0, id, null, &status, 1, null));
        }

        /// Copies final response headers into nghttp2. With a body, produce is
        /// called as flow-control credit allows. Header names must be lowercase.
        pub fn respond(
            self: *Self,
            id: i32,
            status: u16,
            headers: []const http.Header,
            has_body: bool,
        ) Error!void {
            if (status < 200 or status > 599) return error.InvalidOperation;
            if (headers.len > 63) return error.HeaderListTooLarge;
            var code: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&code, "{d}", .{status}) catch unreachable;
            var fields: [64]c.nghttp2_nv = undefined;
            fields[0] = field(":status", &code);
            for (headers, 1..) |entry, index| {
                if (entry.name.len == 0 or entry.name[0] == ':') return error.InvalidOperation;
                for (entry.name) |byte| if (std.ascii.isUpper(byte)) return error.InvalidOperation;
                fields[index] = field(entry.name, entry.value);
            }
            const provider: c.nghttp2_data_provider2 = .{
                .source = .{ .ptr = null },
                .read_callback = produce,
            };
            try check(c.nghttp2_submit_response2(
                self.handle,
                id,
                &fields,
                headers.len + 1,
                if (has_body) &provider else null,
            ));
        }

        /// Reschedules a producer that previously returned null when output becomes available.
        pub fn resumeBody(self: *Self, id: i32) Error!void {
            try check(c.nghttp2_session_resume_data(self.handle, id));
        }

        /// Queues cancellation of one stream; other streams remain usable.
        pub fn reset(self: *Self, id: i32) Error!void {
            try check(c.nghttp2_submit_rst_stream(self.handle, 0, id, c.NGHTTP2_CANCEL));
        }

        /// Stop an unread request after its final response has been serialized.
        pub fn finishInput(self: *Self, id: i32) Error!void {
            try check(c.nghttp2_submit_rst_stream(self.handle, 0, id, c.NGHTTP2_NO_ERROR));
        }

        /// Refuses streams beyond last_id while allowing already accepted streams
        /// to finish. The caller supplies the highest stream it actually accepted.
        pub fn shutdown(self: *Self, last_id: i32) Error!void {
            try check(c.nghttp2_submit_goaway(
                self.handle,
                0,
                last_id,
                c.NGHTTP2_NO_ERROR,
                null,
                0,
            ));
        }

        fn owner(pointer: ?*anyopaque) *Self {
            return @ptrCast(@alignCast(pointer.?));
        }

        fn failed(self: *Self, id: i32, err: Error) c_int {
            @branchHint(.cold);
            if (err != error.OutOfMemory) {
                const code: u32 = if (err == error.RefusedStream)
                    c.NGHTTP2_REFUSED_STREAM
                else
                    c.NGHTTP2_PROTOCOL_ERROR;
                if (c.nghttp2_submit_rst_stream(self.handle, 0, id, code) == 0)
                    return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
            self.callback_error = error.OutOfMemory;
            return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        }

        fn begin(
            _: ?*c.nghttp2_session,
            incoming: [*c]const c.nghttp2_frame,
            pointer: ?*anyopaque,
        ) callconv(.c) c_int {
            const self = owner(pointer);
            self.header_bytes = 0;
            self.handler.begin(
                incoming.*.hd.stream_id,
                incoming.*.headers.cat == c.NGHTTP2_HCAT_HEADERS,
            ) catch |err|
                return self.failed(incoming.*.hd.stream_id, err);
            return 0;
        }

        fn header(
            _: ?*c.nghttp2_session,
            incoming: [*c]const c.nghttp2_frame,
            name: [*c]const u8,
            name_len: usize,
            value: [*c]const u8,
            value_len: usize,
            _: u8,
            pointer: ?*anyopaque,
        ) callconv(.c) c_int {
            const self = owner(pointer);
            const id = incoming.*.hd.stream_id;
            const size = std.math.add(
                usize,
                name_len,
                value_len,
            ) catch return self.failed(id, error.HeaderListTooLarge);
            const charge = std.math.add(
                usize,
                size,
                32,
            ) catch return self.failed(id, error.HeaderListTooLarge);
            if (charge > self.limits.header_bytes - self.header_bytes) return self.failed(
                id,
                error.HeaderListTooLarge,
            );
            self.header_bytes += charge;
            self.handler.header(
                id,
                name[0..name_len],
                value[0..value_len],
            ) catch |err| return self.failed(id, err);
            return 0;
        }

        fn invalidHeader(
            _: ?*c.nghttp2_session,
            _: [*c]const c.nghttp2_frame,
            _: [*c]const u8,
            _: usize,
            _: [*c]const u8,
            _: usize,
            _: u8,
            _: ?*anyopaque,
        ) callconv(.c) c_int {
            // The default discards malformed fields, potentially changing request
            // semantics. nghttp2 resets only this stream with PROTOCOL_ERROR.
            return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        }

        fn body(
            _: ?*c.nghttp2_session,
            _: u8,
            id: i32,
            bytes: [*c]const u8,
            len: usize,
            pointer: ?*anyopaque,
        ) callconv(.c) c_int {
            const self = owner(pointer);
            self.handler.body(id, bytes[0..len]) catch |err| {
                // DATA callbacks do not accept TEMPORAL_CALLBACK_FAILURE.
                if (self.failed(
                    id,
                    err,
                ) == c.NGHTTP2_ERR_CALLBACK_FAILURE) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            };
            return 0;
        }

        fn frame(
            _: ?*c.nghttp2_session,
            incoming: [*c]const c.nghttp2_frame,
            pointer: ?*anyopaque,
        ) callconv(.c) c_int {
            const self = owner(pointer);
            const hd = incoming.*.hd;
            if (hd.type == c.NGHTTP2_HEADERS) {
                const result = if (comptime @hasDecl(Handler, "headComplete"))
                    self.handler.headComplete(
                        hd.stream_id,
                        incoming.*.headers.cat == c.NGHTTP2_HCAT_HEADERS,
                        hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0,
                    )
                else
                    self.handler.head(hd.stream_id, incoming.*.headers.cat == c.NGHTTP2_HCAT_HEADERS);
                result catch |err| {
                    if (self.failed(
                        hd.stream_id,
                        err,
                    ) == c.NGHTTP2_ERR_CALLBACK_FAILURE) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                    return 0;
                };
            }
            if ((hd.type == c.NGHTTP2_HEADERS or hd.type == c.NGHTTP2_DATA) and
                hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0)
            {
                self.handler.end(hd.stream_id) catch |err| {
                    if (self.failed(
                        hd.stream_id,
                        err,
                    ) == c.NGHTTP2_ERR_CALLBACK_FAILURE) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                };
            }
            return 0;
        }

        fn closed(
            _: ?*c.nghttp2_session,
            id: i32,
            code: u32,
            pointer: ?*anyopaque,
        ) callconv(.c) c_int {
            owner(pointer).handler.closed(id, code);
            return 0;
        }

        fn sent(
            _: ?*c.nghttp2_session,
            outgoing: [*c]const c.nghttp2_frame,
            pointer: ?*anyopaque,
        ) callconv(.c) c_int {
            if (comptime @hasDecl(Handler, "responseEnd")) {
                const hd = outgoing.*.hd;
                if ((hd.type == c.NGHTTP2_HEADERS or hd.type == c.NGHTTP2_DATA) and
                    hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0)
                {
                    const self = owner(pointer);
                    self.handler.responseEnd(hd.stream_id) catch |err| {
                        self.callback_error = err;
                        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                    };
                }
            }
            return 0;
        }

        fn produce(
            _: ?*c.nghttp2_session,
            id: i32,
            bytes: [*c]u8,
            len: usize,
            flags: [*c]u32,
            _: [*c]c.nghttp2_data_source,
            pointer: ?*anyopaque,
        ) callconv(.c) isize {
            const self = owner(pointer);
            const count = (self.handler.produce(id, bytes[0..len]) catch |err| return self.failed(id, err)) orelse
                return c.NGHTTP2_ERR_DEFERRED;
            std.debug.assert(count <= len);
            if (count == 0 or (if (comptime @hasDecl(
                Handler,
                "producedEnd",
            )) self.handler.producedEnd(id) else false))
                flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
            return @intCast(count);
        }
    };
}

fn field(name: []const u8, value: []const u8) c.nghttp2_nv {
    return .{
        .name = @constCast(name.ptr),
        .namelen = name.len,
        .value = @constCast(value.ptr),
        .valuelen = value.len,
        .flags = 0,
    };
}

fn mapped(code: isize) Error {
    @branchHint(.cold);
    return switch (code) {
        c.NGHTTP2_ERR_NOMEM => error.OutOfMemory,
        c.NGHTTP2_ERR_INVALID_ARGUMENT,
        c.NGHTTP2_ERR_INVALID_STATE,
        c.NGHTTP2_ERR_STREAM_CLOSED,
        => error.InvalidOperation,
        else => error.Protocol,
    };
}

fn check(code: c_int) Error!void {
    if (code < 0) return mapped(code);
}

const Memory = struct {
    gpa: std.mem.Allocator,
    limit: usize,
    used: usize = 0,

    const Prefix = extern struct {
        len: usize,
        padding: usize = 0,
    };

    fn callbacks(self: *Memory) c.nghttp2_mem {
        return .{
            .mem_user_data = self,
            .malloc = allocate,
            .free = release,
            .calloc = zeroed,
            .realloc = resize,
        };
    }

    fn owner(pointer: ?*anyopaque) *Memory {
        return @ptrCast(@alignCast(pointer.?));
    }

    fn allocation(pointer: *anyopaque) []align(16) u8 {
        const bytes: [*]align(16) u8 = @ptrFromInt(@intFromPtr(pointer) - @sizeOf(Prefix));
        const prefix: *Prefix = @ptrCast(bytes);
        return bytes[0..prefix.len];
    }

    fn allocate(size: usize, pointer: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self = owner(pointer);
        const len = std.math.add(usize, size, @sizeOf(Prefix)) catch return null;
        if (len > self.limit - self.used) return null;
        const bytes = self.gpa.alignedAlloc(u8, .@"16", len) catch return null;
        const prefix: *Prefix = @ptrCast(bytes.ptr);
        prefix.* = .{ .len = len };
        self.used += len;
        return bytes.ptr + @sizeOf(Prefix);
    }

    fn release(pointer: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const bytes = allocation(pointer orelse return);
        const self = owner(user);
        self.used -= bytes.len;
        self.gpa.free(bytes);
    }

    fn zeroed(count: usize, size: usize, user: ?*anyopaque) callconv(.c) ?*anyopaque {
        const len = std.math.mul(usize, count, size) catch return null;
        const pointer = allocate(len, user) orelse return null;
        @memset(@as([*]u8, @ptrCast(pointer))[0..len], 0);
        return pointer;
    }

    fn resize(pointer: ?*anyopaque, size: usize, user: ?*anyopaque) callconv(.c) ?*anyopaque {
        const old = allocation(pointer orelse return allocate(size, user));
        // Charge peak allocation, not just the final size, while copying.
        const next = allocate(size, user) orelse return null;
        const len = @min(size, old.len - @sizeOf(Prefix));
        @memcpy(@as([*]u8, @ptrCast(next))[0..len], old[@sizeOf(Prefix)..][0..len]);
        release(pointer, user);
        return next;
    }
};

const Probe = struct {
    streams: [8]Stream = @splat(.{}),
    reject_body: bool = false,

    const Stream = struct {
        opened: bool = false,
        head_ready: bool = false,
        ended: bool = false,
        close_code: ?u32 = null,
        path: [32]u8 = undefined,
        path_len: usize = 0,
        body_bytes: usize = 0,
        ready: bool = false,
        response: []const u8 = "",
    };

    fn stream(self: *Probe, id: i32) *Stream {
        return &self.streams[@intCast(@divTrunc(id, 2))];
    }

    pub fn begin(self: *Probe, id: i32, trailers: bool) Error!void {
        if (id <= 0 or id >= 16) return error.RefusedStream;
        if (!trailers) self.stream(id).opened = true;
    }

    pub fn header(self: *Probe, id: i32, name: []const u8, value: []const u8) Error!void {
        if (std.mem.eql(u8, name, ":path")) {
            const target = self.stream(id);
            if (value.len > target.path.len) return error.HeaderListTooLarge;
            @memcpy(target.path[0..value.len], value);
            target.path_len = value.len;
        }
    }

    pub fn head(self: *Probe, id: i32, _: bool) Error!void {
        self.stream(id).head_ready = true;
    }

    pub fn body(self: *Probe, id: i32, bytes: []const u8) Error!void {
        if (self.reject_body) return error.RefusedStream;
        self.stream(id).body_bytes += bytes.len;
    }

    pub fn end(self: *Probe, id: i32) Error!void {
        self.stream(id).ended = true;
    }

    pub fn closed(self: *Probe, id: i32, code: u32) void {
        if (id > 0 and id < 16) self.stream(id).close_code = code;
    }

    pub fn produce(self: *Probe, id: i32, destination: []u8) Error!?usize {
        const target = self.stream(id);
        if (!target.ready) return null;
        const count = @min(destination.len, target.response.len);
        @memcpy(destination[0..count], target.response[0..count]);
        target.response = target.response[count..];
        return count;
    }
};

const test_headers = "\x82\x87\x84\x01\x09localhost";

fn inputFrame(session: *Session(Probe), kind: u8, flags: u8, id: u32, payload: []const u8) !void {
    var header: [9]u8 = undefined;
    std.mem.writeInt(u24, header[0..3], @intCast(payload.len), .big);
    header[3] = kind;
    header[4] = flags;
    std.mem.writeInt(u32, header[5..9], id, .big);
    // Split framing and HPACK at every possible byte boundary.
    for (&header) |*byte| try std.testing.expectEqual(@as(usize, 1), try session.receive(byte[0..1]));
    for (payload) |*byte| try std.testing.expectEqual(@as(usize, 1), try session.receive(byte[0..1]));
}

fn preface(session: *Session(Probe)) !void {
    const bytes = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    try std.testing.expectEqual(bytes.len, try session.receive(bytes));
    try inputFrame(session, c.NGHTTP2_SETTINGS, 0, 0, "");
}

test "http2 multiplexes responses without waiting for an earlier stream" {
    var handler: Probe = .{};
    var session: Session(Probe) = undefined;
    try session.init(std.testing.allocator, &handler, .{});
    defer session.deinit();
    try preface(&session);
    try inputFrame(&session, c.NGHTTP2_HEADERS, 5, 1, test_headers);
    try inputFrame(&session, c.NGHTTP2_HEADERS, 5, 3, test_headers);
    for ([_]i32{ 1, 3 }) |id| {
        const stream = handler.stream(id);
        try std.testing.expect(stream.head_ready and stream.ended);
        try std.testing.expectEqualStrings("/", stream.path[0..stream.path_len]);
        try session.respond(id, 200, &.{}, true);
    }
    handler.stream(3).ready = true;
    handler.stream(3).response = "second";
    var body_bytes: usize = 0;
    while (true) {
        const bytes = try session.output();
        if (bytes.len == 0) break;
        if (bytes[3] == c.NGHTTP2_DATA) {
            try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[5..9], .big));
            if (bytes.len > 9) try std.testing.expectEqualStrings("second", bytes[9..]);
            body_bytes += bytes.len - 9;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), body_bytes);
    try std.testing.expectEqual(@as(?u32, 0), handler.stream(3).close_code);
    try std.testing.expectEqual(@as(?u32, null), handler.stream(1).close_code);
    handler.stream(1).ready = true;
    handler.stream(1).response = "first";
    try session.resumeBody(1);
    body_bytes = 0;
    while (true) {
        const bytes = try session.output();
        if (bytes.len == 0) break;
        if (bytes[3] == c.NGHTTP2_DATA) {
            try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[5..9], .big));
            if (bytes.len > 9) try std.testing.expectEqualStrings("first", bytes[9..]);
            body_bytes += bytes.len - 9;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), body_bytes);
    try std.testing.expectEqual(@as(?u32, 0), handler.stream(1).close_code);
}

test "http2 credits input only after consumption and resets one stream" {
    var handler: Probe = .{};
    var session: Session(Probe) = undefined;
    try session.init(std.testing.allocator, &handler, .{ .stream_window = 8 });
    defer session.deinit();
    try preface(&session);
    while ((try session.output()).len != 0) {}
    try inputFrame(&session, c.NGHTTP2_SETTINGS, 1, 0, "");
    try inputFrame(&session, c.NGHTTP2_HEADERS, 4, 1, test_headers);
    try inputFrame(&session, c.NGHTTP2_HEADERS, 5, 3, test_headers);
    try inputFrame(&session, c.NGHTTP2_DATA, 0, 1, "abcdefgh");
    try std.testing.expectEqual(@as(usize, 8), handler.stream(1).body_bytes);
    try std.testing.expect(!handler.stream(1).ended);
    try std.testing.expectEqual(@as(usize, 0), (try session.output()).len);
    try session.consume(1, 8);
    const update = try session.output();
    try std.testing.expectEqual(@as(u8, c.NGHTTP2_WINDOW_UPDATE), update[3]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, update[5..9], .big));
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, update[9..13], .big));
    try inputFrame(&session, c.NGHTTP2_DATA, 1, 1, "xyz");
    try std.testing.expectEqual(@as(usize, 11), handler.stream(1).body_bytes);
    try std.testing.expect(handler.stream(1).ended);
    try session.reset(1);
    try session.respond(3, 204, &.{}, false);
    while ((try session.output()).len != 0) {}
    try std.testing.expectEqual(@as(?u32, c.NGHTTP2_CANCEL), handler.stream(1).close_code);
    try std.testing.expectEqual(@as(?u32, 0), handler.stream(3).close_code);
}

test "http2 bounds decoded headers and session allocations" {
    var handler: Probe = .{};
    var session: Session(Probe) = undefined;
    try std.testing.expectError(error.OutOfMemory, session.init(
        std.testing.allocator,
        &handler,
        .{ .session_bytes = 1 },
    ));
    try std.testing.expectEqual(@as(usize, 0), session.memory.used);
    try session.init(std.testing.allocator, &handler, .{ .header_bytes = 100 });
    defer session.deinit();
    try preface(&session);
    try inputFrame(&session, c.NGHTTP2_HEADERS, 5, 1, test_headers);
    while ((try session.output()).len != 0) {}
    try std.testing.expect(!handler.stream(1).ended);
    try std.testing.expectEqual(@as(?u32, c.NGHTTP2_PROTOCOL_ERROR), handler.stream(1).close_code);
}

test "http2 initialization unwinds every allocator failure" {
    const allocation_test = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var handler: Probe = .{};
            var session: Session(Probe) = undefined;
            try session.init(gpa, &handler, .{});
            defer session.deinit();
            try preface(&session);
            try inputFrame(&session, c.NGHTTP2_HEADERS, 5, 1, test_headers);
            try session.respond(1, 204, &.{}, false);
            while ((try session.output()).len != 0) {}
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocation_test.run, .{});
}

test "http2 refuses excess streams before settings acknowledgement" {
    var handler: Probe = .{};
    var session: Session(Probe) = undefined;
    try session.init(std.testing.allocator, &handler, .{ .streams = 1 });
    defer session.deinit();
    try preface(&session);
    try inputFrame(&session, c.NGHTTP2_HEADERS, 5, 1, test_headers);
    try inputFrame(&session, c.NGHTTP2_HEADERS, 5, 3, test_headers);
    try std.testing.expect(handler.stream(1).ended);
    try std.testing.expect(!handler.stream(3).opened);
    var refused = false;
    while (true) {
        const bytes = try session.output();
        if (bytes.len == 0) break;
        if (bytes[3] == c.NGHTTP2_RST_STREAM) {
            try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[5..9], .big));
            try std.testing.expectEqual(@as(u32, c.NGHTTP2_REFUSED_STREAM), std.mem.readInt(
                u32,
                bytes[9..13],
                .big,
            ));
            refused = true;
        }
    }
    try std.testing.expect(refused);
    try session.shutdown(1);
    const goaway = try session.output();
    try std.testing.expectEqual(@as(u8, c.NGHTTP2_GOAWAY), goaway[3]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, goaway[9..13], .big));
    try session.respond(1, 204, &.{}, false);
    while ((try session.output()).len != 0) {}
    try std.testing.expectEqual(@as(?u32, 0), handler.stream(1).close_code);
}

test "http2 response waits for peer window credit" {
    var handler: Probe = .{};
    var session: Session(Probe) = undefined;
    try session.init(std.testing.allocator, &handler, .{});
    defer session.deinit();
    try preface(&session);
    try inputFrame(&session, c.NGHTTP2_SETTINGS, 0, 0, "\x00\x04\x00\x00\x00\x00");
    try inputFrame(&session, c.NGHTTP2_HEADERS, 5, 1, test_headers);
    handler.stream(1).ready = true;
    handler.stream(1).response = "abcdef";
    try session.respond(1, 200, &.{}, true);
    while (true) {
        const bytes = try session.output();
        if (bytes.len == 0) break;
        try std.testing.expect(bytes[3] != c.NGHTTP2_DATA);
    }
    try inputFrame(&session, c.NGHTTP2_WINDOW_UPDATE, 0, 1, "\x00\x00\x00\x03");
    const first = try session.output();
    try std.testing.expectEqual(@as(u8, c.NGHTTP2_DATA), first[3]);
    try std.testing.expectEqualStrings("abc", first[9..]);
    try std.testing.expectEqual(@as(usize, 0), (try session.output()).len);
    try inputFrame(&session, c.NGHTTP2_WINDOW_UPDATE, 0, 1, "\x00\x00\x00\x04");
    const second = try session.output();
    try std.testing.expectEqualStrings("def", second[9..]);
    while ((try session.output()).len != 0) {}
    try std.testing.expectEqual(@as(?u32, 0), handler.stream(1).close_code);
}

test "http2 body rejection never dispatches request completion" {
    var handler: Probe = .{ .reject_body = true };
    var session: Session(Probe) = undefined;
    try session.init(std.testing.allocator, &handler, .{});
    defer session.deinit();
    try preface(&session);
    try inputFrame(&session, c.NGHTTP2_HEADERS, 4, 1, test_headers);
    try inputFrame(&session, c.NGHTTP2_DATA, 1, 1, "rejected");
    while ((try session.output()).len != 0) {}
    try std.testing.expect(!handler.stream(1).ended);
    try std.testing.expectEqual(@as(?u32, c.NGHTTP2_REFUSED_STREAM), handler.stream(1).close_code);
}
