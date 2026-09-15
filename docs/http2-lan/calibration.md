# HTTP/2 client placement calibration

> Artifact retention: [Run summaries and setup records](../runs/README.md) are retained.
> Raw traces, binaries, profiles, and source snapshots were removed.
> Artifact paths and restoration commands below describe the original runs.

At eight server CPUs and 64 connections, the primary client layout gives ZHTPS 285,662 and Go 242,359 verified responses/s. Leaving the client NIC’s physical core free gives ZHTPS 339,973 and Go 370,399 with seven client processes, reversing the throughput ranking. Repeating the original layout gives 288,148 and 252,242, respectively. These are medians of three trials, all with zero failures; the primary matrix measures this client/LAN configuration rather than isolated server ceilings.

The supplemental check holds the server at eight physical CPU cores, uses 64 connections with four streams each, and retains the same binary hashes, two-second warmup, eight-second issuing window, and three rotated repeats. The load host is still `client.example`. It contains 18 supplemental trials; the primary matrix is unchanged.

| Client layout | Server | Median verified responses/s | Range | Successful p99 (ms) | Client CPU cores | Failed operations |
|---|---|---:|---:|---:|---:|---:|
| 8 processes × 2 threads; CPUs 0–15 (primary) | ZHTPS | 285,662 | 284,595–288,255 | 1.990 | 6.44 | 0 |
| 8 processes × 2 threads; CPUs 0–15 (primary) | Go | 242,359 | 241,816–246,892 | 2.230 | 6.11 | 0 |
| 7 processes × 2 threads; CPUs 0–6,8–14 | ZHTPS | 339,973 | 339,792–340,700 | 1.130 | 7.42 | 0 |
| 7 processes × 2 threads; CPUs 0–6,8–14 | Go | 370,399 | 369,454–373,289 | 1.410 | 7.59 | 0 |
| 14 processes × 1 thread; CPUs 0–6,8–14 | ZHTPS | 333,419 | 333,253–333,777 | 1.080 | 6.61 | 0 |
| 14 processes × 1 thread; CPUs 0–6,8–14 | Go | 373,654 | 373,330–373,875 | 1.400 | 6.63 | 0 |
| 8 processes × 2 threads; CPUs 0–15 (repeat) | ZHTPS | 288,148 | 284,237–292,712 | 1.970 | 6.42 | 0 |
| 8 processes × 2 threads; CPUs 0–15 (repeat) | Go | 252,242 | 244,201–254,729 | 2.240 | 6.22 | 0 |

The seven-process layout changes median throughput by +19.0% for ZHTPS and +52.8% for Go relative to the primary layout. ZHTPS retains the lower successful-response p99 in that layout. The fourteen-process layout changes process count while keeping the same seven physical cores; it also places Go ahead on throughput.

The client interrupt snapshot reports `client_eth0` on IRQ 115 with effective affinity CPU 7. Its SMT sibling is CPU 15. The alternate layouts exclude both. The server snapshot places its NIC IRQ on CPU 24, outside server CPUs 0–7. No IRQ affinity, host sysctl, NIC setting, or server setting is changed.

The runs occurred in the order primary layout, seven processes, fourteen processes, then a repeat of the original layout. This return to the original layout checks temporal drift. The result supports a material effect of client placement and packet processing on this workload; it does not locate packet loss or prove an intrinsic HTTP/2 engine ceiling. This calibration covers only 64 connections and must not be extrapolated to the high-connection failure rates.

All 18 supplemental trials pass the same independent log/accounting audit. Every connection reached the ready and participating population, and every phase had zero failures.

- [Calibration summary and audit receipts](../runs/http2-lan.json "Summary of docs/http2-lan/calibration.json; raw artifact retired").
- Complete supplemental trials, logs, commands, histograms, and measured sources.
- [Primary matrix and method](../http2-lan.md).

```sh
python3 bench/compare_http2_lan.py --workers 8 --servers zhtps,go --connections 64 \
  --client-processes 7 --client-cpus 0-6,8-14 --output /tmp/http2-client7
python3 bench/compare_http2_lan.py --workers 8 --servers zhtps,go --connections 64 \
  --client-processes 14 --client-cpus 0-6,8-14 --output /tmp/http2-client14
python3 bench/compare_http2_lan.py --workers 8 --servers zhtps,go --connections 64 \
  --output /tmp/http2-client8-control
```
