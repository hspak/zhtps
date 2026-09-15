//! Owned response bytes and completion records borrowed from a worker's fixed pool.

const std = @import("std");
const log = std.log.scoped(.response_batch);
const ResponseBatch = @This();

bytes: [4096]u8 = undefined,
responses: [16]Response = undefined,
next: ?*ResponseBatch = null,
deadline: u64 = 0,
resume_deadline: u64 = 0,
len: u16 = 0,
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
    request_id: u64,
    method: [8]u8 = undefined,
    end: u16 = 0,
    body_bytes: u16,
    status: u16,
    method_len: u8 = 0,
};

/// Copies one complete serialization and its owned metadata. Asserts both fit.
pub fn append(
    batch: *ResponseBatch,
    bytes: []const u8,
    response: Response,
) void {
    std.debug.assert(!batch.sending and batch.count < batch.responses.len);
    std.debug.assert(bytes.len > 0 and bytes.len <= batch.bytes.len - batch.len);
    @memcpy(batch.bytes[batch.len..][0..bytes.len], bytes);
    batch.len += @intCast(bytes.len);
    batch.responses[batch.count] = response;
    batch.responses[batch.count].end = batch.len;
    batch.count += 1;
}
