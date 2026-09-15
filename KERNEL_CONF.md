# Linux kernel configuration for ZHTPS

Size process limits from total connection capacity. Size network queues from
connection arrival rates and service delays. Worker and connection counts alone
cannot determine optimal TCP buffers, NIC queues, or congestion control.
The recommendations below are starting points to validate against successful
requests per second and tail latency under the intended workload.

## Configuration inputs

| Symbol | ZHTPS setting | Meaning |
|---|---|---|
| `W` | `--workers` | Event-loop threads; default 1 |
| `C` | `--max-connections` | Public connection slots per worker; default 256 |
| `A` | `--admin-connections` | Admin slots on worker zero only; default 8 |
| `P` | `--max-active` | Active public request permits per worker; default 256 |
| `N` | `W * C + A` | Total application connection slots |

The current implementation requires `1 <= W <= 256`, `1 <= A <= 128`, and
`C + A <= 8176`. With default admin capacity, `C <= 8168`, regardless of `W`.
These are application limits; sysctls cannot raise them. See
[Config.zig](src/Config.zig) and [worker ownership](docs/workers.md).

Idle, reading, writing, rejecting, and closing connections all consume slots.
Use `N` for descriptor and allocation sizing even when `P` is much smaller than
`C`. Public active requests are bounded by `W * min(P, C)`; admin connections
bypass those permits. `SO_REUSEPORT` distributes connections among workers, but
does not guarantee equal occupancy. Leave room for the busiest worker.

## File descriptors

All workers share one process descriptor limit. The known descriptor budget at
full application occupancy is:

```text
D = N + 2 * W + 4 + F_other
    N accepted sockets
    W public listeners
    W io_uring descriptors
    1 admin listener
    3 standard descriptors
    F_other additional descriptors used by application hooks/runtime facilities

F = nextPowerOfTwo(max(1024, ceil(1.25 * D)))
```

Set the process soft `RLIMIT_NOFILE` to at least `F`, with a hard limit at least
as large. The 25% margin and power-of-two rounding are deployment heuristics,
not kernel requirements. Increase the budget for applications that open files,
upstream sockets, or other resources beyond the bundled handlers.

Examples use `A = 8`, `F_other = 0`, and the default application buffers:

| `W` | `C` | Total slots `N` | Recommended minimum soft limit `F` | Application buffer capacity |
|---|---|---|---|---|
| 1 | 256 | 264 | 1,024 | 39.19 MiB |
| 1 | 8,168 | 8,176 | 16,384 | 1.185 GiB |
| 4 | 2,048 | 8,200 | 16,384 | 1.189 GiB |
| 16 | 2,048 | 32,776 | 65,536 | 4.751 GiB |
| 16 | 8,168 | 130,696 | 262,144 | 18.945 GiB |

For a systemd service running `--workers 16 --max-connections 2048`, a service
override can contain:

```ini
[Service]
LimitNOFILE=65536
```

This sets both soft and hard limits. Preserve a larger hard limit with
`LimitNOFILE=65536:524288` when appropriate. For a shell launch, run
`ulimit -Sn 65536` before starting ZHTPS, within the inherited hard limit.
Inspect the running server's `/proc/<pid>/limits`; an interactive shell's limits
may differ from the service's. User services also inherit limits from their
service manager. See [systemd's limit documentation](https://github.com/systemd/systemd/blob/main/man/systemd.exec.xml).

| Kernel setting | Sizing rule |
|---|---|
| `fs.nr_open` | At least the desired process hard descriptor limit |
| `fs.file-max` | At least the aggregate peak file-handle demand of all services, with headroom |
| `fs.file-nr` | Monitor actual system-wide file-handle usage |

Keep existing larger ceilings. For multiple ZHTPS processes, sum their budgets
when planning host capacity. Connections still waiting in the kernel accept
queue consume kernel memory but have no accepted descriptor in the process yet.
See the [filesystem sysctl reference](https://docs.kernel.org/admin-guide/sysctl/fs.html).

## TCP baseline

Use these starting values when provisioning a host. Preserve existing larger
queue limits unless measurements support reducing them.

```ini
# /etc/sysctl.d/90-zhtps.conf
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_moderate_rcvbuf = 1
```

These values do not multiply by `W` or `C`. SYN cookies provide overflow
protection; they do not replace adequate capacity for legitimate traffic.
Keep receive autotuning enabled and avoid resetting clients on accept overflow.
See the [kernel TCP settings](https://docs.kernel.org/networking/ip-sysctl.html).

### Accept backlog

ZHTPS currently calls `listen()` with **128 per public listener** and **32 for
the admin listener**, hardcoded in [server.zig](src/server.zig). There is no
backlog CLI option. The effective public backlog limit is:

```text
B_effective = min(128, net.core.somaxconn)
```

Thus, `somaxconn >= 128` accommodates the current request; `4096` leaves room
for future application changes. Increasing it beyond 128 does not enlarge
ZHTPS's queues. Each worker has a separate public listener and queue; their
capacity is not a shared pool. See [listen(2)](https://man7.org/linux/man-pages/man2/listen.2.html).

For burst sizing, estimate the arrivals at the busiest listener during the
longest expected pause in accepting:

```text
B_needed ~= ceil(peak_new_connections_per_second_per_worker * accept_pause_seconds)
```

Account separately for instantaneous bursts. Measure the busiest worker rather
than assuming arrivals are exactly the total divided by `W`. If this estimate
exceeds 128, increasing capacity requires a code change as well as a sufficient
`somaxconn`. Candidate application backlogs to benchmark are 128, 1024, and 4096;
there is no reason to set the backlog equal to `W * C`.

This estimate assumes accepting resumes and catches up. ZHTPS stops accepting
when a worker has no free connection slots. A larger queue cannot resolve
sustained slot exhaustion and can prolong client waits. Adjust connection
headroom, connection lifetime, or offered load in that case.

### SYN backlog

`net.ipv4.tcp_max_syn_backlog` limits remembered incomplete handshakes per
listener. Start at 4096. A planning estimate is:

```text
S_needed ~= peak_new_connections_per_second_per_worker * handshake_retention_seconds
```

Use retention including delayed or lost handshake packets. If legitimate bursts
produce SYN overflow, test a higher limit, such as 8192 or 16384, alongside the
accept backlog. This estimate is not an exact queue guarantee; listen capacity
and SYN-cookie behavior also matter. See the
[SYN backlog documentation](https://docs.kernel.org/networking/ip-sysctl.html).

HTTP request rate differs from connection arrival rate. Keep-alive can serve
many requests per socket. ZHTPS's `--rate` and `--burst` govern request admission
after parsing and do not limit incoming TCP handshakes.

## io_uring availability and memory

Use Linux 6.0 or later with `CONFIG_IO_URING` enabled. ZHTPS probes synchronous
cancellation at startup and requires its io_uring and networking operations to
be permitted by the execution environment. A capable kernel alone does not
override a container seccomp policy. See [runtime requirements](README.md).

Choose the host's access policy:

| Setting | Configuration |
|---|---|
| `kernel.io_uring_disabled = 0` | Allows normal ring creation; no worker-dependent value |
| `kernel.io_uring_disabled = 1` | Set `kernel.io_uring_group` to a group containing the service user |
| `kernel.io_uring_disabled = 2` | Prevents ZHTPS from creating its rings |

The group setting is relevant only with mode 1. See the
[kernel io_uring controls](https://docs.kernel.org/admin-guide/sysctl/kernel.html#io-uring-disabled).

ZHTPS already sizes its rings from local connection capacity:

```text
slots_0 = C + A
slots_i = C                         for workers i > 0
CQ_i = nextPowerOfTwo(4 * slots_i + 64)
SQ_i = min(CQ_i, 256)
```

CQ capacity is capped at 32768 by the application. These are queue entries,
not a number of kernel threads or a sysctl to set. Current ring creation uses
`IORING_SETUP_CQSIZE`, without SQPOLL. See [server.zig](src/server.zig) and
[io_uring_setup(2)](https://man7.org/linux/man-pages/man2/io_uring_setup.2.html).

`fs.aio-max-nr` governs the older `io_setup()` API and does not size these rings.
See the [AIO sysctl description](https://docs.kernel.org/admin-guide/sysctl/fs.html).
ZHTPS does not register its connection buffers as fixed io_uring buffers or
lock them with `mlock`. Do not derive `LimitMEMLOCK` from `N * 152 KiB` or
require an unlimited value as a generic tuning step. If fixed buffers are added,
account for their pinned bytes as described in
[io_uring_register(2)](https://man7.org/linux/man-pages/man2/io_uring_register.2.html).

## RAM and TCP buffers

Default application buffer capacity is:

```text
M_buffers = N * (32 + 8 + 16 + 32 + 64) KiB = N * 152 KiB
```

These allocations are reserved at startup; resident usage depends on pages
touched. Add connection/parser structures, logging queues, worker stacks,
application-owned allocations, and kernel memory. The built-in application's
response aggregation also reserves `min(--response-batches, C) * 4648` bytes per
worker (290.5 KiB at the default 64), plus an 8-byte pointer per connection slot.
The pool is omitted for custom applications and active-request budgets below
four; `--response-batches 0` disables it. Lowering `--max-active`
does not shrink the per-slot buffers. See [allocation code](src/server.zig).

Provision RAM for the intended occupancy and workload:

```text
M_peak = M_buffers + M_structures_and_application
       + M_rings + M_live_and_queued_sockets + M_other_charges
```

Measure the variable terms under load. In particular, socket memory depends on
traffic and slow peers, and can remain after an application descriptor closes.
Place `memory.high` above the intended working set with headroom, and any
`memory.max` above that threshold within the host budget. Check `memory.events`,
`memory.stat`, and memory pressure for reclaim, swapping, or limit hits. Cgroup
accounting includes TCP socket buffers. See the
[cgroup memory controller](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory).

| Setting | Relationship to ZHTPS capacity |
|---|---|
| `net.ipv4.tcp_rmem`, `net.ipv4.tcp_wmem` | Per-socket tuning bounds; retain defaults initially, rather than multiplying by `N` |
| `net.core.rmem_max`, `net.core.wmem_max` | Relevant to explicit socket-buffer requests; current ZHTPS does not set `SO_RCVBUF` or `SO_SNDBUF` |

For sustained large transfers, estimate the per-flow bandwidth-delay product:
`target_bytes_per_second_per_connection * round_trip_seconds`. Test larger
buffer ceilings only when the existing buffers constrain that throughput.
Include socket overhead and concurrent flows in the memory budget; a buffer
ceiling is not a preallocation for every connection. See
[tcp(7)](https://man7.org/linux/man-pages/man7/tcp.7.html).

## CPU and NIC capacity

Start with one worker per physical core allocated to ZHTPS, then benchmark
fewer workers and SMT siblings. Reserve capacity for network processing and
other workloads. Larger `C` increases connection and memory capacity without
adding CPU capacity. `--worker-cpus LIST` pins one event-loop worker per listed
logical CPU in order; omit it to inherit scheduler placement. `/debug/workers`
exposes the configured CPU and thread ID for verification with
`taskset -pc THREAD_ID`. Mappings cannot expand the serving thread's inherited
CPU allocation. Application executor threads retain that inherited allocation.

`python3 deploy/worker_cpus.py --interface INTERFACE --workers W --json` suggests
distinct physical worker cores sharing NIC IRQ L3 caches while excluding IRQ
cores and their SMT siblings. It reads current topology and changes no IRQ,
queue, RPS, or systemd settings. Run it within the service's CPU allocation;
recheck after irqbalance, hotplug, or deployment changes. It refuses enabled
RPS, missing topology, and insufficient local cores instead of guessing. The
one-worker measurements favor this placement, but do not establish a universal
multi-queue policy. See the [NIC experiment](docs/kernel-work.md).

For a dedicated deployment, an unthrottled CPU allocation is a useful baseline.
If a cgroup quota is required, `cpu.max` quota divided by period is its maximum
CPU-equivalent bandwidth. Account for ancestor limits and inspect `cpu.stat`
for throttling. Size worker count against that allocation, not just host CPU
count. See the [cgroup CPU controller](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu).

For maximum-performance trials, use `scaling_governor=performance` on the CPU
policies serving ZHTPS when the driver supports it. On drivers exposing an
energy preference, test `energy_performance_preference=performance` as well.
These are per-policy sysfs controls under
`/sys/devices/system/cpu/cpufreq/policy*/`, not values proportional to `W` or `C`.
Compare sustained throughput, p99 latency, power, and thermal behavior with the
existing policy. See [CPU frequency controls](https://docs.kernel.org/admin-guide/pm/cpufreq.html)
and [AMD P-state controls](https://docs.kernel.org/admin-guide/pm/amd-pstate.html).

For physical NIC traffic, begin with RSS queues distributed across available
network-processing cores, limited by NIC capability. Tune IRQ affinity with
CPU/NUMA locality. RPS can help when hardware queues are insufficient, but can
add overhead when RSS already distributes processing adequately. NIC queue count
need not equal `W`. See [Linux network scaling](https://docs.kernel.org/networking/scaling.html).

`net.core.netdev_max_backlog` is a packet queue limit, not a connection limit.
Keep it and `netdev_budget`/`netdev_budget_usecs` unchanged initially. Increase
them only when receive drops or exhausted polling budgets support doing so;
larger polling budgets can take CPU time from application workers. Check NIC
statistics, `/proc/net/softnet_stat`, and per-CPU softirq load. These host/driver
settings may be unavailable inside a container and require host configuration.
See the [network sysctl reference](https://docs.kernel.org/admin-guide/sysctl/net.html).

## Connection tracking

If firewall or NAT rules track this traffic, plan `net.netfilter.nf_conntrack_max` for the
tracking namespace's aggregate flow population:

```text
tracked_peak ~= live_flows + queued_and_half_open_flows
              + recently_closed_flows_still_tracked + other_services
```

Use `N` as an application-capacity input, not the entire tracking budget.
Closed-flow retention can dominate at high churn. A starting margin is 25%
above a representative measured peak; validate reconnect storms and recovery.
Preserve existing larger limits. Monitor `net.netfilter.nf_conntrack_count` and insertion
failures; account for hash-table size and memory before increasing capacity.
See the [conntrack reference](https://docs.kernel.org/networking/nf_conntrack-sysctl.html).

## Settings without a worker/connection multiplier

Leave `net.ipv4.tcp_congestion_control` and `net.core.default_qdisc` at the host
baseline until tests over the real network path justify changing them. Loopback throughput
does not establish an optimal WAN congestion-control choice.

Do not shrink `tcp_fin_timeout` to clear TIME_WAIT: it controls orphaned
FIN_WAIT_2 connections. Keep `net.ipv4.tcp_tw_reuse` at its baseline absent a
specific diagnosed problem. `net.ipv4.ip_local_port_range` primarily affects outgoing
connections, including load generators, rather than the number of clients
accepted on ZHTPS's listening port. See
[tcp(7)](https://man7.org/linux/man-pages/man7/tcp.7.html) and the
[IP sysctl reference](https://docs.kernel.org/networking/ip-sysctl.html).

ZHTPS already sets `TCP_NODELAY` on accepted sockets. It does not enable
`SO_KEEPALIVE`; its HTTP idle timeout is an application setting. Increasing
kernel TCP keepalive frequency therefore does not tune that timeout. See
[socket setup](src/server.zig).

## Validate the configuration

Measure sustained traffic, new-connection bursts, slow peers, and overload.
Keep the same `W`, `C`, `P`, logging configuration, and client workload while
comparing kernel changes. Include persistent connections and reconnects;
ZHTPS's default `--max-requests 1000` contributes to connection turnover.

| Observe | Desired result / next action |
|---|---|
| `/proc/<pid>/limits` and descriptor usage | Soft limit covers the calculated budget; no `EMFILE`/`ENFILE` |
| `ss -lnt` | Listener queues drain after expected bursts |
| `nstat -az` | Compare before/after deltas of `TcpExtListenOverflows`, `TcpExtListenDrops`, `TcpExtSyncookiesSent`, and `TcpRetransSegs` |
| `/debug/workers` | No unexpected worker-local slot exhaustion or severe load imbalance |
| CPU/memory cgroup statistics | No unintended throttling, memory-limit hits, or sustained pressure |
| NIC drops and softirq load | Receive processing keeps up without starving event loops |
| Client results | Higher successful throughput or lower p99 latency without extra errors |

Run checks in the server's network namespace and inspect host NIC counters on
the actual ingress interface. Kernel TCP counters also include other traffic
in that namespace. Record effective values with the benchmark results; retain
changes only when they improve the intended workload.
