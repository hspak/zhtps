//! Owned response bytes and completion records borrowed from a worker's fixed pool.

const std = @import("std");
const ResponseBatch = @This();

/// Wire bytes grow from the front; copied User-Agent values grow from the back.
bytes: [4096]u8 = undefined,
responses: [16]Response = undefined,
next: ?*ResponseBatch = null,
deadline: u64 = 0,
resume_deadline: u64 = 0,
len: u16 = 0,
metadata_start: u16 = 4096,
sent: u16 = 0,
count: u8 = 0,
completed: u8 = 0,
sending: bool = false,
send_more: bool = false,
resume_response: bool = false,

/// Owns log metadata so resetting the parser cannot change a queued record.
/// Each entry owns one admission permit until completion or batch abort.
pub const Response = struct {
    started_ns: u64,
    method: [8]u8 = undefined,
    user_agent: ?struct { start: u16, len: u16 } = null,
    end: u16 = 0,
    body_bytes: u16,
    status: u16,
    method_len: u8 = 0,
};

/// Space available for both response bytes and copied log metadata.
pub fn remainingCapacity(batch: *const ResponseBatch) usize {
    return batch.metadata_start - batch.len;
}

/// Copies a response and its User-Agent before the parser is reused. Null omits
/// the header from its log record. Asserts the response, header, and entry fit.
pub fn append(
    batch: *ResponseBatch,
    bytes: []const u8,
    response: Response,
    user_agent: ?[]const u8,
) void {
    std.debug.assert(!batch.sending and batch.count < batch.responses.len);
    std.debug.assert(bytes.len > 0 and bytes.len <= batch.remainingCapacity());
    const user_agent_len = if (user_agent) |header| header.len else 0;
    std.debug.assert(user_agent_len <= batch.remainingCapacity() - bytes.len);
    @memcpy(batch.bytes[batch.len..][0..bytes.len], bytes);
    batch.len += @intCast(bytes.len);
    const entry = &batch.responses[batch.count];
    entry.* = response;
    entry.end = batch.len;
    entry.user_agent = null;
    if (user_agent) |header| {
        batch.metadata_start -= @intCast(header.len);
        @memcpy(batch.bytes[batch.metadata_start..][0..header.len], header);
        entry.user_agent = .{ .start = batch.metadata_start, .len = @intCast(header.len) };
    }
    batch.count += 1;
}
