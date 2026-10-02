//! Descriptor-relative file lookup without following symlinks.

const std = @import("std");
const linux = std.os.linux;

pub const Error = std.Io.Dir.OpenError || std.Io.File.OpenError;

/// Rejects empty, dot, parent and control-character components.
pub fn validSegment(segment: []const u8, dotfiles: bool) bool {
    if (segment.len == 0 or std.mem.eql(u8, segment, ".") or
        std.mem.eql(u8, segment, "..")) return false;
    if (!dotfiles and segment[0] == '.') return false;
    for (segment) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '\\') return false;
    }
    return true;
}

/// Assumes validated path components. Returns an owned file without following symlinks.
pub fn openPath(io: std.Io, root: std.Io.Dir, path: []const u8) Error!std.Io.File {
    var directory = root;
    var owned = false;
    defer if (owned) directory.close(io);
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    var segment = segments.next() orelse return openFile(root, ".");
    while (segments.next()) |next| {
        // Each lookup contains one component: NOFOLLOW also protects ancestors.
        const child = try directory.openDir(io, segment, .{ .follow_symlinks = false });
        if (owned) directory.close(io);
        directory = child;
        owned = true;
        segment = next;
    }
    return openFile(directory, segment);
}

/// Assumes one validated component. Returns an owned descriptor; callers must stat
/// it before reading because it may refer to a directory or a special file.
pub fn openFile(directory: std.Io.Dir, name: []const u8) Error!std.Io.File {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (name.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    while (true) {
        // NONBLOCK prevents a FIFO from occupying a lane indefinitely before stat
        // rejects it; NOCTTY prevents device nodes from acquiring a controlling tty.
        const result = linux.openat(directory.handle, buffer[0..name.len :0], .{
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
            .NOCTTY = true,
        }, 0);
        switch (linux.errno(result)) {
            .SUCCESS => return .{ .handle = @intCast(result), .flags = .{ .nonblocking = true } },
            .INTR => continue,
            .NOENT, .NOTDIR, .LOOP, .NXIO, .NODEV => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE, .NFILE, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}
