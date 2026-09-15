//! Build the pinned libnghttp2 sources for zhtps's Linux targets.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// Returns null while Zig fetches the lazy source dependency and reruns configuration.
pub fn addLibrary(b: *std.Build, options: Options) ?*std.Build.Step.Compile {
    const source = b.lazyDependency("nghttp2", .{}) orelse return null;
    const module = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .pic = true,
    });
    module.addIncludePath(source.path("lib/includes"));
    module.addCMacro("BUILDING_NGHTTP2", "1");
    module.addCMacro("NGHTTP2_STATICLIB", "1");
    module.addCMacro("HAVE_ARPA_INET_H", "1");
    module.addCMacro("HAVE_NETINET_IN_H", "1");
    // Reset rate limits must use Linux's monotonic clock, not the time() fallback.
    module.addCMacro("_POSIX_C_SOURCE", "200809L");
    module.addCMacro("HAVE_CLOCK_GETTIME", "1");
    module.addCMacro("HAVE_DECL_CLOCK_MONOTONIC", "1");
    module.addCSourceFiles(.{
        .root = source.path("lib"),
        // Keep this list in sync with lib/CMakeLists.txt when updating the release.
        .files = &.{
            "nghttp2_pq.c",
            "nghttp2_map.c",
            "nghttp2_queue.c",
            "nghttp2_frame.c",
            "nghttp2_buf.c",
            "nghttp2_stream.c",
            "nghttp2_outbound_item.c",
            "nghttp2_session.c",
            "nghttp2_submit.c",
            "nghttp2_helper.c",
            "nghttp2_alpn.c",
            "nghttp2_hd.c",
            "nghttp2_hd_huffman.c",
            "nghttp2_hd_huffman_data.c",
            "nghttp2_version.c",
            "nghttp2_priority_spec.c",
            "nghttp2_option.c",
            "nghttp2_callbacks.c",
            "nghttp2_mem.c",
            "nghttp2_http.c",
            "nghttp2_rcbuf.c",
            "nghttp2_extpri.c",
            "nghttp2_ratelim.c",
            "nghttp2_time.c",
            "nghttp2_debug.c",
            "sfparse.c",
        },
        .flags = &.{"-std=c99"},
    });
    const library = b.addLibrary(.{
        .name = "nghttp2",
        .linkage = .static,
        .root_module = module,
    });
    library.installHeader(source.path("lib/includes/nghttp2/nghttp2.h"), "nghttp2/nghttp2.h");
    library.installHeader(source.path("lib/includes/nghttp2/nghttp2ver.h"), "nghttp2/nghttp2ver.h");
    return library;
}
