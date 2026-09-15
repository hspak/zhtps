# NIC-aware worker placement

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

ZHTPS now accepts an explicit worker-to-CPU mapping. This implements the
operational finding in [the kernel experiments](kernel-work.md) without putting
topology discovery in the request path.

```sh
python3 deploy/worker_cpus.py --interface server_eth0 --workers 1 --json
./zig-out/bin/zhtps --workers 1 --worker-cpus 9
```

The helper currently recommends CPU 9 on this host: NIC IRQ 103 runs on CPU 24,
whose physical core also includes CPU 8. CPU 9 is a separate core in that L3.
[Captured topology](runs/nic-placement.json "Summary of docs/nic-placement/topology.json; raw artifact retired"). This is a topology check of the
implementation, not a new physical-NIC throughput measurement.

`--worker-cpus 9,10-12 --workers 4` assigns workers 0–3 in that order. The library
uses `Config.worker_cpus` with the same borrowed string. Empty configuration
inherits scheduler placement. Explicit mappings require one distinct logical
CPU per worker, with IDs 0–1023; malformed, overlapping, and wrong-length lists
are rejected. Availability is checked against the **serving thread's** inherited
affinity before spawning workers, so an explicit mapping cannot widen an
existing taskset or cpuset allocation. Each worker rechecks and pins itself
before passing the startup barrier. Readiness records follow that barrier.

Application executor threads start before their worker is pinned and retain
the inherited allocation. Worker zero restores its caller's original mask on
both normal shutdown and runtime errors. Affinity restoration errors are
returned through the existing server error path. `/debug/workers` adds `cpu`,
which is the configured logical CPU or null; its existing thread ID allows
checking actual affinity with `taskset -pc THREAD_ID`. A later external CPU
hotplug or cpuset change can affect the actual mask.

The Python helper reads effective IRQ affinity, online CPUs, L3 sharing, SMT
siblings, and the invoking thread's allowed set. It chooses one logical CPU per
physical core, excludes all NIC IRQ cores and their siblings, and rotates among
IRQ L3 domains. It supports MSI/MSI-X and the legacy device IRQ. It refuses
missing topology, enabled RPS, virtual interfaces without physical IRQs, and
insufficient local cores. By default it prints a suggestion; `--exec PATH -- ARGS`
replaces the launcher with the server and supplies the discovered mapping.
Worker options in ARGS are rejected so they cannot override the topology choice.
No IRQ, offload, queue, systemd, or sysctl settings are changed. Run it in the service's CPU allocation
and recheck when IRQ placement changes. The multi-domain selection is a policy
heuristic; the original measured benefit covers one worker and a one-queue NIC.

Placement stores one borrowed string in configuration and one optional CPU ID
per worker. It adds no connection fields, request allocations, or affinity
system calls to the request path. The fixed affinity mask supports up to 1024
CPU IDs; explicit affinity reports `AffinityMaskTooSmall` when the kernel needs
a larger mask. Unconfigured placement does not query that mask.

The tests cover ordered live worker pinning and HTTP service, inherited default
masks, rejection outside the inherited mask without readiness, caller-mask
restoration after normal stop and a forced event-loop error, and endpoint
executor inheritance through a separate library consumer. Synthetic sysfs
fixtures cover L3 boundaries, SMT exclusion, allowed/offline CPUs, multi-domain
selection, legacy IRQs, and unsupported processing topology.

Final Debug and
ReleaseSafe runs pass all 48 build
steps, including 81 component tests, declaration checks, the embedded consumer,
58 existing wire tests, five pipeline boundaries, three live placement tests,
and five synthetic topology tests. The new tests preserve existing coverage.

Linux references: [per-thread affinity and mask restrictions](https://man7.org/linux/man-pages/man2/sched_setaffinity.2.html)
and [network CPU placement](https://docs.kernel.org/networking/scaling.html).
