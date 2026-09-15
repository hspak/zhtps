The isolated send-pacing-v1 source passed 65/65 ReleaseSafe build steps and
100/100 Zig tests, plus 62 wire tests and the embedded library, application,
request storage, buffer, idle-reclamation, and upload/streaming checks.
The three new wire tests exercise delayed delivery with responsive admin
traffic, write-deadline cancellation followed by reuse of the sole public
connection slot, and shutdown with queued output. Existing tests remain intact.

The candidate uses the retained public thin-retry policy. It introduces one
bounded queue entry per connection only when pacing is enabled, keeps prepared
send buffers borrowed until submission or cancellation, and retains original
write deadlines. Admin writes bypass pacing. A timer's timespec remains stable
until its completion arrives. Queued writes protect response ownership without
pretending to be submitted kernel operations.

The measured default is 100,000 send submissions/s per worker with a burst of
four. Seven workers therefore have independent budgets totaling 700,000/s;
this is not one globally synchronized wire-rate limiter. Larger sends may
contain multiple packets. The queue adds storage, clock reads and timer work;
all of these costs belong in the performance decision.

The source and binaries are frozen in the build receipt. Root production
source remains tcp-retries-v1 while the experiment is evaluated.
