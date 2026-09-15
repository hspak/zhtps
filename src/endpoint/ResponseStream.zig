//! Bounded rendezvous between one application producer and its transport worker.

const std = @import("std");
const platform = @import("../platform.zig");
const ResponseStream = @This();

/// Only the producer may access this writer. Its buffer is borrowed through
/// producer completion; writeAll and print copy caller bytes before returning.
writer: std.Io.Writer = .failing,
io: std.Io = undefined,
event_fd: platform.linux.fd_t = -1,
cancellation: *const std.atomic.Value(bool) = undefined,
mutex: std.Io.Mutex = .init,
ready: std.Io.Condition = .init,
publication: std.atomic.Value(Publication) = .init(.writing),
published_len: usize = 0,
/// Producer-owned diagnostic for a writer's WriteFailed error.
write_error: ?Error = null,

pub const Error = error{ Canceled, WakeUnavailable };
pub const Publication = enum(u8) {
    writing,
    ready,
    finished,
    failed,
};

/// Transport-only initialization. Borrows a nonempty buffer, I/O, eventfd and
/// cancellation flag until the executor completion is consumed. Keep at a
/// stable address and run exactly one producer, with no concurrent writer use.
pub fn init(
    stream: *ResponseStream,
    buffer: []u8,
    io: std.Io,
    event_fd: platform.linux.fd_t,
    cancellation: *const std.atomic.Value(bool),
) void {
    std.debug.assert(buffer.len > 0);
    stream.* = .{
        .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain, .flush = flushWriter } },
        .io = io,
        .event_fd = event_fd,
        .cancellation = cancellation,
    };
}

/// Publishes buffered output now and waits for transport capacity. HTTP framing,
/// TLS and peer flow control still apply; this does not acknowledge peer receipt.
/// May block the application lane, never the transport worker. After cancellation
/// returns Canceled, including when no bytes are buffered. Returning from the
/// producer flushes and ends the response automatically.
pub fn flush(stream: *ResponseStream) Error!void {
    stream.mutex.lockUncancelable(stream.io);
    defer stream.mutex.unlock(stream.io);
    if (stream.cancellation.load(.acquire)) return error.Canceled;
    if (stream.writer.end == 0) return;
    stream.published_len = stream.writer.end;
    stream.publication.store(.ready, .release);
    try stream.notify();
    while (stream.publication.load(.acquire) == .ready) {
        if (stream.cancellation.load(.acquire)) return error.Canceled;
        stream.ready.waitUncancelable(stream.io, &stream.mutex);
    }
    if (stream.cancellation.load(.acquire)) return error.Canceled;
    stream.writer.end = 0;
}

/// Transport-only acknowledgement after copying or sending the published bytes.
/// Those bytes must no longer be borrowed when this returns.
pub fn consume(stream: *ResponseStream) void {
    stream.mutex.lockUncancelable(stream.io);
    defer stream.mutex.unlock(stream.io);
    std.debug.assert(stream.publication.load(.acquire) == .ready);
    stream.publication.store(.writing, .release);
    stream.ready.signal(stream.io);
}

/// Transport-only wake after setting the borrowed cancellation flag. Storage
/// remains borrowed until the producer returns and its completion is consumed.
pub fn cancel(stream: *ResponseStream) void {
    stream.mutex.lockUncancelable(stream.io);
    defer stream.mutex.unlock(stream.io);
    stream.ready.signal(stream.io);
}

/// Producer-only successful completion; errors must call fail instead.
pub fn finish(stream: *ResponseStream) Error!void {
    try stream.flush();
    stream.publication.store(.finished, .release);
    try stream.notify();
}

/// Producer-only failure. Discards unflushed bytes and terminates the response
/// without a successful HTTP message boundary.
pub fn fail(stream: *ResponseStream) void {
    @branchHint(.cold);
    stream.publication.store(.failed, .release);
    stream.notify() catch {};
}

fn flushWriter(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const stream: *ResponseStream = @fieldParentPtr("writer", writer);
    stream.flush() catch |err| {
        stream.write_error = err;
        return error.WriteFailed;
    };
}

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    try flushWriter(writer);
    for (data, 0..) |bytes, index| {
        if (index == data.len - 1 and splat == 0) break;
        if (bytes.len == 0) continue;
        const count = @min(bytes.len, writer.buffer.len);
        @memcpy(writer.buffer[0..count], bytes[0..count]);
        writer.end = count;
        return count;
    }
    return 0;
}

fn notify(stream: *ResponseStream) Error!void {
    const one: u64 = 1;
    while (true) {
        const result = platform.linux.write(stream.event_fd, @ptrCast(&one), @sizeOf(u64));
        switch (platform.linux.errno(result)) {
            .SUCCESS, .AGAIN => return,
            .INTR => continue,
            else => return error.WakeUnavailable,
        }
    }
}
