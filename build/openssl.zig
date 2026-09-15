//! Compile OpenSSL with generated Linux x86-64 inputs matching the pinned release.

const std = @import("std");
const builtin = @import("builtin");
const sources = @import("openssl/sources.zon");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const AddLibraryError = error{UnsupportedTarget};

/// Returns null while Zig fetches the lazy upstream dependency and reruns configuration.
/// Returns UnsupportedTarget for targets without matching generated OpenSSL inputs.
pub fn addLibrary(b: *std.Build, options: Options) AddLibraryError!?*std.Build.Step.Compile {
    if (options.target.result.os.tag != .linux or options.target.result.cpu.arch != .x86_64)
        return error.UnsupportedTarget;
    const source = b.lazyDependency("openssl", .{}) orelse return null;
    const module = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .pic = true,
    });
    const generated = b.path("build/openssl/generated");
    const build_info = b.addWriteFiles();
    _ = build_info.add("crypto/buildinf.h", b.fmt(
        \\#define PLATFORM "platform: linux-x86_64"
        \\#define DATE "built on: reproducible build"
        \\static const char compiler_flags[] = "compiler: Zig {s}, {s}";
        \\
    , .{ builtin.zig_version_string, @tagName(options.optimize) }));
    module.addIncludePath(build_info.getDirectory().path(b, "crypto"));
    module.addIncludePath(generated);
    module.addIncludePath(generated.path(b, "include"));
    module.addIncludePath(source.path("."));
    module.addIncludePath(source.path("include"));
    if (options.optimize == .ReleaseFast or options.optimize == .ReleaseSmall)
        module.addCMacro("NDEBUG", "1");
    var include_paths: std.StringHashMapUnmanaged(void) = .empty;
    defer include_paths.deinit(b.allocator);
    inline for (sources.groups) |group| {
        // Additional include directories contain private provider and crypto headers.
        inline for (group.includes) |path| {
            const entry = include_paths.getOrPut(b.allocator, path) catch @panic("OOM");
            if (!entry.found_existing) {
                module.addIncludePath(generated.path(b, path));
                module.addIncludePath(source.path(path));
            }
        }
        // OpenSSL's typed stack wrappers cast callbacks to generic function
        // pointers. LLVM's function-type sanitizer traps on that dispatch.
        const flags = &(.{ "-pthread", "-fno-sanitize=function" } ++ group.flags);
        if (group.upstream.len != 0) module.addCSourceFiles(.{
            .root = source.path("."),
            .files = &group.upstream,
            .flags = flags,
        });
        if (group.generated.len != 0) module.addCSourceFiles(.{
            .root = generated,
            .files = &group.generated,
            .flags = flags,
        });
    }
    const library = b.addLibrary(.{
        .name = "openssl",
        .linkage = .static,
        .root_module = module,
    });
    const version = b.addCheckFile(source.path("VERSION.dat"), .{
        .expected_exact = sources.version_file,
    });
    version.setName("Check OpenSSL source and generated versions match");
    library.step.dependOn(&version.step);
    library.installHeadersDirectory(source.path("include/openssl"), "openssl", .{
        .include_extensions = &.{".h"},
    });
    library.installHeadersDirectory(generated.path(b, "include/openssl"), "openssl", .{
        .include_extensions = &.{".h"},
    });
    return library;
}
