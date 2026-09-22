//! Build the library, standalone server, consumer tests and benchmarks.

const std = @import("std");
const nghttp2 = @import("build/nghttp2.zig");
const openssl = @import("build/openssl.zig");

const DeclarationOptions = struct {
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) !void {
    const format_paths = &.{
        "build.zig",
        "build.zig.zon",
        "build",
        "src",
        "bench",
        "tests",
        "examples/embedded/build.zig",
        "examples/embedded/build.zig.zon",
        "examples/embedded/main.zig",
        "examples/embedded/endpoints.zig",
    };
    b.step("fmt", "Format maintained Zig sources").dependOn(&b.addFmt(.{
        .paths = format_paths,
    }).step);
    b.step("check-fmt", "Check formatting of maintained Zig sources").dependOn(&b.addFmt(.{
        .paths = format_paths,
        .check = true,
    }).step);
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
    const error_tracing = b.option(
        bool,
        "error-tracing",
        "Override error return tracing (use false for the Zig 0.16 fuzz runner)",
    );
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
    if (system_openssl) {
        mod.linkSystemLibrary("ssl", .{});
        mod.linkSystemLibrary("crypto", .{});
    } else if (try openssl.addLibrary(b, .{ .target = target, .optimize = optimize })) |library| {
        mod.linkLibrary(library);
    }
    if (system_nghttp2) {
        mod.linkSystemLibrary("nghttp2", .{});
    } else if (nghttp2.addLibrary(b, .{ .target = target, .optimize = optimize })) |library| {
        mod.linkLibrary(library);
        mod.addCMacro("NGHTTP2_STATICLIB", "1");
    }
    mod.link_libc = true;
    mod.addIncludePath(b.path("src"));
    // An explicit Linux target disables Zig's implicit native search paths.
    // Reuse host libraries only when the architecture, OS and ABI match.
    const host = b.graph.host.result;
    if ((system_openssl or system_nghttp2) and b.sysroot == null and
        target.result.cpu.arch == host.cpu.arch and
        target.result.os.tag == host.os.tag and target.result.abi == host.abi and
        (target.result.abi != .gnu or target.result.os.version_range.linux.glibc.order(
            host.os.version_range.linux.glibc,
        ) == .eq))
    {
        const paths = std.zig.system.NativePaths.detect(
            b.allocator,
            b.graph.io,
            &host,
            &b.graph.environ_map,
        ) catch @panic("cannot discover native library search paths");
        for (paths.include_dirs.items) |path| {
            std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch continue;
            mod.addSystemIncludePath(.{ .cwd_relative = path });
        }
        for (paths.lib_dirs.items) |path| {
            std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch continue;
            mod.addLibraryPath(.{ .cwd_relative = path });
        }
        for (paths.rpaths.items) |path| mod.addRPath(.{ .cwd_relative = path });
    }
    exe.pie = true;
    if (b.option(bool, "build-server", "Install the standalone server executable") orelse true) {
        b.installArtifact(exe);
        if (!system_openssl)
            b.installFile("licenses/openssl.txt", "share/licenses/zhtps/openssl.txt");
        if (!system_nghttp2)
            b.installFile("licenses/nghttp2.txt", "share/licenses/zhtps/nghttp2.txt");
    }
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the HTTP server").dependOn(&run.step);
    const application_bench = b.addExecutable(.{
        .name = "application-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/application.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zhtps", .module = mod }},
        }),
    });
    b.step("install-application-bench", "Install the generated application benchmark").dependOn(
        &b.addInstallArtifact(application_bench, .{}).step,
    );
    const upload_options = b.addOptions();
    upload_options.addOption(
        bool,
        "streaming",
        b.option(bool, "body-streaming", "Use the incremental upload consumer") orelse true,
    );
    upload_options.addOption(
        bool,
        "observe",
        b.option(
            bool,
            "upload-observe",
            "Enable upload fixture inspection counters and gates",
        ) orelse true,
    );
    upload_options.addOption(
        bool,
        "fast_crc",
        b.option(
            bool,
            "upload-fast-crc",
            "Use hardware-assisted IEEE CRC32 in the upload fixture",
        ) orelse true,
    );
    const upload_bench = b.addExecutable(.{
        .name = "upload-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/upload.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhtps", .module = mod },
                .{ .name = "upload_options", .module = upload_options.createModule() },
            },
        }),
    });
    b.step("install-upload-bench", "Install the upload checksum benchmark").dependOn(
        &b.addInstallArtifact(upload_bench, .{}).step,
    );
    const upload_wire = b.addSystemCommand(&.{ "python3", "tests/body_streaming.py" });
    upload_wire.addArtifactArg(upload_bench);
    b.step(
        "test-upload",
        "Check incremental request consumption and backpressure",
    ).dependOn(&upload_wire.step);
    const checksum_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/Crc32.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    const checksum_run = b.addRunArtifact(checksum_tests);
    b.step("test-crc", "Check portable and hardware IEEE CRC32").dependOn(&checksum_run.step);
    const executor_wire = b.addSystemCommand(&.{ "python3", "tests/application_executor.py" });
    executor_wire.addArtifactArg(application_bench);
    b.step("test-application", "Check shared executor scheduling and lifetime").dependOn(&executor_wire.step);
    const filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const tests = b.addTest(.{
        .root_module = mod,
        .filters = if (filter) |name| &.{name} else &.{},
        // Zig 0.16's native x86 backend does not populate fuzz coverage PCs.
        .use_llvm = true,
    });
    const test_step = b.step("test", "Run protocol, component and declaration tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const declarations = b.step(
        "test-endpoint-declarations",
        "Reject invalid endpoint declarations at compile time",
    );
    addEndpointDeclarationTests(
        b,
        declarations,
        .{
            .module = mod,
            .target = target,
            .optimize = optimize,
        },
    );
    if (filter == null) {
        test_step.dependOn(declarations);
        test_step.dependOn(&checksum_run.step);
    }
    const consumer = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        "--global-cache-dir",
        // The consumer changes directory, so a relative cache path would fetch again.
        b.pathResolve(&.{ b.graph.cache.cwd, b.graph.global_cache_root.path orelse "." }),
    });
    consumer.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    consumer.addArg(b.fmt("-Dsystem-openssl={}", .{system_openssl}));
    consumer.addArg(b.fmt("-Dsystem-nghttp2={}", .{system_nghttp2}));
    const consumer_target = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const consumer_cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    consumer.addArg(b.fmt("-Dtarget={s}", .{consumer_target}));
    consumer.addArg(b.fmt("-Dcpu={s}", .{consumer_cpu}));
    consumer.setCwd(b.path("examples/embedded"));
    b.step("test-library", "Build and test a separate project importing zhtps").dependOn(&consumer.step);
    const wire = b.addSystemCommand(&.{ "python3", "tests/wire.py" });
    const tls_wire = b.addSystemCommand(&.{ "python3", "tests/tls.py" });
    tls_wire.addArtifactArg(exe);
    const tls_application = b.addExecutable(.{
        .name = "tls-application",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tls_application.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zhtps", .module = mod }},
        }),
    });
    tls_wire.addArtifactArg(tls_application);
    b.step("install-response-fixture", "Install the response comparison application").dependOn(
        &b.addInstallArtifact(tls_application, .{}).step,
    );
    const streaming_wire = b.addSystemCommand(&.{ "python3", "tests/response_streaming.py" });
    streaming_wire.addArtifactArg(tls_application);
    b.step(
        "test-response-streaming",
        "Check generated response streaming over HTTP/1 and TLS",
    ).dependOn(&streaming_wire.step);
    b.step("test-tls", "Check TLS policy, encrypted HTTP and connection lifetimes").dependOn(&tls_wire.step);
    const http2_wire = b.addSystemCommand(&.{
        b.option(
            []const u8,
            "http2-python",
            "Python interpreter with the h2 test dependency",
        ) orelse "python3",
        "tests/http2.py",
    });
    http2_wire.addArtifactArg(exe);
    http2_wire.addArtifactArg(tls_application);
    b.step("test-http2", "Check multiplexed HTTP/2 over TLS with real clients").dependOn(&http2_wire.step);
    wire.addArtifactArg(exe);
    const automatic_wire = b.addSystemCommand(&.{ "python3", "tests/automatic_resources.py" });
    automatic_wire.addArtifactArg(exe);
    wire.step.dependOn(&automatic_wire.step);
    b.step("test-resources", "Check automatic resource sizing and explicit overrides").dependOn(&automatic_wire.step);
    const kernel_wire = b.addSystemCommand(&.{ "python3", "tests/kernel_work.py" });
    kernel_wire.addArtifactArg(exe);
    kernel_wire.step.dependOn(&wire.step);
    const aggregation_wire = b.addSystemCommand(&.{ "python3", "tests/response_aggregation.py" });
    aggregation_wire.addArtifactArg(exe);
    aggregation_wire.step.dependOn(&kernel_wire.step);
    const placement_wire = b.addSystemCommand(&.{ "python3", "tests/worker_placement.py" });
    placement_wire.addArtifactArg(exe);
    placement_wire.step.dependOn(&aggregation_wire.step);
    const placement_topology = b.addSystemCommand(&.{ "python3", "tests/nic_placement.py" });
    placement_topology.step.dependOn(&placement_wire.step);
    const buffers_wire = b.addSystemCommand(&.{ "python3", "tests/buffer_pools.py" });
    buffers_wire.addArtifactArg(exe);
    buffers_wire.step.dependOn(&placement_topology.step);
    const requests_wire = b.addSystemCommand(&.{ "python3", "tests/request_storage.py" });
    requests_wire.addArtifactArg(exe);
    requests_wire.step.dependOn(&buffers_wire.step);
    const reclaim_wire = b.addSystemCommand(&.{ "python3", "tests/idle_reclamation.py" });
    reclaim_wire.addArtifactArg(exe);
    reclaim_wire.step.dependOn(&requests_wire.step);
    const shutdown_wire = b.addSystemCommand(&.{ "python3", "tests/shutdown.py" });
    shutdown_wire.addArtifactArg(exe);
    shutdown_wire.step.dependOn(&reclaim_wire.step);
    b.step("test-wire", "Run raw TCP integration and overload tests").dependOn(&shutdown_wire.step);
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
    b.step(
        "bench-hot-paths",
        "Measure admission, metrics, and parsing CPU costs",
    ).dependOn(&run_hot_paths.step);
    const install_hot_paths = b.addInstallArtifact(hot_paths, .{});
    b.step("install-hot-paths", "Install the hot path benchmark").dependOn(&install_hot_paths.step);
    const request_costs = b.addExecutable(.{
        .name = "request-costs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/request_costs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zhtps", .module = mod }},
        }),
    });
    b.step("install-request-costs", "Install the request cost benchmark").dependOn(&b.addInstallArtifact(
        request_costs,
        .{},
    ).step);
    const access_log = b.addExecutable(.{
        .name = "access-log",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/access_log.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zhtps", .module = mod }},
        }),
    });
    b.step("install-access-log", "Install the access log benchmark").dependOn(&b.addInstallArtifact(
        access_log,
        .{},
    ).step);
}

fn addEndpointDeclarationTests(
    b: *std.Build,
    step: *std.Build.Step,
    options: DeclarationOptions,
) void {
    const errors = [_][]const u8{
        "unknown option: befor",
        "unknown option: max_body_byte",
        "unknown option: befor",
        "unknown option: timeot_ms",
        "metric enums must be exhaustive and numbered from zero without gaps",
        "metric enums must be exhaustive and numbered from zero without gaps",
        "duplicate emitted metric name: jobs",
        "duplicate emitted metric name: latency_sum",
        "metric names must contain only letters, digits and underscores",
        "the zhtps metric namespace is reserved",
        "endpoint paths must be normalized",
        "endpoint paths must be normalized",
        "group prefixes cannot contain parameters",
        "duplicate endpoint method and path pattern",
        "an endpoint group cannot be empty",
        "JSON responses require a status with content; use empty",
        "endpoint paths must contain only URI path characters",
        "an application must declare at least one lane",
        "streaming endpoints need a body consumer",
        "body consumers require the stream policy",
        "unknown option: cache_contol",
        "duplicate endpoint method and path pattern",
        "endpoint group prefixes must not end with '/'",
        "static index_file must be a single permitted filename",
        "static cache_control must be a valid HTTP field",
    };
    for (errors, 0..) |message, index| {
        const scenario = b.addOptions();
        scenario.addOption(usize, "index", index);
        const check = b.addTest(.{
            .name = b.fmt("endpoint-declaration-{d}", .{index}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/endpoint_declarations.zig"),
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "zhtps", .module = options.module },
                    .{ .name = "scenario", .module = scenario.createModule() },
                },
            }),
        });
        check.expect_errors = .{ .contains = b.fmt("error: {s}", .{message}) };
        step.dependOn(&check.step);
    }
}
