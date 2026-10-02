//! Immutable lookup of boot-compressed files, owned by one server instance.

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const path = @import("path.zig");
const zstd = @import("zstd.zig");
const Cache = @This();

directory: std.Io.Dir,
temporary_path: []const u8,
entries: std.AutoHashMapUnmanaged(Snapshot, Entry) = .empty,

pub const Mount = struct {
    root: []const u8,
    dotfiles: bool,
};

const Entry = struct {
    name: [16]u8,
    length: u64,
};

pub const Selected = struct {
    /// Caller owns this descriptor.
    file: std.Io.File,
    length: u64,
};

pub const Error = Allocator.Error || path.Error || zstd.Error ||
    std.Io.File.StatError || std.Io.Dir.Reader.Error || std.Io.Dir.CreateDirError ||
    std.Io.Dir.CreateFileAtomicError || std.Io.File.Atomic.ReplaceError ||
    error{ StaticTreeTooDeep, MetadataUnavailable };

/// Creates an empty private cache in /tmp. The caller owns it until deinit.
pub fn init(gpa: Allocator, io: std.Io) Error!Cache {
    var random: [16]u8 = undefined;
    io.random(&random);
    const name = try std.fmt.allocPrint(gpa, "/tmp/zhtps-zstd-{s}", .{std.fmt.bytesToHex(random, .lower)});
    errdefer gpa.free(name);
    try std.Io.Dir.cwd().createDir(io, name, .fromMode(0o700));
    errdefer std.Io.Dir.cwd().deleteTree(io, name) catch {};
    const directory = try std.Io.Dir.cwd().openDir(io, name, .{ .follow_symlinks = false });
    return .{ .directory = directory, .temporary_path = name };
}

/// Removes generated files and releases the index. No requests may still use it.
pub fn deinit(cache: *Cache, gpa: Allocator, io: std.Io) void {
    cache.entries.deinit(gpa);
    cache.directory.close(io);
    std.Io.Dir.cwd().deleteTree(io, cache.temporary_path) catch {};
    gpa.free(cache.temporary_path);
    cache.* = undefined;
}

/// Prepares a mount synchronously before publishing the cache to request threads.
/// Errors leave acquired entries owned by cache and safe to release with deinit.
pub fn prepare(cache: *Cache, gpa: Allocator, io: std.Io, mount: Mount) Error!void {
    const root = try std.Io.Dir.cwd().openDir(io, mount.root, .{ .iterate = true });
    defer root.close(io);
    try cache.walk(gpa, io, root, mount.dotfiles, 0);
}

fn walk(cache: *Cache, gpa: Allocator, io: std.Io, directory: std.Io.Dir, dotfiles: bool, depth: usize) Error!void {
    if (depth == 128) return error.StaticTreeTooDeep;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!path.validSegment(entry.name, dotfiles)) continue;
        var kind = entry.kind;
        if (kind == .unknown) {
            const probe = path.openFile(directory, entry.name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer probe.close(io);
            kind = (try probe.stat(io)).kind;
        }
        if (kind == .directory) {
            const child = try directory.openDir(io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer child.close(io);
            try cache.walk(gpa, io, child, dotfiles, depth + 1);
        } else if (kind == .file) {
            if (!compressible(entry.name)) continue;
            const file = try path.openFile(directory, entry.name);
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size < 1024) continue;
            const snapshot = try Snapshot.read(file);
            if (!snapshot.matches(stat)) return error.FileChanged;
            if (cache.entries.contains(snapshot)) continue;
            const name = std.fmt.hex(@as(u64, cache.entries.count()));
            var output = try cache.directory.createFileAtomic(io, &name, .{
                .replace = true,
                .permissions = .fromMode(0o600),
            });
            defer output.deinit(io);
            const length = try zstd.compress(io, file, stat.size, output.file);
            if (!std.meta.eql(snapshot, try Snapshot.read(file))) return error.FileChanged;
            if (length >= stat.size) continue;
            try cache.entries.ensureUnusedCapacity(gpa, 1);
            try output.replace(io);
            cache.entries.putAssumeCapacity(snapshot, .{ .name = name, .length = length });
        }
    }
}

/// Returns an owned compressed descriptor only if the opened source still matches
/// its boot-time snapshot. Missing or changed cache files fall back to identity.
pub fn select(cache: *const Cache, io: std.Io, source: std.Io.File, stat: std.Io.File.Stat) Error!?Selected {
    const snapshot = try Snapshot.read(source);
    if (!snapshot.matches(stat)) return null;
    const entry = cache.entries.get(snapshot) orelse return null;
    const file = path.openFile(cache.directory, &entry.name) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return null,
        else => return err,
    };
    errdefer file.close(io);
    const compressed_stat = try file.stat(io);
    if (compressed_stat.kind != .file or compressed_stat.size != entry.length) {
        file.close(io);
        return null;
    }
    return .{ .file = file, .length = entry.length };
}

const Snapshot = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
    size: u64,
    mtime: i128,
    ctime: i128,

    fn read(file: std.Io.File) error{MetadataUnavailable}!Snapshot {
        var stat: linux.Statx = undefined;
        while (true) {
            switch (linux.errno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .BASIC_STATS, &stat))) {
                .SUCCESS => break,
                .INTR => continue,
                else => return error.MetadataUnavailable,
            }
        }
        if (!stat.mask.INO or !stat.mask.SIZE or !stat.mask.MTIME or !stat.mask.CTIME)
            return error.MetadataUnavailable;
        return .{
            .device_major = stat.dev_major,
            .device_minor = stat.dev_minor,
            .inode = stat.ino,
            .size = stat.size,
            .mtime = @as(i128, stat.mtime.sec) * std.time.ns_per_s + stat.mtime.nsec,
            .ctime = @as(i128, stat.ctime.sec) * std.time.ns_per_s + stat.ctime.nsec,
        };
    }

    fn matches(snapshot: Snapshot, stat: std.Io.File.Stat) bool {
        return snapshot.inode == stat.inode and snapshot.size == stat.size and
            snapshot.mtime == stat.mtime.nanoseconds and snapshot.ctime == stat.ctime.nanoseconds;
    }
};

fn compressible(name: []const u8) bool {
    const extension = std.fs.path.extension(name);
    for ([_][]const u8{
        ".html",
        ".htm",
        ".css",
        ".js",
        ".mjs",
        ".json",
        ".map",
        ".webmanifest",
        ".txt",
        ".md",
        ".xml",
        ".svg",
        ".wasm",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    }
    return false;
}

test "static cache releases preparation resources after allocation failure" {
    const testing = std.testing;
    var root = testing.tmpDir(.{});
    defer root.cleanup();
    try root.dir.writeFile(testing.io, .{ .sub_path = "index.html", .data = "compress me\n" ** 2048 });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try root.dir.realPath(testing.io, &buffer);
    const prepareCache = struct {
        fn run(gpa: Allocator, source: []const u8) !void {
            var cache = try Cache.init(gpa, testing.io);
            defer cache.deinit(gpa, testing.io);
            try cache.prepare(gpa, testing.io, .{ .root = source, .dotfiles = false });
            try testing.expectEqual(@as(usize, 1), cache.entries.count());
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, prepareCache, .{buffer[0..length]});
}

test "static cache cleanup removes generated files" {
    const testing = std.testing;
    var cache = try Cache.init(testing.allocator, testing.io);
    const name = try testing.allocator.dupe(u8, cache.temporary_path);
    defer testing.allocator.free(name);
    cache.deinit(testing.allocator, testing.io);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, name, .{}));
}
