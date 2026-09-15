//! Startup resource discovery within the caller's affinity and visible cgroup hierarchy.

const std = @import("std");
const linux = std.os.linux;
const platform = @import("../platform.zig");
const log = std.log.scoped(.config_resources);
const Resources = @This();

report: Report = .{},
allowed: CpuSet = .initEmpty(),
cores: CpuSet = .initEmpty(),
placement: [256]u16 = undefined,
placement_count: usize = 0,

pub const CpuSet = std.StaticBitSet(1024);
pub const Error = std.mem.Allocator.Error || platform.Error || error{
    ResourceDetectionUnavailable,
    InvalidResourceFile,
};

pub const Report = struct {
    allowed_cpus: usize = 0,
    physical_cores: usize = 0,
    topology_available: bool = false,
    cpu_quota_millis: ?u64 = null,
    memory_limit_bytes: u64 = 0,
    memory_available_bytes: u64 = 0,
    memory_source: enum {
        host,
        cgroup_max,
        cgroup_high,
    } = .host,
    cgroup: enum {
        none,
        v1,
        v2,
        hybrid,
    } = .none,
    nofile_limit: u64 = 0,
    reserved_fds: usize = 32,
    available_threads: ?u64 = null,
    placement: enum {
        scheduler,
        nic,
        explicit,
        unavailable,
        ambiguous,
    } = .scheduler,
};

/// Reads host and service limits before allocating server storage. Missing or
/// unreadable cgroup membership/mount information is an error, never permission
/// to size from unrestricted host totals. No host settings are changed.
pub fn detect(gpa: std.mem.Allocator, io: std.Io) Error!Resources {
    const affinity = try platform.getAffinity();
    var allowed: CpuSet = .initEmpty();
    for (0..allowed.capacity()) |cpu| {
        if (platform.cpuAllowed(&affinity, cpu)) allowed.set(cpu);
    }
    var limits: linux.rlimit = undefined;
    _ = try platform.check(linux.getrlimit(.NOFILE, &limits));
    var root = std.Io.Dir.openDirAbsolute(io, "/", .{}) catch
        return error.ResourceDetectionUnavailable;
    defer root.close(io);
    return read(gpa, io, root, allowed, limits.cur);
}

fn read(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    allowed: CpuSet,
    nofile: u64,
) Error!Resources {
    var result: Resources = .{ .allowed = allowed };
    result.report.nofile_limit = nofile;
    var small: [64 * 1024]u8 = undefined;
    const meminfo = (try readOptional(io, root, "proc/meminfo", &small)) orelse
        return error.ResourceDetectionUnavailable;
    result.report.memory_limit_bytes = try meminfoBytes(meminfo, "MemTotal:");
    result.report.memory_available_bytes = @min(
        result.report.memory_limit_bytes,
        try meminfoBytes(meminfo, "MemAvailable:"),
    );
    var memberships_buffer: [64 * 1024]u8 = undefined;
    const memberships = (try readOptional(io, root, "proc/thread-self/cgroup", &memberships_buffer)) orelse
        (try readOptional(io, root, "proc/self/cgroup", &memberships_buffer)) orelse
        return error.ResourceDetectionUnavailable;
    const mounts_buffer = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(mounts_buffer);
    const mounts = (try readOptional(io, root, "proc/thread-self/mountinfo", mounts_buffer)) orelse
        (try readOptional(io, root, "proc/self/mountinfo", mounts_buffer)) orelse
        return error.ResourceDetectionUnavailable;
    var lines = std.mem.tokenizeScalar(u8, memberships, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const hierarchy = fields.next() orelse return error.InvalidResourceFile;
        const controllers = fields.next() orelse return error.InvalidResourceFile;
        const group = fields.rest();
        if (!validAbsolutePath(group)) return error.InvalidResourceFile;
        if (std.mem.eql(u8, hierarchy, "0") and controllers.len == 0) {
            result.report.cgroup = switch (result.report.cgroup) {
                .none, .v2 => .v2,
                .v1, .hybrid => .hybrid,
            };
            try result.readHierarchy(io, root, mounts, group, .unified);
        } else {
            result.report.cgroup = switch (result.report.cgroup) {
                .none, .v1 => .v1,
                .v2, .hybrid => .hybrid,
            };
            inline for (.{
                Controller.cpu,
                Controller.memory,
                Controller.cpuset,
                Controller.pids,
            }) |controller| {
                if (contains(controllers, @tagName(controller)))
                    try result.readHierarchy(io, root, mounts, group, controller);
            }
        }
    }
    result.report.allowed_cpus = result.allowed.count();
    if (result.report.allowed_cpus == 0) return error.CpuUnavailable;
    try result.readCores(io, root);
    var descriptors = root.openDir(io, "proc/self/fd", .{ .iterate = true }) catch null;
    if (descriptors) |*directory| {
        defer directory.close(io);
        var iterator = directory.iterate();
        var count: usize = 0;
        while (iterator.next(io) catch return error.ResourceDetectionUnavailable) |_| count += 1;
        result.report.reserved_fds = @max(result.report.reserved_fds, count + 16);
    }
    return result;
}

const Controller = enum {
    unified,
    cpu,
    memory,
    cpuset,
    pids,
};

fn readHierarchy(
    resources: *Resources,
    io: std.Io,
    root: std.Io.Dir,
    mounts: []const u8,
    group: []const u8,
    controller: Controller,
) Error!void {
    var found = false;
    var lines = std.mem.tokenizeScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOf(u8, line, " - ") orelse
            return error.InvalidResourceFile;
        var after = std.mem.tokenizeScalar(u8, line[separator + 3 ..], ' ');
        const filesystem = after.next() orelse return error.InvalidResourceFile;
        _ = after.next() orelse return error.InvalidResourceFile;
        const options = after.next() orelse return error.InvalidResourceFile;
        if (controller == .unified) {
            if (!std.mem.eql(u8, filesystem, "cgroup2")) continue;
        } else if (!std.mem.eql(u8, filesystem, "cgroup") or
            !contains(options, @tagName(controller))) continue;
        var before = std.mem.tokenizeScalar(u8, line[0..separator], ' ');
        for (0..3) |_| _ = before.next() orelse return error.InvalidResourceFile;
        var mount_root_buffer: [4096]u8 = undefined;
        const mount_root = try unescape(
            before.next() orelse return error.InvalidResourceFile,
            &mount_root_buffer,
        );
        var mount_buffer: [4096]u8 = undefined;
        const mount = try unescape(before.next() orelse return error.InvalidResourceFile, &mount_buffer);
        if (!validAbsolutePath(mount_root) or !validAbsolutePath(mount)) return error.InvalidResourceFile;
        const suffix = if (std.mem.eql(u8, mount_root, "/"))
            group
        else if (std.mem.eql(u8, group, mount_root))
            ""
        else if (std.mem.startsWith(u8, group, mount_root) and group.len > mount_root.len and
            group[mount_root.len] == '/')
            group[mount_root.len..]
        else if (std.mem.eql(u8, group, "/"))
            ""
        else
            continue;
        var path_buffer: [8192]u8 = undefined;
        var path: []const u8 = std.fmt.bufPrint(&path_buffer, "{s}{s}", .{
            std.mem.trimEnd(u8, mount, "/"), suffix,
        }) catch return error.InvalidResourceFile;
        path = std.mem.trimEnd(u8, path, "/");
        var directory = root.openDir(io, std.mem.trimStart(u8, path, "/"), .{}) catch
            return error.ResourceDetectionUnavailable;
        directory.close(io);
        found = true;
        const boundary = std.mem.trimEnd(u8, mount, "/").len;
        while (true) {
            try resources.readGroup(io, root, path, controller);
            if (path.len == boundary) break;
            const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse
                return error.InvalidResourceFile;
            if (slash < boundary) return error.InvalidResourceFile;
            path = path[0..slash];
        }
    }
    if (!found) return error.ResourceDetectionUnavailable;
}

fn readGroup(
    resources: *Resources,
    io: std.Io,
    root: std.Io.Dir,
    path: []const u8,
    controller: Controller,
) Error!void {
    var buffer: [8192]u8 = undefined;
    if (controller == .unified) {
        if (try groupFile(io, root, path, "cpu.max", &buffer)) |text| {
            var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
            const quota = fields.next() orelse return error.InvalidResourceFile;
            const period = try number(fields.next() orelse return error.InvalidResourceFile);
            if (period == 0 or fields.next() != null) return error.InvalidResourceFile;
            if (!std.mem.eql(u8, quota, "max")) try resources.applyQuota(try number(quota), period);
        }
    } else if (controller == .cpu) {
        if (try groupFile(io, root, path, "cpu.cfs_quota_us", &buffer)) |text| {
            if (!std.mem.eql(u8, text, "-1")) {
                const quota = try number(text);
                const period = try number((try groupFile(io, root, path, "cpu.cfs_period_us", &buffer)) orelse
                    return error.ResourceDetectionUnavailable);
                try resources.applyQuota(quota, period);
            }
        }
    }
    if (controller == .unified or controller == .memory) {
        const names = if (controller == .unified)
            [_][]const u8{ "memory.max", "memory.high" }
        else
            [_][]const u8{ "memory.limit_in_bytes", "memory.limit_in_bytes" };
        for (names, 0..) |name, index| {
            if (controller == .memory and index == 1) break;
            const text = (try groupFile(io, root, path, name, &buffer)) orelse continue;
            if (std.mem.eql(u8, text, "max")) continue;
            const limit = try number(text);
            const usage_name = if (controller == .unified) "memory.current" else "memory.usage_in_bytes";
            const usage = try number((try groupFile(io, root, path, usage_name, &buffer)) orelse
                return error.ResourceDetectionUnavailable);
            if (limit < resources.report.memory_limit_bytes) {
                resources.report.memory_limit_bytes = limit;
                resources.report.memory_source = if (index == 1) .cgroup_high else .cgroup_max;
            }
            resources.report.memory_available_bytes = @min(
                resources.report.memory_available_bytes,
                limit -| usage,
            );
        }
    }
    if (controller == .unified or controller == .cpuset) {
        const name = if (controller == .unified) "cpuset.cpus.effective" else "cpuset.effective_cpus";
        const text = (try groupFile(io, root, path, name, &buffer)) orelse
            (try groupFile(io, root, path, "cpuset.cpus", &buffer));
        if (text) |cpus| {
            if (cpus.len != 0) resources.allowed.setIntersection(try cpuList(cpus));
        }
    }
    if (controller == .unified or controller == .pids) {
        if (try groupFile(io, root, path, "pids.max", &buffer)) |text| {
            if (!std.mem.eql(u8, text, "max")) {
                const limit = try number(text);
                const current = try number((try groupFile(io, root, path, "pids.current", &buffer)) orelse
                    return error.ResourceDetectionUnavailable);
                resources.report.available_threads = @min(
                    resources.report.available_threads orelse std.math.maxInt(u64),
                    limit -| current,
                );
            }
        }
    }
}

fn applyQuota(resources: *Resources, quota: u64, period: u64) Error!void {
    if (quota == 0 or period == 0) return error.InvalidResourceFile;
    const millis: u64 = @intCast(@min(std.math.maxInt(u64), @as(u128, quota) * 1000 / period));
    resources.report.cpu_quota_millis = @min(
        resources.report.cpu_quota_millis orelse std.math.maxInt(u64),
        millis,
    );
}

fn readCores(resources: *Resources, io: std.Io, root: std.Io.Dir) Error!void {
    var seen: CpuSet = .initEmpty();
    var iterator = resources.allowed.iterator(.{});
    while (iterator.next()) |cpu| {
        if (seen.isSet(cpu)) continue;
        var path: [128]u8 = undefined;
        const name = std.fmt.bufPrint(
            &path,
            "sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list",
            .{cpu},
        ) catch unreachable;
        var buffer: [8192]u8 = undefined;
        const text = (try readOptional(io, root, name, &buffer)) orelse {
            // Unknown SMT topology must not turn a large logical CPU count into
            // an equally large automatic transport pool.
            resources.cores = .initEmpty();
            resources.cores.set(resources.allowed.findFirstSet().?);
            resources.report.physical_cores = 1;
            return;
        };
        const siblings = try cpuList(text);
        if (!siblings.isSet(cpu)) return error.InvalidResourceFile;
        seen.setUnion(siblings);
        resources.cores.set(cpu);
    }
    resources.report.physical_cores = resources.cores.count();
    resources.report.topology_available = true;
}

/// Selects one CPU per physical core in NIC IRQ cache domains, excluding IRQ
/// cores and SMT siblings. Ambiguous or unsupported NIC topology leaves scheduler
/// placement intact. The returned mapping is stored in this value.
pub fn detectPlacement(resources: *Resources, io: std.Io, address: []const u8) Error!void {
    resources.placement_count = 0;
    resources.report.placement = .scheduler;
    if (std.mem.startsWith(u8, address, "127.") or std.mem.eql(u8, address, "::1")) return;
    var root = std.Io.Dir.openDirAbsolute(io, "/", .{}) catch return error.ResourceDetectionUnavailable;
    defer root.close(io);
    try resources.readPlacement(io, root);
}

fn readPlacement(resources: *Resources, io: std.Io, root: std.Io.Dir) Error!void {
    resources.placement_count = 0;
    if (!resources.report.topology_available) {
        resources.report.placement = .unavailable;
        return;
    }
    var network = root.openDir(io, "sys/class/net", .{ .iterate = true }) catch {
        resources.report.placement = .unavailable;
        return;
    };
    defer network.close(io);
    var iterator = network.iterate();
    var selected: [256]u8 = undefined;
    var selected_len: usize = 0;
    while (iterator.next(io) catch return error.ResourceDetectionUnavailable) |entry| {
        var path: [512]u8 = undefined;
        const device = std.fmt.bufPrint(&path, "{s}/device", .{entry.name}) catch continue;
        var directory = network.openDir(io, device, .{}) catch continue;
        directory.close(io);
        if (selected_len != 0) {
            resources.report.placement = .ambiguous;
            return;
        }
        if (entry.name.len > selected.len) return error.InvalidResourceFile;
        @memcpy(selected[0..entry.name.len], entry.name);
        selected_len = entry.name.len;
    }
    resources.report.placement = .unavailable;
    if (selected_len == 0) return;
    resources.readNic(io, root, selected[0..selected_len]) catch |err| switch (err) {
        error.ResourceDetectionUnavailable, error.InvalidResourceFile => return,
        else => return err,
    };
}

fn readNic(resources: *Resources, io: std.Io, root: std.Io.Dir, interface: []const u8) Error!void {
    var path_buffer: [8192]u8 = undefined;
    const nic_path = std.fmt.bufPrint(&path_buffer, "sys/class/net/{s}", .{interface}) catch
        return error.InvalidResourceFile;
    var nic = root.openDir(io, nic_path, .{}) catch return error.ResourceDetectionUnavailable;
    defer nic.close(io);
    var queues = nic.openDir(io, "queues", .{ .iterate = true }) catch return error.ResourceDetectionUnavailable;
    defer queues.close(io);
    var queue_iterator = queues.iterate();
    var buffer: [8192]u8 = undefined;
    while (queue_iterator.next(io) catch return error.ResourceDetectionUnavailable) |queue| {
        if (!std.mem.startsWith(u8, queue.name, "rx-")) continue;
        const name = std.fmt.bufPrint(&path_buffer, "{s}/rps_cpus", .{queue.name}) catch
            return error.InvalidResourceFile;
        const rps = (try readOptional(io, queues, name, &buffer)) orelse
            return error.ResourceDetectionUnavailable;
        for (rps) |byte| {
            if (byte != '0' and byte != ',') return;
        }
    }
    var irq_cpus: CpuSet = .initEmpty();
    var irqs = nic.openDir(io, "device/msi_irqs", .{ .iterate = true }) catch null;
    if (irqs) |*directory| {
        defer directory.close(io);
        var iterator = directory.iterate();
        while (iterator.next(io) catch return error.ResourceDetectionUnavailable) |entry| {
            try readIrq(io, root, try number(entry.name), &irq_cpus);
        }
    }
    if (irq_cpus.count() == 0) {
        const irq = try number((try readOptional(io, nic, "device/irq", &buffer)) orelse
            return error.ResourceDetectionUnavailable);
        if (irq == 0) return;
        try readIrq(io, root, irq, &irq_cpus);
    }
    var excluded: CpuSet = .initEmpty();
    var domains: [256]CpuSet = undefined;
    var domain_count: usize = 0;
    var iterator = irq_cpus.iterator(.{});
    while (iterator.next()) |cpu| {
        const siblings_path = std.fmt.bufPrint(
            &path_buffer,
            "sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list",
            .{cpu},
        ) catch unreachable;
        excluded.setUnion(try cpuList((try readOptional(io, root, siblings_path, &buffer)) orelse
            return error.ResourceDetectionUnavailable));
        const cache_path = std.fmt.bufPrint(
            &path_buffer,
            "sys/devices/system/cpu/cpu{d}/cache",
            .{cpu},
        ) catch unreachable;
        var caches = root.openDir(io, cache_path, .{ .iterate = true }) catch
            return error.ResourceDetectionUnavailable;
        defer caches.close(io);
        var cache_iterator = caches.iterate();
        var found = false;
        while (cache_iterator.next(io) catch return error.ResourceDetectionUnavailable) |entry| {
            const level_path = std.fmt.bufPrint(&path_buffer, "{s}/level", .{entry.name}) catch
                return error.InvalidResourceFile;
            const level = (try readOptional(io, caches, level_path, &buffer)) orelse continue;
            if (!std.mem.eql(u8, level, "3")) continue;
            const shared_path = std.fmt.bufPrint(&path_buffer, "{s}/shared_cpu_list", .{entry.name}) catch
                return error.InvalidResourceFile;
            var domain = try cpuList((try readOptional(io, caches, shared_path, &buffer)) orelse
                return error.ResourceDetectionUnavailable);
            domain.setIntersection(resources.cores);
            var duplicate = false;
            for (domains[0..domain_count]) |previous| {
                if (previous.eql(domain)) duplicate = true;
            }
            if (!duplicate) {
                if (domain_count == domains.len) return error.InvalidResourceFile;
                domains[domain_count] = domain;
                domain_count += 1;
            }
            found = true;
            break;
        }
        if (!found) return error.ResourceDetectionUnavailable;
    }
    var used = excluded;
    while (resources.placement_count < resources.placement.len) {
        var advanced = false;
        for (domains[0..domain_count]) |domain| {
            var candidates = domain;
            candidates.setIntersection(used.complement());
            const cpu = candidates.findFirstSet() orelse continue;
            resources.placement[resources.placement_count] = @intCast(cpu);
            resources.placement_count += 1;
            used.set(cpu);
            advanced = true;
            if (resources.placement_count == resources.placement.len) break;
        }
        if (!advanced) break;
    }
    if (resources.placement_count != 0) resources.report.placement = .nic;
}

fn readIrq(io: std.Io, root: std.Io.Dir, irq: u64, cpus: *CpuSet) Error!void {
    var path: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&path, "proc/irq/{d}/effective_affinity_list", .{irq}) catch unreachable;
    var buffer: [8192]u8 = undefined;
    cpus.setUnion(try cpuList((try readOptional(io, root, name, &buffer)) orelse
        return error.ResourceDetectionUnavailable));
}

fn readOptional(io: std.Io, root: std.Io.Dir, path: []const u8, buffer: []u8) Error!?[]const u8 {
    const text = root.readFile(io, path, buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.ResourceDetectionUnavailable,
    };
    if (text.len == buffer.len) return error.InvalidResourceFile;
    return std.mem.trim(u8, text, " \t\r\n");
}

fn groupFile(io: std.Io, root: std.Io.Dir, group: []const u8, name: []const u8, buffer: []u8) Error!?[]const u8 {
    var path_buffer: [8192]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{
        std.mem.trimStart(u8, group, "/"), name,
    }) catch return error.InvalidResourceFile;
    return readOptional(io, root, path, buffer);
}

fn meminfoBytes(text: []const u8, key: []const u8) Error!u64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, fields.next().?, key)) continue;
        const amount = try number(fields.next() orelse return error.InvalidResourceFile);
        if (!std.mem.eql(u8, fields.next() orelse return error.InvalidResourceFile, "kB"))
            return error.InvalidResourceFile;
        return std.math.mul(u64, amount, 1024) catch return error.InvalidResourceFile;
    }
    return error.InvalidResourceFile;
}

fn number(text: []const u8) Error!u64 {
    if (text.len == 0) return error.InvalidResourceFile;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidResourceFile;
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidResourceFile;
}

fn cpuList(text: []const u8) Error!CpuSet {
    var result: CpuSet = .initEmpty();
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), ',');
    while (parts.next()) |part| {
        var range = std.mem.splitScalar(u8, part, '-');
        const first = try number(range.next().?);
        const last = if (range.next()) |end| try number(end) else first;
        if (range.next() != null or last < first) return error.InvalidResourceFile;
        if (last >= result.capacity()) return error.AffinityMaskTooSmall;
        for (@intCast(first)..@as(usize, @intCast(last)) + 1) |cpu| result.set(cpu);
    }
    return result;
}

fn contains(csv: []const u8, item: []const u8) bool {
    var parts = std.mem.splitScalar(u8, csv, ',');
    while (parts.next()) |part| if (std.mem.eql(u8, part, item)) return true;
    return false;
}

fn validAbsolutePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            std.mem.indexOfScalar(u8, part, 0) != null) return false;
    }
    return true;
}

fn unescape(text: []const u8, buffer: []u8) Error![]const u8 {
    var read_index: usize = 0;
    var written: usize = 0;
    while (read_index < text.len) : (written += 1) {
        if (written == buffer.len) return error.InvalidResourceFile;
        if (text[read_index] == '\\') {
            if (text.len - read_index < 4) return error.InvalidResourceFile;
            buffer[written] = std.fmt.parseInt(u8, text[read_index + 1 ..][0..3], 8) catch
                return error.InvalidResourceFile;
            read_index += 4;
        } else {
            buffer[written] = text[read_index];
            read_index += 1;
        }
    }
    return buffer[0..written];
}

fn fixtureFile(directory: std.Io.Dir, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try directory.createDirPath(std.testing.io, parent);
    try directory.writeFile(std.testing.io, .{ .sub_path = path, .data = text });
}

fn fixtureHost(directory: std.Io.Dir) !void {
    try fixtureFile(directory, "proc/meminfo", "MemTotal: 8388608 kB\nMemAvailable: 6291456 kB\n");
    for (0..8) |cpu| {
        var path: [128]u8 = undefined;
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &path,
            "sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list",
            .{cpu},
        );
        try fixtureFile(directory, name, try std.fmt.bufPrint(
            &buffer,
            "{d},{d}\n",
            .{ cpu % 4, cpu % 4 + 4 },
        ));
    }
}

test "resource discovery enforces v2 parents including high memory and cpusets" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = temporary.dir;
    try fixtureHost(root);
    try fixtureFile(root, "proc/self/cgroup", "0::/tenant/service\n");
    try fixtureFile(root, "proc/self/mountinfo", "1 0 0:1 / /cg rw - cgroup2 cgroup rw\n");
    try fixtureFile(root, "cg/tenant/service/cpu.max", "400000 100000\n");
    try fixtureFile(root, "cg/tenant/cpu.max", "200000 100000\n");
    try fixtureFile(root, "cg/cpu.max", "max 100000\n");
    try fixtureFile(root, "cg/tenant/service/memory.max", "2147483648\n");
    try fixtureFile(root, "cg/tenant/service/memory.current", "67108864\n");
    try fixtureFile(root, "cg/tenant/memory.max", "1073741824\n");
    try fixtureFile(root, "cg/tenant/memory.high", "805306368\n");
    try fixtureFile(root, "cg/tenant/memory.current", "134217728\n");
    try fixtureFile(root, "cg/tenant/cpuset.cpus.effective", "1-3,5-7\n");
    try fixtureFile(root, "cg/tenant/pids.max", "32\n");
    try fixtureFile(root, "cg/tenant/pids.current", "8\n");
    const resources = try read(testing.allocator, testing.io, root, try cpuList("0-7"), 512);
    try testing.expectEqual(.v2, resources.report.cgroup);
    try testing.expectEqual(@as(?u64, 2000), resources.report.cpu_quota_millis);
    try testing.expectEqual(@as(u64, 805306368), resources.report.memory_limit_bytes);
    try testing.expectEqual(@as(u64, 671088640), resources.report.memory_available_bytes);
    try testing.expectEqual(.cgroup_high, resources.report.memory_source);
    try testing.expectEqual(@as(usize, 6), resources.report.allowed_cpus);
    try testing.expectEqual(@as(usize, 3), resources.report.physical_cores);
    try testing.expectEqual(@as(?u64, 24), resources.report.available_threads);
    try testing.expectEqual(@as(u64, 512), resources.report.nofile_limit);
}

test "resource discovery resolves v1 controller mounts with escaped subtree paths" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = temporary.dir;
    try fixtureHost(root);
    try fixtureFile(root, "proc/self/cgroup", "2:cpu,cpuacct:/tenant/app\n3:memory:/tenant/app\n");
    try fixtureFile(root, "proc/self/mountinfo", "1 0 0:1 /tenant /cpu\\040limits rw - cgroup cgroup rw,cpu,cpuacct\n" ++
        "2 0 0:2 /tenant /mem rw - cgroup cgroup rw,memory\n");
    try fixtureFile(root, "cpu limits/app/cpu.cfs_quota_us", "-1\n");
    try fixtureFile(root, "cpu limits/cpu.cfs_quota_us", "50000\n");
    try fixtureFile(root, "cpu limits/cpu.cfs_period_us", "100000\n");
    try fixtureFile(root, "mem/app/memory.limit_in_bytes", "9223372036854771712\n");
    try fixtureFile(root, "mem/app/memory.usage_in_bytes", "1048576\n");
    try fixtureFile(root, "mem/memory.limit_in_bytes", "268435456\n");
    try fixtureFile(root, "mem/memory.usage_in_bytes", "67108864\n");
    const resources = try read(testing.allocator, testing.io, root, try cpuList("2,6"), 128);
    try testing.expectEqual(.v1, resources.report.cgroup);
    try testing.expectEqual(@as(?u64, 500), resources.report.cpu_quota_millis);
    try testing.expectEqual(@as(u64, 268435456), resources.report.memory_limit_bytes);
    try testing.expectEqual(@as(u64, 201326592), resources.report.memory_available_bytes);
    try testing.expectEqual(@as(usize, 1), resources.report.physical_cores);
}

test "resource discovery supports a cgroup namespace root and unlimited controllers" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = temporary.dir;
    try fixtureHost(root);
    try fixtureFile(root, "proc/self/cgroup", "0::/\n");
    try fixtureFile(root, "proc/self/mountinfo", "1 0 0:1 /container/service /cg rw - cgroup2 cgroup rw\n");
    try fixtureFile(root, "cg/cpu.max", "max 100000\n");
    try fixtureFile(root, "cg/memory.max", "max\n");
    try fixtureFile(root, "cg/memory.high", "max\n");
    const resources = try read(testing.allocator, testing.io, root, try cpuList("0,1"), 256);
    try testing.expectEqual(@as(?u64, null), resources.report.cpu_quota_millis);
    try testing.expectEqual(@as(u64, 6 * 1024 * 1024 * 1024), resources.report.memory_available_bytes);
    try testing.expectEqual(.host, resources.report.memory_source);
}

test "resource discovery rejects broken service limits instead of using host totals" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = temporary.dir;
    try fixtureHost(root);
    try fixtureFile(root, "proc/self/cgroup", "0::/service\n");
    try fixtureFile(root, "proc/self/mountinfo", "1 0 0:1 / /cg rw - cgroup2 cgroup rw\n");
    try fixtureFile(root, "cg/service/cpu.max", "max 100000\n");
    try fixtureFile(root, "cg/cpu.max", "garbage 100000\n");
    try testing.expectError(
        error.InvalidResourceFile,
        read(testing.allocator, testing.io, root, try cpuList("0-7"), 256),
    );
    try fixtureFile(root, "cg/cpu.max", "100000 0\n");
    try testing.expectError(
        error.InvalidResourceFile,
        read(testing.allocator, testing.io, root, try cpuList("0-7"), 256),
    );
    try fixtureFile(root, "proc/self/mountinfo", "1 0 0:1 /unrelated /cg rw - cgroup2 cgroup rw\n");
    try testing.expectError(
        error.ResourceDetectionUnavailable,
        read(testing.allocator, testing.io, root, try cpuList("0-7"), 256),
    );
}

test "resource placement excludes IRQ siblings and rotates through local physical cores" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = temporary.dir;
    try fixtureHost(root);
    try fixtureFile(root, "proc/self/cgroup", "0::/\n");
    try fixtureFile(root, "proc/self/mountinfo", "1 0 0:1 / /cg rw - cgroup2 cgroup rw\n");
    try fixtureFile(root, "cg/cpu.max", "max 100000\n");
    try fixtureFile(root, "sys/class/net/eth0/queues/rx-0/rps_cpus", "00000000\n");
    try fixtureFile(root, "sys/class/net/eth0/device/msi_irqs/20", "msi\n");
    try fixtureFile(root, "proc/irq/20/effective_affinity_list", "4\n");
    try fixtureFile(root, "sys/devices/system/cpu/cpu4/cache/index3/level", "3\n");
    try fixtureFile(root, "sys/devices/system/cpu/cpu4/cache/index3/shared_cpu_list", "0-7\n");
    var resources = try read(testing.allocator, testing.io, root, try cpuList("0-7"), 256);
    try resources.readPlacement(testing.io, root);
    try testing.expectEqual(.nic, resources.report.placement);
    try testing.expectEqualSlices(
        u16,
        &.{
            1,
            2,
            3,
        },
        resources.placement[0..resources.placement_count],
    );
    try fixtureFile(root, "sys/class/net/eth0/queues/rx-0/rps_cpus", "00000001\n");
    resources.placement_count = 0;
    try resources.readPlacement(testing.io, root);
    try testing.expectEqual(@as(usize, 0), resources.placement_count);
    try testing.expectEqual(.unavailable, resources.report.placement);
    try fixtureFile(root, "sys/class/net/eth1/device/irq", "21\n");
    try resources.readPlacement(testing.io, root);
    try testing.expectEqual(.ambiguous, resources.report.placement);
}
