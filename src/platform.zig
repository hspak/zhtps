//! Linux x86-64-v4 primitives used outside the io_uring submission/completion loop.

const std = @import("std");
const builtin = @import("builtin");
const zeit = @import("zeit");
pub const linux = std.os.linux;
const log = std.log.scoped(.platform);

comptime {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64)
        @compileError("ZHTPS requires Linux on x86_64");
    if (!builtin.cpu.hasAll(.x86, &.{
        .avx512bw,
        .avx512cd,
        .avx512dq,
        .avx512f,
        .avx512vl,
    })) @compileError("ZHTPS requires the x86-64-v4 instruction set");
}

pub const Error = error{
    InvalidAddress,
    PermissionDenied,
    AddressInUse,
    SystemResources,
    NetworkUnavailable,
    SystemCallUnexpected,
};

pub fn check(result: usize) Error!usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .ACCES, .PERM => error.PermissionDenied,
        .ADDRINUSE => error.AddressInUse,
        .NOMEM, .NOBUFS, .MFILE, .NFILE => error.SystemResources,
        .AFNOSUPPORT, .PROTONOSUPPORT, .NETDOWN, .ADDRNOTAVAIL => error.NetworkUnavailable,
        else => error.SystemCallUnexpected,
    };
}

pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    std.debug.assert(linux.clock_gettime(.MONOTONIC, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Reads UTC wall time through zeit. Pre-epoch clocks clamp to zero for logs
/// and Date; elapsed durations use monotonicNs instead.
pub fn realtimeNs(io: std.Io) u64 {
    const timestamp = zeit.instant(.{ .now = io }, &zeit.utc).timestamp;
    return @intCast(@max(0, timestamp));
}

pub fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

pub fn setOption(fd: linux.fd_t, level: i32, option: u32, value: i32) Error!void {
    _ = try check(linux.setsockopt(fd, level, option, std.mem.asBytes(&value), @sizeOf(i32)));
}

pub const Listener = struct {
    fd: linux.fd_t,
    port: u16,
};

pub const ListenOptions = struct {
    backlog: u31 = 128,
    /// Only listeners serving the same trust domain may share a port.
    reuse_port: bool = false,
};

/// Returns an owned listener; the caller closes it after stopping its accepts.
/// A zero port requests a kernel-assigned port, returned in the result.
pub fn listen(address: []const u8, port: u16, options: ListenOptions) Error!Listener {
    const ip = std.Io.net.IpAddress.parse(address, port) catch return error.InvalidAddress;
    const domain: u32 = switch (ip) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    const fd: linux.fd_t = @intCast(try check(linux.socket(
        domain,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        linux.IPPROTO.TCP,
    )));
    errdefer close(fd);
    try setOption(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
    if (options.reuse_port) try setOption(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, 1);
    var actual_port: u16 = 0;
    switch (ip) {
        .ip4 => |v4| {
            var addr: linux.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = @bitCast(v4.bytes),
            };
            _ = try check(linux.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
            var len: linux.socklen_t = @sizeOf(@TypeOf(addr));
            _ = try check(linux.getsockname(fd, @ptrCast(&addr), &len));
            actual_port = std.mem.bigToNative(u16, addr.port);
        },
        .ip6 => |v6| {
            try setOption(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, 1);
            var addr: linux.sockaddr.in6 = .{
                .family = linux.AF.INET6,
                .port = std.mem.nativeToBig(u16, port),
                .flowinfo = 0,
                .addr = v6.bytes,
                .scope_id = 0,
            };
            _ = try check(linux.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
            var len: linux.socklen_t = @sizeOf(@TypeOf(addr));
            _ = try check(linux.getsockname(fd, @ptrCast(&addr), &len));
            actual_port = std.mem.bigToNative(u16, addr.port);
        },
    }
    _ = try check(linux.listen(fd, options.backlog));
    return .{ .fd = fd, .port = actual_port };
}
