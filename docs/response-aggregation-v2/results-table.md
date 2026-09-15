| Workload | Permits | Baseline responses/s | Adaptive responses/s | Throughput change | CPU/response change | TCP segments/response, baseline → adaptive |
|---|---:|---:|---:|---:|---:|---:|
| Depth 1 | 192 | 516,334 | 519,810 | +0.7% | -1.0% | 2.000 → 2.000 |
| Depth 8 | 192 | 1,330,753 | 1,318,268 | -0.9% | +1.0% | 0.250 → 0.250 |
| Depth 32 | 192 | 1,472,233 | 1,466,720 | -0.4% | +0.6% | 0.125 → 0.125 |
| Depth 8, 8-byte writes | 192 | 499,238 | 501,383 | +0.4% | -0.2% | 5.379 → 5.373 |
| Depth 8 | 1024 | 1,312,365 | 1,583,693 | +20.7% | -18.4% | 0.250 → 0.250 |
| Depth 32 | 1024 | 1,479,855 | 2,049,208 | +38.5% | -27.3% | 0.125 → 0.125 |
