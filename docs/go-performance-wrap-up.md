The performance investigation ended at the user's request on September 13,
2026. All experiments have stopped. The results do **not** establish that ZHTPS
beats Go on every metric, or that read timeouts are impossible. Other
unfavorable results and ties are documented as unresolved; no further work is
scheduled under this investigation.

> Artifact retention: [Run summaries and setup records](runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

The retained source and binaries are `tcp-retries-v1`, including the earlier
common-buffer allocation improvement and bounded thin-stream TCP retries.
The latter is the adopted timeout mitigation: it substantially reduced read
timeouts while keeping the original two-second GET deadline. Its unchanged
packet-loss regression passes after six deliberately dropped response packets.
The retained implementation and complete GET/upload comparison are documented
in the [retry report](tcp-read-timeout-mitigation.md).

In the retained 48-trial comparison against Go, 16k read timeouts fell by
99.65% under 300k offered/s and 99.92% at saturation. ZHTPS led high-load GET
throughput and p99 across the four 8k/16k scenarios. The higher p50 in three high-load GET scenarios is accepted under the user's
preference for lower p99; all three have lower p99 with separated trial ranges.
Important gaps remain: the default-queue 64 KiB upload p99, some overlapping
upload results, generator misses, and ties including
capped throughput and zero failures. The complete ledger contains 45 favorable
comparisons with separated trial ranges, 14 lower count totals, 11 unfavorable
comparisons, five overlapping favorable comparisons, and 15 ties. These are
observations from repeated trials, not guarantees.
[Retained ledger](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/comparisons.json; raw artifact retired"). The separate
[acceptance record](runs/thin-retry-integration.json "Summary of docs/thin-retry-integration/acceptance.json; raw artifact retired") accepts three of the
11 unfavorable observations, leaving eight unaccepted; all 15 ties remain open.

The final [adaptive pacing experiment](adaptive-send-pacing.md) added 18
audited trials against retained ZHTPS and Go. It reduced read timeouts from
21 to three offered, and five to zero saturated, but lost 20–30% throughput,
raised p50 about tenfold, and nearly doubled memory. Higher p50 for lower p99 is now acceptable, but the throughput and resource
regressions still prevent adoption. It is discarded and was
never applied to the retained root. Earlier fixed pacing, server NAPI polling,
and the standalone 50 ms minimum-RTO candidate were also discarded with their
benefits and regressions preserved in their reports.

The delivery investigation found failed responses already handed to TCP;
two sampled traces reached the driver's transmit timestamp repeatedly without
an acknowledgment for the response. That narrows the failure path but does
not locate the exact NIC, switch, wire or receiver loss. The final read-only
checks verified disabled Ethernet pause configuration on both hosts and the
16-bit export width of their NIC missed counters. Pause negotiation, reliable
short-interval loss sampling, ingress correlation and ECN remain untested
ideas, not retained changes or scheduled experiments.
[Delivery evidence](read-timeout-followup.md),
[final findings and limitations](adaptive-send-pacing.md).

Correctness logs, immutable source/binary receipts, every decision run and
failure count, and discarded candidate patches remain available for review.
The final [verification record](runs/adaptive-send-pacing.json "Summary of docs/adaptive-send-pacing/wrap-up.json; raw artifact retired") records
retained-source hashes and benchmark-process cleanup on both hosts. Existing
staged and unstaged work is preserved; this wrap-up creates no commit.
