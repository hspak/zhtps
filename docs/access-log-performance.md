# Access-log costs

Measured September 21, 2026. The retained changes reduce browser-style access-record
generation from 171.5 to 110.4 ns per record (35.6%). At 50,000 requests/s with every
log retained, whole-server CPU fell from 2,920 to 2,841 ns per response (2.7%).
Larger writes also greatly improve retention under saturation, although the default
queue still drops records. [Run evidence](runs/access-log.json) contains the trial
results, configuration, and source/binary hashes.

The baseline already includes integer worker/connection generation/slot fields,
User-Agent capture, and removal of the access-record request counter. These
measurements isolate the subsequent formatting, queue, and write-batching changes.
Both variants produce the same schema.

## Retained implementation

- Scan strings in 16-byte blocks. Plain ASCII strings need one output reservation
  and copy. Strings needing escapes use the standard encoder; invalid UTF-8 keeps
  the previous standard-library representation as an array of byte integers.
- Replace ring-index division with bounded wrap checks. Account for all records
  completed by a write with one queue-count and pending-gauge update.
- Submit up to 128 queued records per asynchronous write, previously 16. There is
  no wait to fill a batch. The selected prefix stays fixed through partial writes,
  and the shared owner still prevents records from different workers interleaving.

The path remains allocation-free. The larger descriptor array adds 1,792 bytes
per worker on this target, covered by existing worker-resource sizing. Atomic
metrics remain compatible with callers sharing a Metrics instance.

A baseline user-space cycle profile put 26.6% of samples in memcpy and 21.5% in
Logger.writeJsonString. Generic JSON string handling repeated UTF-8 validation,
byte classification, and writer bookkeeping. Decimal formatting already uses the
standard library's two-digit conversion; a custom integer formatter was not needed.

## Generation benchmark

The benchmark uses the real logger, a 256-slot queue, and four record shapes. It
includes formatting, queue operations, and metrics; clock reads, networking, and
sink I/O are outside the timed loop. Five alternating repetitions each generate
two million records per case at batch sizes 1, 16, and 64. The table shows batch 16
medians; the evidence retains every trial and all batch sizes.

| Record | Before, ns | After, ns | Reduction |
|---|---:|---:|---:|
| Minimal, no User-Agent | 124.8 | 99.8 | 20.0% |
| Browser User-Agent | 171.5 | 110.4 | 35.6% |
| Escapes and Unicode | 172.9 | 155.3 | 10.1% |
| Route and structured fields | 211.4 | 154.1 | 27.1% |

Byte counts, checksums, and queue accounting agree across variants, with zero
drops. These lightweight benchmark checks do not prove byte-for-byte equality;
the differential encoding test provides that check separately.

## Real requests and sinks

Each trial starts a fresh server, warms up for 0.5 seconds, and validates every
HTTP response. The harness parses every retained JSON record after shutdown and
checks the expected public access count, integer identifiers, User-Agent, status,
method, and response bytes. It records drops and write errors rather than treating
lost logs as successful work. CPU spent draining after the request interval is
reported separately, along with pipe-collector CPU.

The fixed-rate tests use 1,024 queue slots per worker so both versions perform
complete logging. There are three alternating repetitions, with logging-enabled
and disabled controls.

| Workload | Before CPU, ns/response | After CPU, ns/response | Retention |
|---|---:|---:|---|
| 1 worker, file, 50k/s, logs on | 2,920 | 2,841 | 100% in every trial |
| Same, logs off | 2,160 | 2,160 | Disabled |
| 4 pinned workers, pipe, 100k/s, logs on | 7,533 | 7,467 | 100% in every trial |
| Same, logs off | 5,533 | 5,433 | Disabled |

The one-worker trials last five seconds. Subtracting the disabled medians gives
about 760 versus 680 ns of incremental logging CPU per response. This small
whole-server improvement is less decisive than the generation benchmark. The
four-worker trials last three seconds; their enabled and disabled variation does
not establish a CPU improvement. An earlier four-worker trial without individual
worker pinning was especially noisy; its inconclusive results are retained too.
Median trial p99 offered-to-response latency was 1.22 ms for both versions at
50k/s; the pinned pipe comparison was 1.17 versus 1.20 ms, within trial variation.

Closed-loop saturation uses 64 connections and the default 256-slot queue:

| Pipeline depth | Before responses/s | After responses/s | Before logs retained | After logs retained |
|---|---:|---:|---:|---:|
| 1 | 386,022 | 357,914 | 27.3% | 96.8% |
| 16 | 896,278 | 847,346 | 4.4% | 34.3% |

These are three-trial medians, lasting three seconds at depth 1 and two seconds at
depth 16. Retention counts include warmup. All retained records parsed correctly;
missing records were accounted for by drop counters, with zero write errors.
The optimized server spends more CPU writing substantially more logs, so the
response-throughput decrease is not an equal-work comparison. Depth-1 logging-off
controls measured 403,357 versus 413,257 responses/s.

The remaining limit under bursts is queue/sink drain capacity. A 64-record write
candidate already improved retention substantially; 128 further amortizes writes
at modest fixed memory cost. Increasing a bounded queue alone cannot make a
persistently overloaded sink lossless.

## Environment and limits

AMD Ryzen AI Max+ 395, 16 cores/32 threads, performance governor, Linux
7.2.6-arch2-1-strixhalo. Zig 0.16.0, ReleaseSafe, default x86_64_v4-linux-gnu target;
the host selects glibc 2.44 and Zig uses its available 2.43 implementation.
One-worker trials pin the server to CPU 2; four-worker trials pin workers to
8–11. Clients run on 4–7 and the harness/collector on CPU 0. Affinity does not
reserve CPUs against unrelated host work.

All requests are loopback HTTP/1.1 GETs with a browser User-Agent and a validated
six-byte body. The file sink is on tmpfs, and the pipe collector copies bytes to
tmpfs. These results do not measure persistent-disk durability, fsync, log-agent
parsing/shipping, TLS, or a remote NIC. Process CPU comes from /proc tick accounting
and does not include every kernel or collector cost. Source hashes identify the
measured variants; the benchmark's later list-formatting edit changes no workload.

## Correctness and reproduction

The encoding test compares against the original standard-library implementation
for all 256 byte values at each of 80 positions, plus Unicode, empty strings,
escaping, and exact/insufficient output capacity. It caught an initial candidate
that mishandled invalid UTF-8; the same test passes with the compatibility fallback.
Existing tests cover queue wrap and partial writes, blocked log pipes, worker
ownership, and per-response User-Agent lifetime through parser reuse.

Validation passed: 125 component/declaration tests, 43 HTTP/2 tests, the Debug and
ReleaseSafe wire suites, Go load-client tests, and formatting checks.

Preserve both variants with the same schema and toolchain before comparing:

~~~sh
# Before applying the optimization, with the benchmark target available:
zig build -Doptimize=ReleaseSafe --prefix /tmp/log-before install install-access-log
# After applying the optimization:
zig build -Doptimize=ReleaseSafe --prefix /tmp/log-after install install-access-log
GO111MODULE=off go build -o /tmp/log-pipeline ./bench/pipeline
GO111MODULE=off go build -o /tmp/log-offered ./bench/load

python3 bench/measure_access_log.py \
  before=/tmp/log-before/bin/access-log after=/tmp/log-after/bin/access-log \
  --output zig-out/bench/log-micro.json
python3 bench/access_log.py \
  before=/tmp/log-before/bin/zhtps after=/tmp/log-after/bin/zhtps \
  --client /tmp/log-pipeline --offered-client /tmp/log-offered \
  --rate 50000 --seconds 5 --log-slots 1024 \
  --output zig-out/bench/log-fixed.json
~~~

Omit the offered-client/rate options and use 256 log slots for closed-loop
saturation. Add `--depth 16 --seconds 2 --logging on` for bursts. For the pipe
comparison use `--sink pipe --workers 4 --server-cpus 8-11 --rate 100000 --seconds 3`
with 1,024 slots. Select available, disjoint CPUs on other hosts. The harness
deletes audited logs by default; `--keep-logs` retains them for further inspection.
