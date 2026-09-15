Closed-loop GET currently records durations but not measurement start/end wall
clock timestamps. The existing audit therefore reports whole-process CPU and
post-run RSS explicitly; it does not infer interval CPU. With public buffers
now released when clients disconnect, post-run RSS cannot represent live
connection memory.

Add two output-only timestamps derived from the existing measurement deadline
variables. Freeze a new client executable and source receipt without replacing
the old executable. Use the same new client for both servers in subsequent
closed-loop comparisons. Keep existing trials bound to their original client
SHA and preserve the old duration-only metrics. The updated audit will check
wall-clock duration and use interior samples for CPU and median RSS, while
retaining peak and post-run RSS with explicit labels.

The new client source is prepared in /tmp/zhtps-client-window. Build and run
its tests only after the current client-placement benchmarks have finished.

The first client build forced GO111MODULE=off, which unexpectedly embedded
legacy DefaultGODEBUG settings. Its tests passed, but it was never benchmarked.
V2 preserves automatic module mode and asserts that its complete Go build
settings match the original client's, before allowing comparison. Both source
and build receipts are retained.
