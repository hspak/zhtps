//! Build and exercise a separate consumer of the public library API.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v4 },
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = if (b.graph.host.result.os.tag == .linux and b.graph.host.result.abi == .gnu)
            b.graph.host.result.os.version_range.linux.glibc
        else
            null,
    } });
    const optimize = b.standardOptimizeOption(.{});
    const system_openssl = b.option(
        bool,
        "system-openssl",
        "Link system OpenSSL instead of building the pinned 3.5 LTS release",
    ) orelse false;
    const system_nghttp2 = b.option(
        bool,
        "system-nghttp2",
        "Link system libnghttp2 instead of building the pinned source release",
    ) orelse false;
    const zhtps = b.dependency("zhtps", .{
        .target = target,
        .optimize = optimize,
        .@"build-server" = false,
        .@"system-openssl" = system_openssl,
        .@"system-nghttp2" = system_nghttp2,
    }).module("zhtps");
    const main = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zhtps", .module = zhtps }},
    });
    const exe = b.addExecutable(.{ .name = "embedded", .root_module = main });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Serve until Enter is pressed").dependOn(&run.step);
    const filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const tests = b.addTest(.{
        .root_module = main,
        .filters = if (filter) |name| &.{name} else &.{},
    });
    b.step(
        "test",
        "Exercise the library through a separate consumer",
    ).dependOn(&b.addRunArtifact(tests).step);
}
