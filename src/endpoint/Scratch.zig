//! Bounded request allocation with checked offsets in every optimization mode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const log = std.log.scoped(.endpoint_scratch);
const Scratch = @This();

buffer: []u8 = &.{},
/// Always at most buffer.len. Only the exchange may reset this cursor.
end_index: usize = 0,

/// Borrows buffer; keep both it and scratch at stable addresses until cleanup ends.
pub fn init(scratch: *Scratch, buffer: []u8) void {
    scratch.* = .{ .buffer = buffer };
}

/// Valid through request cleanup, including between hooks. Not thread safe.
/// Allocations are reclaimed automatically when the exchange finishes cleanup.
pub fn allocator(scratch: *Scratch) Allocator {
    return .{
        .ptr = scratch,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const scratch: *Scratch = @ptrCast(@alignCast(ptr));
    const address = std.math.add(usize, @intFromPtr(scratch.buffer.ptr), scratch.end_index) catch
        return null;
    const mask = alignment.toByteUnits() - 1;
    const padding = (0 -% address) & mask;
    if (padding > scratch.buffer.len - scratch.end_index) return null;
    const start = scratch.end_index + padding;
    if (len > scratch.buffer.len - start) return null;
    scratch.end_index = start + len;
    return scratch.buffer.ptr + start;
}

fn resize(
    ptr: *anyopaque,
    bytes: []u8,
    _: Alignment,
    new_len: usize,
    _: usize,
) bool {
    const scratch: *Scratch = @ptrCast(@alignCast(ptr));
    const start = scratch.offset(bytes);
    if (bytes.len != scratch.end_index - start) return new_len <= bytes.len;
    if (new_len > scratch.buffer.len - start) return false;
    scratch.end_index = start + new_len;
    return true;
}

fn remap(
    ptr: *anyopaque,
    bytes: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    return if (resize(ptr, bytes, alignment, new_len, return_address)) bytes.ptr else null;
}

fn free(ptr: *anyopaque, bytes: []u8, _: Alignment, _: usize) void {
    const scratch: *Scratch = @ptrCast(@alignCast(ptr));
    const start = scratch.offset(bytes);
    if (bytes.len == scratch.end_index - start) scratch.end_index = start;
}

fn offset(scratch: *const Scratch, bytes: []u8) usize {
    assert(@intFromPtr(bytes.ptr) >= @intFromPtr(scratch.buffer.ptr));
    const start = @intFromPtr(bytes.ptr) - @intFromPtr(scratch.buffer.ptr);
    assert(start <= scratch.end_index);
    assert(bytes.len <= scratch.end_index - start);
    return start;
}

test "scratch rejects wrapping allocation resize and remap without consuming capacity" {
    const testing = std.testing;
    var buffer: [64]u8 align(16) = undefined;
    var scratch: Scratch = .{};
    scratch.init(&buffer);
    const gpa = scratch.allocator();
    _ = try gpa.alloc(u8, 8);
    const bytes = try gpa.dupe(u8, "retained");
    const saved = scratch.end_index;
    const huge = std.math.maxInt(usize);
    try testing.expectError(error.OutOfMemory, gpa.alloc(u8, huge));
    try testing.expectError(error.OutOfMemory, gpa.alignedAlloc(u8, .@"16", huge));
    try testing.expectError(error.OutOfMemory, gpa.alloc(u64, huge));
    try testing.expect(!gpa.resize(bytes, huge));
    try testing.expect(gpa.remap(bytes, huge) == null);
    try testing.expectError(error.OutOfMemory, gpa.realloc(bytes, huge));
    try testing.expectEqual(saved, scratch.end_index);
    try testing.expectEqualStrings("retained", bytes);
    const rest = try gpa.alloc(u8, buffer.len - saved);
    try testing.expectError(error.OutOfMemory, gpa.alloc(u8, 1));
    gpa.free(rest);
    try testing.expectEqual(saved, scratch.end_index);
}

test "scratch accounts for alignment and reuses only the last allocation" {
    const testing = std.testing;
    var buffer: [64]u8 align(16) = undefined;
    var scratch: Scratch = .{};
    scratch.init(buffer[1..]);
    const gpa = scratch.allocator();
    const first = try gpa.dupe(u8, "first");
    const aligned = try gpa.alignedAlloc(u8, .@"16", 16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 16);
    try testing.expectEqual(@as(usize, 31), scratch.end_index);
    try testing.expect(!gpa.resize(first, 6));
    try testing.expect(gpa.resize(first, 3));
    try testing.expectEqual(@as(usize, 31), scratch.end_index);
    try testing.expect(gpa.resize(aligned, 32));
    try testing.expectEqual(@as(usize, 47), scratch.end_index);
    const grown: []align(16) u8 = aligned.ptr[0..32];
    try testing.expect(!gpa.resize(grown, 49));
    gpa.free(grown);
    try testing.expectEqual(@as(usize, 15), scratch.end_index);
    try testing.expectEqualStrings("first", first);
    const saved = scratch.end_index;
    const huge_alignment: Alignment = @enumFromInt(@bitSizeOf(usize) - 1);
    try testing.expect(gpa.rawAlloc(1, huge_alignment, @returnAddress()) == null);
    try testing.expectEqual(saved, scratch.end_index);
}

test "scratch satisfies the allocator contract" {
    const buffer = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(buffer);
    var scratch: Scratch = .{};
    scratch.init(buffer);
    try std.heap.testAllocator(scratch.allocator());
    try std.heap.testAllocatorAligned(scratch.allocator());
    try std.heap.testAllocatorLargeAlignment(scratch.allocator());
    try std.heap.testAllocatorAlignedShrink(scratch.allocator());
}
