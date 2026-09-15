//! Per-worker HTTP/2 budget sharing the server's allocator serialization lock.

const std = @import("std");
const log = std.log.scoped(.server_http2_allocator);
const Http2Allocator = @This();

gpa: std.mem.Allocator,
io: std.Io,
mutex: *std.Io.Mutex,
limit: usize,
used: usize = 0,

/// Borrows this budget and its mutex until every returned allocation is freed.
/// Only the owning worker may use it; the mutex serializes the shared backing allocator.
pub fn allocator(self: *Http2Allocator) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    } };
}

fn alloc(
    pointer: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    address: usize,
) ?[*]u8 {
    const self: *Http2Allocator = @ptrCast(@alignCast(pointer));
    if (len > self.limit - self.used) return null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const bytes = self.gpa.rawAlloc(
        len,
        alignment,
        address,
    ) orelse return null;
    self.used += len;
    return bytes;
}

fn free(
    pointer: *anyopaque,
    bytes: []u8,
    alignment: std.mem.Alignment,
    address: usize,
) void {
    const self: *Http2Allocator = @ptrCast(@alignCast(pointer));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.gpa.rawFree(
        bytes,
        alignment,
        address,
    );
    self.used -= bytes.len;
}
