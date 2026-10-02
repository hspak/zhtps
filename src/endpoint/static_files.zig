//! Directory-backed responses with bounded streaming and descriptor-relative path resolution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const file_path = @import("static_files/path.zig");
const validSegment = file_path.validSegment;
const openPath = file_path.openPath;
const openFile = file_path.openFile;
pub const Cache = @import("static_files/Cache.zig");
const encoding = @import("static_files/encoding.zig");
const http = @import("../http.zig");
const platform = @import("../platform.zig");
const ResponseStream = @import("ResponseStream.zig");

pub const Options = struct {
    /// URL-escaped path relative to directory. Null uses the request path without '/'.
    path: ?[]const u8 = null,
    /// A single filename, or null to disable index pages. Directories are never listed.
    index_file: ?[]const u8 = "index.html",
    cache_control: []const u8 = "no-cache",
    /// Allows dot-prefixed names, but never '.' or '..'.
    dotfiles: bool = false,
    /// Borrows a prepared cache through response selection. Null disables negotiation.
    cache: ?*const Cache = null,
};

pub const Error = Cache.Error || Allocator.Error || std.Io.Dir.OpenError || std.Io.File.OpenError ||
    std.Io.File.StatError || std.Io.File.ReadPositionalError || error{
    InvalidInput,
    FileChanged,
};

pub const Transfer = struct {
    /// Owned by the exchange through response completion, including HEAD and aborts.
    file: std.Io.File,
    length: u64,
};

/// Rejects invalid static configuration before an application can run.
pub fn validateOptions(comptime options: Options) void {
    if (options.index_file) |index| {
        if (!validSegment(index, options.dotfiles) or std.mem.indexOfScalar(u8, index, '/') != null)
            @compileError("static index_file must be a single permitted filename");
    }
    if (!http.syntax.isField(options.cache_control))
        @compileError("static cache_control must be a valid HTTP field");
}

/// Borrows directory for this call; transfers the opened file to the exchange only
/// after all fallible preparation succeeds. Response fields live in request scratch.
pub fn serve(call: anytype, directory: std.Io.Dir, options: Options) Error!http.Response {
    const gpa = call.scratch.allocator();
    const encoded = options.path orelse std.mem.trimStart(u8, call.request.path, "/");
    const path = decodePath(gpa, encoded, options.dotfiles) catch |err| switch (err) {
        error.InvalidInput => return call.text(.not_found, http.Response.errorBody(404)),
        error.OutOfMemory => return err,
    };
    var file = openPath(call.io, directory, path) catch |err| return failure(call, err);
    var owned = true;
    defer if (owned) file.close(call.io);
    var stat = try file.stat(call.io);
    var served_path: []const u8 = path;
    if (stat.kind == .directory) {
        const index = options.index_file orelse
            return call.text(.not_found, http.Response.errorBody(404));
        if (!validSegment(index, options.dotfiles) or std.mem.indexOfScalar(u8, index, '/') != null)
            return error.InvalidInput;
        const index_file = openFile(.{ .handle = file.handle }, index) catch |err|
            return failure(call, err);
        file.close(call.io);
        file = index_file;
        stat = try file.stat(call.io);
        if (stat.kind != .file) return call.text(.not_found, http.Response.errorBody(404));
        if (!std.mem.endsWith(u8, call.request.path, "/")) {
            // An absolute-path reference with one leading slash cannot redirect to
            // an authority when a request path begins with repeated slashes.
            const location = try std.fmt.allocPrint(gpa, "/{s}/{s}{s}", .{
                std.mem.trimStart(u8, call.request.path, "/"),
                if (call.request.query.len != 0) "?" else "",
                call.request.query,
            });
            return call.redirect(.permanent_redirect, location);
        }
        served_path = if (path.len == 0) index else try std.fmt.allocPrint(gpa, "{s}/{s}", .{
            std.mem.trimEnd(u8, path, "/"),
            index,
        });
    } else if (stat.kind != .file or std.mem.endsWith(u8, path, "/")) {
        return call.text(.not_found, http.Response.errorBody(404));
    }

    var length = stat.size;
    var compressed = false;
    if (options.cache) |cache| {
        const preferences = try encoding.parse(call.request.headers);
        if (preferences.zstd > 0 and preferences.zstd >= preferences.identity) {
            if (try cache.select(call.io, file, stat)) |selected| {
                file.close(call.io);
                file = selected.file;
                length = selected.length;
                compressed = true;
            }
        }
        if (!compressed and preferences.identity == 0) return .{
            .status = 406,
            .headers = &.{.{ .name = "Vary", .value = "Accept-Encoding" }},
            .body = .{ .bytes = "406 Not Acceptable\n" },
        };
    }
    const fields = try gpa.alloc(http.Header, 7);
    const etag = try std.fmt.allocPrint(gpa, "W/\"{s}{x}-{x}-{x}-{x}\"", .{
        if (compressed) "zstd-" else "",
        stat.inode,
        stat.size,
        stat.mtime.nanoseconds,
        stat.ctime.nanoseconds,
    });
    fields[0] = .{ .name = "Content-Type", .value = contentType(served_path) };
    fields[1] = .{ .name = "Cache-Control", .value = try gpa.dupe(u8, options.cache_control) };
    fields[2] = .{ .name = "ETag", .value = etag };
    fields[3] = .{ .name = "X-Content-Type-Options", .value = "nosniff" };
    var field_count: usize = 4;
    const modified = stat.mtime.toSeconds();
    // HTTP dates only represent years 1970 through 9999 here.
    if (modified >= 0 and modified < 253402300800) {
        const date = try gpa.create([29]u8);
        http.Response.formatDate(@intCast(modified), date);
        fields[field_count] = .{ .name = "Last-Modified", .value = date };
        field_count += 1;
    }
    if (options.cache != null) {
        fields[field_count] = .{ .name = "Vary", .value = "Accept-Encoding" };
        field_count += 1;
    }
    if (compressed) {
        fields[field_count] = .{ .name = "Content-Encoding", .value = "zstd" };
        field_count += 1;
    }
    const status = http.conditions.evaluate(call.request, .{
        .etag = etag,
        .last_modified = if (modified >= 0 and modified < 253402300800) modified else null,
    }, platform.realtimeNs(call.io) / std.time.ns_per_s) catch return error.InvalidInput;
    call.access.put("file_path", served_path);
    if (status) |code| return .{
        .status = code,
        .headers = fields[0 .. field_count - @as(usize, if (compressed and code != 304) 1 else 0)],
        .body = if (code == 304) .{ .stream = length } else .{ .bytes = "" },
    };
    if (call.response_file.*) |previous| previous.file.close(call.io);
    call.response_file.* = .{ .file = file, .length = length };
    owned = false;
    const C = @TypeOf(call.*);
    const producer = struct {
        fn run(request_call: *C, output: *ResponseStream) C.HandlerError!void {
            const transfer = request_call.response_file.*.?;
            var buffer: [16 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (offset < transfer.length) {
                if (request_call.isCanceled()) return error.Canceled;
                const size: usize = @intCast(@min(buffer.len, transfer.length - offset));
                const count = try transfer.file.readPositional(
                    request_call.io,
                    &.{buffer[0..size]},
                    offset,
                );
                if (count == 0) return error.FileChanged;
                try output.writer.writeAll(buffer[0..count]);
                offset += count;
            }
        }
    };
    return call.stream(.{
        .headers = fields[0..field_count],
        .length = length,
    }, producer.run);
}

fn failure(call: anytype, err: Error) Error!http.Response {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.NameTooLong,
        error.SymLinkLoop,
        error.AccessDenied,
        error.PermissionDenied,
        => call.text(.not_found, http.Response.errorBody(404)),
        else => err,
    };
}

// Successful paths borrow a prefix of their allocation from request scratch;
// invalid paths release the entire allocation before returning.
fn decodePath(gpa: Allocator, encoded: []const u8, dotfiles: bool) (Allocator.Error ||
    error{InvalidInput})![]const u8 {
    if (std.mem.startsWith(u8, encoded, "/")) return error.InvalidInput;
    const decoded = try gpa.alloc(u8, encoded.len);
    errdefer gpa.free(decoded);
    var read: usize = 0;
    var written: usize = 0;
    while (read < encoded.len) : (written += 1) {
        var byte = encoded[read];
        read += 1;
        if (byte == '%') {
            if (encoded.len - read < 2) return error.InvalidInput;
            const high = std.fmt.charToDigit(encoded[read], 16) catch return error.InvalidInput;
            const low = std.fmt.charToDigit(encoded[read + 1], 16) catch return error.InvalidInput;
            byte = high * 16 + low;
            read += 2;
            if (byte == '/') return error.InvalidInput;
        }
        if (byte < 0x20 or byte == 0x7f or byte == '\\') return error.InvalidInput;
        decoded[written] = byte;
    }
    const path = decoded[0..written];
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (!validSegment(segment, dotfiles)) return error.InvalidInput;
    }
    return path;
}

fn contentType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    const types = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".map", "application/json" },
        .{ ".webmanifest", "application/manifest+json" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".xml", "application/xml" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        .{ ".wasm", "application/wasm" },
        .{ ".pdf", "application/pdf" },
        .{ ".zip", "application/zip" },
        .{ ".gz", "application/gzip" },
        .{ ".mp4", "video/mp4" },
        .{ ".webm", "video/webm" },
        .{ ".mp3", "audio/mpeg" },
        .{ ".ogg", "audio/ogg" },
    };
    inline for (types) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

test "invalid static paths release decoding storage" {
    const testing = std.testing;
    for ([_][]const u8{
        "%",
        "%GG",
        "%2f",
        "%00",
        "a/..",
        ".hidden",
    }) |path| {
        try testing.expectError(error.InvalidInput, decodePath(testing.allocator, path, false));
    }
}

test {
    _ = Cache;
}
