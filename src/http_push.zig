//! Shared origin validation and deadline-bound HTTP delivery for telemetry senders.

const std = @import("std");

pub const UrlError = error{InvalidOriginUrl};
pub const PostError = std.mem.Allocator.Error || std.Io.ConcurrentError || std.Io.Cancelable;

/// Returns an HTTP(S) origin borrowing url, without DNS or network I/O.
/// Rejects credentials, non-root paths, queries, fragments and invalid hosts.
pub fn parseOrigin(url: []const u8) UrlError!std.Uri {
    for (url) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidOriginUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidOriginUrl;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or uri.port == 0)
        return error.InvalidOriginUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.InvalidOriginUrl;
    // Uri.parse is deliberately permissive; validate before passing its host
    // to HTTP APIs that assume a validated hostname or bracketed IP literal.
    const host = uri.host.?.percent_encoded;
    if (host[0] == '[') {
        _ = std.Io.net.IpAddress.parseLiteral(host) catch return error.InvalidOriginUrl;
    } else std.Io.net.HostName.validate(host) catch return error.InvalidOriginUrl;
    const authority = url[uri.scheme.len + 3 .. url.len - path.len];
    const host_end = if (uri.port != null) std.mem.lastIndexOfScalar(u8, authority, ':').? else authority.len;
    if (!std.mem.eql(u8, host, authority[0..host_end])) return error.InvalidOriginUrl;
    return uri;
}

const Completion = union(enum) {
    response: std.http.Client.FetchError!std.http.Client.FetchResult,
    deadline: std.Io.Cancelable!void,
};

/// Borrows all inputs until the request completes or its two-second deadline.
/// Returns false for transport errors, timeouts, redirects and non-2xx responses.
/// Allocation, concurrency and cancellation errors propagate to the caller.
/// The caller owns the client and may reuse its connections between deliveries.
pub fn post(
    client: *std.http.Client,
    uri: std.Uri,
    payload: []const u8,
    content_type: []const u8,
) PostError!bool {
    // Refresh verification time without rebuilding the client's cached CA bundle.
    if (client.now != null) client.now = std.Io.Clock.real.now(client.io);
    var results: [2]Completion = undefined;
    var selection: std.Io.Select(Completion) = .init(client.io, &results);
    defer selection.cancelDiscard();
    try selection.concurrent(.response, std.http.Client.fetch, .{ client, .{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = payload,
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = content_type } },
    } });
    try selection.concurrent(.deadline, std.Io.sleep, .{
        client.io,
        .fromSeconds(2),
        .awake,
    });
    return switch (try selection.await()) {
        .response => |response| if (response) |result| result.status.class() == .success else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => false,
        },
        .deadline => false,
    };
}
