//! Linux x86-64-v4 primitives used outside the io_uring submission/completion loop.

const std = @import("std");
pub const linux = std.os.linux;
const builtin = @import("builtin");
const zeit = @import("zeit");
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
    TcpThinRetriesUnavailable,
    SystemCallUnexpected,
    CpuUnavailable,
    AffinityMaskTooSmall,
};

/// Returns the calling thread's allowed CPUs. Masks larger than 1024 CPUs are
/// rejected explicitly; affinity is optional on such hosts.
pub fn getAffinity() Error!linux.cpu_set_t {
    var mask: linux.cpu_set_t = undefined;
    const result = linux.sched_getaffinity(
        0,
        @sizeOf(linux.cpu_set_t),
        &mask,
    );
    if (linux.errno(result) == .INVAL) return error.AffinityMaskTooSmall;
    _ = try check(result);
    return mask;
}

/// Sets only the calling thread's affinity. The kernel may further restrict
/// this mask if CPUs go offline or the thread's cpuset changes.
pub fn setAffinity(mask: *const linux.cpu_set_t) Error!void {
    const result = linux.syscall3(
        .sched_setaffinity,
        0,
        @sizeOf(linux.cpu_set_t),
        @intFromPtr(mask),
    );
    if (linux.errno(result) == .INVAL) return error.CpuUnavailable;
    _ = try check(result);
}

/// Checks a borrowed affinity mask; CPU IDs beyond its capacity return false.
pub fn cpuAllowed(mask: *const linux.cpu_set_t, cpu: usize) bool {
    const bits = @bitSizeOf(usize);
    return cpu < @bitSizeOf(linux.cpu_set_t) and
        mask[cpu / bits] & (@as(usize, 1) << @intCast(cpu % bits)) != 0;
}

/// Pins the calling thread within its inherited allowed set. Returns the old
/// mask, which the caller must restore before returning to an embedding caller.
pub fn pinCpu(cpu: usize) Error!linux.cpu_set_t {
    const original = try getAffinity();
    if (!cpuAllowed(&original, cpu)) return error.CpuUnavailable;
    var mask = std.mem.zeroes(linux.cpu_set_t);
    mask[cpu / @bitSizeOf(usize)] = @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    try setAffinity(&mask);
    return original;
}

/// Maps a raw Linux syscall result to the platform error set, preserving successful values.
pub fn check(result: usize) Error!usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .ACCES, .PERM => error.PermissionDenied,
        .ADDRINUSE => error.AddressInUse,
        .NOMEM,
        .NOBUFS,
        .MFILE,
        .NFILE,
        => error.SystemResources,
        .AFNOSUPPORT,
        .PROTONOSUPPORT,
        .NETDOWN,
        .ADDRNOTAVAIL,
        => error.NetworkUnavailable,
        else => error.SystemCallUnexpected,
    };
}

/// Returns monotonic nanoseconds for elapsed-time and deadline comparisons.
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

/// Releases an owned descriptor. Linux closes it even when close reports an error.
pub fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

/// Copies a signed integer socket option into the kernel; retains no caller storage.
pub fn setOption(
    fd: linux.fd_t,
    level: i32,
    option: u32,
    value: i32,
) Error!void {
    _ = try check(linux.setsockopt(
        fd,
        level,
        option,
        std.mem.asBytes(&value),
        @sizeOf(i32),
    ));
}

pub const Listener = struct {
    fd: linux.fd_t,
    port: u16,
};

pub const ListenOptions = struct {
    backlog: u31 = 128,
    /// Only listeners serving the same trust domain may share a port.
    reuse_port: bool = false,
    /// Accepted sockets inherit bounded linear retries for thin TCP streams.
    /// Support is checked before binding; failure leaves no listening socket.
    thin_linear_timeouts: bool = false,
};

/// Returns an owned listener; the caller closes it after stopping its accepts.
/// A zero port requests a kernel-assigned port, returned in the result.
pub fn listen(
    address: []const u8,
    port: u16,
    options: ListenOptions,
) Error!Listener {
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
    try setOption(
        fd,
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        1,
    );
    if (options.reuse_port) try setOption(
        fd,
        linux.SOL.SOCKET,
        linux.SO.REUSEPORT,
        1,
    );
    if (options.thin_linear_timeouts) {
        const enabled: i32 = 1;
        const result = linux.setsockopt(
            fd,
            linux.IPPROTO.TCP,
            linux.TCP.THIN_LINEAR_TIMEOUTS,
            std.mem.asBytes(&enabled),
            @sizeOf(i32),
        );
        switch (linux.errno(result)) {
            .NOPROTOOPT, .OPNOTSUPP => {
                @branchHint(.cold);
                return error.TcpThinRetriesUnavailable;
            },
            else => _ = try check(result),
        }
    }
    var actual_port: u16 = 0;
    switch (ip) {
        .ip4 => |v4| {
            var addr: linux.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = @bitCast(v4.bytes),
            };
            _ = try check(linux.bind(
                fd,
                @ptrCast(&addr),
                @sizeOf(@TypeOf(addr)),
            ));
            var len: linux.socklen_t = @sizeOf(@TypeOf(addr));
            _ = try check(linux.getsockname(
                fd,
                @ptrCast(&addr),
                &len,
            ));
            actual_port = std.mem.bigToNative(u16, addr.port);
        },
        .ip6 => |v6| {
            try setOption(
                fd,
                linux.IPPROTO.IPV6,
                linux.IPV6.V6ONLY,
                1,
            );
            var addr: linux.sockaddr.in6 = .{
                .family = linux.AF.INET6,
                .port = std.mem.nativeToBig(u16, port),
                .flowinfo = 0,
                .addr = v6.bytes,
                .scope_id = 0,
            };
            _ = try check(linux.bind(
                fd,
                @ptrCast(&addr),
                @sizeOf(@TypeOf(addr)),
            ));
            var len: linux.socklen_t = @sizeOf(@TypeOf(addr));
            _ = try check(linux.getsockname(
                fd,
                @ptrCast(&addr),
                &len,
            ));
            actual_port = std.mem.bigToNative(u16, addr.port);
        },
    }
    _ = try check(linux.listen(fd, options.backlog));
    return .{ .fd = fd, .port = actual_port };
}

test "accepted IPv4 and IPv6 sockets inherit the listener retry option" {
    const testing = std.testing;
    for ([_][]const u8{ "127.0.0.1", "::1" }) |host| {
        for ([_]bool{ false, true }) |enabled| {
            const listener = try listen(
                host,
                0,
                .{ .thin_linear_timeouts = enabled },
            );
            defer close(listener.fd);
            const ip = try std.Io.net.IpAddress.parse(host, listener.port);
            const domain: u32 = switch (ip) {
                .ip4 => linux.AF.INET,
                .ip6 => linux.AF.INET6,
            };
            const client: linux.fd_t = @intCast(try check(linux.socket(
                domain,
                linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
                linux.IPPROTO.TCP,
            )));
            defer close(client);
            switch (ip) {
                .ip4 => |v4| {
                    var address: linux.sockaddr.in = .{
                        .port = std.mem.nativeToBig(u16, listener.port),
                        .addr = @bitCast(v4.bytes),
                    };
                    _ = try check(linux.connect(
                        client,
                        @ptrCast(&address),
                        @sizeOf(@TypeOf(address)),
                    ));
                },
                .ip6 => |v6| {
                    var address: linux.sockaddr.in6 = .{
                        .family = linux.AF.INET6,
                        .port = std.mem.nativeToBig(u16, listener.port),
                        .flowinfo = 0,
                        .addr = v6.bytes,
                        .scope_id = 0,
                    };
                    _ = try check(linux.connect(
                        client,
                        @ptrCast(&address),
                        @sizeOf(@TypeOf(address)),
                    ));
                },
            }
            const accepted: linux.fd_t = @intCast(try check(linux.accept4(
                listener.fd,
                null,
                null,
                linux.SOCK.CLOEXEC,
            )));
            defer close(accepted);
            var actual: i32 = -1;
            var size: linux.socklen_t = @sizeOf(i32);
            _ = try check(linux.getsockopt(
                accepted,
                linux.IPPROTO.TCP,
                linux.TCP.THIN_LINEAR_TIMEOUTS,
                std.mem.asBytes(&actual),
                &size,
            ));
            try testing.expectEqual(@as(linux.socklen_t, @sizeOf(i32)), size);
            try testing.expectEqual(@as(i32, @intFromBool(enabled)), actual);
        }
    }
}
