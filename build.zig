const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const error_tracing = b.option(bool, "error-tracing", "Override error return tracing (use false for the Zig 0.16 fuzz runner)");
    const mod = b.addModule("zhtps", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = error_tracing,
    });
    const exe = b.addExecutable(.{
        .name = "zhtps",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zhtps", .module = mod }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the HTTP server").dependOn(&run.step);
    const filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const tests = b.addTest(.{
        .root_module = mod,
        .filters = if (filter) |name| &.{name} else &.{},
        // Zig 0.16's native x86 backend does not populate fuzz coverage PCs.
        .use_llvm = true,
    });
    b.step("test", "Run protocol and component tests").dependOn(&b.addRunArtifact(tests).step);
    const wire = b.addSystemCommand(&.{ "python3", "tests/wire.py" });
    wire.addArtifactArg(exe);
    b.step("test-wire", "Run raw TCP integration and overload tests").dependOn(&wire.step);
    const hot_paths = b.addExecutable(.{
        .name = "hot-paths",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/hot_paths.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zhtps", .module = mod }},
        }),
    });
    const run_hot_paths = b.addRunArtifact(hot_paths);
    if (b.args) |args| run_hot_paths.addArgs(args);
    b.step("bench-hot-paths", "Measure admission, metrics, and parsing CPU costs").dependOn(&run_hot_paths.step);
    const install_hot_paths = b.addInstallArtifact(hot_paths, .{});
    b.step("install-hot-paths", "Install the hot path benchmark").dependOn(&install_hot_paths.step);
}
