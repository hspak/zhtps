# Envoy hot restart and feasibility for zhtps

Reviewed 2026-09-14. Envoy source: `../envoy`, revision
`db4eba933c9335c35f28fc0168db1ccaf851117b`; the examined paths have no local changes.
zhtps: working tree based on `19d07be51f9041bb6290d40dc9b813f2bc891a51`, including
the pending TLS/HTTP/2 and streaming work. This is a source review and design
proposal, not an implemented restart feature.

## Conclusion

**Yes. Envoy's process-overlap approach fits zhtps's architecture.** Keep the old
process serving its accepted connections, pass copies of its listening sockets
to the new process, and drain the old process after the replacement is ready.
Each process keeps its own io_uring rings, TLS sessions, HTTP parsers, HTTP/2
streams, buffers, and application resources.

The achievable contract is continuous listening and graceful completion of
accepted work within configured deadlines. It is not indefinite preservation
of every connection. Envoy explicitly documents that established connections
stay in the old process and that remaining connections are terminated when that
process shuts down. [Envoy documentation](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/hot_restart)

zhtps already supplies much of the protocol draining. The substantive work is
listener ownership, accept completion races, readiness, and process coordination.
Simply starting another zhtps with `SO_REUSEPORT` and signaling the old process
does not provide the same guarantee.

## What Envoy actually does

1. **Launch a separate executable.** The example Python restarter responds to
   SIGHUP by forking and executing the configured launcher with an incremented
   restart epoch. It does not replace the running server process in place.
   [hot-restarter.py](../../envoy/restarter/hot-restarter.py), `fork_and_exec`, line 175.
2. **Request listeners over a Unix socket.** The replacement asks for a listener
   by address, worker index, and network namespace. The parent returns the
   matching listening descriptor. The descriptor travels as `SCM_RIGHTS`
   ancillary data on `sendmsg`/`recvmsg`; the receiving process obtains another
   reference to the same kernel socket, including its accept queue.
   [child](../../envoy/source/server/hot_restarting_child.cc), line 128;
   [parent](../../envoy/source/server/hot_restarting_parent.cc), line 170;
   [RPC transport](../../envoy/source/server/hot_restarting_base.cc), line 78.
3. **Initialize the replacement before retiring the parent.** Listener creation
   adopts the parent's descriptor when available. After worker startup completes,
   `InstanceBase::startWorkers` sends the parent drain request and starts the
   separate parent termination timer.
   [listener creation](../../envoy/source/common/listener_manager/listener_manager_impl.cc), line 378;
   [server startup](../../envoy/source/server/server.cc), line 961.
4. **Stop old accepts and close old listener references.** The listener manager
   waits for its workers to stop accepting before closing its TCP listener
   descriptors. The replacement's references keep those kernel listeners alive.
   Accepted sockets remain with their original process.
   [listener stopping](../../envoy/source/common/listener_manager/listener_manager_impl.cc),
   `stopListeners`, line 1214, and `maybeCloseSocketsForListener`, line 1387.
5. **Discourage reuse, finish work, then terminate.** HTTP draining includes
   closing HTTP/1 connections and an HTTP/2 shutdown notice followed by final
   GOAWAY. The default CLI drain time is 600 seconds; the independent parent
   shutdown time is 900 seconds. A finite parent lifetime can truncate a stream
   that is still running. These are separate from the HTTP connection manager's
   own drain timer.
   [HTTP draining](../../envoy/source/common/http/conn_manager_impl.cc), lines 905 and 1802;
   [defaults](../../envoy/source/server/options_impl.cc), line 161;
   [termination timer](../../envoy/source/server/drain_manager_impl.cc), line 218.

```mermaid
sequenceDiagram
    participant S as Supervisor
    participant O as Old binary
    participant N as New binary
    participant C as Clients
    C->>O: Existing requests
    S->>N: Launch replacement
    N->>O: Request listening sockets
    O->>N: SCM_RIGHTS, same kernel listeners
    N->>N: Initialize workers and application
    N->>O: Ready; begin drain
    O->>O: Stop accepts, close local listener references
    C->>N: New connections
    O-->>C: Finish existing requests, close gracefully
    N->>O: Terminate at parent deadline
```

There is a short overlap when both generations can accept. The inspected Envoy
drain RPC is asynchronous and does not acknowledge that all parent accepts have
stopped. Its `parent_stop_accepting_requested_` flag explicitly describes a request
having been sent, not completion of that transition.
[hot_restarting_child.cc](../../envoy/source/server/hot_restarting_child.cc), line 168.

### Limits behind the claim

- Per-worker listener transfer preserves the old accept queues. Envoy documents
  that decreasing worker count can drop connections queued on omitted workers.
  Rebinding fresh `SO_REUSEPORT` sockets alone does not preserve those queues.
- Existing connections continue using the old code and configuration until they
  finish. A streaming response cannot move to the new binary by passing its TCP
  descriptor: its TLS, HTTP/2, and application progress also live in process memory.
- Listener socket options persist across the transfer. Envoy documents that
  changing them through hot restart is unsupported.
- Compatible restart protocol versions are required. The inspected implementation
  checks shared-memory size and `HOT_RESTART_VERSION` (11). It uses shared memory
  for logging mutexes and initialization coordination; counters and gauges use
  the RPC path. That is coordination and observability machinery, not storage
  for live connections.
  [compatibility checks](../../envoy/source/server/hot_restart_impl.cc), line 26;
  [shared structure](../../envoy/source/server/hot_restart_impl.h), line 22.
- The example wrapper is not a general rollback system: unexpected child failure
  can cause it to terminate the other children. A replacement crash after it has
  accepted traffic cannot preserve the connections it owned.
  [hot-restarter.py](../../envoy/restarter/hot-restarter.py), `sigchld_handler`.

The queue, worker-count, and socket-option qualifications also appear in the
[local documentation](../../envoy/docs/root/intro/arch_overview/operations/hot_restart.rst).
Envoy's integration test holds responses open on the old instance, starts the
replacement, verifies fresh connections reach its new upstream, then releases
the old responses. That demonstrates overlapping generations rather than moving
established connections.
[hotrestart_handoff_test.py](../../envoy/test/integration/python/hotrestart_handoff_test.py), line 590.

## What zhtps already has, and what must change

| Area | Current behavior | Restart work |
|---|---|---|
| Worker ownership | Each worker owns its ring and connections | Preserve that ownership for the entire connection lifetime |
| Public listeners | One freshly bound `SO_REUSEPORT` socket per worker | Allow adoption of the corresponding existing listener |
| Admin listener | Worker zero binds a separate socket without port sharing | Transfer it with an explicit admin role and readiness policy |
| Initialization | All workers initialize; worker threads meet a startup barrier | Add reliable cross-process readiness after accept setup is submitted |
| Stop | Atomic stop flag begins graceful shutdown | Add a distinct handoff transition and listener ownership rules |
| HTTP/1 | Closing responses, final keepalive window, bounded drain | Reuse those policies, with a defined grace for accepts racing handoff |
| TLS | Worker-owned SSL/BIO objects and orderly close alerts | Leave sessions in the old process |
| HTTP/2 | GOAWAY at the highest accepted stream ID; existing streams finish | Reuse draining and test streams opened during the transition |
| Process control | Standalone TERM/INT handlers; library owns no signals | Add a supervisor/control protocol; keep launch policy outside library hooks |

Sources: [Server lifecycle](../src/server.zig),
[worker startup and I/O](../src/server/worker.zig),
[socket creation](../src/platform.zig),
[TLS ownership](../src/Tls.zig),
[HTTP/2 draining](../src/server/http2.zig), and
[standalone signals](../src/main.zig).

### 1. Shared listeners must never be shut down by a retiring process

`Worker.stopListening` calls `linux.shutdown(listener.fd, SHUT.RDWR)` for both
listeners. `beginShutdown` calls it, and `workerMain` calls it again through a
defer. This deliberately rejects queued connections during ordinary shutdown.
With shared descriptors, it would also disable the replacement's listener.
[worker.zig](../src/server/worker.zig), lines 614 and 3571.

A handoff needs to stop submitting accepts, cancel/reap the old worker's pending
accepts, and eventually **close only its own descriptor references**. Descriptors
must remain valid until no queued submission can reference their numeric values.
The current ordinary-stop behavior remains an intentional contract, covered by
[tests/shutdown.py](../tests/shutdown.py), line 70.

Ownership must be tracked from the moment a listener is shared, including in the
replacement before readiness. Otherwise a replacement worker startup failure or
error cleanup could call `shutdown()` and break the still-serving parent. Changing
only `beginShutdown` would miss the deferred cleanup path.

### 2. Canceling an accept does not settle an already completed accept

`acceptConnection` currently closes every successful accepted descriptor when
`draining` or `shouldStop()` is true. `beginShutdown` also closes `waiting_accept`,
the descriptor temporarily held during idle reclamation.
[worker.zig](../src/server/worker.zig), lines 1520 and 3581.

That is correct for the existing stop contract but loses connections during a
handoff. The transition must account for both the cancellation completion and the
original accept completion. A successful accept must remain owned and usable even
if its completion is dispatched after handoff begins.

Prefer finishing these connections in the old process, with reserved transition
capacity and a bounded first-request/handshake window. Include the extra
`waiting_accept` descriptor in that budget. Alternatively, an accepted descriptor
that has never been read can be forwarded to the new process; this adds protocol
and ownership complexity and is unnecessary for connections already being served.
Preserve the existing stop-race regression and add separate handoff coverage.

### 3. Readiness and failure handling need an explicit protocol

`Server.initInner` always binds listeners; it has no supplied-listener input.
`workerMain` increments `shared.ready` before entering `loop`, where accepts are
actually queued and submitted. Its listening log is not a reliable restart
acknowledgement or proof that initial accept operations succeeded.
[server.zig](../src/server.zig), line 65;
[worker.zig](../src/server/worker.zig), lines 630 and 1165.

Add listener adoption with documented ownership on success and error, and a
control-channel acknowledgement for initialized workers and submitted accept work.
Use a separate acknowledgement after the old workers have settled pending accepts.
Socket errors can still occur after readiness; no handshake makes later crashes
lossless.

Before retirement begins, a failed replacement must cancel its own operations and
close its copies while the parent continues serving. After retirement begins,
recovery can restore service for new traffic but cannot promise recovery of
connections owned by a crashed generation. Serialize restarts and initially allow
only one draining predecessor.

### 4. Admin access needs its own handoff

The new process currently cannot bind the same admin address while the old one is
listening. Enabling admin `SO_REUSEPORT` would also undermine the intentional
public/admin separation. Transfer the admin listener as a separately identified
descriptor instead. The old generation's already accepted admin connections need
an explicit drain policy.

Use the private control channel for candidate readiness: an HTTP probe to a shared
admin listener can reach either generation during overlap. Report the generation
in diagnostics. During the old process's drain, its `/healthz` reports unhealthy;
deployment health checks must observe the active generation once handoff completes.
[worker.zig](../src/server/worker.zig), lines 716, 2480, and 2582.

### 5. Grace periods and resource overlap are product decisions

zhtps defaults to a five-second shutdown grace and a 100 ms final keepalive
window. These can finish short requests, but cannot promise uninterrupted long
uploads or streaming responses. Existing per-request deadlines also still apply.
Choose an explicit upgrade grace; allow the old process to exit early when work
finishes. An unlimited wait retains the old binary indefinitely for unending work.
[Config.zig](../src/Config.zig), line 48.

Clients still need to reconnect after graceful closure. HTTP/1 pipelined requests
beyond the response being completed are not all guaranteed to run: the current
shutdown tests explicitly expect the trailing request to be discarded. HTTP/2
streams beyond the final GOAWAY boundary are likewise not accepted work. An upgrade
claim must distinguish requests the server has begun handling from additional
bytes a client has already sent.
[shutdown tests](../tests/shutdown.py), line 36;
[HTTP/2 GOAWAY](../src/http2.zig), line 178.

Application hooks must return before their storage can be released. Consequently,
`serve` can outlive its grace deadline; a supervisor hard deadline is a separate,
potentially destructive termination policy.
[server.zig](../src/server.zig), `requestStop`, line 172.

Both processes consume resources during overlap: rings, connection slots, caches,
TLS credentials, executor threads, and admission budgets. Per-worker limits are
currently per process, so aggregate capacity and load can grow during overlap.
Application-global memory is not transferred; embedded applications must support
two versions running simultaneously against their shared external resources.

TLS session tickets currently do not survive restart. New connections can do a
full handshake; existing TLS connections keep working in the old process.
Cross-generation ticket sharing is an optional resumption optimization, not a
requirement for preserving established connections.
[TLS policy](tls.md#lifetimes-and-limits).

## Recommended implementation scope

Implement a small Linux restart protocol and supervisor around the existing server:

1. **Listener adoption and handoff lifecycle.** Add an explicitly owned set of
   per-worker public listeners plus the admin listener. Validate address, socket
   type, listening status, role, worker mapping, and inherited socket policy.
   Preserve actual ports when the original configuration used port zero. Add
   retirement that preserves shared listeners and handles raced accepts. Expose
   the lifecycle through both the low-level and endpoint server facades.
2. **Generation coordination.** Use a private Unix control channel and
   `SCM_RIGHTS`, with a bounded, versioned wire format independent of Zig struct
   layout. Validate the peer, descriptor count, and truncated ancillary messages;
   set close-on-exec on received descriptors. Supply explicit readiness,
   retirement acknowledgement, abort, and exit reporting. Keep the protocol off
   the request path. A supervisor launches binaries and tracks their exit status;
   library users supply their own process policy.
3. **Conservative compatibility rules first.** Require the same worker count,
   listener identities, public/admin roles, TLS mode, and listener socket options.
   Reject unsupported changes before retirement instead of silently rebinding.
   Certificate and application changes can take effect on the new generation.
4. **Observable drain.** Report generation, active/draining status, remaining
   connections, and forced deadline closures. Keep per-generation metrics at
   first, with an explicit way to inspect the draining process; Envoy's counter
   merging and shared logging locks are not prerequisites for socket handoff.

A supervisor that owns listeners from initial startup and supplies inherited
descriptors is another implementation of the same approach. It still requires
zhtps listener adoption and shared-socket-safe cleanup. Plain socket activation
without overlapping old/new workers does not preserve accepted connections.

The first deployment of this capability needs a normal restart: today's binary
has no listener export/adoption protocol. Subsequent compatible binaries can use
the new path. I would treat this as a server lifecycle feature delivered in stages,
not a signal-handler-only change.

## Validation

### Experiment performed during this review

A small Python probe launched a fresh process, passed a loopback TCP listener
using `SCM_RIGHTS`, and tested an already accepted connection, one queued before
handoff, and a fresh connection after handoff:

| Parent action after descriptor transfer | Existing accepted connection | Queued connection | New process listener |
|---|---|---|---|
| `close()` | Remained usable in parent | Accepted by child | Accepted fresh connection |
| `shutdown(SHUT_RDWR)`, then `close()` | Remained usable in parent | Reset | `accept` returned EINVAL; new connect refused |

The sandbox denied socket creation; the probe completed successfully with the
approved loopback execution outside that restriction. It verifies kernel socket
sharing semantics, not zhtps io_uring handoff or Envoy end-to-end behavior. Neither
server's test suite was run for this review.
The probe is retained at `/tmp/zhtps_listener_handoff_probe.py` for this workspace session.

### Tests required before claiming graceful upgrades

- Run two distinguishable executable versions: hold uploads and backpressured
  responses on the old version, verify fresh connections reach the new version,
  then complete the old work without truncated bodies or duplicate execution.
- Fill each old worker's connection slots and queue additional TCP connections.
  Confirm every eligible queued connection reaches a worker after handoff.
- Exercise accept cancellation races and `waiting_accept` with deterministic
  control points, plus repeated connection churn through many restarts.
- Cover HTTP/1 final keepalive requests, TLS handshakes/uploads/close alerts, and
  HTTP/2 active streams, GOAWAY boundaries, refused new streams, and client reconnects.
- Fail the replacement before and after descriptor receipt, during worker startup,
  and after readiness. Verify parent service survives pre-retirement failures,
  including errors reached through deferred cleanup.
- Reject protocol, worker-count, socket-policy, and public/admin role mismatches
  without altering the serving generation. Test port-zero and IPv6 adoption.
- Test long streams past the upgrade deadline, stuck application hooks, consecutive
  upgrades, process exits, and descriptor/resource cleanup. Report forced closure
  honestly rather than counting client retries as uninterrupted requests.
- Keep the existing ordinary shutdown behavior and regressions intact.

Existing useful coverage to extend includes [shutdown tests](../tests/shutdown.py),
[TLS upload shutdown](../tests/tls.py) (`test_shutdown_finishes_upload_and_sends_close_notify`),
and [HTTP/2 shutdown](../tests/http2.py)
(`test_shutdown_goaway_allows_existing_response_to_finish`).
