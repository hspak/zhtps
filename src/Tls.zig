//! OpenSSL server credentials and bounded, socket-independent TLS sessions.

const std = @import("std");
const Config = @import("Config.zig");
const c = @cImport({
    @cInclude("tls_openssl.h");
});
const log = std.log.scoped(.tls);
const Tls = @This();

handle: *c.SSL_CTX,

pub const Error = std.mem.Allocator.Error || error{
    InvalidCertificate,
    InvalidPrivateKey,
    InvalidTlsConfiguration,
    TlsProtocol,
};

pub const Session = struct {
    ssl: *c.SSL,
    network: *c.BIO,
    operation: Operation = .handshake,
    result: ?usize = null,
    failure_reason: ?Error = null,
    read_count: usize = 0,

    pub const Operation = union(enum) {
        handshake,
        read: []u8,
        write: []const u8,
        shutdown,
        idle,
    };

    pub const Step = union(enum) {
        receive: []u8,
        send: []const u8,
        complete: usize,
    };

    /// Owns an SSL object and a BIO pair with 18 KiB per direction. Neither
    /// OpenSSL nor this object accesses sockets. One worker owns each session.
    pub fn init(self: *Session, tls: *const Tls) Error!void {
        c.ERR_clear_error();
        const ssl = c.SSL_new(tls.handle) orelse return failure(error.OutOfMemory);
        errdefer c.SSL_free(ssl);
        var internal: ?*c.BIO = null;
        var network: ?*c.BIO = null;
        if (c.BIO_new_bio_pair(
            &internal,
            18 * 1024,
            &network,
            18 * 1024,
        ) != 1)
            return failure(error.OutOfMemory);
        c.SSL_set_bio(
            ssl,
            internal,
            internal,
        );
        c.SSL_set_accept_state(ssl);
        self.* = .{ .ssl = ssl, .network = network.? };
    }

    /// Call only after all network operations borrowing BIO storage complete.
    pub fn deinit(self: *Session) void {
        c.SSL_free(self.ssl);
        _ = c.BIO_free(self.network);
        self.* = undefined;
    }

    /// Reports whether the completed handshake resumed a previous TLS session.
    pub fn reused(self: *const Session) bool {
        return c.SSL_session_reused(self.ssl) == 1;
    }

    /// Reports whether ALPN selected h2; an absent selection uses HTTP/1.1.
    pub fn isHttp2(self: *const Session) bool {
        var protocol: [*c]const u8 = null;
        var len: c_uint = 0;
        c.SSL_get0_alpn_selected(
            self.ssl,
            &protocol,
            &len,
        );
        return len == 2 and std.mem.eql(
            u8,
            protocol[0..len],
            "h2",
        );
    }

    /// Copies ciphertext into the bounded BIO. The caller retains any remainder.
    /// These duplex methods require a completed handshake and transport buffers
    /// independent of BIO storage, so socket reads and writes can overlap.
    pub fn feedCiphertext(self: *Session, bytes: []const u8) usize {
        const count = c.BIO_write(
            self.network,
            bytes.ptr,
            @intCast(bytes.len),
        );
        return if (count > 0) @intCast(count) else 0;
    }

    /// Copies pending ciphertext into caller-owned asynchronous send storage.
    pub fn drainCiphertext(self: *Session, bytes: []u8) usize {
        const count = c.BIO_read(
            self.network,
            bytes.ptr,
            @intCast(bytes.len),
        );
        return if (count > 0) @intCast(count) else 0;
    }

    /// Null needs more ciphertext or output space; zero is authenticated EOF.
    pub fn readPlaintext(self: *Session, bytes: []u8) Error!?usize {
        c.ERR_clear_error();
        var count: usize = 0;
        const result = c.SSL_read_ex(
            self.ssl,
            bytes.ptr,
            bytes.len,
            &count,
        );
        if (result == 1) return count;
        return switch (c.SSL_get_error(self.ssl, result)) {
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => null,
            c.SSL_ERROR_ZERO_RETURN => 0,
            else => failure(error.TlsProtocol),
        };
    }

    /// Reserve room for a complete TLS record before writing. Avoids suspending
    /// application reads behind a write retry when the peer is a slow reader.
    pub fn canWritePlaintext(self: *Session, len: usize) bool {
        return c.BIO_ctrl_get_write_guarantee(c.SSL_get_wbio(self.ssl)) >= len + 64;
    }

    /// Null requires retrying with exactly the same bytes before another SSL
    /// operation. Feed/drain ciphertext between retries to make progress.
    pub fn writePlaintext(self: *Session, bytes: []const u8) Error!?usize {
        c.ERR_clear_error();
        var count: usize = 0;
        const result = c.SSL_write_ex(
            self.ssl,
            bytes.ptr,
            bytes.len,
            &count,
        );
        if (result == 1) return count;
        return switch (c.SSL_get_error(self.ssl, result)) {
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => null,
            else => failure(error.TlsProtocol),
        };
    }

    /// The plaintext slice stays borrowed, unchanged, until complete. Asserts
    /// the previous operation completed, except a read may be abandoned after
    /// its pending socket receive has been canceled and reaped.
    pub fn start(self: *Session, operation: Operation) void {
        std.debug.assert(self.operation == .idle or self.operation == .read);
        self.operation = operation;
        self.result = null;
        self.read_count = 0;
    }

    /// Commits bytes written into the receive slice returned by advance.
    pub fn received(self: *Session, count: usize) void {
        var buffer: [*c]u8 = undefined;
        const committed = c.BIO_nwrite(
            self.network,
            &buffer,
            @intCast(count),
        );
        std.debug.assert(committed == count);
    }

    /// Releases bytes from the send slice returned by advance after socket I/O.
    pub fn sent(self: *Session, count: usize) void {
        var buffer: [*c]u8 = undefined;
        const committed = c.BIO_nread(
            self.network,
            &buffer,
            @intCast(count),
        );
        std.debug.assert(committed == count);
    }

    /// Returns borrowed BIO storage or completes the plaintext operation. Do
    /// not call any SSL/BIO method while a returned slice is borrowed by I/O,
    /// except received/sent to commit its completion. Flushes output even on
    /// WANT_READ, avoiding the BIO-pair handshake deadlock documented by OpenSSL.
    pub fn advance(self: *Session) Error!Step {
        var read_calls: usize = 0;
        while (true) {
            var buffer: [*c]u8 = undefined;
            const pending = c.BIO_nread0(self.network, &buffer);
            if (pending > 0) return .{ .send = buffer[0..@intCast(pending)] };
            if (self.failure_reason) |err| return err;
            if (self.result) |count| {
                self.operation = .idle;
                self.result = null;
                return .{ .complete = count };
            }
            c.ERR_clear_error();
            var count: usize = 0;
            const result = switch (self.operation) {
                .handshake => c.SSL_do_handshake(self.ssl),
                .read => |bytes| c.SSL_read_ex(
                    self.ssl,
                    bytes[self.read_count..].ptr,
                    bytes.len - self.read_count,
                    &count,
                ),
                .write => |bytes| c.SSL_write_ex(
                    self.ssl,
                    bytes.ptr,
                    bytes.len,
                    &count,
                ),
                .shutdown => c.SSL_shutdown(self.ssl),
                .idle => unreachable,
            };
            if (result == 1 or (self.operation == .shutdown and result == 0)) {
                if (self.operation == .read) {
                    self.read_count += count;
                    read_calls += 1;
                    // Only OpenSSL-authenticated plaintext crosses into HTTP. Drain
                    // buffered records to expose pipelines, bounded by space and work.
                    if (self.read_count < self.operation.read.len and read_calls < 16 and
                        (c.SSL_has_pending(self.ssl) == 1 or
                            c.BIO_ctrl_pending(c.SSL_get_rbio(self.ssl)) != 0)) continue;
                    count = self.read_count;
                }
                self.result = count;
                continue;
            }
            // SSL_get_error must immediately follow the operation on this thread.
            const reason = c.SSL_get_error(self.ssl, result);
            switch (reason) {
                c.SSL_ERROR_WANT_READ => {
                    // A partial next record must not hold ready application bytes.
                    // OpenSSL owns its partial input; read retries may change buffers.
                    if (self.operation == .read and self.read_count != 0) {
                        self.result = self.read_count;
                        continue;
                    }
                    if (c.BIO_ctrl_pending(self.network) != 0) continue;
                    const available = c.BIO_nwrite0(self.network, &buffer);
                    if (available <= 0) return error.TlsProtocol;
                    return .{ .receive = buffer[0..@intCast(available)] };
                },
                c.SSL_ERROR_WANT_WRITE => {
                    if (c.BIO_ctrl_pending(self.network) == 0) return error.TlsProtocol;
                },
                c.SSL_ERROR_ZERO_RETURN => {
                    if (self.operation == .read)
                        self.result = self.read_count
                    else
                        self.failure_reason = error.TlsProtocol;
                },
                else => self.failure_reason = failure(error.TlsProtocol),
            }
        }
    }
};

comptime {
    if (c.OPENSSL_VERSION_MAJOR < 3) @compileError("ZHTPS requires OpenSSL 3 or newer");
}

/// Loads credentials before listeners start. Owns the OpenSSL configuration;
/// sessions may share it across threads, but configuration is immutable after init.
pub fn init(
    self: *Tls,
    gpa: std.mem.Allocator,
    options: Config.Tls,
) Error!void {
    const certificate = try gpa.dupeZ(u8, options.certificate);
    defer gpa.free(certificate);
    const private_key = try gpa.dupeZ(u8, options.private_key);
    defer gpa.free(private_key);
    c.ERR_clear_error();
    const handle = c.SSL_CTX_new(c.TLS_server_method()) orelse return failure(error.OutOfMemory);
    errdefer c.SSL_CTX_free(handle);
    if (c.SSL_CTX_set_min_proto_version(handle, c.TLS1_3_VERSION) != 1 or
        c.SSL_CTX_set_max_proto_version(handle, c.TLS1_3_VERSION) != 1)
        return failure(error.InvalidTlsConfiguration);
    _ = c.SSL_CTX_set_options(handle, c.zhtps_ssl_options);
    c.SSL_CTX_set_security_level(handle, 2);
    _ = c.SSL_CTX_set_mode(handle, c.SSL_MODE_RELEASE_BUFFERS);
    if (c.SSL_CTX_set_ciphersuites(
        handle,
        "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
    ) != 1)
        return failure(error.InvalidTlsConfiguration);
    // Keep modern group defaults supplied by the linked OpenSSL, including
    // hybrid post-quantum exchange where available.
    // Replayable early data must never reach ordinary application hooks.
    if (c.SSL_CTX_set_max_early_data(handle, 0) != 1)
        return failure(error.InvalidTlsConfiguration);
    c.SSL_CTX_set_default_passwd_cb(handle, rejectPassword);
    if (c.SSL_CTX_use_certificate_chain_file(handle, certificate.ptr) != 1)
        return failure(error.InvalidCertificate);
    if (c.SSL_CTX_use_PrivateKey_file(
        handle,
        private_key.ptr,
        c.SSL_FILETYPE_PEM,
    ) != 1 or
        c.SSL_CTX_check_private_key(handle) != 1) return failure(error.InvalidPrivateKey);
    c.SSL_CTX_set_alpn_select_cb(
        handle,
        selectProtocol,
        null,
    );
    // Shared credentials also share the bounded session cache and ticket keys
    // across all workers; no process-shared cache or custom ticket crypto needed.
    _ = c.SSL_CTX_set_session_cache_mode(handle, c.SSL_SESS_CACHE_SERVER);
    _ = c.SSL_CTX_sess_set_cache_size(handle, 1024);
    _ = c.SSL_CTX_set_timeout(handle, 300);
    if (c.SSL_CTX_set_session_id_context(
        handle,
        "zhtps",
        5,
    ) != 1)
        return failure(error.InvalidTlsConfiguration);
    self.* = .{ .handle = handle };
}

/// Releases credentials after every worker has released its sessions.
pub fn deinit(self: *Tls) void {
    c.SSL_CTX_free(self.handle);
    self.* = undefined;
}

fn rejectPassword(
    _: [*c]u8,
    _: c_int,
    _: c_int,
    _: ?*anyopaque,
) callconv(.c) c_int {
    return 0;
}

fn selectProtocol(
    _: ?*c.SSL,
    out: [*c][*c]const u8,
    out_len: [*c]u8,
    input: [*c]const u8,
    input_len: c_uint,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const protocols = input[0..input_len];
    for ([_][]const u8{ "h2", "http/1.1" }) |preferred| {
        var offset: usize = 0;
        while (offset < protocols.len) {
            const len = protocols[offset];
            offset += 1;
            if (len == 0 or len > protocols.len - offset) return c.SSL_TLSEXT_ERR_ALERT_FATAL;
            if (std.mem.eql(
                u8,
                protocols[offset..][0..len],
                preferred,
            )) {
                out.* = protocols[offset..].ptr;
                out_len.* = len;
                return c.SSL_TLSEXT_ERR_OK;
            }
            offset += len;
        }
    }
    return c.SSL_TLSEXT_ERR_ALERT_FATAL;
}

fn failure(fallback: Error) Error {
    @branchHint(.cold);
    var result = fallback;
    while (true) {
        const code = c.ERR_get_error();
        if (code == 0) return result;
        if (c.ERR_GET_REASON(code) == c.ERR_R_MALLOC_FAILURE) result = error.OutOfMemory;
    }
}
