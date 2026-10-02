//! Bounded boot-time compression with HTTP-compatible zstd frames.

const std = @import("std");
const c = @cImport({
    @cInclude("zstd.h");
    @cInclude("zstd_errors.h");
});

pub const Error = std.mem.Allocator.Error || std.Io.File.ReadPositionalError ||
    std.Io.File.Writer.Error || error{ FileChanged, CompressionError };

/// Borrows both files. Writes one complete frame using level 3, a window of at
/// most 8 MiB and a checksum. Memory use is independent of source length.
pub fn compress(io: std.Io, source: std.Io.File, size: u64, destination: std.Io.File) Error!u64 {
    const encoder = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = c.ZSTD_freeCCtx(encoder);
    _ = try check(c.ZSTD_CCtx_setParameter(encoder, c.ZSTD_c_compressionLevel, 3));
    _ = try check(c.ZSTD_CCtx_setParameter(encoder, c.ZSTD_c_windowLog, 23));
    _ = try check(c.ZSTD_CCtx_setParameter(encoder, c.ZSTD_c_checksumFlag, 1));
    _ = try check(c.ZSTD_CCtx_setPledgedSrcSize(encoder, size));
    var input: [64 * 1024]u8 = undefined;
    var output: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    var written: u64 = 0;
    while (true) {
        const count = if (offset < size) try source.readPositional(io, &.{input[0..@intCast(
            @min(input.len, size - offset),
        )]}, offset) else 0;
        if (count == 0 and offset < size) return error.FileChanged;
        offset += count;
        var incoming: c.ZSTD_inBuffer = .{ .src = &input, .size = count, .pos = 0 };
        const directive: c.ZSTD_EndDirective = if (offset == size) c.ZSTD_e_end else c.ZSTD_e_continue;
        while (true) {
            var outgoing: c.ZSTD_outBuffer = .{ .dst = &output, .size = output.len, .pos = 0 };
            const remaining = try check(c.ZSTD_compressStream2(encoder, &outgoing, &incoming, directive));
            try destination.writeStreamingAll(io, output[0..outgoing.pos]);
            written += outgoing.pos;
            if (offset == size) {
                if (remaining == 0) return written;
            } else if (incoming.pos == incoming.size) break;
        }
    }
}

fn check(result: usize) error{ OutOfMemory, CompressionError }!usize {
    if (c.ZSTD_isError(result) == 0) return result;
    if (c.ZSTD_getErrorCode(result) == c.ZSTD_error_memory_allocation) return error.OutOfMemory;
    return error.CompressionError;
}
