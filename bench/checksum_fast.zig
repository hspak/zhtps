//! Measure the upload fixture's checksum work without transport or executor work.

const std = @import("std");
const linux = std.os.linux;
const Crc32 = @import("Crc32.zig");
const log = std.log.scoped(.checksum_fast);

fn cpuNs() u64 {
    var time: linux.timespec = undefined;
    std.debug.assert(linux.clock_gettime(.PROCESS_CPUTIME_ID, &time) == 0);
    return @as(u64, @intCast(time.sec)) * 1_000_000_000 + @as(u64, @intCast(time.nsec));
}

pub fn main(init: std.process.Init) !void {
    const size = 8 * 1024 * 1024;
    const iterations = 64;
    const bytes = try init.gpa.alloc(u8, size);
    defer init.gpa.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index);
    const warm_checksum = Crc32.hash(bytes);
    var sum: u64 = 0;
    const started = cpuNs();
    for (0..iterations) |_| {
        // Vary the input and retain every result so repeated work cannot be hoisted.
        bytes[0] +%= 1;
        var checksum: Crc32 = .{};
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 64 * 1024)
            checksum.update(bytes[offset..][0 .. 64 * 1024]);
        sum += checksum.final();
    }
    const elapsed = cpuNs() - started;
    std.debug.print(
        "{{\"bytes\":{d},\"iterations\":{d},\"chunk_bytes\":65536,\"cpu_ns\":{d},\"checksum_sum\":{d},\"warm_checksum\":{d}}}\n",
        .{
            size,
            iterations,
            elapsed,
            sum,
            warm_checksum,
        },
    );
}
