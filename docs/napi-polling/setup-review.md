The isolated napi-poll-v1 candidate registers a ten-microsecond NAPI polling
budget on each io_uring instance before submitting operations. Dynamic tracking
selects the NAPI IDs associated with sockets that enter asynchronous poll.
Preferred busy polling remains false, and no host IRQ, qdisc, sysctl or NIC
setting is changed. This is an experiment in servicing incoming packets from
the worker, not an HTTP deadline or retransmission-policy change.
[Kernel dynamic tracking](https://raw.githubusercontent.com/torvalds/linux/master/io_uring/napi.h),
[poll registration path](https://raw.githubusercontent.com/torvalds/linux/master/io_uring/poll.c).

> Artifact retention: [Run summaries and setup records](../runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The experimental default is ten microseconds; `--napi-poll-us 0` leaves NAPI
registration disabled. Values above the kernel's 10,000 µs registration cap
are rejected rather than silently clamped. Registration happens once per ring;
ring destruction owns cleanup. Unsupported operation fails startup explicitly.
Kernel allocation failure is propagated as OutOfMemory. The worker retains its
existing completion, buffer-ownership, cancellation and application logic.
[Registration implementation](https://raw.githubusercontent.com/torvalds/linux/master/io_uring/napi.c),
candidate patch.

Zig's installed NAPI structure uses the older layout, with reserved bytes in
positions that newer kernels use for operation and tracking selectors. The
candidate zero-initializes the entire structure, selecting registration and
dynamic tracking on the current kernel while keeping those bytes reserved on
older kernels. The actual running kernel reports the intended settings; this
is not inferred only from successful compilation.

A new wire test starts two workers with polling disabled and then enabled.
It reads each actual ring's `/proc/<pid>/fdinfo` entry, verifies disabled versus
enabled dynamic tracking, the 10,000 ns duration, and preferred polling false.
It also checks reported configuration and a validated HTTP response. A separate
configuration test checks the disable path, option resolution, missing arguments
and rejection above the kernel cap. Existing tests remain unchanged.
The complete ReleaseSafe suite passed 65/65 build steps, 98/98 Zig tests,
60 wire tests, and the library, application and upload/streaming checks.
Full test log,
[effective ring configuration fields](https://raw.githubusercontent.com/torvalds/linux/master/io_uring/fdinfo.c).

Two controlled LAN probes use the exact retained and candidate executables,
seven workers on CPUs 9–15, and 64 persistent TCP connections from the second
host. All responses validate and all workers complete requests. The parent
process briefly duplicates its own child server's socket descriptors with
pidfd_getfd, reads SO_INCOMING_NAPI_ID, and closes the duplicates. Client socket
IDs are read on the client itself. Endpoint tuples match on both sides.
All seven candidate rings report the expected polling settings; all retained
rings report NAPI disabled.
Candidate observation,
retained control,
probe source.

Both controls report server NAPI ID 104 and client NAPI ID 8194. These are in
the valid ranges for the inspected kernels: the server builds for 32 CPUs and
the client for 8192, and NAPI IDs start above NR_CPUS. Both kernels enable
CONFIG_NET_RX_BUSY_POLL. Nonzero alone would not have been a sufficient range
check. The kernel configurations and boot IDs are preserved.
[Kernel configuration](../runs/napi-polling.json "Summary of docs/napi-polling/kernel-config.json; raw artifact retired"),
[valid ID range](https://raw.githubusercontent.com/torvalds/linux/master/include/net/busy_poll.h).

This verifies effective registration and physical-NIC association. Actual
polling invocation is inferred from those observations and the kernel path,
not directly captured in a kernel stack trace. The host has perf_event_paranoid
set to 2; the attempted `sudo -n perf stat -e cycles:k -- true` check reports
that a password is required. No privileged profile was obtained and no privilege
or host configuration was changed to bypass that restriction.

The decision comparison uses the same exact binaries and unchanged sparse
load client, with no association probe or profiler during its measurement
windows. It includes process CPU and whole-host CPU separately. Host CPU already
includes the server process: adding the two would double-count work. NAPI can
move packet processing from interrupt context into server threads, so a change
in process CPU alone is not a complete resource-cost comparison.
