# Admission before the origin

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

For a single-host deployment, use [direct-server admission](native-admission.md).
ZHTPS handles request admission itself, and the standalone connection policy can
protect its listener without an HTTP proxy. The NGINX bundle below is an optional
deployment choice when a proxy is wanted; distributed benchmark collection also
supports clients connecting directly to ZHTPS.

[The ingress generator](../deploy/ingress.py) creates an optional bundle for an NGINX host in
front of ZHTPS. Request rate, new-connection attempt rate, and reset-response rate
are separate, explicitly supplied budgets. The server's automatic per-worker
concurrency defaults and bounded HTTP rejection policy remain in effect.

There is no universal request-rate default. The 250,000 requests/s and 60,000
new connections/s figures in the [overload report](overload.md) are calibration
starting points for its particular host and workload, not limits inferred from
worker count or suitable for every application.

## Placement and behavior

```text
load-generator host -> ingress host -> private ZHTPS origin
                       |              |
                       |              existing per-worker admission
                       NGINX request rate + active-origin connection bound
                       nftables SYN rate + bounded reset responses
```

NGINX rejects excess requests before proxying them to the origin. Its shared
request budget is aggregate across all clients and NGINX workers in one instance.
`nodelay` prevents a rate-limit waiting queue. Excess requests receive 503, and a
healthy HTTP connection can stay open after that rejection. Successful requests
reuse a bounded cache of origin connections, so frontend churn need not become
origin churn. NGINX documents the [request limiter](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)
and [upstream connection limits](https://nginx.org/en/docs/http/ngx_http_upstream_module.html).

The nftables policy matches SYN packets only for the configured interface,
destination address, and port. It runs at prerouting priority -300, before
connection tracking and the listening socket's TCP acceptance work. It counts
all matched SYNs, including retransmissions. Above the connection-attempt budget,
it sends TCP resets within a separate reset budget and drops remaining excess
SYNs. Established traffic and other listeners are unaffected. See the
[nftables limit and reject contracts](https://netfilter.org/projects/nftables/manpage.html).

These controls bound work that reaches ZHTPS; they do not make ingress processing
free. Dropped SYNs still depend on client deadlines for failure, and the ingress
host itself needs capacity. TCP reset replies also cost work, which is why their
rate and burst are bounded. The goal of prompt failure for every possible excess
arrival cannot be claimed from these controls alone.

The origin must be reachable only through the ingress in the intended deployment.
Use loopback for a same-host functional test, or a private listener and an existing
network/firewall policy permitting the ingress host for a distributed deployment.
Direct public access to the origin bypasses the upstream request gate. The bundle
does not guess the origin's firewall or change unrelated rules.

## Generate a calibrated configuration

This example uses the prior one-core calibration values. Supply addresses and
budgets measured for the actual deployment:

```sh
python3 deploy/ingress.py --output /tmp/zhtps-ingress \
  --listen-address 192.0.2.10 --listen-port 8081 --interface eth0 \
  --origin-address 192.0.2.20 --origin-port 8080 \
  --origin-workers 1 --origin-slots 512 --proxy-workers 1 \
  --request-rate 250000 --request-burst 384 \
  --connection-rate 60000 --connection-burst 384 \
  --reset-rate 1000 --reset-burst 32
```

All three rates and their bursts are required. They do not scale automatically
when worker counts change. Multiple ingress instances each have their own
budgets; aggregate cluster limits require allocating the calibrated total among
them.

Supply either explicit `--origin-workers` and `--origin-slots` values or an
effective configuration snapshot with `--origin-config origin-config.json`.
The snapshot is the JSON returned by ZHTPS's `/debug/config`. It supplies the
worker, connection, and active-request budgets and is retained in the bundle.
Conflicting explicit counts are rejected. An explicit active-request budget
also caps forwarded concurrency, including when it is below the automatic
three-quarter limit.

The origin connection budget is three quarters of each worker's public slots,
summed across origin workers. For one 512-slot worker it is 384 total active plus
cached idle connections: the default one-worker NGINX configuration allocates
352 active and 32 idle. Because NGINX's idle cache is per proxy worker, increasing
proxy workers subtracts their combined idle allowance from the active allowance.
This avoids treating `max_conns` as a bound on active plus idle sockets. Distribution
among origin `SO_REUSEPORT` workers still needs validation; an aggregate budget
does not guarantee equal occupancy of every worker.

The generator writes:

* `nginx.conf`: NGINX 1.30+ configuration, bounded active upstream connections,
  request limiting, timeouts, and connection reuse.
* `connections.nft`: one named nftables table scoped to the selected listener.
* `remove-connections.nft`: removes only that named table.
* `limits.json`: explicit rates and resolved connection budgets.

It also creates local log/temp directories. Existing bundle files are not
overwritten. `--access-log` enables buffered NGINX JSON records with status,
request-limit outcome, upstream status, and request duration. Access logging is
otherwise off for the proxy; ZHTPS retains its own independent logging setting.
`--max-body-bytes` and `--keepalive-requests` make workload and lifetime bounds
explicit. Rejections do not retry against the origin or queue for an upstream
slot; exhausted origin capacity can also produce an upstream error response.

Validate on the ingress host before starting the configuration:

```sh
nginx -t -p /tmp/zhtps-ingress/ -c nginx.conf
sudo nft --check --file /tmp/zhtps-ingress/connections.nft
```

For a reviewed deployment, apply only the generated table and run the separate
NGINX instance. Its prefix owns its PID/log files:

```sh
sudo nft --file /tmp/zhtps-ingress/connections.nft
nginx -p /tmp/zhtps-ingress/ -c nginx.conf
sudo nft list counters table inet zhtps_ingress
```

Use `nginx -p /tmp/zhtps-ingress/ -c nginx.conf -s quit` to stop that instance and
`sudo nft --file /tmp/zhtps-ingress/remove-connections.nft` to remove that table.
Apply or remove the table atomically rather than flushing the host ruleset.
The default table name identifies one instance; use `--table` for additional
listeners. Reapplying an existing table is not the supported update procedure.

## Verification and remaining validation

The functional tests use real HTTP/TCP connections. The SYN tests create a fresh
user/network namespace and refuse to modify the parent network namespace.

```sh
python3 tests/ingress.py --nginx /path/to/nginx -v
python3 tests/ingress_kernel.py -v
python3 tests/ingress_zhtps.py --nginx /path/to/nginx \
  --zhtps zig-out/bench/ingress/bin/zhtps -v
python3 tests/remote_load.py -v
python3 tests/overload_remote.py --zhtps zig-out/bench/ingress/bin/zhtps -v
python3 tests/check_overload.py -v
```

The NGINX tests verify that rejected requests never reach the origin, rejection
keeps a healthy client connection alive, client churn reuses an origin connection,
busy origin requests are rejected without waiting, service recovers, and worker
counts do not alter explicit rates. Kernel tests verify actual IPv4/IPv6 refusal,
bounded reset/drop counters, established-connection continuity, unrelated-port
isolation, and token refill recovery. The generated configuration was validated
with NGINX 1.30.4 and this host's nftables/kernel.

The fixed-rate client now reports p99.9 and p99.99 as well as p99 and maximum
latency for success, HTTP failure, transport failure, and scheduling. Its tail
test reproduces rare slow outcomes that p99 alone hides.

The [local policy integration record](runs/ingress.json "Summary of docs/ingress/local-policy-smoke.json; raw artifact retired") uses the
actual ReleaseSafe ZHTPS executable, a 32 KiB echo request/response, access logging,
and frontend connection turnover. All 1,000 scheduled requests/s were written
during its three-second overload phase. The ingress admitted 608 requests across
that phase (200/s plus burst allowance) and returned 2,392 HTTP 503s; rejection
p99.9 was 1.16 ms. The origin admitted exactly the 808 validated successes across
all phases, with zero origin admission rejections. Recovery succeeded completely.
This is functional evidence at a small rate, not a capacity measurement. Its
kernel policy was not applied to the host; the independent namespace tests above
exercise that policy.

The [direct echo record](runs/ingress.json "Summary of docs/ingress/local-echo-smoke.json; raw artifact retired") additionally verifies
3,400 exact 32 KiB echoes with access logging and three-request client connection
lifetimes. These records do not replace the required sustained distributed runs.

## Distributed benchmark support

`bench/overload.py` can start the origin locally while executing the load driver
on an SSH host. `--target-address` can route the client through an ingress;
`--server-address` and `--server-port` fix the origin endpoint used by that ingress.
The remote host needs Python 3 and an already installed `bench/load` binary.
SSH runs noninteractively and requires an existing trusted host key.

The collector records remote host/kernel identity, the actual client binary hash,
CPU placement, descriptor limits, payload hashes, process CPU/RSS, and raw client
output. Five round trips estimate clock offset and uncertainty so remote phases
can be aligned with origin samples. The original `.client.json` timestamps are
preserved. Successful goodput and latency remain calculated on the generator's
own clock. Clock alignment does not establish that two machines are physically
independent; deployment inventory must establish that separately.

The collector refuses a shared kernel by default. `--allow-same-host-client` is
for protocol tests only and records `separate_kernel: false`. A hard run deadline,
stdin-disconnect detection, and a 15-second heartbeat timeout stop and reap the
load process if the controller disappears. The controller samples remote client
CPU, not the local SSH process's CPU.

Workload options include `--method`, `--path`, `--request-body`, `--expect-body`,
`--content-type`, `--allow-chunked`, `--client-max-requests`, `--server-max-requests`,
`--access-log`, and `--timeout`. Request and expected-response files are limited
to 64 MiB each, uploaded to a temporary directory, hashed, and deleted after the
run. Successful responses must match the expected bytes exactly. `--allow-chunked`
permits chunked framing without weakening that validation. A healthy keep-alive
HTTP rejection is reused; a closing or broken connection is re-established.

For example, after replacing the documentation addresses, installed binary path,
and illustrative rates with the actual deployment/calibration, and preparing
`payload.bin` with representative echo request bytes:

```sh
python3 bench/overload.py --output docs/ingress/distributed-echo.json \
  --server-binary zig-out/bench/ingress/bin/zhtps \
  --server-address 192.0.2.20 --server-port 8080 --server-cpus 0 \
  --target-address 192.0.2.10:8081 \
  --client-host bench@192.0.2.30 --remote-client-binary /opt/zhtps/load \
  --client-cpus 0-7 --connections 4096 --shards 8 --max-connections 512 \
  --method POST --path /echo --request-body payload.bin --expect-body payload.bin \
  --client-max-requests 1000 --server-max-requests 1000 --access-log \
  --schedule 1000:10s,1000:60s,2000:180s,500:30s,5000:180s,500:30s,10000:180s,500:30s \
  --labels warmup,baseline,overload_2x,recovery_2x,overload_5x,recovery_5x,overload_10x,recovery_10x
```

Repeat both persistent and `--churn` modes, realistic handler/payload cases,
logging on/off, normal/short connection lifetimes, and the intended worker counts.
Recalibrate rates for each configuration; worker-count changes do not justify
multiplying the request cap without measurement. Increase independent client
connections until actual attempts/writes support the offered pressure. In a
timeout-heavy churn trial, roughly `failed attempts/s × timeout seconds` client
slots are occupied by failures alone. Preserve the actual timeout and unsent
counts; a nominal multiplier with generator drops is not evidence of delivered
overload.

`bench/check_overload.py` audits each completed workload/configuration:

```sh
python3 bench/check_overload.py docs/ingress/distributed-echo.json \
  --output docs/ingress/distributed-echo-audit.json
```

The default audit requires distinct kernel identities and usable clock alignment,
60-second baseline, three 180-second overload phases, 30-second recoveries,
at least 99.9% of scheduled network writes (or dial attempts for churn), 90%
retention of baseline goodput, success p99 at most 10 ms, failure p99.9 at most
100 ms, at least 15% headroom on every assigned server core, and at most 5% RSS
growth. Baseline and recovery need at least 99.9% successful offers. These are
explicit engineering test targets; latency/headroom targets are configurable.
The audit exits nonzero and lists missing or failed evidence. Passing one case
does not establish the full workload matrix or universal deployment safety.

The [audit of the prior sustained trials](runs/ingress.json "Summary of docs/ingress/prior-evidence-audit.json; raw artifact retired")
correctly fails: those trials shared a host, did not sustain all nominal network
offers, lacked the newly recorded failure percentiles, and saturated their server
core. This audit records missing evidence rather than changing the earlier results.

The implementation objective still requires separate-host sustained validation
with actual attempted/written/delivered traffic accounted for, realistic handlers
and payloads, logging on/off, connection lifetimes, and multiple worker counts.
The existing overload reports are historical observations of the earlier direct
server setup, not validation of the new policies. No remote generator host is
currently available, so separate-host validation is deferred. Local calibration
uses the built-in `GET /` workload with the confirmed 10 ms successful-request
p99 and 99.9% successful-offer targets. The broader workload matrix remains
unverified; no separate-host performance or CPU-headroom result is claimed.
