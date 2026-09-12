const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const error_tracing = b.option(bool, "error-tracing", "Override error return tracing (use false for the Zig 0.16 fuzz runner)");
    const zeit = b.dependency("zeit", .{ .target = target, .optimize = optimize }).module("zeit");
    const mod = b.addModule("zhtps", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = error_tracing,
        .imports = &.{.{ .name = "zeit", .module = zeit }},
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
    exe.pie = true;
    if (b.option(bool, "build-server", "Install the standalone server executable") orelse true)
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
    const consumer = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        "--global-cache-dir",
        b.graph.global_cache_root.path.?,
    });
    consumer.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    consumer.setCwd(b.path("examples/embedded"));
    b.step("test-library", "Build and test a separate project importing zhtps").dependOn(&consumer.step);
    const wire = b.addSystemCommand(&.{ "python3", "tests/wire.py" });
    wire.addArtifactArg(exe);
    b.step("test-wire", "Run raw TCP integration and overload tests").dependOn(&wire.step);
    const deployment = b.addSystemCommand(&.{ "python3", "tests/deploy_security.py" });
    b.step("test-deploy", "Check deployment input and file safety").dependOn(&deployment.step);
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
    const request_costs = b.addExecutable(.{
        .name = "request-costs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("docs/request-critical-path/measure.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zhtps", .module = mod }},
        }),
    });
    b.step("install-request-costs", "Install the request cost benchmark").dependOn(&b.addInstallArtifact(request_costs, .{}).step);
}
