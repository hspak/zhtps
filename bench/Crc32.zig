//! Incremental IEEE CRC32 for upload workloads, with x86 carry-less multiplication.
// The folding and reduction are ported from Go's hash/crc32/crc32_amd64.s.
// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by the BSD license in licenses/go.txt.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.bench_crc32);
const Crc32 = @This();

crc: u32 = 0xffffffff,

const V = @Vector(2, u64);
const Wide = @Vector(8, u64);
// Zig 0.16's native backend cannot encode PCLMULQDQ; LLVM handles both widths.
const has_hardware = builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm;
const has_wide = has_hardware and builtin.cpu.has(.x86, .avx512f);
const Mode = enum(u8) {
    unknown,
    portable,
    pclmul,
    wide,
};
var mode: std.atomic.Value(Mode) = .init(.unknown);
const fold_64: V = .{ 0x154442bd4, 0x1c6e41596 };
const fold_16: V = .{ 0x1751997d0, 0x0ccaa009e };

/// Consume bytes without retaining them. Updates may have arbitrary boundaries.
pub fn update(self: *Crc32, bytes: []const u8) void {
    const selected = available();
    if (selected == .portable or bytes.len < 64) {
        self.updatePortable(bytes);
        return;
    }
    if (comptime has_hardware) {
        const length = bytes.len & ~@as(usize, 15);
        self.crc = fold(
            self.crc,
            bytes[0..length],
            selected,
        );
        self.updatePortable(bytes[length..]);
    } else unreachable;
}

/// Return the current checksum without changing the incremental accumulator.
pub fn final(self: *const Crc32) u32 {
    return ~self.crc;
}

/// Compute the IEEE checksum of a complete byte slice.
pub fn hash(bytes: []const u8) u32 {
    var checksum: Crc32 = .{};
    checksum.update(bytes);
    return checksum.final();
}

fn updatePortable(self: *Crc32, bytes: []const u8) void {
    var checksum: std.hash.Crc32 = .{ .crc = self.crc };
    checksum.update(bytes);
    self.crc = checksum.crc;
}

fn available() Mode {
    if (comptime !has_hardware) return .portable;
    const cached = mode.load(.monotonic);
    if (cached != .unknown) return cached;
    const leaf1 = cpuid(1);
    var selected: Mode = if (leaf1 & (1 << 1) != 0) .pclmul else .portable;
    // The target's AVX512 requirement already includes OS register-state support.
    if (comptime has_wide) {
        if (selected == .pclmul and cpuid(7) & (1 << 10) != 0) selected = .wide;
    }
    mode.store(selected, .monotonic);
    return selected;
}

fn cpuid(leaf: u32) u32 {
    return asm volatile ("cpuid"
        : [ecx] "={ecx}" (-> u32),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (@as(u32, 0)),
        : .{
          .eax = true,
          .ebx = true,
          .edx = true,
        });
}

inline fn multiply(
    left: V,
    right: V,
    comptime selector: u8,
) V {
    return asm (std.fmt.comptimePrint("pclmulqdq ${d}, %[right], %[result]", .{selector})
        : [result] "=x" (-> V),
        : [left] "0" (left),
          [right] "x" (right),
    );
}

inline fn multiplyWide(
    left: Wide,
    right: Wide,
    comptime selector: u8,
) Wide {
    return asm (std.fmt.comptimePrint("vpclmulqdq ${d}, %[right], %[left], %[result]", .{selector})
        : [result] "=v" (-> Wide),
        : [left] "v" (left),
          [right] "v" (right),
    );
}

inline fn load(comptime T: type, bytes: []const u8) T {
    return @as(*align(1) const T, @ptrCast(bytes.ptr)).*;
}

inline fn combine(
    left: V,
    right: V,
    factor: V,
) V {
    return multiply(
        left,
        factor,
        0,
    ) ^ multiply(
        left,
        factor,
        0x11,
    ) ^ right;
}

fn fold(
    initial: u32,
    bytes: []const u8,
    selected: Mode,
) u32 {
    std.debug.assert(bytes.len >= 64 and bytes.len % 16 == 0);
    var lanes: [4]V = undefined;
    var offset: usize = 64;
    var used_wide = false;
    if (comptime has_wide) {
        if (selected == .wide and bytes.len >= 1024) {
            const factor: Wide = .{
                fold_64[0],
                fold_64[1],
                fold_64[0],
                fold_64[1],
                fold_64[0],
                fold_64[1],
                fold_64[0],
                fold_64[1],
            };
            var accumulator = load(Wide, bytes) ^ @as(Wide, .{
                initial,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            });
            while (offset + 64 <= bytes.len) : (offset += 64) {
                accumulator = multiplyWide(
                    accumulator,
                    factor,
                    0,
                ) ^
                    multiplyWide(
                        accumulator,
                        factor,
                        0x11,
                    ) ^ load(Wide, bytes[offset..]);
            }
            lanes = @bitCast(accumulator);
            used_wide = true;
        }
    }
    if (!used_wide) {
        inline for (0..4) |index| lanes[index] = load(V, bytes[index * 16 ..]);
        lanes[0] ^= .{ initial, 0 };
        while (offset + 64 <= bytes.len) : (offset += 64) {
            inline for (0..4) |index|
                lanes[index] = combine(
                    lanes[index],
                    load(V, bytes[offset + index * 16 ..]),
                    fold_64,
                );
        }
    }
    var accumulator = lanes[0];
    inline for (1..4) |index| accumulator = combine(
        accumulator,
        lanes[index],
        fold_16,
    );
    while (offset < bytes.len) : (offset += 16)
        accumulator = combine(
            accumulator,
            load(V, bytes[offset..]),
            fold_16,
        );

    const zero: V = @splat(0);
    accumulator = multiply(
        accumulator,
        fold_16,
        0x10,
    ) ^
        @shuffle(
            u64,
            accumulator,
            zero,
            @Vector(2, i32){ 1, -1 },
        );
    const Words = @Vector(4, u32);
    const shifted: V = @bitCast(@shuffle(
        u32,
        @as(Words, @bitCast(accumulator)),
        @as(Words, @splat(0)),
        @Vector(4, i32){
            1,
            2,
            3,
            -1,
        },
    ));
    const mask: V = @splat(0xffffffff);
    accumulator = multiply(
        accumulator & mask,
        .{ 0x163cd6124, 0 },
        0,
    ) ^ shifted;
    const unreduced = accumulator;
    const polynomial: V = .{ 0x1db710641, 0x1f7011641 };
    accumulator = multiply(
        accumulator & mask,
        polynomial,
        0x10,
    );
    accumulator = multiply(
        accumulator & mask,
        polynomial,
        0,
    ) ^ unreduced;
    return @as(@Vector(4, u32), @bitCast(accumulator))[1];
}

test "IEEE CRC32 matches known vectors and unaligned folding boundaries" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), hash(""));
    try testing.expectEqual(@as(u32, 0xcbf43926), hash("123456789"));
    var storage: [8192 + 32]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(0xf891843);
    random.random().bytes(&storage);
    for (0..32) |offset| {
        for (0..130) |length| {
            const bytes = storage[offset..][0..length];
            try testing.expectEqual(std.hash.Crc32.hash(bytes), hash(bytes));
        }
        for ([_]usize{
            255,
            256,
            511,
            512,
            1008,
            1023,
            1024,
            1025,
            4095,
            4096,
            8192,
        }) |length| {
            const bytes = storage[offset..][0..length];
            const expected = std.hash.Crc32.hash(bytes);
            try testing.expectEqual(expected, hash(bytes));
            if (comptime has_hardware) {
                if (available() != .portable) {
                    var checksum: Crc32 = .{
                        .crc = fold(
                            0xffffffff,
                            bytes[0 .. length & ~@as(usize, 15)],
                            .pclmul,
                        ),
                    };
                    checksum.updatePortable(bytes[length & ~@as(usize, 15) ..]);
                    try testing.expectEqual(expected, checksum.final());
                }
            }
        }
    }
}

test "IEEE CRC32 preserves the accumulator across arbitrary chunks" {
    const testing = std.testing;
    var bytes: [65537]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(789);
    random.random().bytes(&bytes);
    const expected = std.hash.Crc32.hash(&bytes);
    for ([_]usize{
        1,
        3,
        15,
        16,
        31,
        63,
        64,
        65,
        127,
        1023,
        1024,
        4097,
        65536,
    }) |chunk| {
        var checksum: Crc32 = .{};
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + chunk);
            checksum.update(bytes[offset..end]);
            checksum.update("");
            offset = end;
        }
        try testing.expectEqual(expected, checksum.final());
        try testing.expectEqual(expected, checksum.final());
    }
}
