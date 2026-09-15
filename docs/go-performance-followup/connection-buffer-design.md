The first candidate removes eager common-buffer reservation for unused public
connection slots. It is isolated in /tmp/zhtps-go-performance-connection-buffers
until correctness and performance measurements justify retaining it.

- Keep configured slot capacity, receive sizes, HTTP limits, request leases,
  admission, application isolation, and reserved admin storage unchanged.
- Acquire one common buffer set when a public socket is accepted. Cache up to
  64 returned sets per worker. Release after application cleanup and all socket
  I/O have ended. Protect allocator misses/eviction with the existing mutex.
- On allocation failure, close only that public socket, count the failure, and
  back off public acceptance for 100 ms; admin uses its reserved storage.
- Keep common-buffer metrics separate from the existing large-buffer budget.
- A permanent wire regression compares startup RSS for 64 and 4,096 configured
  slots while exercising the same one live request. The old eager allocation
  should exceed the 16 MiB allowed metadata difference. Run it against the old
  binary before the candidate, without modifying the test between runs.
- Additional coverage exercises partial-read cancellation, reuse across new
  sockets, and real TCP recovery after allocator failure while admin remains
  responsive. Existing wire, streaming, executor, and library checks also apply.

Two existing component tests directly acquire request leases without accepting
real sockets. The refactor requires acquiring their connection buffers first;
this preserves the existing application-initialization and request-pool OOM
assertions. Their changes are structural setup changes, not weakened coverage.

Review identified that fatal ring cleanup intentionally leaves some per-socket
completion counters stale after kernel access has ended. Buffer release must
respect actual ownership (normal close drains I/O; deinit destroys the ring),
rather than adding an invalid assertion about those stale counters.

Performance concerns to measure: per-connection allocations may give common
buffer starts less cache-set diversity than the original odd-stride contiguous
array. Connection churn also moves allocator work from startup to acceptance.
Evaluate CPU/tail/throughput along with RSS, and include connection churn and
cleanup checks before retaining this implementation.

V1 validation found an existing embedded contract: bounded small pipelines must
work without allocating after init. Keep that test unchanged. V2 preallocates
up to 64 common sets (matching the existing request-cache scale), preserving
that bounded behavior while avoiding reservation against thousands of unused
slots. The new OOM integration case consumes those 64 sets before forcing a
65th allocation to fail. The original RSS regression remains unchanged.

V2 measured 3.3% more GET CPU at 8k and 4.6% at 16k (three rotated
pairs, non-overlapping per-variant ranges), despite lower memory. V3 is an
isolated experiment: add 960 bytes of owned padding to each common buffer
set and rotate its starting offset through sixteen 64-byte positions on
accept. For the default 20,928-byte set, both allocation sizes fit six
4 KiB pages. This preserves stable buffer lifetimes and pool ownership; the
common-buffer gauges include the padding. Large request-buffer pools are
unchanged. Profiles and before/after measurements will decide retention.

The first churn control exceeded the load host's source-port budget: its
32768–60999 range supplies 28,232 ports, while the test requested 155,000
connections to one destination. Each run opened 5,000 + 23,229 connections
(approximately the available source-port range), then
reported EADDRNOTAVAIL. Retain those failures as a load-generator-limited
control. A replacement uses 2,000 connections/s for ten seconds after
2,000 preparation connections, staying below that limit without changing
host TCP settings. It does not claim to validate 10k/s churn.
