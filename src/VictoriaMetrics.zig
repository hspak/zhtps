//! Periodic aggregate Prometheus snapshots delivered outside the HTTP event loops.

const std = @import("std");
const Metrics = @import("Metrics.zig");
const http_push = @import("http_push.zig");
const metrics_format = @import("metrics_format.zig");
const VictoriaMetrics = @This();

client: std.http.Client,
origin: std.Uri,
metrics: *Metrics,
labels: [1024]u8 = undefined,
labels_len: usize,
buffer: [256 * 1024]u8 = undefined,
future: ?std.Io.Future(void) = null,

pub const UrlError = error{InvalidVictoriaMetricsUrl};
pub const InitError = UrlError || error{IdentityTooLong};
pub const StartError = std.Io.ConcurrentError;

pub const Identity = struct {
    address: []const u8,
    port: u16,
};

/// Returns an HTTP(S) origin borrowing url, without DNS or network I/O.
/// Rejects credentials, non-root paths, queries, fragments and invalid hosts.
pub fn parseOrigin(url: []const u8) UrlError!std.Uri {
    return http_push.parseOrigin(url) catch return error.InvalidVictoriaMetricsUrl;
}

/// Borrows io, url and metrics until deinit; copies the bound listener identity.
/// io must support concurrent, cancellable network operations. Uses an independent
/// allocator so publishing does not race the serving application's allocator.
pub fn init(
    self: *VictoriaMetrics,
    io: std.Io,
    url: []const u8,
    metrics: *Metrics,
    identity: Identity,
) InitError!void {
    const origin = try parseOrigin(url);
    var labels: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&labels);
    const uts = std.posix.uname();
    var instance_buffer: [128]u8 = undefined;
    const instance = std.fmt.bufPrint(&instance_buffer, "[{s}]:{d}", .{
        identity.address,
        identity.port,
    }) catch return error.IdentityTooLong;
    writer.writeAll("extra_label=job=zhtps&extra_label=host=") catch unreachable;
    writeQueryValue(&writer, std.mem.sliceTo(&uts.nodename, 0)) catch return error.IdentityTooLong;
    writer.writeAll("&extra_label=instance=") catch return error.IdentityTooLong;
    writeQueryValue(&writer, instance) catch return error.IdentityTooLong;
    self.* = .{
        .client = .{ .allocator = std.heap.page_allocator, .io = io },
        .origin = origin,
        .metrics = metrics,
        .labels_len = writer.end,
    };
    @memcpy(self.labels[0..writer.end], writer.buffered());
}

/// Starts publishing immediately and then ten seconds after each completed attempt.
/// Source.writePrometheus must snapshot atomic metrics into the supplied writer.
/// Borrows source and self at their final addresses until finish.
pub fn start(self: *VictoriaMetrics, comptime Source: type, source: *const Source) StartError!void {
    std.debug.assert(self.future == null);
    const task = struct {
        fn run(sender: *VictoriaMetrics, input: *const Source) void {
            while (true) {
                sender.push(Source, input) catch return;
                std.Io.sleep(sender.client.io, .fromSeconds(10), .awake) catch return;
            }
        }
    };
    self.future = try self.client.io.concurrent(task.run, .{ self, source });
}

/// Call after all producers stop. Cancels any in-flight request, then attempts
/// one final snapshot with a two-second network deadline. No retries or spool.
pub fn finish(self: *VictoriaMetrics, comptime Source: type, source: *const Source) void {
    if (self.future) |*future| future.cancel(self.client.io);
    self.future = null;
    self.push(Source, source) catch {};
}

/// Releases the HTTP client and its cached connections. Call finish if started.
pub fn deinit(self: *VictoriaMetrics) void {
    std.debug.assert(self.future == null);
    self.client.deinit();
    self.* = undefined;
}

fn push(self: *VictoriaMetrics, comptime Source: type, source: *const Source) std.Io.Cancelable!void {
    try self.client.io.checkCancel();
    const timestamp_ms = std.Io.Clock.real.now(self.client.io).toMilliseconds();
    var writer: std.Io.Writer = .fixed(&self.buffer);
    source.writePrometheus(&writer) catch {
        self.metrics.add(.metrics_push_errors_total, 1);
        return;
    };
    var query_buffer: [1088]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buffer, "{s}&timestamp={d}", .{
        self.labels[0..self.labels_len],
        timestamp_ms,
    }) catch unreachable;
    var uri = self.origin;
    uri.path = .{ .percent_encoded = "/api/v1/import/prometheus" };
    uri.query = .{ .percent_encoded = query };
    const succeeded = http_push.post(
        &self.client,
        uri,
        writer.buffered(),
        metrics_format.prometheus.content_type,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory, error.ConcurrencyUnavailable => false,
    };
    self.metrics.add(if (succeeded) .metrics_pushes_total else .metrics_push_errors_total, 1);
}

fn writeQueryValue(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else try writer.print("%{X:0>2}", .{byte});
    }
}

const OversizedSnapshot = struct {
    fn writePrometheus(_: *const OversizedSnapshot, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.splatByteAll('x', 1024 * 1024);
    }
};

test "VictoriaMetrics counts oversized snapshots as delivery errors" {
    const testing = std.testing;
    var metrics: Metrics = .{};
    var sender: VictoriaMetrics = undefined;
    try sender.init(testing.io, "http://localhost:8428", &metrics, .{
        .address = "127.0.0.1",
        .port = 8080,
    });
    defer sender.deinit();
    try sender.push(OversizedSnapshot, &.{});
    try testing.expectEqual(@as(u64, 1), metrics.get(.metrics_push_errors_total));
    try testing.expectEqual(@as(u64, 0), metrics.get(.metrics_pushes_total));
}
