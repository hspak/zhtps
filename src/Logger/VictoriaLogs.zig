//! Bounded JSON-line batches sent off the event loops through an owned pipe.

const std = @import("std");
const linux = std.os.linux;
const Logger = @import("../Logger.zig");
const Metrics = @import("../Metrics.zig");
const platform = @import("../platform.zig");
const VictoriaLogs = @This();

io: std.Io,
origin: std.Uri,
read_fd: linux.fd_t,
write_fd: linux.fd_t,
metrics: *Metrics,
host: [65]u8,
host_len: usize,
instance: [128]u8 = undefined,
instance_len: usize = 0,
batch: [batch_bytes]u8 = undefined,
batch_len: usize = 0,
batch_records: usize = 0,
final_loggers: []*Logger = &.{},
finishing: std.atomic.Value(bool) = .init(false),
selection: Selection = undefined,
results: [2]Completion = undefined,
started: bool = false,

const batch_bytes = 256 * 1024;
const Completion = union(enum) {
    drained: void,
    deadline: std.Io.Cancelable!void,
};
const Selection = std.Io.Select(Completion);
const PostCompletion = union(enum) {
    response: std.http.Client.FetchError!std.http.Client.FetchResult,
    deadline: std.Io.Cancelable!void,
};

pub const UrlError = error{InvalidVictoriaLogsUrl};
pub const IdentityError = error{IdentityTooLong};
pub const InitError = UrlError || platform.Error;
pub const StartError = std.Io.ConcurrentError;

/// Accepts an HTTP(S) origin with an optional trailing slash. Rejects credentials,
/// paths, queries and fragments rather than silently changing their meaning.
/// The returned URI borrows url. No DNS lookup or network access occurs.
pub fn parseOrigin(url: []const u8) UrlError!std.Uri {
    for (url) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidVictoriaLogsUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidVictoriaLogsUrl;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or uri.port == 0)
        return error.InvalidVictoriaLogsUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.InvalidVictoriaLogsUrl;
    // Uri.parse is deliberately permissive; validate before passing its host
    // to HTTP APIs that assume a validated hostname or bracketed IP literal.
    const host = uri.host.?.percent_encoded;
    if (host[0] == '[') {
        _ = std.Io.net.IpAddress.parseLiteral(host) catch return error.InvalidVictoriaLogsUrl;
    } else std.Io.net.HostName.validate(host) catch return error.InvalidVictoriaLogsUrl;
    const authority = url[uri.scheme.len + 3 .. url.len - path.len];
    const host_end = if (uri.port != null) std.mem.lastIndexOfScalar(u8, authority, ':').? else authority.len;
    if (!std.mem.eql(u8, host, authority[0..host_end])) return error.InvalidVictoriaLogsUrl;
    return uri;
}

/// Owns both pipe descriptors. Borrows io, url and metrics until deinit; io must
/// support concurrent, cancellable network operations. Keep self at its final address.
pub fn init(self: *VictoriaLogs, io: std.Io, url: []const u8, metrics: *Metrics) InitError!void {
    const origin = try parseOrigin(url);
    var descriptors: [2]linux.fd_t = undefined;
    _ = try platform.check(linux.pipe2(&descriptors, .{ .CLOEXEC = true }));
    errdefer platform.close(descriptors[0]);
    errdefer platform.close(descriptors[1]);
    // Only the read end is nonblocking. io_uring waits for pipe capacity on the
    // write end while the event loop continues serving requests.
    _ = try platform.check(linux.fcntl(descriptors[0], linux.F.SETFL, @as(u32, @bitCast(linux.O{
        .NONBLOCK = true,
    }))));
    const uts = std.posix.uname();
    const host = std.mem.sliceTo(&uts.nodename, 0);
    self.* = .{
        .io = io,
        .origin = origin,
        .read_fd = descriptors[0],
        .write_fd = descriptors[1],
        .metrics = metrics,
        .host = undefined,
        .host_len = host.len,
    };
    @memcpy(self.host[0..host.len], host);
}

/// Sets the bound public listener identity before start. The host/instance pair
/// identifies this server; request-varying fields never participate in streams.
pub fn setInstance(self: *VictoriaLogs, address: []const u8, port: u16) IdentityError!void {
    const instance = std.fmt.bufPrint(&self.instance, "[{s}]:{d}", .{ address, port }) catch
        return error.IdentityTooLong;
    self.instance_len = instance.len;
}

/// Borrows identity strings until deinit.
pub fn source(self: *const VictoriaLogs) Logger.Source {
    return .{
        .host = self.host[0..self.host_len],
        .instance = self.instance[0..self.instance_len],
    };
}

/// Starts a background sender; no HTTP request runs on the calling thread.
pub fn start(self: *VictoriaLogs) StartError!void {
    std.debug.assert(!self.started and self.write_fd >= 0);
    self.selection = .init(self.io, &self.results);
    try self.selection.concurrent(.drained, run, .{self});
    self.started = true;
}

/// Call after all producers and their kernel writes have stopped. Borrows their
/// remaining queues during this call and gives the entire final drain two seconds.
/// Failed, timed-out and overflowed deliveries are best effort, without retries.
pub fn finish(self: *VictoriaLogs, loggers: []*Logger) void {
    self.final_loggers = loggers;
    self.finishing.store(true, .release);
    platform.close(self.write_fd);
    self.write_fd = -1;
    if (self.started) {
        self.selection.concurrent(.deadline, std.Io.sleep, .{
            self.io,
            .fromSeconds(2),
            .awake,
        }) catch {
            self.selection.cancelDiscard();
            self.started = false;
        };
        if (self.started) _ = self.selection.await() catch {};
        self.selection.cancelDiscard();
        self.started = false;
    }
    var discarded: [4096]u8 = undefined;
    while (true) {
        const result = linux.read(self.read_fd, &discarded, discarded.len);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) break;
        self.metrics.add(.log_dropped_total, std.mem.count(u8, discarded[0..result], "\n"));
    }
    for (loggers) |logger| {
        logger.metrics.add(.log_dropped_total, logger.count);
        while (logger.peek() != null) logger.consume();
    }
}

/// Releases owned descriptors. Call finish first if start succeeded.
pub fn deinit(self: *VictoriaLogs) void {
    std.debug.assert(!self.started);
    if (self.write_fd >= 0) platform.close(self.write_fd);
    platform.close(self.read_fd);
    self.* = undefined;
}

fn run(self: *VictoriaLogs) void {
    // Independent allocator: serving applications may be using the caller's
    // allocator concurrently under the server's own lock.
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = self.io };
    defer client.deinit();
    defer self.dropBatch();
    self.drain(&client) catch |err| {
        if (err != error.Canceled) self.metrics.add(.log_write_errors_total, 1);
    };
}

fn drain(self: *VictoriaLogs, client: *std.http.Client) !void {
    while (true) {
        try self.io.checkCancel();
        const result = linux.read(self.read_fd, self.batch[self.batch_len..].ptr, batch_bytes - self.batch_len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) break;
                self.batch_records += std.mem.count(u8, self.batch[self.batch_len..][0..result], "\n");
                self.batch_len += result;
                if (self.batch_len < batch_bytes) continue;
            },
            .INTR => continue,
            .AGAIN => {
                if (self.batch_len == 0) {
                    try std.Io.sleep(self.io, .fromMilliseconds(50), .awake);
                    continue;
                }
            },
            else => {
                self.metrics.add(.log_write_errors_total, 1);
                return;
            },
        }
        try self.flush(client);
    }
    // EOF follows finish's close after all worker threads have joined.
    std.debug.assert(self.finishing.load(.acquire));
    for (self.final_loggers) |logger| {
        while (logger.peek()) |slot| {
            if (batch_bytes - self.batch_len < slot.len) try self.flush(client);
            @memcpy(self.batch[self.batch_len..][0..slot.len], slot.bytes[0..slot.len]);
            self.batch_len += slot.len;
            self.batch_records += 1;
            logger.consume();
        }
    }
    if (self.batch_len != 0) try self.flush(client);
}

fn flush(self: *VictoriaLogs, client: *std.http.Client) !void {
    const end = if (std.mem.lastIndexOfScalar(u8, self.batch[0..self.batch_len], '\n')) |index|
        index + 1
    else
        return;
    // The client caches its CA bundle and verification time. Keep certificate
    // validity checks current when a long-running sender reconnects.
    if (client.now != null) client.now = std.Io.Clock.real.now(self.io);
    var uri = self.origin;
    uri.path = .{ .percent_encoded = "/insert/jsonline" };
    uri.query = .{ .percent_encoded = "_msg_field=event&_time_field=timestamp_ns&_stream_fields=app,host,instance" };
    var results: [2]PostCompletion = undefined;
    var selection: std.Io.Select(PostCompletion) = .init(self.io, &results);
    defer selection.cancelDiscard();
    try selection.concurrent(.response, std.http.Client.fetch, .{ client, .{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = self.batch[0..end],
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = "application/stream+json" } },
    } });
    try selection.concurrent(.deadline, std.Io.sleep, .{
        self.io,
        .fromSeconds(2),
        .awake,
    });
    const succeeded = switch (try selection.await()) {
        .response => |response| if (response) |result| result.status.class() == .success else |_| false,
        .deadline => false,
    };
    // The request must stop borrowing the batch before the buffer is reused.
    selection.cancelDiscard();
    if (!succeeded) {
        self.metrics.add(.log_write_errors_total, 1);
        self.metrics.add(.log_dropped_total, self.batch_records);
    }
    std.mem.copyForwards(u8, &self.batch, self.batch[end..self.batch_len]);
    self.batch_len -= end;
    self.batch_records = 0;
    if (!succeeded) try std.Io.sleep(self.io, .fromSeconds(1), .awake);
}

fn dropBatch(self: *VictoriaLogs) void {
    self.metrics.add(.log_dropped_total, self.batch_records);
    self.batch_records = 0;
    self.batch_len = 0;
}
