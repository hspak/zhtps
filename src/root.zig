//! Embeddable HTTP/1.1 server for Zig 0.16 on Linux x86_64 with io_uring.

const server = @import("server.zig");

pub const http = @import("http.zig");
pub const Config = @import("Config.zig");
pub const Metrics = @import("Metrics.zig");
pub const metrics_format = @import("metrics_format.zig");
pub const Logger = @import("Logger.zig");
pub const Admission = @import("Admission.zig");
pub const application = @import("application.zig");
pub const Server = server.Server;
/// Server with the bundled root, echo, and stream resources; no router setup required.
pub const DefaultServer = Server(application);
pub const InitError = server.InitError;
pub const RunError = server.RunError;
pub const platform = @import("platform.zig");

test {
    _ = http;
    _ = Config;
    _ = Metrics;
    _ = metrics_format;
    _ = Logger;
    _ = Admission;
    _ = application;
    _ = platform;
    _ = server;
}
