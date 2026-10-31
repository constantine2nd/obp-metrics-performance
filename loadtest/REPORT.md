# OBP metric tables: load test

pgbench against a generated copy of the OBP metric tables (5M + 15M rows). Runs: `baseline`, `corrid`. Reference: `baseline`.

## read — Dashboards and metric screens

No writes: the metrics list, aggregates, top APIs and consumers, a lookup by correlation id, and a search in the archive.

| Clients | baseline TPS | baseline p95 | corrid TPS | corrid p95 |
|---|---|---|---|---|
| 1 | 20.6 | 241 ms | 107 | 34 ms |
| 4 | 30.4 | 728 ms | 193 | 82 ms |
| 8 | 30.1 | 1.51 s | 208 | 153 ms |
| 16 | 31.1 | 4.16 s | 219 | 307 ms |

## write — API traffic being logged

Inserts only: one metric row per API call, the write path of every request.

| Clients | baseline TPS | baseline p95 | corrid TPS | corrid p95 |
|---|---|---|---|---|
| 1 | 497 | 2.49 ms | 544 | 2.38 ms |
| 4 | 1,169 | 3.93 ms | 1,233 | 3.61 ms |
| 8 | 2,332 | 4.11 ms | 2,368 | 3.71 ms |
| 16 | 4,515 | 4.30 ms | 4,448 | 4.36 ms |

## mixed — Both at once, with the archive job

70% inserts plus the read mix, while a rate-limited background client moves old rows to metricarchive in batches.

| Clients | baseline TPS | baseline p95 | corrid TPS | corrid p95 |
|---|---|---|---|---|
| 1 | 59.6 | 63 ms | 240 | 26 ms |
| 4 | 88.3 | 506 ms | 358 | 75 ms |
| 8 | 90.0 | 671 ms | 287 | 199 ms |
| 16 | 89.8 | 1.25 s | 232 | 513 ms |

## Findings

**The lookup by correlation id was the whole bottleneck.** In the baseline, SELECT * FROM metric WHERE correlationid = $1 scanned all 5M rows on every call. At 16 clients it reached a p95 of 4.95 s and consumed 93% of all query time in the run, for 8% of the calls. With the index it answers in 15 ms: 323x faster.

**Without the index, reads did not scale at all.** Baseline read throughput was 20.6 tps at 1 client and 31.1 tps at 16: the extra clients only queued, while p95 grew from 241 ms to 4.16 s. With the index, throughput rises from 107 tps to 219 tps and the worst p95 in the matrix is 307 ms.

**The write path was never the problem.** Inserts scale almost linearly in both runs, from 497 tps at 1 client to 4,515 tps at 16, with p95 around 4 ms throughout. Six indexes on a 5M-row table are not what makes this system slow.

**The extra index costs nothing measurable on writes.** Write throughput with the index: 544 tps, 1,233 tps, 2,368 tps, 4,448 tps — between +10% and -1% of baseline, i.e. run-to-run noise. A single-statement bulk insert of 10,000 rows does pay for index maintenance (the showcase measured 1.7-3.4x), but a workload that inserts one row per transaction hides that cost in the commit.

**Under load the gain shows as throughput, not as lower latency everywhere.** In the mixed scenario at 16 clients, total throughput goes from 89.8 tps to 232 tps and p95 from 1.25 s to 513 ms, but the heavy aggregates get slower than in the baseline (top consumers 610 ms to 1.11 s). The system now completes far more transactions per second, so the remaining heavy queries compete for the same cache and disk. The bottleneck moved, it did not disappear.

**What to fix next.** With the lookup fixed, the heaviest statements are the top-APIs aggregate and the archive search by consumer, which together read tens of millions of blocks per run. The showcase measured both fixes: a covering index (demo 07) and a daily materialized view (demo 11, 20-30x on the same aggregate).

**Recommendation.** Add the index on the live table: CREATE INDEX CONCURRENTLY metric_correlationid ON metric (correlationid); — CONCURRENTLY so it does not block writes while it builds. Cost: 283 MB. For tracing old requests, metricarchive.correlationid needs its own index; a hash index there is 40% smaller than a B-tree and equally fast for exact lookups.
