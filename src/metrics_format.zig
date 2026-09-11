//! Renderers that consume Metrics.Snapshot without accessing live metric storage.

pub const prometheus = @import("metrics_format/prometheus.zig");
pub const json = @import("metrics_format/json.zig");

test {
    _ = prometheus;
    _ = json;
}
