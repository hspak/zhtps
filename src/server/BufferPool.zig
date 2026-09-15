//! Worker-owned reuse of fixed-size buffers; allocation only occurs on cache misses.

const std = @import("std");
const BufferPool = @This();

size: usize = 0,
free: ?*Block = null,
cached: usize = 0,
borrowed: usize = 0,

pub const cache_limit = 64;
const cache_bytes = 4 * 1024 * 1024;
const large_cache_limit = 8;

pub const Block = struct {
    bytes: []u8,
    next: ?*Block = null,
};

/// Transfers a cached block to the caller, or returns null without allocating.
/// The caller must eventually return the block through put.
pub fn take(pool: *BufferPool) ?*Block {
    const block = pool.free orelse return null;
    pool.free = block.next;
    block.next = null;
    pool.cached -= 1;
    pool.borrowed += 1;
    return block;
}

/// Allocates a borrowed block. Callers sharing an allocator must serialize misses.
pub fn create(pool: *BufferPool, gpa: std.mem.Allocator) std.mem.Allocator.Error!*Block {
    const block = try gpa.create(Block);
    errdefer gpa.destroy(block);
    block.* = .{ .bytes = try gpa.alloc(u8, pool.size) };
    pool.borrowed += 1;
    return block;
}

/// Retains at most 64 blocks within 4 MiB, or up to eight blocks when that
/// allowance exceeds 4 MiB. False transfers an excess block back to the caller,
/// which must destroy it after serializing access to a shared allocator.
pub fn put(pool: *BufferPool, block: *Block) bool {
    std.debug.assert(pool.borrowed > 0 and block.bytes.len == pool.size);
    pool.borrowed -= 1;
    if (pool.cached == cache_limit or
        (pool.cached >= large_cache_limit and pool.size > cache_bytes / (pool.cached + 1)))
        return false;
    block.next = pool.free;
    pool.free = block;
    pool.cached += 1;
    return true;
}

/// Frees an excess block returned by put; no references may remain.
pub fn destroy(gpa: std.mem.Allocator, block: *Block) void {
    gpa.free(block.bytes);
    gpa.destroy(block);
}

/// Frees cached buffers. Asserts every borrowed block has been returned.
pub fn deinit(pool: *BufferPool, gpa: std.mem.Allocator) void {
    std.debug.assert(pool.borrowed == 0);
    while (pool.free) |block| {
        pool.free = block.next;
        destroy(gpa, block);
    }
    pool.* = undefined;
}

test "buffer reuse preserves independent borrowers and bounds retained storage" {
    const testing = std.testing;
    var pool: BufferPool = .{ .size = 128 };
    defer pool.deinit(testing.allocator);
    var blocks: [cache_limit + 2]*Block = undefined;
    var borrowed: usize = 0;
    defer for (blocks[0..borrowed]) |block| {
        if (!pool.put(block)) destroy(testing.allocator, block);
    };
    for (&blocks, 0..) |*block, index| {
        block.* = try pool.create(testing.allocator);
        borrowed += 1;
        @memset(block.*.bytes, @intCast(index));
    }
    for (blocks, 0..) |block, index| {
        try testing.expectEqual(@as(u8, @intCast(index)), block.bytes[0]);
    }
    while (borrowed > 0) {
        borrowed -= 1;
        const block = blocks[borrowed];
        if (!pool.put(block)) destroy(testing.allocator, block);
    }
    try testing.expectEqual(cache_limit, pool.cached);
    for (blocks[0..cache_limit]) |*block| {
        block.* = pool.take().?;
        borrowed += 1;
    }
    try testing.expect(pool.take() == null);
    try testing.expectEqual(cache_limit, pool.borrowed);
    while (borrowed > 0) {
        borrowed -= 1;
        const block = blocks[borrowed];
        const retained = pool.put(block);
        if (!retained) destroy(testing.allocator, block);
        try testing.expect(retained);
    }
}

test "buffer allocation failure releases its descriptor and leaves the pool usable" {
    const testing = std.testing;
    var pool: BufferPool = .{ .size = 128 };
    defer pool.deinit(testing.allocator);
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, pool.create(failing.allocator()));
    try testing.expectEqual(@as(usize, 0), pool.borrowed);
    const block = try pool.create(testing.allocator);
    defer if (pool.borrowed > 0) {
        if (!pool.put(block)) destroy(testing.allocator, block);
    };
    try testing.expect(pool.put(block));
    try testing.expect(pool.take().? == block);
    try testing.expect(pool.put(block));
}

test "buffer cache bounds bytes while retaining eight large blocks" {
    const testing = std.testing;
    const cases = .{
        .{ .size = 128 * 1024, .retained = 32 },
        .{ .size = 1024 * 1024, .retained = 8 },
    };
    inline for (cases) |limits| {
        var pool: BufferPool = .{ .size = limits.size };
        defer pool.deinit(testing.allocator);
        var blocks: [limits.retained + 1]*Block = undefined;
        var borrowed: usize = 0;
        defer for (blocks[0..borrowed]) |block| {
            if (!pool.put(block)) destroy(testing.allocator, block);
        };
        for (&blocks) |*block| {
            block.* = try pool.create(testing.allocator);
            borrowed += 1;
        }
        for (blocks) |block| {
            if (!pool.put(block)) destroy(testing.allocator, block);
        }
        borrowed = 0;
        try testing.expectEqual(@as(usize, limits.retained), pool.cached);
    }
}
