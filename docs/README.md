# Documentation

## Guides

- [Build and run](getting-started.md): requirements, standalone resources, HTTPS, and listeners.
- [systemd service](systemd.md): installation, service configuration, TLS, and process limits.
- [Dependency maintenance](dependencies.md): bundled OpenSSL/libnghttp2, system linking, and updates.
- [Configuration and tuning](configuration.md): workers, lanes, CPU placement, and memory budgets.
- [Runtime](runtime.md): admission, overload, I/O batching, deadlines, and graceful shutdown.
- [Observability](observability.md): admin routes, metrics, structured logs, and inspection.
- [Embedding](embedding.md): dependency setup, server lifecycle, and low-level APIs.
- [Custom endpoints](endpoints.md): routing, middleware, JSON, uploads, response streams, and ownership.
- [Testing](testing.md): component, wire, library, fuzz, and load-test commands.

## Protocol and security

- [HTTP conformance](conformance.md): HTTP/1 semantics, supported scope, and application responsibilities.
- [HTTP/2](http2.md): multiplexing, flow control, stream budgets, and verification.
- [Failure-mode comparison](failure-modes.md): request, response, lifecycle, and
  HTTP/2 control-frame behavior compared with Node and Go.
- [TLS](tls.md): TLS 1.3 policy, certificates, resumption, and transport lifetimes.
- [Security review](security.md): defenses, regression evidence, and deployment boundaries.
- [Direct-server admission](native-admission.md) and [NGINX ingress](ingress.md): deployment options.

## Performance evidence

- [Browser report](benchmarks.html): offline charts, reports, and summary downloads.
- [Recorded runs](runs/README.md): result catalogs, run setup, and artifact retention.
- [Benchmark guide](../bench/README.md): reproducible harnesses and methodology.
- [Access-log costs](access-log-performance.md): generation CPU, write batching, and retained records.
- [Architecture implementation](architecture-implementation.md): CPU placement, buffers, and executors.
- [SIMD](simd.md), [response aggregation](response-aggregation-integrated.md), and
  [request storage and uploads](nginx-implementation.md): measurements behind retained designs.
- [HTTP/2 implementation experiments](bun-http2-implementation.md) and
  [remote comparisons](http2-lan.md): optimizations, capacity, and workload limits.
- [Testing and load measurement](testing.md): links to historical comparisons and profiling reports.

Measurement reports retain their original dates and configurations; use the guides
and current source for supported settings.
