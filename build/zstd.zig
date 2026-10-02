//! Build the pinned, single-threaded zstd encoder.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// Returns null while Zig fetches the lazy dependency and reruns configuration.
pub fn addLibrary(b: *std.Build, options: Options) ?*std.Build.Step.Compile {
    const source = b.lazyDependency("zstd", .{}) orelse return null;
    const module = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .pic = true,
    });
    module.addIncludePath(source.path("lib"));
    module.addCMacro("ZSTD_DISABLE_ASM", "1");
    module.addCSourceFiles(.{
        .root = source.path("lib"),
        .files = &.{
            "common/debug.c",
            "common/entropy_common.c",
            "common/error_private.c",
            "common/fse_decompress.c",
            "common/xxhash.c",
            "common/zstd_common.c",
            "compress/fse_compress.c",
            "compress/hist.c",
            "compress/huf_compress.c",
            "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",
            "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c",
            "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",
            "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",
            "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",
        },
        .flags = &.{"-std=c99"},
    });
    const library = b.addLibrary(.{
        .name = "zstd",
        .linkage = .static,
        .root_module = module,
    });
    library.installHeader(source.path("lib/zstd.h"), "zstd.h");
    library.installHeader(source.path("lib/zstd_errors.h"), "zstd_errors.h");
    return library;
}
