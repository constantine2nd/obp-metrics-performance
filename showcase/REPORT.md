# Query optimization patterns on real OBP metric data

Common SQL optimization advice (anti-patterns, indexing and query patterns, database-specific features) tested on `obp_showcase`: 5M `metric` + 15M `metricarchive` rows modelled on the real OBP rows. Each claim is confirmed or corrected with measurements.

PostgreSQL 14 on a 4-core / 8-thread laptop CPU, 16 GB RAM, NVMe, `shared_buffers` = 128 MB (default); full details under [Test environment](#test-environment). Times are the median of up to 5 runs from `EXPLAIN (ANALYZE, BUFFERS)` (server-side execution time) unless marked *client*: those are measured end to end through psql, including result transfer, minus the psql start-up time. “First run” shows cache effects. Pages count from cache as *hit*; *read* came from the OS, which may itself have cached them.

Regenerate: `./showcase.py` (all) or `./showcase.py <demo>`; details per demo below.

## Summary

| # | Pattern | Category | Before → after | Result | Verdict |
|---|---|---|---|---|---|
| 00 | [Reading an execution plan](#00-reading-an-execution-plan) | Execution plans | - | - | Confirmed |
| 01 | [Estimated vs actual rows: stale statistics](#01-estimated-vs-actual-rows-stale-statistics) | Execution plans | 247 ms → 0.04 ms | **5,886× faster** | Confirmed, dramatically |
| 02 | [SELECT * vs only the needed columns](#02-select--vs-only-the-needed-columns) | Anti-pattern | 41 ms → 1.6 ms | **25× faster** | Partly confirmed, with a delayed side effect |
| 03 | [N+1 queries vs one query](#03-n1-queries-vs-one-query) | Anti-pattern | 68 ms → 22 ms | **3.1× faster** | Confirmed, but the cost is round trips, not the database |
| 04 | [Function wrapped around a column in WHERE](#04-function-wrapped-around-a-column-in-where) | Anti-pattern | 193 ms → 2.4 ms | **80× faster** | Confirmed |
| 05 | [OR across different columns vs UNION](#05-or-across-different-columns-vs-union) | Anti-pattern | 1.1 ms → 0.71 ms | **1.5× faster** | A myth for PostgreSQL, true in one case |
| 06 | [Implicit type conversion](#06-implicit-type-conversion) | Anti-pattern | 223 ms → 0.04 ms | **4,963× faster** | Different in PostgreSQL, and mostly safer |
| 07 | [Covering index for a frequent query](#07-covering-index-for-a-frequent-query) | Indexing | 50 ms → 38 ms | ≈ same | Confirmed, with a trade-off |
| 08 | [Partial index for a filtered subset](#08-partial-index-for-a-filtered-subset) | Indexing | 29 ms → 9.1 ms | **3.2× faster** | Confirmed |
| 09 | [OFFSET vs keyset pagination](#09-offset-vs-keyset-pagination) | Query pattern | 241 ms → 0.04 ms | **6,515× faster** | Confirmed exactly |
| 10 | [Row-by-row vs batch: the archive job](#10-row-by-row-vs-batch-the-archive-job) | Query pattern | 1.49 s → 213 ms | **7.0× faster** | Confirmed, and confirmed in OBP's code |
| 11 | [Materialized view for dashboard aggregations](#11-materialized-view-for-dashboard-aggregations) | Query pattern | 663 ms → 30 ms | **22× faster** | Confirmed |
| 12 | [EXPLAIN BUFFERS: cache vs disk](#12-explain-buffers-cache-vs-disk) | PostgreSQL feature | - | - | Confirmed, with nuance |
| 13 | [Expression index](#13-expression-index) | Indexing | 366 ms → 3.5 ms | **104× faster** | Confirmed |
| 14 | [Parallel query](#14-parallel-query) | PostgreSQL feature | 3.83 s → 1.88 s | **2.0× faster** | Confirmed, with diminishing returns |
| 15 | [Optimizer hints (MySQL) vs the PostgreSQL planner](#15-optimizer-hints-mysql-vs-the-postgresql-planner) | Planner (MySQL-style hints) | 242 ms → 0.86 ms | **281× faster** | PostgreSQL has no hints, and here it did not need them |
| 16 | [Stored generated column](#16-stored-generated-column) | Indexing (generated columns) | 241 ms → 3.3 ms | **73× faster** | Confirmed, though in PostgreSQL an expression index does the same without storing a column |
| 17 | [BRIN index for time series (PostgreSQL's answer to columnstore-style scans)](#17-brin-index-for-time-series-postgresqls-answer-to-columnstore-style-scans) | Indexing (columnstore alternative) | 851 ms → 14 ms | **59× faster** | BRIN is the size champion, not the speed champion |
| 18 | [Substring search: LIKE '%...%' vs trigram index](#18-substring-search-like--vs-trigram-index) | Indexing (text search) | 379 ms → 8.9 ms | **42× faster** | Confirmed |
| 19 | [Query Store (SQL Server) = pg_stat_statements + pgstat](#19-query-store-sql-server--pg_stat_statements--pgstat) | Monitoring (Query Store equivalent) | - | - | The equivalent exists in two parts |
| 20 | [Finale: tracing one request by correlation id](#20-finale-tracing-one-request-by-correlation-id) | Case study | 1.15 s → 0.04 ms | **29,369× faster** | One missing index was the whole story |

## Test environment

*Collected 2026-09-22 10:51 (automatically at the end of every `./showcase.py` run, or with `--env`).*

| Machine | |
|---|---|
| CPU | 11th Gen Intel(R) Core(TM) i7-11390H @ 3.40GHz (4 cores / 8 threads) |
| RAM | 15.4 GiB usable |
| Disk | SK hynix PC801 HFS512GEJ9X101N 476,9G (SSD) |
| OS | Linux Mint 21.3, kernel 5.15.0-190-generic |

| PostgreSQL | |
|---|---|
| Server | PostgreSQL 14.24 (Ubuntu 14.24-0ubuntu0.22.04.1) |
| Client | psql (PostgreSQL) 14.24 (Ubuntu 14.24-0ubuntu0.22.04.1) |
| Extensions | pg_buffercache 1.3, pg_stat_statements 1.9, pg_trgm 1.6 |
| Database | obp_showcase, 6430 MB |

### Memory and caching

| | Value | What it means |
|---|---|---|
| RAM | 15 GB usable, 5.9 GB available at collection | everything not used by programs acts as the OS page cache |
| OS page cache | 6.1 GB | file pages the kernel keeps in RAM; PostgreSQL's 'read' pages are often served from here |
| shared_buffers | 128 MB = 16,384 pages of 8 kB | PostgreSQL's own cache; the data is 50× larger. Common starting point: 25% of RAM ≈ 3.8 GB |
| effective_cache_size | 4.0 GB | not allocated: tells the planner how much cache (shared_buffers + OS) to expect, which favours index scans |
| work_mem | 4.0 MB | memory per sort / hash step before it spills to temp files |
| maintenance_work_mem | 64 MB | for CREATE INDEX and VACUUM; the demos raise it to 1 GB for their index builds |
| Cache hit ratio | 41.6% | since obp_showcase was created, all runs including setup and index builds: 26,423,181 pages from shared_buffers, 37,134,851 requested from the OS (283 GB). Large scans bypass shared_buffers (a 256 kB ring) so they don't evict it, which keeps this ratio low |
| Avg read time per page | 1.3 µs | from track_io_timing; a few µs means the OS page cache, NVMe random reads take ~50-100 µs |
| Temp files | 92 files, 4.4 GB | same period. Mostly index builds and the materialized view build/refresh (demo 11: sorting 5M rows with 4 MB work_mem). Two measured cases spill a little: 02 star_index (~3 MB per run, sorting whole rows) and 05 union_count (~1 MB, UNION de-duplication); a larger work_mem keeps them in memory |

Sizes: RAM (usable) 15 GB, OS page cache (at collection) 6.1 GB, effective_cache_size (planner assumption) 4.0 GB, shared_buffers (PostgreSQL cache) 128 MB, obp_showcase database 6.3 GB, metricarchive + indexes 4.9 GB, metric + indexes 1.3 GB.

**Reading BUFFERS** (one page = 8 kB)

| Term | Meaning |
|---|---|
| shared hit | page found in shared_buffers: no system call, fastest |
| shared read | page requested from the OS: served from the OS page cache (µs) or the disk (tens of µs+) |
| dirtied / written | pages this query changed / had to write out itself to free a buffer |
| I/O Timings: read | time spent in those reads (needs track_io_timing = on) |
| temp read / written | sort or hash data spilled to disk because it did not fit in work_mem |
| first run vs median | the first run shows a cold cache, later runs find the pages already cached |

| Setting | Value | Source | Why it matters here |
|---|---|---|---|
| `autovacuum` | on | default | keeps statistics fresh; demo 01 turns it off for its own table to show stale statistics |
| `checkpoint_timeout` | 5min | default | checkpoint interval; a checkpoint during a case can add write time |
| `effective_cache_size` | 4GB | default | planner's guess of total cache (shared_buffers + OS); higher favours index scans |
| `jit` | on | default | compiles expressions of large queries; adds start-up time to big aggregates (11, 14) |
| `maintenance_work_mem` | 64MB | default | index build speed; the demos set 1 GB in their own session |
| `max_parallel_workers` | 8 | default | parallel workers available to all queries (demo 14) |
| `max_parallel_workers_per_gather` | 2 | default | workers per query: parallel scans in 04, 06, 11, 17; varied 0-6 in demo 14 |
| `max_wal_size` | 1GB | configuration file | checkpoint distance; matters for index builds and bulk writes |
| `max_worker_processes` | 8 | default | upper limit for parallel workers (demo 14) |
| `pg_stat_statements.track` | top | default | which statements pg_stat_statements records (demo 19) |
| `random_page_cost` | 4 | default | 4 is the spinning-disk default; on NVMe ~1.1 is common and shifts plans to index scans |
| `shared_buffers` | 128MB | configuration file | PostgreSQL's cache: decides 'hit' vs 'read' in every plan (demos 00, 12) |
| `synchronous_commit` | on | default | each commit waits for the WAL flush; affects the insert cases (07, 10, 20) |
| `track_io_timing` | on | configuration file | adds I/O read time to BUFFERS output and pg_stat_statements |
| `work_mem` | 4MB | default | per sort / hash step; top-N sorts and aggregates (01, 07, 11) fit in 4 MB here |

| Table | Rows | Data | Indexes | Dates |
|---|---|---|---|---|
| `metric` | 5,032,502 | 1000 MB | 360 MB (6) | 2025-08-18 → 2026-09-22 |
| `metricarchive` | 15,137,962 | 3543 MB | 1473 MB (10) | 2022-09-23 → 2025-09-22 |

The rows are generated from the real `obp_mapped` rows (same mix of consumers, URLs, API functions, verbs and HTTP codes) with new correlation ids, varied durations and dates spread over the period.

| Method | |
|---|---|
| Timing | EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON), median of 5 runs (3 when the first run takes over 2 s); first run reported separately |
| Client timing | psql wall clock, results discarded, minus psql start-up (22 ms, measured each run) |
| Isolation | each demo creates its own indexes/tables and drops them afterwards; data-changing cases run in BEGIN ... ROLLBACK |
| Runner | showcase.py, Python 3.10.12 |

**Reproduce**

```bash
cd ../loadtest && ./01_build_base.sh   # obp_loadtest_base: copy of obp_mapped metric tables, scaled to 5M + 15M rows (~3 min)
cd ../showcase && ./00_setup.sh                           # obp_showcase: clone of the base (~20 s) + pg_trgm, pg_buffercache
./showcase.py                                             # all demos (~4 min), writes REPORT.md and REPORT.html
./99_cleanup.sh --yes                                     # drop obp_showcase afterwards (6.5 GB)
```

## 00 Reading an execution plan

*Execution plans*

> **Common advice:** EXPLAIN shows the plan without running the query; EXPLAIN ANALYZE runs it and adds real timings. Watch estimated vs actual rows, scan types (Seq Scan vs Index Scan), join methods and the costliest node.

**Verdict:** Confirmed. The plan shows the query walking metric_date_c backwards and filtering by consumer: thousands of rows are read and thrown away to return 50 (Rows Removed by Filter). BUFFERS adds where the pages came from: hit = already in shared_buffers, read = requested from the OS or the disk. A cold first run reads, a repeat hits; that explains most 'same query, different speed' puzzles (compare 'First run' with 'Time' in every table of this report).

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `metrics_list` | GET /management/metrics for one consumer, last 30 days, newest 50 | 0.65 ms | 0.62 ms | Limit → Index Scan Backward (metric_date_c) | 188 / 0 | 50 |

**1. EXPLAIN: the plan the optimizer picked, estimates only (the query is not executed)**

```
QUERY PLAN                                             
---------------------------------------------------------------------------------------------------
 Limit  (cost=0.44..418.45 rows=50 width=60)
   ->  Index Scan Backward using metric_date_c on metric  (cost=0.44..36283.81 rows=4340 width=60)
         Index Cond: (date_c >= (LOCALTIMESTAMP - '30 days'::interval))
         Filter: ((consumerid)::text = 'consumer-010'::text)
(4 rows)
```

**2. EXPLAIN (ANALYZE, BUFFERS): executed; actual rows, time per node and pages (hit = cache, read = disk/OS)**

```
QUERY PLAN                                                                  
----------------------------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=0.44..418.45 rows=50 width=60) (actual time=0.097..9.903 rows=50 loops=1)
   Buffers: shared hit=36 read=152
   I/O Timings: read=9.221
   ->  Index Scan Backward using metric_date_c on metric  (cost=0.44..36283.81 rows=4340 width=60) (actual time=0.096..9.894 rows=50 loops=1)
         Index Cond: (date_c >= (LOCALTIMESTAMP - '30 days'::interval))
         Filter: ((consumerid)::text = 'consumer-010'::text)
         Rows Removed by Filter: 5088
         Buffers: shared hit=36 read=152
         I/O Timings: read=9.221
 Planning:
   Buffers: shared hit=212
 Planning Time: 0.338 ms
 Execution Time: 9.923 ms
(13 rows)
```

<details><summary>metrics_list: SQL and plan</summary>

```sql
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days'
 ORDER BY date_c DESC LIMIT 50;
```

```
Limit | rows=50 (est 50) loops=1 time=0.612 ms | buffers hit=188 read=0
  -> Index Scan Backward (metric_date_c) | cond (date_c >= (LOCALTIMESTAMP - '30 days'::interval)) | filter ((consumerid)::text = 'consumer-010'::text) | rows=50 (est 4340) loops=1 time=0.608 ms | removed by filter=5088 | buffers hit=188 read=0
Planning 0.34 ms, execution 0.63 ms
```
</details>

## 01 Estimated vs actual rows: stale statistics

*Execution plans*

> **Common advice:** If the database thinks it is processing 100 rows but actually processes 100,000, its optimization decisions will be terrible. Large discrepancies often point to outdated statistics.

**Verdict:** Confirmed, dramatically. With statistics from before the new consumer's 1M rows, the planner estimated a few hundred rows, fetched all 1,000,000 through the consumer index and sorted them (247 ms). After ANALYZE (0.2 s) it expects 1M rows, walks the date index backwards and stops after 20 (0.04 ms): 5,886× faster. Autovacuum re-analyzes only after about 10% of a table changes, so bulk loads and new tenants can outrun it: run ANALYZE after big loads.

<table>
<tr><th width="50%">❌ Before: <code>stale</code><br><sub>latest 20 calls of the new consumer, statistics from before its 1M rows</sub></th><th width="50%">✅ After: <code>fresh</code><br><sub>same query after ANALYZE</sub><br><b>5,886× faster</b></th></tr>
<tr><td valign="top"><b>247 ms</b> &nbsp;·&nbsp; first run 265 ms<br>pages hit 7,599 / read 9,584 &nbsp;·&nbsp; 20 rows<pre>SELECT id, date_c, url, httpcode FROM sc_stale WHERE consumerid = 'new-bot' ORDER BY date_c DESC LIMIT 20;</pre><pre>Limit
   rows 20 (est 20), 247.194 ms
  -&gt; Sort
     rows 20 (est 290), 247.191 ms
    -&gt; Index Scan (sc_stale_consumer)
       rows 1000000 (est 290), 157.168 ms</pre></td><td valign="top"><b>0.04 ms</b> &nbsp;·&nbsp; first run 0.06 ms<br>pages hit 5 / read 0 &nbsp;·&nbsp; 20 rows<pre>SELECT id, date_c, url, httpcode FROM sc_stale WHERE consumerid = 'new-bot' ORDER BY date_c DESC LIMIT 20;</pre><pre>Limit
   rows 20 (est 20), 0.013 ms
  -&gt; Index Scan Backward (sc_stale_date)
     rows 20 (est 977752), 0.012 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `stale` | latest 20 calls of the new consumer, statistics from before its 1M rows | 247 ms | 265 ms | Limit → Sort → Index Scan (sc_stale_consumer) | 7,599 / 9,584 | 20 |
| `fresh` | same query after ANALYZE | 0.04 ms | 0.06 ms | Limit → Index Scan Backward (sc_stale_date) | 5 / 0 | 20 |

<details><summary>setup: setup (8.09 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
DROP TABLE IF EXISTS sc_stale;
-- Half of metric, with autovacuum (and so auto-ANALYZE) switched off for this table.
CREATE TABLE sc_stale WITH (autovacuum_enabled = false) AS SELECT * FROM metric WHERE id % 2 = 0;
CREATE INDEX sc_stale_consumer ON sc_stale (consumerid);
CREATE INDEX sc_stale_date ON sc_stale (date_c);
ANALYZE sc_stale;
-- After the last ANALYZE a new consumer (a bot, a partner's load test) makes 1M calls.
INSERT INTO sc_stale (url, duration, date_c, consumerid, correlationid, httpcode, verb)
SELECT '/obp/v5.1.0/banks', 20, localtimestamp - g * interval '1 second', 'new-bot', gen_random_uuid()::text, 200, 'GET'
  FROM generate_series(1, 1000000) g;
```
</details>

<details><summary>step: ANALYZE (217 ms)</summary>

```sql
ANALYZE sc_stale;
```
</details>

<details><summary>stale: SQL and plan</summary>

```sql
SELECT id, date_c, url, httpcode FROM sc_stale WHERE consumerid = 'new-bot' ORDER BY date_c DESC LIMIT 20;
```

```
Limit | rows=20 (est 20) loops=1 time=247.194 ms | buffers hit=7599 read=9584
  -> Sort | rows=20 (est 290) loops=1 time=247.191 ms | sort=top-N heapsort 26kB Memory | buffers hit=7599 read=9584
    -> Index Scan (sc_stale_consumer) | cond ((consumerid)::text = 'new-bot'::text) | rows=1000000 (est 290) loops=1 time=157.168 ms | buffers hit=7596 read=9584
Planning 0.26 ms, execution 247 ms, I/O read 21 ms
```
</details>

<details><summary>fresh: SQL and plan</summary>

```sql
SELECT id, date_c, url, httpcode FROM sc_stale WHERE consumerid = 'new-bot' ORDER BY date_c DESC LIMIT 20;
```

```
Limit | rows=20 (est 20) loops=1 time=0.013 ms | buffers hit=5 read=0
  -> Index Scan Backward (sc_stale_date) | filter ((consumerid)::text = 'new-bot'::text) | rows=20 (est 977752) loops=1 time=0.012 ms | buffers hit=5 read=0
Planning 0.27 ms, execution 0.03 ms
```
</details>

## 02 SELECT * vs only the needed columns

*Anti-pattern*

> **Common advice:** SELECT * transfers more data and prevents covering indexes: with only indexed columns the database can answer from the index without touching the table.

**Verdict:** Partly confirmed, with a delayed side effect. **SELECT * has a delayed side effect that no test can catch when the code is written: its cost depends on columns that do not exist yet. When a column is added to the table later, for example a large text or JSON field, every SELECT * starts reading, transferring and decoding it and gets slower, without any change to the query and without a new deployment of the code that runs it.** Measured below: after a migration added a ~2 kB JSON column (table 82 MB to 905 MB), the unchanged SELECT * for one consumer's 30 days went from 30 ms to 144 ms (4.8× slower), while the explicit-column query stayed at 23 ms. EXPLAIN ANALYZE hides most of it (13 ms to 21 ms): it never fetches the out-of-line (TOAST) values, which only happens when rows are really sent to the client. Sending all columns of 96k rows took 2.6× longer than 4 columns (rows average 203 vs 83 bytes). The bigger win is the covering effect: with only indexed columns the query became an Index Only Scan, 41 ms to 1.6 ms (25×), reading 89 pages instead of 15,205. metric rows are narrow; with large responsebody values the transfer gap grows.

<table>
<tr><th width="50%">❌ Before: <code>star_index</code><br><sub>SELECT * for one consumer, last 30 days (index + table)</sub></th><th width="50%">✅ After: <code>columns_index_only</code><br><sub>only columns that are in the index -&gt; Index Only Scan</sub><br><b>25× faster</b></th></tr>
<tr><td valign="top"><b>41 ms</b> &nbsp;·&nbsp; first run 163 ms<br>pages hit 15,205 / read 0 &nbsp;·&nbsp; 11,689 rows<pre>SELECT * FROM metric WHERE consumerid = 'consumer-004' AND date_c &gt;= localtimestamp - interval '30 days' ORDER BY date_c DESC;</pre><pre>Gather Merge
   rows 11689 (est 11530), 32.07 ms
  -&gt; Parallel Index Scan Backward (metric_date_c)
     rows 3896 (est 4804), 22.849 ms</pre></td><td valign="top"><b>1.6 ms</b> &nbsp;·&nbsp; first run 1.8 ms<br>pages hit 89 / read 0 &nbsp;·&nbsp; 11,689 rows<pre>SELECT date_c, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-004' AND date_c &gt;= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- Delayed side effect: the same unchanged SELECT * before and after a later migration adds a wide column.
-- Uses a copy of the last 30 days of metric, so the real table is not rewritten.</pre><pre>Index Only Scan Backward (sc_metric_consumer_date_incl)
   rows 11689 (est 11530), 2.005 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `star_client` | SELECT * of the last 7 days (~96k rows) sent to the client | 141 ms *client* | 159 ms | - | - | - |
| `columns_client` | same rows, only id, date_c, url, duration | 54 ms *client* | 54 ms | - | - | - |
| `star_index` | SELECT * for one consumer, last 30 days (index + table) | 41 ms | 163 ms | Parallel Index Scan Backward (metric_date_c) | 15,205 / 0 | 11,689 |
| `columns_index_only` | only columns that are in the index -> Index Only Scan | 1.6 ms | 1.8 ms | Index Only Scan Backward (sc_metric_consumer_date_incl) | 89 / 0 | 11,689 |
| `wide_star_before` | SELECT * for one consumer, 30 days, sent to the client (before) | 30 ms *client* | 49 ms | - | - | - |
| `wide_columns_before` | the same rows, only the 5 needed columns (before) | 23 ms *client* | 27 ms | - | - | - |
| `wide_star_before_server` | server side of SELECT * (before) | 13 ms | 13 ms | Sort → Bitmap Heap Scan (sc_wide) → Bitmap Index Scan (sc_wide_consumer_date) | 7,397 / 0 | 11,689 |
| `wide_star_after` | the SAME SELECT * after the migration, sent to the client | 144 ms *client* | 134 ms | - | - | - |
| `wide_columns_after` | the SAME explicit-column query after the migration | 23 ms *client* | 36 ms | - | - | - |
| `wide_star_after_server` | server side of the same SELECT * (after) | 21 ms | 18 ms | Sort → Bitmap Heap Scan (sc_wide) → Bitmap Index Scan (sc_wide_consumer_date) | 7,602 / 0 | 11,689 |

<details><summary>setup: setup (3.80 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_consumer_date_incl ON metric (consumerid, date_c) INCLUDE (duration, httpcode);
VACUUM metric;
```
</details>

**Row width: all columns vs the 4 needed ones (average bytes per row, 1% sample)**

```
all_columns_bytes | four_columns_bytes 
-------------------+--------------------
               199 |                 84
(1 row)
```

<details><summary>step: copy of the last 30 days of metric (~410k rows) with its index (731 ms)</summary>

```sql
SET maintenance_work_mem = '1GB';
DROP TABLE IF EXISTS sc_wide;
CREATE TABLE sc_wide AS SELECT * FROM metric WHERE date_c >= localtimestamp - interval '30 days';
CREATE INDEX sc_wide_consumer_date ON sc_wide (consumerid, date_c);
VACUUM ANALYZE sc_wide;
```
</details>

**Table size before the migration**

```
table_incl_toast |  rows  
------------------+--------
 82 MB            | 410706
(1 row)
```

<details><summary>step: a later migration adds a JSON column (~2 kB per row), no query changes (38.34 s)</summary>

```sql
ALTER TABLE sc_wide ADD COLUMN details text;
UPDATE sc_wide SET details = (SELECT '{"request":{"headers":{},"body":"' || string_agg(md5(sc_wide.id::text || g), '')
                                     || '"},"response":{"status":200}}' FROM generate_series(1, 60) g);
VACUUM FULL sc_wide;
ANALYZE sc_wide;
```
</details>

**Table size after the migration (the new values are stored out of line in the TOAST table)**

```
table_incl_toast | toast_part | avg_details_chars 
------------------+------------+-------------------
 905 MB           | 802 MB     |              1982
(1 row)
```

<details><summary>star_client: SQL</summary>

```sql
SELECT * FROM metric WHERE date_c >= localtimestamp - interval '7 days';
```
</details>

<details><summary>columns_client: SQL</summary>

```sql
SELECT id, date_c, url, duration FROM metric WHERE date_c >= localtimestamp - interval '7 days';
```
</details>

<details><summary>star_index: SQL and plan</summary>

```sql
SELECT * FROM metric WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;
```

```
Gather Merge | rows=11689 (est 11530) loops=1 time=32.07 ms | workers=2 | buffers hit=15205 read=0
  -> Parallel Index Scan Backward (metric_date_c) | cond (date_c >= (LOCALTIMESTAMP - '30 days'::interval)) | filter ((consumerid)::text = 'consumer-004'::text) | rows=3896 (est 4804) loops=3 time=22.849 ms | removed by filter=133006 | buffers hit=15205 read=0
Planning 0.40 ms, execution 33 ms
```
</details>

<details><summary>columns_index_only: SQL and plan</summary>

```sql
SELECT date_c, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- Delayed side effect: the same unchanged SELECT * before and after a later migration adds a wide column.
-- Uses a copy of the last 30 days of metric, so the real table is not rewritten.
```

```
Index Only Scan Backward (sc_metric_consumer_date_incl) | cond ((consumerid = 'consumer-004'::text) AND (date_c >= (LOCALTIMESTAMP - '30 days'::interval))) | rows=11689 (est 11530) loops=1 time=2.005 ms | heap fetches=0 | buffers hit=89 read=0
Planning 0.55 ms, execution 2.4 ms
```
</details>

<details><summary>wide_star_before: SQL</summary>

```sql
SELECT * FROM sc_wide WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;
```
</details>

<details><summary>wide_columns_before: SQL</summary>

```sql
SELECT id, date_c, url, duration, httpcode FROM sc_wide
 WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;
```
</details>

<details><summary>wide_star_before_server: SQL and plan</summary>

```sql
SELECT * FROM sc_wide WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;
```

```
Sort | rows=11689 (est 11553) loops=1 time=14.499 ms | sort=quicksort 4020kB Memory | buffers hit=7397 read=0
  -> Bitmap Heap Scan (sc_wide) | rows=11689 (est 11553) loops=1 time=10.744 ms | buffers hit=7394 read=0
    -> Bitmap Index Scan (sc_wide_consumer_date) | cond (((consumerid)::text = 'consumer-004'::text) AND (date_c >= (LOCALTIMESTAMP - '30 days'::interval))) | rows=11689 (est 11553) loops=1 time=1.798 ms | buffers hit=60 read=0
Planning 0.44 ms, execution 15 ms
```
</details>

<details><summary>wide_star_after: SQL</summary>

```sql
SELECT * FROM sc_wide WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;
```
</details>

<details><summary>wide_columns_after: SQL</summary>

```sql
SELECT id, date_c, url, duration, httpcode FROM sc_wide
 WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;
```
</details>

<details><summary>wide_star_after_server: SQL and plan</summary>

```sql
SELECT * FROM sc_wide WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;
```

```
Sort | rows=11689 (est 11348) loops=1 time=20.146 ms | sort=external merge 3016kB Disk | buffers hit=7602 read=0
  -> Bitmap Heap Scan (sc_wide) | rows=11689 (est 11348) loops=1 time=12.771 ms | buffers hit=7599 read=0
    -> Bitmap Index Scan (sc_wide_consumer_date) | cond (((consumerid)::text = 'consumer-004'::text) AND (date_c >= (LOCALTIMESTAMP - '30 days'::interval))) | rows=11689 (est 11348) loops=1 time=1.287 ms | buffers hit=60 read=0
Planning 0.39 ms, execution 21 ms
```
</details>

## 03 N+1 queries vs one query

*Anti-pattern*

> **Common advice:** One query for a list, then one query per item: with 100 items that is 101 queries when 1 or 2 would do.

**Verdict:** Confirmed, but the cost is round trips, not the database. 1,001 queries took 68 ms vs 22 ms for one LATERAL query (3.1×) over a local Unix socket, where a round trip costs well under 0.1 ms. Over a network with 1 ms latency the N+1 version would add about 1 s; an ORM talking to a remote database pays that on every page load.

<table>
<tr><th width="50%">❌ Before: <code>n_plus_1</code><br><sub>1 query for the failed calls + 1 query per call for the previous call (1000 round trips)</sub></th><th width="50%">✅ After: <code>lateral_client</code><br><sub>the same data in one query with a LATERAL join (1 round trip)</sub><br><b>3.1× faster</b></th></tr>
<tr><td valign="top"><b>68 ms</b> <i>client</i> &nbsp;·&nbsp; first run 64 ms<br><pre>SELECT format('SELECT id, date_c, url, httpcode FROM metric WHERE userid = %L AND date_c &lt; %L '
              'ORDER BY date_c DESC LIMIT 1', userid, date_c)
  FROM (SELECT userid, date_c FROM metric WHERE httpcode &gt;= 400 AND userid IS NOT NULL
         ORDER BY date_c DESC LIMIT 1000) f \gexec</pre></td><td valign="top"><b>22 ms</b> <i>client</i> &nbsp;·&nbsp; first run 13 ms<br><pre>SELECT f.id, f.date_c, f.url, p.id AS prev_id, p.date_c AS prev_date, p.url AS prev_url, p.httpcode AS prev_code
  FROM (SELECT id, userid, date_c, url FROM metric WHERE httpcode &gt;= 400 AND userid IS NOT NULL
         ORDER BY date_c DESC LIMIT 1000) f
  LEFT JOIN LATERAL (SELECT id, date_c, url, httpcode FROM metric m
                      WHERE m.userid = f.userid AND m.date_c &lt; f.date_c
                      ORDER BY m.date_c DESC LIMIT 1) p ON true;</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `n_plus_1` | 1 query for the failed calls + 1 query per call for the previous call (1000 round trips) | 68 ms *client* | 64 ms | - | - | - |
| `lateral_client` | the same data in one query with a LATERAL join (1 round trip) | 22 ms *client* | 13 ms | - | - | - |
| `lateral_server` | server-side execution time of the single query | 11 ms | 11 ms | Nested Loop → Limit → Index Scan Backward (metric_date_c) → Index Scan Backward (sc_metric_user_date) | 5,604 / 0 | 1,000 |

<details><summary>setup: setup (2.43 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_user_date ON metric (userid, date_c);

-- Typical ORM screen: the latest 1000 failed calls, and for each one the same user's previous call.
```
</details>

<details><summary>n_plus_1: SQL</summary>

```sql
SELECT format('SELECT id, date_c, url, httpcode FROM metric WHERE userid = %L AND date_c < %L '
              'ORDER BY date_c DESC LIMIT 1', userid, date_c)
  FROM (SELECT userid, date_c FROM metric WHERE httpcode >= 400 AND userid IS NOT NULL
         ORDER BY date_c DESC LIMIT 1000) f \gexec
```
</details>

<details><summary>lateral_client: SQL</summary>

```sql
SELECT f.id, f.date_c, f.url, p.id AS prev_id, p.date_c AS prev_date, p.url AS prev_url, p.httpcode AS prev_code
  FROM (SELECT id, userid, date_c, url FROM metric WHERE httpcode >= 400 AND userid IS NOT NULL
         ORDER BY date_c DESC LIMIT 1000) f
  LEFT JOIN LATERAL (SELECT id, date_c, url, httpcode FROM metric m
                      WHERE m.userid = f.userid AND m.date_c < f.date_c
                      ORDER BY m.date_c DESC LIMIT 1) p ON true;
```
</details>

<details><summary>lateral_server: SQL and plan</summary>

```sql
SELECT f.id, f.date_c, f.url, p.id AS prev_id, p.date_c AS prev_date, p.url AS prev_url, p.httpcode AS prev_code
  FROM (SELECT id, userid, date_c, url FROM metric WHERE httpcode >= 400 AND userid IS NOT NULL
         ORDER BY date_c DESC LIMIT 1000) f
  LEFT JOIN LATERAL (SELECT id, date_c, url, httpcode FROM metric m
                      WHERE m.userid = f.userid AND m.date_c < f.date_c
                      ORDER BY m.date_c DESC LIMIT 1) p ON true;
```

```
Nested Loop | rows=1000 (est 1000) loops=1 time=10.432 ms | buffers hit=5604 read=0
  -> Limit | rows=1000 (est 1000) loops=1 time=5.35 ms | buffers hit=1602 read=0
    -> Index Scan Backward (metric_date_c) | filter ((userid IS NOT NULL) AND (httpcode >= 400)) | rows=1000 (est 77038) loops=1 time=5.304 ms | removed by filter=44799 | buffers hit=1602 read=0
  -> Limit | rows=1 (est 1) loops=1000 time=0.005 ms | buffers hit=4002 read=0
    -> Index Scan Backward (sc_metric_user_date) | cond (((userid)::text = (metric.userid)::text) AND (date_c < metric.date_c)) | rows=1 (est 10910) loops=1000 time=0.005 ms | buffers hit=4002 read=0
Planning 0.43 ms, execution 10 ms
```
</details>

## 04 Function wrapped around a column in WHERE

*Anti-pattern*

> **Common advice:** Wrapping a column in a function makes indexes useless: rewrite as a range, or index the computed value.

**Verdict:** Confirmed. date_c::date = day forced a parallel scan of all 5M rows (193 ms); the equivalent range used the date index (2.4 ms, 80× faster). lower(developeremail) scanned all 15M archive rows (1.71 s); an expression index brought it to 233 ms, about the speed of the plain column (225 ms; the rest is fetching 160k matching rows). PostgreSQL offers both fixes: rewrite as a range, or index the expression.

<table>
<tr><th width="50%">❌ Before: <code>cast_date</code><br><sub>calls on one day with date_c::date = day</sub></th><th width="50%">✅ After: <code>range</code><br><sub>same day as a range on the raw column</sub><br><b>80× faster</b></th></tr>
<tr><td valign="top"><b>193 ms</b> &nbsp;·&nbsp; first run 189 ms<br>pages hit 10,947 / read 117,034 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM metric WHERE date_c::date = current_date - 30;</pre><pre>Aggregate
   rows 1 (est 1), 183.128 ms
  -&gt; Gather
     rows 3 (est 2), 183.112 ms
    -&gt; Aggregate
       rows 1 (est 1), 168.304 ms
      -&gt; Parallel Seq Scan (metric)
         rows 4566 (est 10485), 168.081 ms</pre></td><td valign="top"><b>2.4 ms</b> &nbsp;·&nbsp; first run 2.3 ms<br>pages hit 443 / read 0 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM metric WHERE date_c &gt;= current_date - 30 AND date_c &lt; current_date - 29;</pre><pre>Aggregate
   rows 1 (est 1), 2.715 ms
  -&gt; Index Scan (metric_date_c)
     rows 13699 (est 13866), 2.046 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `cast_date` | calls on one day with date_c::date = day | 193 ms | 189 ms | Aggregate → Parallel Seq Scan (metric) | 10,947 / 117,034 | 1 |
| `range` | same day as a range on the raw column | 2.4 ms | 2.3 ms | Aggregate → Index Scan (metric_date_c) | 443 / 0 | 1 |
| `lower_email` | metricarchive, lower(developeremail) = '...' (15M rows) | 1.71 s | 2.36 s | Aggregate → Parallel Seq Scan (metricarchive) | 192 / 449,538 | 1 |
| `plain_email` | same without the function (uses metricarchive_developeremail) | 225 ms | 248 ms | Aggregate → Index Scan (metricarchive_developeremail) | 0 / 120,440 | 1 |
| `lower_email_indexed` | lower(developeremail) = '...' with the expression index | 233 ms | 278 ms | Aggregate → Index Scan (sc_archive_lower_email) | 0 / 120,440 | 1 |

<details><summary>step: expression index on lower(developeremail) (6.22 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_archive_lower_email ON metricarchive (lower(developeremail));
ANALYZE metricarchive;
```
</details>

<details><summary>cast_date: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric WHERE date_c::date = current_date - 30;
```

```
Aggregate | rows=1 (est 1) loops=1 time=183.128 ms | buffers hit=10947 read=117034
  -> Gather | rows=3 (est 2) loops=1 time=183.112 ms | workers=2 | buffers hit=10947 read=117034
    -> Aggregate | rows=1 (est 1) loops=3 time=168.304 ms | buffers hit=10947 read=117034
      -> Parallel Seq Scan (metric) | filter ((date_c)::date = (CURRENT_DATE - 30)) | rows=4566 (est 10485) loops=3 time=168.081 ms | removed by filter=1672939 | buffers hit=10947 read=117034
Planning 0.30 ms, execution 194 ms, I/O read 120 ms
```
</details>

<details><summary>range: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric WHERE date_c >= current_date - 30 AND date_c < current_date - 29;
```

```
Aggregate | rows=1 (est 1) loops=1 time=2.715 ms | buffers hit=443 read=0
  -> Index Scan (metric_date_c) | cond ((date_c >= (CURRENT_DATE - 30)) AND (date_c < (CURRENT_DATE - 29))) | rows=13699 (est 13866) loops=1 time=2.046 ms | buffers hit=443 read=0
Planning 0.31 ms, execution 2.8 ms
```
</details>

<details><summary>lower_email: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metricarchive WHERE lower(developeremail) = 'developer-02@example.com';
```

```
Aggregate | rows=1 (est 1) loops=1 time=1200.32 ms | buffers hit=192 read=449538
  -> Gather | rows=3 (est 2) loops=1 time=1200.298 ms | workers=2 | buffers hit=192 read=449538
    -> Aggregate | rows=1 (est 1) loops=3 time=1186.455 ms | buffers hit=192 read=449538
      -> Parallel Seq Scan (metricarchive) | filter (lower((developeremail)::text) = 'developer-02@example.com'::text) | rows=53545 (est 31538) loops=3 time=1181.851 ms | removed by filter=4992442 | buffers hit=192 read=449538
Planning 0.31 ms, execution 1.21 s, I/O read 464 ms
```
</details>

<details><summary>plain_email: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metricarchive WHERE developeremail = 'developer-02@example.com';
```

```
Aggregate | rows=1 (est 1) loops=1 time=224.937 ms | buffers hit=0 read=120440
  -> Index Scan (metricarchive_developeremail) | cond ((developeremail)::text = 'developer-02@example.com'::text) | rows=160636 (est 167022) loops=1 time=211.882 ms | buffers hit=0 read=120440
Planning 0.41 ms, execution 225 ms, I/O read 151 ms
```
</details>

<details><summary>lower_email_indexed: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metricarchive WHERE lower(developeremail) = 'developer-02@example.com';
```

```
Aggregate | rows=1 (est 1) loops=1 time=230.607 ms | buffers hit=0 read=120440
  -> Index Scan (sc_archive_lower_email) | cond (lower((developeremail)::text) = 'developer-02@example.com'::text) | rows=160636 (est 172580) loops=1 time=217.639 ms | buffers hit=0 read=120440
Planning 0.46 ms, execution 231 ms, I/O read 153 ms
```
</details>

## 05 OR across different columns vs UNION

*Anti-pattern*

> **Common advice:** OR across different columns often prevents index usage; UNION lets each part use its own index.

**Verdict:** A myth for PostgreSQL, true in one case. OR across two indexed columns is answered with a BitmapOr of both indexes: 158 ms vs 194 ms for the UNION. OR with an unindexed column does force a full scan (223 ms). UNION helps for 'newest N' queries where each side reads its own (column, date_c) index in order: 1.1 ms vs 0.71 ms (1.5×), a small absolute gain.

<table>
<tr><th width="50%">❌ Before: <code>or_latest_rare</code><br><sub>newest 20 calls of a rare consumer OR a rare user (~800 matching rows in 5M)</sub></th><th width="50%">✅ After: <code>union_latest_rare</code><br><sub>same as UNION of two index lookups</sub><br><b>1.5× faster</b></th></tr>
<tr><td valign="top"><b>1.1 ms</b> &nbsp;·&nbsp; first run 3.6 ms<br>pages hit 781 / read 0 &nbsp;·&nbsp; 20 rows<pre>SELECT id, date_c, url FROM metric
 WHERE consumerid = 'consumer-036' OR userid = 'user-0077'
 ORDER BY date_c DESC LIMIT 20;</pre><pre>Limit
   rows 20 (est 20), 1.053 ms
  -&gt; Sort
     rows 20 (est 459), 1.051 ms
    -&gt; Bitmap Heap Scan (metric)
       rows 773 (est 459), 0.889 ms
      -&gt; BitmapOr
         rows 0 (est 459), 0.076 ms
        -&gt; Bitmap Index Scan (sc_metric_consumer_date)
           rows 465 (est 1), 0.061 ms
        -&gt; Bitmap Index Scan (metric_userid_idx)
           rows 308 (est 459), 0.014 ms</pre></td><td valign="top"><b>0.71 ms</b> &nbsp;·&nbsp; first run 0.81 ms<br>pages hit 492 / read 0 &nbsp;·&nbsp; 20 rows<pre>SELECT id, date_c, url FROM (
  (SELECT id, date_c, url FROM metric WHERE consumerid = 'consumer-036' ORDER BY date_c DESC LIMIT 20)
  UNION
  (SELECT id, date_c, url FROM metric WHERE userid = 'user-0077' ORDER BY date_c DESC LIMIT 20)
) u ORDER BY date_c DESC LIMIT 20;</pre><pre>Limit
   rows 20 (est 20), 0.647 ms
  -&gt; Sort
     rows 20 (est 21), 0.646 ms
    -&gt; Aggregate
       rows 40 (est 21), 0.63 ms
      -&gt; Append
         rows 40 (est 21), 0.611 ms
        -&gt; Limit
           rows 20 (est 1), 0.578 ms
          -&gt; Sort
             rows 20 (est 1), 0.577 ms
            -&gt; Index Scan (metric_consumerid)
               rows 465 (est 1), 0.479 ms
        -&gt; Limit
           rows 20 (est 20), 0.031 ms
          -&gt; Index Scan Backward (sc_metric_user_date)
             rows 20 (est 459), 0.03 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `or_count` | consumerid = X OR userid = Y, both columns indexed | 158 ms | 169 ms | Aggregate → Bitmap Heap Scan (metric) → BitmapOr → Bitmap Index Scan (metric_consumerid) → Bitmap Index Scan (metric_userid_idx) | 0 / 47,683 | 1 |
| `union_count` | the same as UNION of two queries | 194 ms | 194 ms | Aggregate → Append → Bitmap Heap Scan (metric) → Bitmap Index Scan (metric_consumerid) → Index Scan (metric_userid_idx) | 1,897 / 49,977 | 1 |
| `or_unindexed` | consumerid = X OR correlationid = Y, correlationid has no index | 223 ms | 235 ms | Aggregate → Parallel Seq Scan (metric) | 16,129 / 111,852 | 1 |
| `or_latest` | newest 20 calls of consumer X or user Y | 0.18 ms | 0.58 ms | Limit → Index Scan Backward (metric_date_c) | 49 / 0 | 20 |
| `union_latest` | newest 20 of each side, merged | 0.17 ms | 0.27 ms | Limit → Sort → Aggregate → Append → Index Scan Backward (sc_metric_consumer_date) → Index Scan Backward (sc_metric_user_date) | 47 / 0 | 20 |
| `or_latest_rare` | newest 20 calls of a rare consumer OR a rare user (~800 matching rows in 5M) | 1.1 ms | 3.6 ms | Limit → Sort → Bitmap Heap Scan (metric) → BitmapOr → Bitmap Index Scan (sc_metric_consumer_date) → Bitmap Index Scan (metric_userid_idx) | 781 / 0 | 20 |
| `union_latest_rare` | same as UNION of two index lookups | 0.71 ms | 0.81 ms | Limit → Sort → Aggregate → Append → Index Scan (metric_consumerid) → Index Scan Backward (sc_metric_user_date) | 492 / 0 | 20 |

<details><summary>step: indexes that also cover the sort order (5.53 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_consumer_date ON metric (consumerid, date_c);
CREATE INDEX sc_metric_user_date ON metric (userid, date_c);
```
</details>

<details><summary>or_count: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric
 WHERE consumerid = 'consumer-010' OR userid = 'user-0002';
```

```
Aggregate | rows=1 (est 1) loops=1 time=145.578 ms | buffers hit=0 read=47683
  -> Bitmap Heap Scan (metric) | rows=60672 (est 58981) loops=1 time=135.762 ms | buffers hit=0 read=47683
    -> BitmapOr | rows=0 (est 59048) loops=1 time=4.799 ms | buffers hit=0 read=57
      -> Bitmap Index Scan (metric_consumerid) | cond ((consumerid)::text = 'consumer-010'::text) | rows=51539 (est 52674) loops=1 time=3.927 ms | buffers hit=0 read=47
      -> Bitmap Index Scan (metric_userid_idx) | cond ((userid)::text = 'user-0002'::text) | rows=9133 (est 6375) loops=1 time=0.87 ms | buffers hit=0 read=10
Planning 0.35 ms, execution 158 ms, I/O read 77 ms
```
</details>

<details><summary>union_count: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM (
  SELECT id, duration FROM metric WHERE consumerid = 'consumer-010'
  UNION
  SELECT id, duration FROM metric WHERE userid = 'user-0002') u;
```

```
Aggregate | rows=1 (est 1) loops=1 time=177.789 ms | buffers hit=1897 read=49977
  -> Aggregate | rows=60672 (est 59049) loops=1 time=175.376 ms | buffers hit=1897 read=49977
    -> Append | rows=60672 (est 59049) loops=1 time=149.214 ms | buffers hit=1897 read=49977
      -> Bitmap Heap Scan (metric) | rows=51539 (est 52674) loops=1 time=130.012 ms | buffers hit=792 read=42201
        -> Bitmap Index Scan (metric_consumerid) | cond ((consumerid)::text = 'consumer-010'::text) | rows=51539 (est 52674) loops=1 time=4.159 ms | buffers hit=0 read=47
      -> Index Scan (metric_userid_idx) | cond ((userid)::text = 'user-0002'::text) | rows=9133 (est 6375) loops=1 time=15.011 ms | buffers hit=1105 read=7776
Planning 0.38 ms, execution 190 ms, I/O read 75 ms
```
</details>

<details><summary>or_unindexed: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric
 WHERE consumerid = 'consumer-010' OR correlationid = '00000000-0000-0000-0000-000000000000';
```

```
Aggregate | rows=1 (est 1) loops=1 time=212.597 ms | buffers hit=16129 read=111852
  -> Gather | rows=3 (est 2) loops=1 time=212.564 ms | workers=2 | buffers hit=16129 read=111852
    -> Aggregate | rows=1 (est 1) loops=3 time=197.878 ms | buffers hit=16129 read=111852
      -> Parallel Seq Scan (metric) | filter (((consumerid)::text = 'consumer-010'::text) OR ((correlationid)::text = '00000000-0000-0000-0000-000000000000'::text)) | rows=17180 (est 21948) loops=3 time=196.597 ms | removed by filter=1660326 | buffers hit=16129 read=111852
Planning 0.33 ms, execution 224 ms, I/O read 114 ms
```
</details>

<details><summary>or_latest: SQL and plan</summary>

```sql
SELECT id, date_c, url FROM metric
 WHERE consumerid = 'consumer-010' OR userid = 'user-0002'
 ORDER BY date_c DESC LIMIT 20;
```

```
Limit | rows=20 (est 20) loops=1 time=0.162 ms | buffers hit=49 read=0
  -> Index Scan Backward (metric_date_c) | filter (((consumerid)::text = 'consumer-010'::text) OR ((userid)::text = 'user-0002'::text)) | rows=20 (est 58981) loops=1 time=0.16 ms | removed by filter=1160 | buffers hit=49 read=0
Planning 0.36 ms, execution 0.18 ms
```
</details>

<details><summary>union_latest: SQL and plan</summary>

```sql
SELECT id, date_c, url FROM (
  (SELECT id, date_c, url FROM metric WHERE consumerid = 'consumer-010' ORDER BY date_c DESC LIMIT 20)
  UNION
  (SELECT id, date_c, url FROM metric WHERE userid = 'user-0002' ORDER BY date_c DESC LIMIT 20)
) u ORDER BY date_c DESC LIMIT 20;
```

```
Limit | rows=20 (est 20) loops=1 time=0.123 ms | buffers hit=47 read=0
  -> Sort | rows=20 (est 40) loops=1 time=0.121 ms | sort=quicksort 28kB Memory | buffers hit=47 read=0
    -> Aggregate | rows=40 (est 40) loops=1 time=0.104 ms | buffers hit=44 read=0
      -> Append | rows=40 (est 40) loops=1 time=0.085 ms | buffers hit=44 read=0
        -> Limit | rows=20 (est 20) loops=1 time=0.05 ms | buffers hit=21 read=0
          -> Index Scan Backward (sc_metric_consumer_date) | cond ((consumerid)::text = 'consumer-010'::text) | rows=20 (est 52674) loops=1 time=0.048 ms | buffers hit=21 read=0
        -> Limit | rows=20 (est 20) loops=1 time=0.032 ms | buffers hit=23 read=0
          -> Index Scan Backward (sc_metric_user_date) | cond ((userid)::text = 'user-0002'::text) | rows=20 (est 6375) loops=1 time=0.031 ms | buffers hit=23 read=0
Planning 0.42 ms, execution 0.18 ms
```
</details>

<details><summary>or_latest_rare: SQL and plan</summary>

```sql
SELECT id, date_c, url FROM metric
 WHERE consumerid = 'consumer-036' OR userid = 'user-0077'
 ORDER BY date_c DESC LIMIT 20;
```

```
Limit | rows=20 (est 20) loops=1 time=1.053 ms | buffers hit=781 read=0
  -> Sort | rows=20 (est 459) loops=1 time=1.051 ms | sort=top-N heapsort 27kB Memory | buffers hit=781 read=0
    -> Bitmap Heap Scan (metric) | rows=773 (est 459) loops=1 time=0.889 ms | buffers hit=778 read=0
      -> BitmapOr | rows=0 (est 459) loops=1 time=0.076 ms | buffers hit=8 read=0
        -> Bitmap Index Scan (sc_metric_consumer_date) | cond ((consumerid)::text = 'consumer-036'::text) | rows=465 (est 1) loops=1 time=0.061 ms | buffers hit=5 read=0
        -> Bitmap Index Scan (metric_userid_idx) | cond ((userid)::text = 'user-0077'::text) | rows=308 (est 459) loops=1 time=0.014 ms | buffers hit=3 read=0
Planning 0.36 ms, execution 1.1 ms
```
</details>

<details><summary>union_latest_rare: SQL and plan</summary>

```sql
SELECT id, date_c, url FROM (
  (SELECT id, date_c, url FROM metric WHERE consumerid = 'consumer-036' ORDER BY date_c DESC LIMIT 20)
  UNION
  (SELECT id, date_c, url FROM metric WHERE userid = 'user-0077' ORDER BY date_c DESC LIMIT 20)
) u ORDER BY date_c DESC LIMIT 20;
```

```
Limit | rows=20 (est 20) loops=1 time=0.647 ms | buffers hit=492 read=0
  -> Sort | rows=20 (est 21) loops=1 time=0.646 ms | sort=quicksort 28kB Memory | buffers hit=492 read=0
    -> Aggregate | rows=40 (est 21) loops=1 time=0.63 ms | buffers hit=489 read=0
      -> Append | rows=40 (est 21) loops=1 time=0.611 ms | buffers hit=489 read=0
        -> Limit | rows=20 (est 1) loops=1 time=0.578 ms | buffers hit=466 read=0
          -> Sort | rows=20 (est 1) loops=1 time=0.577 ms | sort=top-N heapsort 27kB Memory | buffers hit=466 read=0
            -> Index Scan (metric_consumerid) | cond ((consumerid)::text = 'consumer-036'::text) | rows=465 (est 1) loops=1 time=0.479 ms | buffers hit=466 read=0
        -> Limit | rows=20 (est 20) loops=1 time=0.031 ms | buffers hit=23 read=0
          -> Index Scan Backward (sc_metric_user_date) | cond ((userid)::text = 'user-0077'::text) | rows=20 (est 459) loops=1 time=0.03 ms | buffers hit=23 read=0
Planning 0.46 ms, execution 0.71 ms
```
</details>

## 06 Implicit type conversion

*Anti-pattern*

> **Common advice:** Comparing a column with a value of another type converts the column on every row and kills index usage.

**Verdict:** Different in PostgreSQL, and mostly safer. Comparing a varchar column with an integer is an error, not a silent conversion, and a quoted '4000000' against a bigint column is typed as bigint and uses the index. The real trap is a numeric value: id = 4000000.0 converts every id to numeric and scans all 5M rows (223 ms vs 0.04 ms, 4,963×). Explicit casts on the column (id::text) do the same. Watch for BigDecimal/numeric parameters from Java.

<table>
<tr><th width="50%">❌ Before: <code>numeric_literal</code><br><sub>id = 4000000.0 (numeric value: the column is converted to numeric)</sub></th><th width="50%">✅ After: <code>int_literal</code><br><sub>id = 4000000 (bigint column, integer value)</sub><br><b>4,963× faster</b></th></tr>
<tr><td valign="top"><b>223 ms</b> &nbsp;·&nbsp; first run 213 ms<br>pages hit 16,096 / read 111,885 &nbsp;·&nbsp; 1 row<pre>SELECT id, date_c, url FROM metric WHERE id = 4000000.0;</pre><pre>Gather
   rows 1 (est 25163), 218.208 ms
  -&gt; Parallel Seq Scan (metric)
     rows 0 (est 10485), 201.721 ms</pre></td><td valign="top"><b>0.04 ms</b> &nbsp;·&nbsp; first run 1.1 ms<br>pages hit 7 / read 0 &nbsp;·&nbsp; 1 row<pre>SELECT id, date_c, url FROM metric WHERE id = 4000000;</pre><pre>Index Scan (metric_pk)
   rows 1 (est 1), 0.016 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `int_literal` | id = 4000000 (bigint column, integer value) | 0.04 ms | 1.1 ms | Index Scan (metric_pk) | 7 / 0 | 1 |
| `string_literal` | id = '4000000' (quoted literal is typed as bigint, index still used) | 0.04 ms | 0.04 ms | Index Scan (metric_pk) | 4 / 0 | 1 |
| `numeric_literal` | id = 4000000.0 (numeric value: the column is converted to numeric) | 223 ms | 213 ms | Parallel Seq Scan (metric) | 16,096 / 111,885 | 1 |
| `cast_column` | id::text = '4000000' (explicit cast on the column) | 213 ms | 213 ms | Parallel Seq Scan (metric) | 16,160 / 111,821 | 1 |

**varchar column compared with an integer: PostgreSQL refuses instead of converting silently**

```
ERROR:  operator does not exist: character varying = integer
LINE 1: SELECT count(*) FROM metric WHERE consumerid = 7;
                                                     ^
HINT:  No operator matches the given name and argument types. You might need to add explicit type casts.
```

<details><summary>int_literal: SQL and plan</summary>

```sql
SELECT id, date_c, url FROM metric WHERE id = 4000000;
```

```
Index Scan (metric_pk) | cond (id = 4000000) | rows=1 (est 1) loops=1 time=0.016 ms | buffers hit=7 read=0
Planning 0.28 ms, execution 0.04 ms
```
</details>

<details><summary>string_literal: SQL and plan</summary>

```sql
SELECT id, date_c, url FROM metric WHERE id = '4000000';
```

```
Index Scan (metric_pk) | cond (id = '4000000'::bigint) | rows=1 (est 1) loops=1 time=0.012 ms | buffers hit=4 read=0
Planning 0.30 ms, execution 0.06 ms
```
</details>

<details><summary>numeric_literal: SQL and plan</summary>

```sql
SELECT id, date_c, url FROM metric WHERE id = 4000000.0;
```

```
Gather | rows=1 (est 25163) loops=1 time=218.208 ms | workers=2 | buffers hit=16096 read=111885
  -> Parallel Seq Scan (metric) | filter ((id)::numeric = 4000000.0) | rows=0 (est 10485) loops=3 time=201.721 ms | removed by filter=1677505 | buffers hit=16096 read=111885
Planning 0.32 ms, execution 230 ms, I/O read 128 ms
```
</details>

<details><summary>cast_column: SQL and plan</summary>

```sql
SELECT id, date_c, url FROM metric WHERE id::text = '4000000';
```

```
Gather | rows=1 (est 25163) loops=1 time=203.506 ms | workers=2 | buffers hit=16160 read=111821
  -> Parallel Seq Scan (metric) | filter ((id)::text = '4000000'::text) | rows=0 (est 10485) loops=3 time=188.96 ms | removed by filter=1677505 | buffers hit=16160 read=111821
Planning 0.34 ms, execution 215 ms, I/O read 113 ms
```
</details>

## 07 Covering index for a frequent query

*Indexing*

> **Common advice:** A covering index holds every column the query needs, so the database never touches the table. Filter columns first, then sort columns, then the selected ones. Costs space and write speed.

**Verdict:** Confirmed, with a trade-off. The covering index (date_c INCLUDE function, version, duration) turned the top-APIs query into an index-only scan: 50 ms to 38 ms (1.3×). Price: 299 MB vs 108 MB for the plain date index, and 10,000 inserts took +8% time. Worth it for a dashboard query that runs constantly, not for every query.

<table>
<tr><th width="50%">❌ Before: <code>date_index</code><br><sub>top 10 APIs of the last 30 days with the existing index on date_c</sub></th><th width="50%">✅ After: <code>covering</code><br><sub>same query, answered from the covering index only</sub><br>≈ same</th></tr>
<tr><td valign="top"><b>50 ms</b> &nbsp;·&nbsp; first run 67 ms<br>pages hit 14,262 / read 0 &nbsp;·&nbsp; 10 rows<pre>SELECT implementedbypartialfunction, implementedinversion, count(*) AS calls, avg(duration) AS avg_ms
  FROM metric WHERE date_c &gt;= localtimestamp - interval '30 days'
 GROUP BY 1, 2 ORDER BY calls DESC LIMIT 10;</pre><pre>Limit
   rows 10 (est 10), 50.627 ms
  -&gt; Sort
     rows 10 (est 1020), 50.626 ms
    -&gt; Aggregate
       rows 136 (est 1020), 50.593 ms
      -&gt; Gather Merge
         rows 407 (est 2040), 50.46 ms
        -&gt; Sort
           rows 136 (est 1020), 44.777 ms
          -&gt; Aggregate
             rows 136 (est 1020), 44.654 ms
            -&gt; Parallel Index Scan (metric_date_c)
               rows 136950 (est 172782), 19.08 ms</pre></td><td valign="top"><b>38 ms</b> &nbsp;·&nbsp; first run 40 ms<br>pages hit 3,274 / read 0 &nbsp;·&nbsp; 10 rows<pre>SELECT implementedbypartialfunction, implementedinversion, count(*) AS calls, avg(duration) AS avg_ms
  FROM metric WHERE date_c &gt;= localtimestamp - interval '30 days'
 GROUP BY 1, 2 ORDER BY calls DESC LIMIT 10;</pre><pre>Limit
   rows 10 (est 10), 36.312 ms
  -&gt; Sort
     rows 10 (est 1020), 36.31 ms
    -&gt; Aggregate
       rows 136 (est 1020), 36.274 ms
      -&gt; Gather Merge
         rows 407 (est 2040), 36.138 ms
        -&gt; Sort
           rows 136 (est 1020), 31.946 ms
          -&gt; Aggregate
             rows 136 (est 1020), 31.829 ms
            -&gt; Parallel Index Only Scan (sc_metric_date_covering)
               rows 136950 (est 171171), 12.811 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `date_index` | top 10 APIs of the last 30 days with the existing index on date_c | 50 ms | 67 ms | Limit → Sort → Aggregate → Parallel Index Scan (metric_date_c) | 14,262 / 0 | 10 |
| `insert_before` | write cost: 10,000 inserts, 6 indexes on metric | 73 ms | 83 ms | ModifyTable (metric) → Subquery Scan → Index Scan (lt_tpl_metric_pkey) | 103,822 / 211 | 0 |
| `covering` | same query, answered from the covering index only | 38 ms | 40 ms | Limit → Sort → Aggregate → Parallel Index Only Scan (sc_metric_date_covering) | 3,274 / 0 | 10 |
| `insert_after` | the same 10,000 inserts with the covering index as a 7th index | 79 ms | 82 ms | ModifyTable (metric) → Subquery Scan → Index Scan (lt_tpl_metric_pkey) | 114,677 / 218 | 0 |

<details><summary>step: covering index: date_c + INCLUDE the grouped and averaged columns (2.06 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_date_covering ON metric (date_c)
  INCLUDE (implementedbypartialfunction, implementedinversion, duration);
VACUUM metric;
```
</details>

**Index sizes: plain date index vs covering index**

```
index          |  size  
-------------------------+--------
 metric_date_c           | 108 MB
 sc_metric_date_covering | 299 MB
(2 rows)
```

<details><summary>date_index: SQL and plan</summary>

```sql
SELECT implementedbypartialfunction, implementedinversion, count(*) AS calls, avg(duration) AS avg_ms
  FROM metric WHERE date_c >= localtimestamp - interval '30 days'
 GROUP BY 1, 2 ORDER BY calls DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=50.627 ms | buffers hit=14262 read=0
  -> Sort | rows=10 (est 1020) loops=1 time=50.626 ms | sort=top-N heapsort 26kB Memory | buffers hit=14262 read=0
    -> Aggregate | rows=136 (est 1020) loops=1 time=50.593 ms | buffers hit=14259 read=0
      -> Gather Merge | rows=407 (est 2040) loops=1 time=50.46 ms | workers=2 | buffers hit=14259 read=0
        -> Sort | rows=136 (est 1020) loops=3 time=44.777 ms | sort=quicksort 42kB Memory | buffers hit=14259 read=0
          -> Aggregate | rows=136 (est 1020) loops=3 time=44.654 ms | buffers hit=14243 read=0
            -> Parallel Index Scan (metric_date_c) | cond (date_c >= (LOCALTIMESTAMP - '30 days'::interval)) | rows=136950 (est 172782) loops=3 time=19.08 ms | buffers hit=14243 read=0
Planning 0.38 ms, execution 51 ms
```
</details>

<details><summary>insert_before: SQL and plan</summary>

```sql
INSERT INTO metric (url, duration, date_c, consumerid, implementedbypartialfunction, implementedinversion, correlationid, httpcode, verb)
SELECT url, duration, localtimestamp, consumerid, implementedbypartialfunction, implementedinversion, gen_random_uuid()::text, httpcode, verb
  FROM lt_tpl_metric WHERE k <= 10000;
```

```
ModifyTable (metric) | rows=0 (est 0) loops=1 time=74.092 ms | buffers hit=103822 read=211
  -> Subquery Scan | rows=10000 (est 9995) loops=1 time=18.17 ms | buffers hit=10348 read=0
    -> Index Scan (lt_tpl_metric_pkey) | cond (k <= 10000) | rows=10000 (est 9995) loops=1 time=14.258 ms | buffers hit=336 read=0
Planning 0.30 ms, execution 74 ms, I/O read 1.7 ms
```
</details>

<details><summary>covering: SQL and plan</summary>

```sql
SELECT implementedbypartialfunction, implementedinversion, count(*) AS calls, avg(duration) AS avg_ms
  FROM metric WHERE date_c >= localtimestamp - interval '30 days'
 GROUP BY 1, 2 ORDER BY calls DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=36.312 ms | buffers hit=3274 read=0
  -> Sort | rows=10 (est 1020) loops=1 time=36.31 ms | sort=top-N heapsort 26kB Memory | buffers hit=3274 read=0
    -> Aggregate | rows=136 (est 1020) loops=1 time=36.274 ms | buffers hit=3271 read=0
      -> Gather Merge | rows=407 (est 2040) loops=1 time=36.138 ms | workers=2 | buffers hit=3271 read=0
        -> Sort | rows=136 (est 1020) loops=3 time=31.946 ms | sort=quicksort 43kB Memory | buffers hit=3271 read=0
          -> Aggregate | rows=136 (est 1020) loops=3 time=31.829 ms | buffers hit=3255 read=0
            -> Parallel Index Only Scan (sc_metric_date_covering) | cond (date_c >= (LOCALTIMESTAMP - '30 days'::interval)) | rows=136950 (est 171171) loops=3 time=12.811 ms | heap fetches=3934 | buffers hit=3255 read=0
Planning 0.38 ms, execution 36 ms
```
</details>

<details><summary>insert_after: SQL and plan</summary>

```sql
INSERT INTO metric (url, duration, date_c, consumerid, implementedbypartialfunction, implementedinversion, correlationid, httpcode, verb)
SELECT url, duration, localtimestamp, consumerid, implementedbypartialfunction, implementedinversion, gen_random_uuid()::text, httpcode, verb
  FROM lt_tpl_metric WHERE k <= 10000;
```

```
ModifyTable (metric) | rows=0 (est 0) loops=1 time=73.909 ms | buffers hit=114677 read=218
  -> Subquery Scan | rows=10000 (est 9995) loops=1 time=16.972 ms | buffers hit=10348 read=0
    -> Index Scan (lt_tpl_metric_pkey) | cond (k <= 10000) | rows=10000 (est 9995) loops=1 time=13.302 ms | buffers hit=336 read=0
Planning 0.27 ms, execution 74 ms, I/O read 2.3 ms
```
</details>

## 08 Partial index for a filtered subset

*Indexing*

> **Common advice:** Index only the rows you query: smaller, fits in memory better, faster, and does not slow down writes of other rows.

**Verdict:** Confirmed. The partial index on error rows is 8.9 MB vs 151 MB for the full (httpcode, date_c) index, 17x smaller, and at least as fast (9.1 ms vs 15 ms; 29 ms without either). The consumer index without NULLs is 13 MB vs 34 MB. Small indexes stay in the 128 MB cache and cost nothing when rows outside the predicate are written.

<table>
<tr><th width="50%">❌ Before: <code>no_index</code><br><sub>errors per day, last 30 days, without either error index</sub></th><th width="50%">✅ After: <code>partial_index</code><br><sub>same with the partial index (only error rows)</sub><br><b>3.2× faster</b></th></tr>
<tr><td valign="top"><b>29 ms</b> &nbsp;·&nbsp; first run 30 ms<br>pages hit 14,244 / read 0 &nbsp;·&nbsp; 31 rows<br><sub>after a session preamble (see details below)</sub><pre>SELECT date_trunc('day', date_c) AS day, count(*) FROM metric
 WHERE httpcode &gt;= 400 AND date_c &gt;= localtimestamp - interval '30 days' GROUP BY 1 ORDER BY 1;</pre><pre>Aggregate
   rows 31 (est 34673), 29.245 ms
  -&gt; Gather Merge
     rows 91 (est 28896), 29.233 ms
    -&gt; Aggregate
       rows 30 (est 14448), 23.787 ms
      -&gt; Sort
         rows 11008 (est 14448), 23.265 ms
        -&gt; Parallel Index Scan (metric_date_c)
           rows 11008 (est 14448), 21.948 ms</pre></td><td valign="top"><b>9.1 ms</b> &nbsp;·&nbsp; first run 9.1 ms<br>pages hit 97 / read 0 &nbsp;·&nbsp; 31 rows<br><sub>after a session preamble (see details below)</sub><pre>SELECT date_trunc('day', date_c) AS day, count(*) FROM metric
 WHERE httpcode &gt;= 400 AND date_c &gt;= localtimestamp - interval '30 days' GROUP BY 1 ORDER BY 1;</pre><pre>Aggregate
   rows 31 (est 34673), 8.995 ms
  -&gt; Sort
     rows 33023 (est 34674), 7.181 ms
    -&gt; Index Only Scan (sc_metric_errors_date)
       rows 33023 (est 34674), 3.787 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `no_index` | errors per day, last 30 days, without either error index | 29 ms | 30 ms | Aggregate → Sort → Parallel Index Scan (metric_date_c) | 14,244 / 0 | 31 |
| `full_index` | same with the full (httpcode, date_c) index | 15 ms | 19 ms | Aggregate → Sort → Index Only Scan (sc_metric_http_date) | 1,350 / 0 | 31 |
| `partial_index` | same with the partial index (only error rows) | 9.1 ms | 9.1 ms | Aggregate → Sort → Index Only Scan (sc_metric_errors_date) | 97 / 0 | 31 |

<details><summary>setup: setup (3.48 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_http_date ON metric (httpcode, date_c);
CREATE INDEX sc_metric_errors_date ON metric (date_c) WHERE httpcode >= 400;
CREATE INDEX sc_metric_consumer_notnull ON metric (consumerid) WHERE consumerid IS NOT NULL;
VACUUM ANALYZE metric;
```
</details>

**Sizes: 8% of calls are errors, 61% have no consumer id**

```
index            |  size   |                 kind                  
----------------------------+---------+---------------------------------------
 metric_consumerid          | 34 MB   | full, includes NULLs
 sc_metric_consumer_notnull | 13 MB   | partial: WHERE consumerid IS NOT NULL
 sc_metric_errors_date      | 8880 kB | partial: WHERE httpcode >= 400
 sc_metric_http_date        | 151 MB  | full (httpcode, date_c)
(4 rows)
```

<details><summary>no_index: SQL and plan</summary>

```sql
DROP INDEX sc_metric_http_date;
DROP INDEX sc_metric_errors_date;
-- @explain
SELECT date_trunc('day', date_c) AS day, count(*) FROM metric
 WHERE httpcode >= 400 AND date_c >= localtimestamp - interval '30 days' GROUP BY 1 ORDER BY 1;
```

```
Aggregate | rows=31 (est 34673) loops=1 time=29.245 ms | buffers hit=14244 read=0
  -> Gather Merge | rows=91 (est 28896) loops=1 time=29.233 ms | workers=2 | buffers hit=14244 read=0
    -> Aggregate | rows=30 (est 14448) loops=3 time=23.787 ms | buffers hit=14244 read=0
      -> Sort | rows=11008 (est 14448) loops=3 time=23.265 ms | sort=quicksort 926kB Memory | buffers hit=14244 read=0
        -> Parallel Index Scan (metric_date_c) | cond (date_c >= (LOCALTIMESTAMP - '30 days'::interval)) | filter (httpcode >= 400) | rows=11008 (est 14448) loops=3 time=21.948 ms | removed by filter=125942 | buffers hit=14230 read=0
Planning 0.31 ms, execution 29 ms
```
</details>

<details><summary>full_index: SQL and plan</summary>

```sql
DROP INDEX sc_metric_errors_date;
-- @explain
SELECT date_trunc('day', date_c) AS day, count(*) FROM metric
 WHERE httpcode >= 400 AND date_c >= localtimestamp - interval '30 days' GROUP BY 1 ORDER BY 1;
```

```
Aggregate | rows=31 (est 34673) loops=1 time=14.708 ms | buffers hit=1350 read=0
  -> Sort | rows=33023 (est 34674) loops=1 time=13.173 ms | sort=quicksort 2914kB Memory | buffers hit=1350 read=0
    -> Index Only Scan (sc_metric_http_date) | cond ((httpcode >= 400) AND (date_c >= (LOCALTIMESTAMP - '30 days'::interval))) | rows=33023 (est 34674) loops=1 time=9.356 ms | heap fetches=0 | buffers hit=1347 read=0
Planning 0.34 ms, execution 15 ms
```
</details>

<details><summary>partial_index: SQL and plan</summary>

```sql
DROP INDEX sc_metric_http_date;
-- @explain
SELECT date_trunc('day', date_c) AS day, count(*) FROM metric
 WHERE httpcode >= 400 AND date_c >= localtimestamp - interval '30 days' GROUP BY 1 ORDER BY 1;
```

```
Aggregate | rows=31 (est 34673) loops=1 time=8.995 ms | buffers hit=97 read=0
  -> Sort | rows=33023 (est 34674) loops=1 time=7.181 ms | sort=quicksort 2914kB Memory | buffers hit=97 read=0
    -> Index Only Scan (sc_metric_errors_date) | cond (date_c >= (LOCALTIMESTAMP - '30 days'::interval)) | rows=33023 (est 34674) loops=1 time=3.787 ms | heap fetches=0 | buffers hit=94 read=0
Planning 0.33 ms, execution 9.1 ms
```
</details>

## 09 OFFSET vs keyset pagination

*Query pattern*

> **Common advice:** OFFSET gets slower the deeper you page, because skipped rows are still read. Keyset pagination ("rows after the last one seen") is equally fast on page 1 and page 1000.

**Verdict:** Confirmed exactly. OFFSET grows with depth: page 1 0.03 ms, page 1,000 3.1 ms, page 50,000 241 ms (1M index entries read and discarded). Keyset stays at 0.04 ms at any depth, 6,515× faster at page 50,000. OBP's /management/metrics pages with offset/limit, so deep pages get slow.

<table>
<tr><th width="50%">❌ Before: <code>offset_page_50000</code><br><sub>page 50,000 (OFFSET 999,980)</sub></th><th width="50%">✅ After: <code>keyset_page_50000</code><br><sub>page 50,000 via WHERE (date_c, id) &lt; last row of page 49,999</sub><br><b>6,515× faster</b></th></tr>
<tr><td valign="top"><b>241 ms</b> &nbsp;·&nbsp; first run 180 ms<br>pages hit 4,030 / read 29,297 &nbsp;·&nbsp; 20 rows<pre>SELECT id, date_c, url, duration FROM metric ORDER BY date_c DESC, id DESC LIMIT 20 OFFSET 999980;</pre><pre>Limit
   rows 20 (est 20), 241.019 ms
  -&gt; Index Scan (sc_metric_date_id)
     rows 1000000 (est 5032517), 214.141 ms</pre></td><td valign="top"><b>0.04 ms</b> &nbsp;·&nbsp; first run 0.04 ms<br>pages hit 4 / read 0 &nbsp;·&nbsp; 20 rows<br><sub>after a session preamble (see details below)</sub><pre>SELECT id, date_c, url, duration FROM metric
 WHERE (date_c, id) &lt; (:'last_date', :last_id) ORDER BY date_c DESC, id DESC LIMIT 20;</pre><pre>Limit
   rows 20 (est 20), 0.012 ms
  -&gt; Index Scan (sc_metric_date_id)
     rows 20 (est 4032504), 0.01 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `offset_page_1` | page 1 of all metrics, 20 per page | 0.03 ms | 0.04 ms | Limit → Index Scan (sc_metric_date_id) | 4 / 0 | 20 |
| `offset_page_1000` | page 1,000 (OFFSET 19,980) | 3.1 ms | 3.5 ms | Limit → Index Scan (sc_metric_date_id) | 664 / 0 | 20 |
| `offset_page_50000` | page 50,000 (OFFSET 999,980) | 241 ms | 180 ms | Limit → Index Scan (sc_metric_date_id) | 4,030 / 29,297 | 20 |
| `keyset_page_1000` | page 1,000 via WHERE (date_c, id) < last row of page 999 | 0.03 ms | 0.04 ms | Limit → Index Scan (sc_metric_date_id) | 4 / 0 | 20 |
| `keyset_page_50000` | page 50,000 via WHERE (date_c, id) < last row of page 49,999 | 0.04 ms | 0.04 ms | Limit → Index Scan (sc_metric_date_id) | 4 / 0 | 20 |

<details><summary>setup: setup (1.28 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_date_id ON metric (date_c DESC, id DESC);
```
</details>

<details><summary>offset_page_1: SQL and plan</summary>

```sql
SELECT id, date_c, url, duration FROM metric ORDER BY date_c DESC, id DESC LIMIT 20 OFFSET 0;
```

```
Limit | rows=20 (est 20) loops=1 time=0.015 ms | buffers hit=4 read=0
  -> Index Scan (sc_metric_date_id) | rows=20 (est 5032517) loops=1 time=0.013 ms | buffers hit=4 read=0
Planning 0.33 ms, execution 0.03 ms
```
</details>

<details><summary>offset_page_1000: SQL and plan</summary>

```sql
SELECT id, date_c, url, duration FROM metric ORDER BY date_c DESC, id DESC LIMIT 20 OFFSET 19980;
```

```
Limit | rows=20 (est 20) loops=1 time=3.085 ms | buffers hit=664 read=0
  -> Index Scan (sc_metric_date_id) | rows=20000 (est 5032517) loops=1 time=2.661 ms | buffers hit=664 read=0
Planning 0.36 ms, execution 3.1 ms
```
</details>

<details><summary>offset_page_50000: SQL and plan</summary>

```sql
SELECT id, date_c, url, duration FROM metric ORDER BY date_c DESC, id DESC LIMIT 20 OFFSET 999980;
```

```
Limit | rows=20 (est 20) loops=1 time=241.019 ms | buffers hit=4030 read=29297
  -> Index Scan (sc_metric_date_id) | rows=1000000 (est 5032517) loops=1 time=214.141 ms | buffers hit=4030 read=29297
Planning 0.50 ms, execution 241 ms, I/O read 59 ms
```
</details>

<details><summary>keyset_page_1000: SQL and plan</summary>

```sql
SELECT date_c AS last_date, id AS last_id FROM metric ORDER BY date_c DESC, id DESC OFFSET 19979 LIMIT 1 \gset
-- @explain
SELECT id, date_c, url, duration FROM metric
 WHERE (date_c, id) < (:'last_date', :last_id) ORDER BY date_c DESC, id DESC LIMIT 20;
```

```
Limit | rows=20 (est 20) loops=1 time=0.011 ms | buffers hit=4 read=0
  -> Index Scan (sc_metric_date_id) | cond (ROW(date_c, id) < ROW('2026-09-20 23:24:09.135856'::timestamp without time zone, 5151394)) | rows=20 (est 5013223) loops=1 time=0.009 ms | buffers hit=4 read=0
Planning 0.20 ms, execution 0.03 ms
```
</details>

<details><summary>keyset_page_50000: SQL and plan</summary>

```sql
SELECT date_c AS last_date, id AS last_id FROM metric ORDER BY date_c DESC, id DESC OFFSET 999979 LIMIT 1 \gset
-- @explain
SELECT id, date_c, url, duration FROM metric
 WHERE (date_c, id) < (:'last_date', :last_id) ORDER BY date_c DESC, id DESC LIMIT 20;
```

```
Limit | rows=20 (est 20) loops=1 time=0.012 ms | buffers hit=4 read=0
  -> Index Scan (sc_metric_date_id) | cond (ROW(date_c, id) < ROW('2026-07-11 10:39:47.843056'::timestamp without time zone, 4171520)) | rows=20 (est 4032504) loops=1 time=0.01 ms | buffers hit=4 read=0
Planning 0.18 ms, execution 0.04 ms
```
</details>

## 10 Row-by-row vs batch: the archive job

*Query pattern*

> **Common advice:** Individual operations in loops are death by a thousand cuts; one set-based statement is often 10-100x faster.

**Verdict:** Confirmed, and confirmed in OBP's code. Moving 10,000 rows one at a time (20,000 statements) took 1.49 s vs 213 ms as one DELETE ... RETURNING + INSERT (7.0×). OBP's MetricsArchiveScheduler does worse: per row it looks the archive row up by metricId twice (dedup in saveMetricsArchive, then a verify) and MetricArchive declares no index on metricId, so every archived row costs two full scans of metricarchive: 1.57 s per row at 15M rows, so one scheduled batch of 10,000 rows would take hours instead of fitting its 10-minute interval. With an index on metricId the same 10 rows took 8.3 ms. It matches the counters in the source OBP database: 1,542 scans of metricarchive for the 766-row run on 2026-08-19. Fix: add Index(metricId) to MetricArchive.dbIndexes.

<table>
<tr><th width="50%">❌ Before: <code>row_by_row</code><br><sub>INSERT + DELETE per row, 20,000 statements</sub></th><th width="50%">✅ After: <code>batch_client</code><br><sub>one statement: DELETE ... RETURNING feeding the INSERT</sub><br><b>7.0× faster</b></th></tr>
<tr><td valign="top"><b>1.49 s</b> <i>client</i> &nbsp;·&nbsp; first run 1.49 s<br><pre>SELECT format('INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid) SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM metric WHERE id = %s', id),
       format('DELETE FROM metric WHERE id = %s', id)
  FROM (SELECT id FROM metric ORDER BY date_c LIMIT 10000) x \gexec</pre></td><td valign="top"><b>213 ms</b> <i>client</i> &nbsp;·&nbsp; first run 246 ms<br><pre>WITH moved AS (
  DELETE FROM metric WHERE id IN (SELECT id FROM metric ORDER BY date_c LIMIT 10000) RETURNING *)
INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid)
SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM moved;</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `row_by_row` | INSERT + DELETE per row, 20,000 statements | 1.49 s *client* | 1.49 s | - | - | - |
| `batch_client` | one statement: DELETE ... RETURNING feeding the INSERT | 213 ms *client* | 246 ms | - | - | - |
| `batch_server` | server-side plan of the batch statement | 205 ms | 200 ms | ModifyTable (metricarchive) → ModifyTable (metric) → Nested Loop → Aggregate → Subquery Scan → Limit → … | 305,058 / 0 | 0 |
| `row_by_row_checked` | 10 rows the OBP way: 2 lookups by metricid (no index) + INSERT + DELETE per row | 15.73 s *client* | 15.73 s | - | - | - |
| `row_by_row_checked_indexed` | the same 10 rows the OBP way, with the index | 8.3 ms *client* | 11 ms | - | - | - |

<details><summary>step: index on metricarchive.metricid (4.67 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_archive_metricid ON metricarchive (metricid);
```
</details>

<details><summary>row_by_row: SQL</summary>

```sql
SELECT format('INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid) SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM metric WHERE id = %s', id),
       format('DELETE FROM metric WHERE id = %s', id)
  FROM (SELECT id FROM metric ORDER BY date_c LIMIT 10000) x \gexec
```
</details>

<details><summary>batch_client: SQL</summary>

```sql
WITH moved AS (
  DELETE FROM metric WHERE id IN (SELECT id FROM metric ORDER BY date_c LIMIT 10000) RETURNING *)
INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid)
SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM moved;
```
</details>

<details><summary>batch_server: SQL and plan</summary>

```sql
WITH moved AS (
  DELETE FROM metric WHERE id IN (SELECT id FROM metric ORDER BY date_c LIMIT 10000) RETURNING *)
INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid)
SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM moved;

-- OBP's MetricsArchiveScheduler (obp-api/src/main/scala/code/scheduler/MetricsArchiveScheduler.scala) per row:
-- saveMetricsArchive() looks the row up by metricId (dedup), inserts it, the scheduler looks it up by metricId
-- again (verify), then deletes the source row. MetricArchive declares no index on metricId.
```

```
ModifyTable (metricarchive) | rows=0 (est 0) loops=1 time=194.901 ms | buffers hit=305058 read=0
  -> ModifyTable (metric) | rows=10000 (est 10000) loops=1 time=34.805 ms | buffers hit=68192 read=0
    -> Nested Loop | rows=10000 (est 10000) loops=1 time=26.766 ms | buffers hit=48192 read=0
      -> Aggregate | rows=10000 (est 10000) loops=1 time=10.653 ms | buffers hit=8192 read=0
        -> Subquery Scan | rows=10000 (est 10000) loops=1 time=5.728 ms | buffers hit=8192 read=0
          -> Limit | rows=10000 (est 10000) loops=1 time=4.441 ms | buffers hit=8192 read=0
            -> Index Scan (metric_date_c) | rows=10000 (est 5032517) loops=1 time=3.978 ms | buffers hit=8192 read=0
      -> Index Scan (metric_pk) | cond (id = "ANY_subquery".id) | rows=1 (est 1) loops=10000 time=0.001 ms | buffers hit=40000 read=0
  -> CTE Scan | rows=10000 (est 10000) loops=1 time=46.81 ms | buffers hit=78204 read=0
Planning 0.52 ms, execution 195 ms
```
</details>

<details><summary>row_by_row_checked: SQL</summary>

```sql
SELECT format('SELECT * FROM metricarchive WHERE metricid = %s', id),
       format('INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid) SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM metric WHERE id = %s', id),
       format('SELECT * FROM metricarchive WHERE metricid = %s', id),
       format('DELETE FROM metric WHERE id = %s', id)
  FROM (SELECT id FROM metric ORDER BY date_c LIMIT 10) x \gexec
```
</details>

<details><summary>row_by_row_checked_indexed: SQL</summary>

```sql
SELECT format('SELECT * FROM metricarchive WHERE metricid = %s', id),
       format('INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid) SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM metric WHERE id = %s', id),
       format('SELECT * FROM metricarchive WHERE metricid = %s', id),
       format('DELETE FROM metric WHERE id = %s', id)
  FROM (SELECT id FROM metric ORDER BY date_c LIMIT 10) x \gexec
```
</details>

## 11 Materialized view for dashboard aggregations

*Query pattern*

> **Common advice:** Pre-compute expensive aggregations that can be slightly stale; queries read the result instantly. Refresh periodically, CONCURRENTLY to keep readers working.

**Verdict:** Confirmed. A daily materialized view (69,620 rows, 11 MB, built from 5M rows / 1.4 GB) answers the 365-day top-APIs query in 30 ms instead of 663 ms (22×) and the 7-day one 26× faster. A full REFRESH takes 2.93 s (4.00 s CONCURRENTLY, which does not block readers), so refreshing every few minutes is cheap.

<table>
<tr><th width="50%">❌ Before: <code>raw_365</code><br><sub>top 10 APIs over a year from metric</sub></th><th width="50%">✅ After: <code>mv_365</code><br><sub>same from the materialized view</sub><br><b>22× faster</b></th></tr>
<tr><td valign="top"><b>663 ms</b> &nbsp;·&nbsp; first run 685 ms<br>pages hit 6,772 / read 121,228 &nbsp;·&nbsp; 10 rows<pre>SELECT implementedbypartialfunction, count(*) AS calls, sum(duration) / count(*) AS avg_ms
  FROM metric WHERE date_c &gt;= current_date - 365 GROUP BY 1 ORDER BY calls DESC LIMIT 10;</pre><pre>Limit
   rows 10 (est 10), 837.706 ms
  -&gt; Sort
     rows 10 (est 81), 829.716 ms
    -&gt; Aggregate
       rows 92 (est 81), 829.659 ms
      -&gt; Gather Merge
         rows 276 (est 162), 829.475 ms
        -&gt; Sort
           rows 92 (est 81), 810.239 ms
          -&gt; Aggregate
             rows 92 (est 81), 810.086 ms
            -&gt; Parallel Seq Scan (metric)
               rows 1676416 (est 2077281), 386.953 ms</pre></td><td valign="top"><b>30 ms</b> &nbsp;·&nbsp; first run 36 ms<br>pages hit 797 / read 0 &nbsp;·&nbsp; 10 rows<pre>SELECT fn, sum(calls) AS calls, sum(total_duration) / sum(calls) AS avg_ms
  FROM sc_metric_daily WHERE day &gt;= current_date - 365 GROUP BY 1 ORDER BY calls DESC LIMIT 10;</pre><pre>Limit
   rows 10 (est 10), 28.068 ms
  -&gt; Sort
     rows 10 (est 92), 28.065 ms
    -&gt; Aggregate
       rows 92 (est 92), 27.982 ms
      -&gt; Seq Scan (sc_metric_daily)
         rows 69389 (est 69155), 9.742 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `raw_7` | top 10 APIs over 7 days from metric | 18 ms | 20 ms | Limit → Sort → Aggregate → Parallel Index Scan (metric_date_c) | 3,546 / 0 | 10 |
| `mv_7` | same from the materialized view | 0.69 ms | 0.75 ms | Limit → Sort → Aggregate → Bitmap Heap Scan (sc_metric_daily) → Bitmap Index Scan (sc_metric_daily_key) | 35 / 0 | 10 |
| `raw_365` | top 10 APIs over a year from metric | 663 ms | 685 ms | Limit → Sort → Aggregate → Parallel Seq Scan (metric) | 6,772 / 121,228 | 10 |
| `mv_365` | same from the materialized view | 30 ms | 36 ms | Limit → Sort → Aggregate → Seq Scan (sc_metric_daily) | 797 / 0 | 10 |
| `refresh` | REFRESH MATERIALIZED VIEW (blocks readers while it runs) | 2.93 s *client* | 2.93 s | - | - | - |
| `refresh_concurrently` | REFRESH ... CONCURRENTLY (readers keep working, slower) | 4.00 s *client* | 4.00 s | - | - | - |

<details><summary>setup: setup (3.13 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
DROP MATERIALIZED VIEW IF EXISTS sc_metric_daily;
CREATE MATERIALIZED VIEW sc_metric_daily AS
SELECT date_c::date AS day,
       coalesce(implementedbypartialfunction, '') AS fn,
       coalesce(implementedinversion, '') AS version,
       coalesce(consumerid, '') AS consumerid,
       count(*) AS calls, sum(duration) AS total_duration,
       count(*) FILTER (WHERE httpcode >= 400) AS errors
  FROM metric GROUP BY 1, 2, 3, 4;
CREATE UNIQUE INDEX sc_metric_daily_key ON sc_metric_daily (day, fn, version, consumerid);
ANALYZE sc_metric_daily;
```
</details>

**Materialized view: rows and size vs the metric table**

```
mv_rows | mv_size | metric_rows | metric_size 
---------+---------+-------------+-------------
   69598 | 10 MB   |     5031353 | 1355 MB
(1 row)
```

<details><summary>raw_7: SQL and plan</summary>

```sql
SELECT implementedbypartialfunction, count(*) AS calls, sum(duration) / count(*) AS avg_ms
  FROM metric WHERE date_c >= current_date - 7 GROUP BY 1 ORDER BY calls DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=17.06 ms | buffers hit=3546 read=0
  -> Sort | rows=10 (est 81) loops=1 time=17.058 ms | sort=top-N heapsort 26kB Memory | buffers hit=3546 read=0
    -> Aggregate | rows=92 (est 81) loops=1 time=17.03 ms | buffers hit=3543 read=0
      -> Gather Merge | rows=264 (est 162) loops=1 time=16.911 ms | workers=2 | buffers hit=3543 read=0
        -> Sort | rows=88 (est 81) loops=3 time=12.241 ms | sort=quicksort 34kB Memory | buffers hit=3543 read=0
          -> Aggregate | rows=88 (est 81) loops=3 time=12.148 ms | buffers hit=3527 read=0
            -> Parallel Index Scan (metric_date_c) | cond (date_c >= (CURRENT_DATE - 7)) | rows=33943 (est 42618) loops=3 time=6.094 ms | buffers hit=3527 read=0
Planning 0.48 ms, execution 17 ms
```
</details>

<details><summary>mv_7: SQL and plan</summary>

```sql
SELECT fn, sum(calls) AS calls, sum(total_duration) / sum(calls) AS avg_ms
  FROM sc_metric_daily WHERE day >= current_date - 7 GROUP BY 1 ORDER BY calls DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=0.603 ms | buffers hit=35 read=0
  -> Sort | rows=10 (est 92) loops=1 time=0.602 ms | sort=top-N heapsort 26kB Memory | buffers hit=35 read=0
    -> Aggregate | rows=92 (est 92) loops=1 time=0.566 ms | buffers hit=32 read=0
      -> Bitmap Heap Scan (sc_metric_daily) | rows=1484 (est 1478) loops=1 time=0.173 ms | buffers hit=32 read=0
        -> Bitmap Index Scan (sc_metric_daily_key) | cond (day >= (CURRENT_DATE - 7)) | rows=1484 (est 1478) loops=1 time=0.052 ms | buffers hit=14 read=0
Planning 0.31 ms, execution 0.67 ms
```
</details>

<details><summary>raw_365: SQL and plan</summary>

```sql
SELECT implementedbypartialfunction, count(*) AS calls, sum(duration) / count(*) AS avg_ms
  FROM metric WHERE date_c >= current_date - 365 GROUP BY 1 ORDER BY calls DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=837.706 ms | buffers hit=6772 read=121228
  -> Sort | rows=10 (est 81) loops=1 time=829.716 ms | sort=top-N heapsort 26kB Memory | buffers hit=6772 read=121228
    -> Aggregate | rows=92 (est 81) loops=1 time=829.659 ms | buffers hit=6769 read=121228
      -> Gather Merge | rows=276 (est 162) loops=1 time=829.475 ms | workers=2 | buffers hit=6769 read=121228
        -> Sort | rows=92 (est 81) loops=3 time=810.239 ms | sort=quicksort 35kB Memory | buffers hit=6769 read=121228
          -> Aggregate | rows=92 (est 81) loops=3 time=810.086 ms | buffers hit=6753 read=121228
            -> Parallel Seq Scan (metric) | filter (date_c >= (CURRENT_DATE - 365)) | rows=1676416 (est 2077281) loops=3 time=386.953 ms | removed by filter=1090 | buffers hit=6753 read=121228
Planning 0.52 ms, execution 853 ms, I/O read 285 ms
```
</details>

<details><summary>mv_365: SQL and plan</summary>

```sql
SELECT fn, sum(calls) AS calls, sum(total_duration) / sum(calls) AS avg_ms
  FROM sc_metric_daily WHERE day >= current_date - 365 GROUP BY 1 ORDER BY calls DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=28.068 ms | buffers hit=797 read=0
  -> Sort | rows=10 (est 92) loops=1 time=28.065 ms | sort=top-N heapsort 26kB Memory | buffers hit=797 read=0
    -> Aggregate | rows=92 (est 92) loops=1 time=27.982 ms | buffers hit=794 read=0
      -> Seq Scan (sc_metric_daily) | filter (day >= (CURRENT_DATE - 365)) | rows=69389 (est 69155) loops=1 time=9.742 ms | removed by filter=209 | buffers hit=794 read=0
Planning 0.98 ms, execution 28 ms
```
</details>

<details><summary>refresh: SQL</summary>

```sql
REFRESH MATERIALIZED VIEW sc_metric_daily;
```
</details>

<details><summary>refresh_concurrently: SQL</summary>

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY sc_metric_daily;
```
</details>

## 12 EXPLAIN BUFFERS: cache vs disk

*PostgreSQL feature*

> **Common advice:** "shared hit" is data found in cache, "shared read" came from disk. If most pages are read, the working set does not fit in memory. A query served from cache can be 100x faster than one hitting disk.

**Verdict:** Confirmed, with nuance. The small query (7.5k pages) read everything on its first run (28 ms), then found all pages in the 128 MB cache (9.5 ms). The large one needs 69.5k pages (550 MB): it read them on every run (254 ms) and pushed everything else out of shared_buffers. Those reads mostly came from the OS page cache (16 GB RAM); from the disk itself they would be slower. shared_buffers is at the 128 MB default: raising it (e.g. 4 GB) is the cheapest win on this machine.

<table>
<tr><th width="50%">A: <code>small_working_set</code><br><sub>one archive URL, 7.5k rows spread over 3 years (~7.5k pages = 60 MB, fits in 128 MB)</sub></th><th width="50%">B: <code>large_working_set</code><br><sub>another URL, 72k rows (~70k pages = 550 MB, does not fit)</sub></th></tr>
<tr><td valign="top"><b>9.5 ms</b> &nbsp;·&nbsp; first run 28 ms<br>pages hit 6,571 / read 0 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM metricarchive WHERE url = '/obp/v5.1.0/management/metrics?offset=2&amp;limit=1';</pre><pre>Aggregate
   rows 1 (est 1), 9.399 ms
  -&gt; Bitmap Heap Scan (metricarchive)
     rows 7575 (est 2661), 8.786 ms
    -&gt; Bitmap Index Scan (metricarchive_url)
       rows 7575 (est 2661), 0.625 ms</pre></td><td valign="top"><b>254 ms</b> &nbsp;·&nbsp; first run 264 ms<br>pages hit 0 / read 59,484 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM metricarchive WHERE url = '/berlin-group/v1.3/consents';</pre><pre>Aggregate
   rows 1 (est 1), 315.198 ms
  -&gt; Bitmap Heap Scan (metricarchive)
     rows 71766 (est 65575), 299.121 ms
    -&gt; Bitmap Index Scan (metricarchive_url)
       rows 72494 (est 65575), 11.771 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `small_working_set` | one archive URL, 7.5k rows spread over 3 years (~7.5k pages = 60 MB, fits in 128 MB) | 9.5 ms | 28 ms | Aggregate → Bitmap Heap Scan (metricarchive) → Bitmap Index Scan (metricarchive_url) | 6,571 / 0 | 1 |
| `large_working_set` | another URL, 72k rows (~70k pages = 550 MB, does not fit) | 254 ms | 264 ms | Aggregate → Bitmap Heap Scan (metricarchive) → Bitmap Index Scan (metricarchive_url) | 0 / 59,484 | 1 |

**shared_buffers and what occupies it right now (pg_buffercache)**

```
shared_buffers 
----------------
 128MB
(1 row)

       relname        | buffers |  size   
----------------------+---------+---------
 metric               |    7079 | 55 MB
 metricarchive        |    4748 | 37 MB
 metricarchive_pk     |     360 | 2880 kB
 metric_date_c        |     312 | 2496 kB
 metricarchive_date_c |     286 | 2288 kB
 metricarchive_url    |     255 | 2040 kB
(6 rows)
```

**shared_buffers afterwards: the large query pushed other pages out**

```
relname             | buffers |  size  
---------------------------------+---------+--------
 metricarchive                   |   16256 | 127 MB
 pg_proc                         |       9 | 72 kB
 pg_proc_oid_index               |       7 | 56 kB
 pg_class                        |       6 | 48 kB
 pg_attribute_relid_attnum_index |       5 | 40 kB
 pg_amop                         |       5 | 40 kB
(6 rows)
```

<details><summary>small_working_set: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metricarchive WHERE url = '/obp/v5.1.0/management/metrics?offset=2&limit=1';
```

```
Aggregate | rows=1 (est 1) loops=1 time=9.399 ms | buffers hit=6571 read=0
  -> Bitmap Heap Scan (metricarchive) | rows=7575 (est 2661) loops=1 time=8.786 ms | buffers hit=6571 read=0
    -> Bitmap Index Scan (metricarchive_url) | cond ((url)::text = '/obp/v5.1.0/management/metrics?offset=2&limit=1'::text) | rows=7575 (est 2661) loops=1 time=0.625 ms | buffers hit=10 read=0
Planning 0.46 ms, execution 9.5 ms
```
</details>

<details><summary>large_working_set: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metricarchive WHERE url = '/berlin-group/v1.3/consents';
```

```
Aggregate | rows=1 (est 1) loops=1 time=315.198 ms | buffers hit=0 read=59484
  -> Bitmap Heap Scan (metricarchive) | rows=71766 (est 65575) loops=1 time=299.121 ms | buffers hit=0 read=59484
    -> Bitmap Index Scan (metricarchive_url) | cond ((url)::text = '/berlin-group/v1.3/consents'::text) | rows=72494 (est 65575) loops=1 time=11.771 ms | buffers hit=0 read=67
Planning 1.4 ms, execution 341 ms, I/O read 168 ms
```
</details>

## 13 Expression index

*Indexing*

> **Common advice:** Index the result of a function so queries filtering on that expression can use an index.

**Verdict:** Confirmed. split_part(url, '/', 3) = 'v4.0.0' scanned all 5M rows (366 ms); with a 33 MB expression index it took 3.5 ms (104×). Run ANALYZE after creating it so the planner gets statistics for the expression.

<table>
<tr><th width="50%">❌ Before: <code>function_no_index</code><br><sub>calls to a rare API version, split_part(url, '/', 3) = 'v4.0.0'</sub></th><th width="50%">✅ After: <code>expression_index</code><br><sub>same query with the expression index</sub><br><b>104× faster</b></th></tr>
<tr><td valign="top"><b>366 ms</b> &nbsp;·&nbsp; first run 304 ms<br>pages hit 384 / read 127,597 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM metric WHERE split_part(url, '/', 3) = 'v4.0.0';</pre><pre>Aggregate
   rows 1 (est 1), 465.788 ms
  -&gt; Gather
     rows 3 (est 2), 465.741 ms
    -&gt; Aggregate
       rows 1 (est 1), 436.877 ms
      -&gt; Parallel Seq Scan (metric)
         rows 1135 (est 10482), 436.304 ms</pre></td><td valign="top"><b>3.5 ms</b> &nbsp;·&nbsp; first run 12 ms<br>pages hit 3,399 / read 0 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM metric WHERE split_part(url, '/', 3) = 'v4.0.0';</pre><pre>Aggregate
   rows 1 (est 1), 3.299 ms
  -&gt; Index Scan (sc_metric_api_version)
     rows 3404 (est 2348), 3.029 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `function_no_index` | calls to a rare API version, split_part(url, '/', 3) = 'v4.0.0' | 366 ms | 304 ms | Aggregate → Parallel Seq Scan (metric) | 384 / 127,597 | 1 |
| `expression_index` | same query with the expression index | 3.5 ms | 12 ms | Aggregate → Index Scan (sc_metric_api_version) | 3,399 / 0 | 1 |

<details><summary>step: expression index + ANALYZE (expression indexes get their own statistics) (2.57 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_api_version ON metric ((split_part(url, '/', 3)));
ANALYZE metric;
```
</details>

**Index size**

```
expression_index_size 
-----------------------
 33 MB
(1 row)
```

<details><summary>function_no_index: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric WHERE split_part(url, '/', 3) = 'v4.0.0';
```

```
Aggregate | rows=1 (est 1) loops=1 time=465.788 ms | buffers hit=384 read=127597
  -> Gather | rows=3 (est 2) loops=1 time=465.741 ms | workers=2 | buffers hit=384 read=127597
    -> Aggregate | rows=1 (est 1) loops=3 time=436.877 ms | buffers hit=384 read=127597
      -> Parallel Seq Scan (metric) | filter (split_part((url)::text, '/'::text, 3) = 'v4.0.0'::text) | rows=1135 (est 10482) loops=3 time=436.304 ms | removed by filter=1676371 | buffers hit=384 read=127597
Planning 0.39 ms, execution 483 ms, I/O read 240 ms
```
</details>

<details><summary>expression_index: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric WHERE split_part(url, '/', 3) = 'v4.0.0';
```

```
Aggregate | rows=1 (est 1) loops=1 time=3.299 ms | buffers hit=3399 read=0
  -> Index Scan (sc_metric_api_version) | cond (split_part((url)::text, '/'::text, 3) = 'v4.0.0'::text) | rows=3404 (est 2348) loops=1 time=3.029 ms | buffers hit=3399 read=0
Planning 0.39 ms, execution 3.4 ms
```
</details>

## 14 Parallel query

*PostgreSQL feature*

> **Common advice:** PostgreSQL can split large scans and aggregations across CPU cores (Parallel Seq Scan, Parallel Aggregate).

**Verdict:** Confirmed, with diminishing returns. Aggregating 15M archive rows took 3.83 s on one core, 1.99 s with 2 workers (the default), 1.88 s with 4 and 1.61 s with 6: each extra worker helps less, because reading 3.5 GB becomes the limit, not CPU. max_parallel_workers_per_gather = 4 on this 4-core / 8-thread machine helps big reports.

<table>
<tr><th width="50%">❌ Before: <code>workers_0</code><br><sub>max_parallel_workers_per_gather = 0 (one core)</sub></th><th width="50%">✅ After: <code>workers_4</code><br><sub>= 4</sub><br><b>2.0× faster</b></th></tr>
<tr><td valign="top"><b>3.83 s</b> &nbsp;·&nbsp; first run 3.83 s<br>pages hit 12,079 / read 441,278 &nbsp;·&nbsp; 10 rows<br><sub>after a session preamble (see details below)</sub><pre>SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;</pre><pre>Limit
   rows 10 (est 10), 3941.202 ms
  -&gt; Sort
     rows 10 (est 98), 3843.59 ms
    -&gt; Aggregate
       rows 126 (est 98), 3843.524 ms
      -&gt; Seq Scan (metricarchive)
         rows 15137962 (est 15017085), 1607.066 ms</pre></td><td valign="top"><b>1.88 s</b> &nbsp;·&nbsp; first run 1.94 s<br>pages hit 12,633 / read 440,756 &nbsp;·&nbsp; 10 rows<br><sub>after a session preamble (see details below)</sub><pre>SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;</pre><pre>Limit
   rows 10 (est 10), 2142.935 ms
  -&gt; Sort
     rows 10 (est 98), 1972.459 ms
    -&gt; Aggregate
       rows 126 (est 98), 1972.347 ms
      -&gt; Gather Merge
         rows 630 (est 392), 1971.862 ms
        -&gt; Sort
           rows 126 (est 98), 1937.083 ms
          -&gt; Aggregate
             rows 126 (est 98), 1936.793 ms
            -&gt; Parallel Seq Scan (metricarchive)
               rows 3027592 (est 3754271), 642.805 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `workers_0` | max_parallel_workers_per_gather = 0 (one core) | 3.83 s | 3.83 s | Limit → Sort → Aggregate → Seq Scan (metricarchive) | 12,079 / 441,278 | 10 |
| `workers_2` | = 2 (the default) | 1.99 s | 2.00 s | Limit → Sort → Aggregate → Parallel Seq Scan (metricarchive) | 12,322 / 441,051 | 10 |
| `workers_4` | = 4 | 1.88 s | 1.94 s | Limit → Sort → Aggregate → Parallel Seq Scan (metricarchive) | 12,633 / 440,756 | 10 |
| `workers_6` | = 6 | 1.61 s | 2.28 s | Limit → Sort → Aggregate → Parallel Seq Scan (metricarchive) | 13,258 / 440,147 | 10 |

<details><summary>workers_0: SQL and plan</summary>

```sql
SET max_parallel_workers_per_gather = 0;
-- @explain
SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=3941.202 ms | buffers hit=12079 read=441278
  -> Sort | rows=10 (est 98) loops=1 time=3843.59 ms | sort=top-N heapsort 26kB Memory | buffers hit=12079 read=441278
    -> Aggregate | rows=126 (est 98) loops=1 time=3843.524 ms | buffers hit=12076 read=441278
      -> Seq Scan (metricarchive) | rows=15137962 (est 15017085) loops=1 time=1607.066 ms | buffers hit=12076 read=441278
Planning 0.36 ms, execution 3.95 s, I/O read 644 ms
```
</details>

<details><summary>workers_2: SQL and plan</summary>

```sql
SET max_parallel_workers_per_gather = 2;
-- @explain
SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=1924.832 ms | buffers hit=12322 read=441051
  -> Sort | rows=10 (est 98) loops=1 time=1749.841 ms | sort=top-N heapsort 26kB Memory | buffers hit=12322 read=441051
    -> Aggregate | rows=126 (est 98) loops=1 time=1749.762 ms | buffers hit=12319 read=441051
      -> Gather Merge | rows=378 (est 196) loops=1 time=1749.539 ms | workers=2 | buffers hit=12319 read=441051
        -> Sort | rows=126 (est 98) loops=3 time=1727.475 ms | sort=quicksort 40kB Memory | buffers hit=12319 read=441051
          -> Aggregate | rows=126 (est 98) loops=3 time=1727.294 ms | buffers hit=12303 read=441051
            -> Parallel Seq Scan (metricarchive) | rows=5045987 (est 6257119) loops=3 time=643.918 ms | buffers hit=12303 read=441051
Planning 0.51 ms, execution 1.95 s, I/O read 670 ms
```
</details>

<details><summary>workers_4: SQL and plan</summary>

```sql
SET max_parallel_workers_per_gather = 4;
-- @explain
SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=2142.935 ms | buffers hit=12633 read=440756
  -> Sort | rows=10 (est 98) loops=1 time=1972.459 ms | sort=top-N heapsort 26kB Memory | buffers hit=12633 read=440756
    -> Aggregate | rows=126 (est 98) loops=1 time=1972.347 ms | buffers hit=12630 read=440756
      -> Gather Merge | rows=630 (est 392) loops=1 time=1971.862 ms | workers=4 | buffers hit=12630 read=440756
        -> Sort | rows=126 (est 98) loops=5 time=1937.083 ms | sort=quicksort 40kB Memory | buffers hit=12630 read=440756
          -> Aggregate | rows=126 (est 98) loops=5 time=1936.793 ms | buffers hit=12598 read=440756
            -> Parallel Seq Scan (metricarchive) | rows=3027592 (est 3754271) loops=5 time=642.805 ms | buffers hit=12598 read=440756
Planning 0.52 ms, execution 2.16 s, I/O read 953 ms
```
</details>

<details><summary>workers_6: SQL and plan</summary>

```sql
SET max_parallel_workers_per_gather = 6;
-- @explain
SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

```
Limit | rows=10 (est 10) loops=1 time=1460.795 ms | buffers hit=13258 read=440147
  -> Sort | rows=10 (est 98) loops=1 time=1453.29 ms | sort=top-N heapsort 26kB Memory | buffers hit=13258 read=440147
    -> Aggregate | rows=126 (est 98) loops=1 time=1453.21 ms | buffers hit=13255 read=440147
      -> Gather Merge | rows=882 (est 588) loops=1 time=1452.668 ms | workers=6 | buffers hit=13255 read=440147
        -> Sort | rows=126 (est 98) loops=7 time=1424.445 ms | sort=quicksort 40kB Memory | buffers hit=13255 read=440147
          -> Aggregate | rows=126 (est 98) loops=7 time=1424.19 ms | buffers hit=13207 read=440147
            -> Parallel Seq Scan (metricarchive) | rows=2162566 (est 2502848) loops=7 time=477.81 ms | buffers hit=13207 read=440147
Planning 0.51 ms, execution 1.48 s, I/O read 963 ms
```
</details>

## 15 Optimizer hints (MySQL) vs the PostgreSQL planner

*Planner (MySQL-style hints)*

> **Common advice:** Force index usage or join order when the optimizer makes a bad choice; use sparingly.

**Verdict:** PostgreSQL has no hints, and here it did not need them. The planner's choice (0.86 ms) beat the alternatives it had rejected: bitmap scan + sort 32 ms, full scan 242 ms. The enable_* switches are an experiment tool to see those alternatives, not a production fix; when the planner picks badly, fix statistics (demo 01) or indexes first. The pg_hint_plan extension exists if hints are really needed.

<table>
<tr><th width="50%">❌ Before: <code>seqscan_only</code><br><sub>all index access off: the plan a missing index would give</sub></th><th width="50%">✅ After: <code>planner_choice</code><br><sub>the metrics list query, plan chosen by the planner</sub><br><b>281× faster</b></th></tr>
<tr><td valign="top"><b>242 ms</b> &nbsp;·&nbsp; first run 281 ms<br>pages hit 4,133 / read 123,922 &nbsp;·&nbsp; 50 rows<br><sub>after a session preamble (see details below)</sub><pre>SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c &gt;= localtimestamp - interval '30 days' ORDER BY date_c DESC LIMIT 50;</pre><pre>Limit
   rows 50 (est 50), 219.707 ms
  -&gt; Gather Merge
     rows 50 (est 3880), 214.618 ms
    -&gt; Sort
       rows 41 (est 1940), 199.473 ms
      -&gt; Parallel Seq Scan (metric)
         rows 1402 (est 1940), 199.094 ms</pre></td><td valign="top"><b>0.86 ms</b> &nbsp;·&nbsp; first run 1.4 ms<br>pages hit 189 / read 0 &nbsp;·&nbsp; 50 rows<pre>SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c &gt;= localtimestamp - interval '30 days' ORDER BY date_c DESC LIMIT 50;</pre><pre>Limit
   rows 50 (est 50), 0.79 ms
  -&gt; Index Scan Backward (metric_date_c)
     rows 50 (est 4657), 0.785 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `planner_choice` | the metrics list query, plan chosen by the planner | 0.86 ms | 1.4 ms | Limit → Index Scan Backward (metric_date_c) | 189 / 0 | 50 |
| `no_index_scan` | enable_indexscan = off (planner falls back to a bitmap scan on consumerid + sort) | 32 ms | 44 ms | Limit → Sort → Bitmap Heap Scan (metric) → BitmapAnd → Bitmap Index Scan (metric_consumerid) → Bitmap Index Scan (metric_date_c) | 4,762 / 0 | 50 |
| `seqscan_only` | all index access off: the plan a missing index would give | 242 ms | 281 ms | Limit → Sort → Parallel Seq Scan (metric) | 4,133 / 123,922 | 50 |

<details><summary>planner_choice: SQL and plan</summary>

```sql
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC LIMIT 50;
```

```
Limit | rows=50 (est 50) loops=1 time=0.79 ms | buffers hit=189 read=0
  -> Index Scan Backward (metric_date_c) | cond (date_c >= (LOCALTIMESTAMP - '30 days'::interval)) | filter ((consumerid)::text = 'consumer-010'::text) | rows=50 (est 4657) loops=1 time=0.785 ms | removed by filter=5088 | buffers hit=189 read=0
Planning 0.43 ms, execution 0.81 ms
```
</details>

<details><summary>no_index_scan: SQL and plan</summary>

```sql
SET enable_indexscan = off;
-- @explain
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC LIMIT 50;
```

```
Limit | rows=50 (est 50) loops=1 time=31.535 ms | buffers hit=4762 read=0
  -> Sort | rows=50 (est 4657) loops=1 time=31.531 ms | sort=top-N heapsort 39kB Memory | buffers hit=4762 read=0
    -> Bitmap Heap Scan (metric) | rows=4207 (est 4657) loops=1 time=30.562 ms | buffers hit=4759 read=0
      -> BitmapAnd | rows=0 (est 4657) loops=1 time=24.65 ms | buffers hit=1175 read=0
        -> Bitmap Index Scan (metric_consumerid) | cond ((consumerid)::text = 'consumer-010'::text) | rows=51539 (est 56895) loops=1 time=8.503 ms | buffers hit=48 read=0
        -> Bitmap Index Scan (metric_date_c) | cond (date_c >= (LOCALTIMESTAMP - '30 days'::interval)) | rows=410835 (est 412143) loops=1 time=13.259 ms | buffers hit=1127 read=0
Planning 0.39 ms, execution 32 ms
```
</details>

<details><summary>seqscan_only: SQL and plan</summary>

```sql
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_indexonlyscan = off;
-- @explain
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC LIMIT 50;
```

```
Limit | rows=50 (est 50) loops=1 time=219.707 ms | buffers hit=4133 read=123922
  -> Gather Merge | rows=50 (est 3880) loops=1 time=214.618 ms | workers=2 | buffers hit=4133 read=123922
    -> Sort | rows=41 (est 1940) loops=3 time=199.473 ms | sort=top-N heapsort 39kB Memory | buffers hit=4133 read=123922
      -> Parallel Seq Scan (metric) | filter (((consumerid)::text = 'consumer-010'::text) AND (date_c >= (LOCALTIMESTAMP - '30 days'::interval))) | rows=1402 (est 1940) loops=3 time=199.094 ms | removed by filter=1676103 | buffers hit=4059 read=123922
Planning 0.45 ms, execution 234 ms, I/O read 162 ms
```
</details>

## 16 Stored generated column

*Indexing (generated columns)*

> **Common advice:** Store a computed value as a generated column and index it; trades storage for query speed.

**Verdict:** Confirmed, though in PostgreSQL an expression index does the same without storing a column. The generated column + index took the query from 241 ms to 3.3 ms (73×), like the expression index in demo 13, but added 39 MB to a 423 MB table (+9%) and rewrote the whole table. Use a generated column when the value is also selected or reused in many queries.

<table>
<tr><th width="50%">❌ Before: <code>expression_no_index</code><br><sub>split_part(url, '/', 3) = 'v4.0.0', computed for every row</sub></th><th width="50%">✅ After: <code>generated_column</code><br><sub>WHERE api_version = 'v4.0.0'</sub><br><b>73× faster</b></th></tr>
<tr><td valign="top"><b>241 ms</b> &nbsp;·&nbsp; first run 227 ms<br>pages hit 2,464 / read 51,714 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM sc_gen WHERE split_part(url, '/', 3) = 'v4.0.0';</pre><pre>Aggregate
   rows 1 (est 1), 245.798 ms
  -&gt; Gather
     rows 3 (est 2), 245.784 ms
    -&gt; Aggregate
       rows 1 (est 1), 240.963 ms
      -&gt; Parallel Seq Scan (sc_gen)
         rows 1135 (est 10484), 240.736 ms</pre></td><td valign="top"><b>3.3 ms</b> &nbsp;·&nbsp; first run 11 ms<br>pages hit 3,376 / read 0 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM sc_gen WHERE api_version = 'v4.0.0';</pre><pre>Aggregate
   rows 1 (est 1), 3.267 ms
  -&gt; Index Scan (sc_gen_api_version)
     rows 3404 (est 3691), 3.008 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `expression_no_index` | split_part(url, '/', 3) = 'v4.0.0', computed for every row | 241 ms | 227 ms | Aggregate → Parallel Seq Scan (sc_gen) | 2,464 / 51,714 | 1 |
| `generated_column` | WHERE api_version = 'v4.0.0' | 3.3 ms | 11 ms | Aggregate → Index Scan (sc_gen_api_version) | 3,376 / 0 | 1 |

<details><summary>setup: setup (3.52 s)</summary>

```sql
DROP TABLE IF EXISTS sc_gen;
CREATE TABLE sc_gen AS SELECT id, url, duration, date_c FROM metric;
ANALYZE sc_gen;
```
</details>

**Table size before (copy of metric with 4 columns)**

```
table_size 
------------
 423 MB
(1 row)
```

<details><summary>step: add STORED generated column api_version + index (rewrites the table) (5.39 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
ALTER TABLE sc_gen ADD COLUMN api_version text GENERATED ALWAYS AS (split_part(url, '/', 3)) STORED;
CREATE INDEX sc_gen_api_version ON sc_gen (api_version);
ANALYZE sc_gen;
```
</details>

**Table size after: the stored value costs space in every row**

```
table_size | index_size 
------------+------------
 462 MB     | 33 MB
(1 row)
```

<details><summary>expression_no_index: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM sc_gen WHERE split_part(url, '/', 3) = 'v4.0.0';
```

```
Aggregate | rows=1 (est 1) loops=1 time=245.798 ms | buffers hit=2464 read=51714
  -> Gather | rows=3 (est 2) loops=1 time=245.784 ms | workers=2 | buffers hit=2464 read=51714
    -> Aggregate | rows=1 (est 1) loops=3 time=240.963 ms | buffers hit=2464 read=51714
      -> Parallel Seq Scan (sc_gen) | filter (split_part((url)::text, '/'::text, 3) = 'v4.0.0'::text) | rows=1135 (est 10484) loops=3 time=240.736 ms | removed by filter=1676371 | buffers hit=2464 read=51714
Planning 0.22 ms, execution 246 ms, I/O read 69 ms
```
</details>

<details><summary>generated_column: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM sc_gen WHERE api_version = 'v4.0.0';
```

```
Aggregate | rows=1 (est 1) loops=1 time=3.267 ms | buffers hit=3376 read=0
  -> Index Scan (sc_gen_api_version) | cond (api_version = 'v4.0.0'::text) | rows=3404 (est 3691) loops=1 time=3.008 ms | buffers hit=3376 read=0
Planning 0.25 ms, execution 3.3 ms
```
</details>

## 17 BRIN index for time series (PostgreSQL's answer to columnstore-style scans)

*Indexing (columnstore alternative)*

> **Common advice:** Columnstore indexes make analytical scans over millions of rows 10-100x faster with ~10x compression. PostgreSQL has no columnstore; for append-only time series like metricarchive a BRIN index is the tiny alternative.

**Verdict:** BRIN is the size champion, not the speed champion. On metricarchive.date_c it is 136 kB vs 326 MB for the B-tree (2,400x smaller) and makes one day 59× faster than a full scan. The B-tree is still faster: 3.4 ms vs 14 ms for a day, 46 ms vs 498 ms for 30 days. BRIN suits a rarely queried, append-only archive; keep the B-tree for hot queries. It is not a columnstore: PostgreSQL has no columnar storage without extensions.

<table>
<tr><th width="50%">❌ Before: <code>day_no_index</code><br><sub>one day in the archive, no date index</sub></th><th width="50%">✅ After: <code>day_brin</code><br><sub>one day, BRIN only</sub><br><b>59× faster</b></th></tr>
<tr><td valign="top"><b>851 ms</b> &nbsp;·&nbsp; first run 904 ms<br>pages hit 5,615 / read 447,739 &nbsp;·&nbsp; 1 row<br><sub>after a session preamble (see details below)</sub><pre>SELECT count(*), avg(duration) FROM metricarchive WHERE date_c &gt;= current_date - 800 AND date_c &lt; current_date - 799;</pre><pre>Aggregate
   rows 1 (est 1), 833.788 ms
  -&gt; Gather
     rows 3 (est 2), 833.76 ms
    -&gt; Aggregate
       rows 1 (est 1), 814.201 ms
      -&gt; Parallel Seq Scan (metricarchive)
         rows 4566 (est 5552), 813.867 ms</pre></td><td valign="top"><b>14 ms</b> &nbsp;·&nbsp; first run 23 ms<br>pages hit 5,637 / read 0 &nbsp;·&nbsp; 1 row<br><sub>after a session preamble (see details below)</sub><pre>SELECT count(*), avg(duration) FROM metricarchive WHERE date_c &gt;= current_date - 800 AND date_c &lt; current_date - 799;</pre><pre>Aggregate
   rows 1 (est 1), 17.969 ms
  -&gt; Bitmap Heap Scan (metricarchive)
     rows 13698 (est 13325), 17.283 ms
    -&gt; Bitmap Index Scan (sc_archive_date_brin)
       rows 56100 (est 17247), 0.544 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `day_no_index` | one day in the archive, no date index | 851 ms | 904 ms | Aggregate → Parallel Seq Scan (metricarchive) | 5,615 / 447,739 | 1 |
| `day_btree` | one day, B-tree only | 3.4 ms | 5.9 ms | Aggregate → Index Scan (metricarchive_date_c) | 546 / 0 | 1 |
| `day_brin` | one day, BRIN only | 14 ms | 23 ms | Aggregate → Bitmap Heap Scan (metricarchive) → Bitmap Index Scan (sc_archive_date_brin) | 5,637 / 0 | 1 |
| `month_btree` | 30 days, B-tree only | 46 ms | 71 ms | Aggregate → Parallel Index Scan (metricarchive_date_c) | 17,284 / 0 | 1 |
| `month_brin` | 30 days, BRIN only | 498 ms | 358 ms | Aggregate → Parallel Bitmap Heap Scan (metricarchive) → Bitmap Index Scan (sc_archive_date_brin) | 8,605 / 8,808 | 1 |

<details><summary>setup: setup (2.76 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_archive_date_brin ON metricarchive USING brin (date_c);
```
</details>

**Sizes: B-tree vs BRIN on metricarchive.date_c (15M rows)**

```
index         |  size  
----------------------+--------
 metricarchive_date_c | 326 MB
 sc_archive_date_brin | 136 kB
(2 rows)
```

<details><summary>day_no_index: SQL and plan</summary>

```sql
DROP INDEX metricarchive_date_c;
DROP INDEX sc_archive_date_brin;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 800 AND date_c < current_date - 799;
```

```
Aggregate | rows=1 (est 1) loops=1 time=833.788 ms | buffers hit=5615 read=447739
  -> Gather | rows=3 (est 2) loops=1 time=833.76 ms | workers=2 | buffers hit=5615 read=447739
    -> Aggregate | rows=1 (est 1) loops=3 time=814.201 ms | buffers hit=5615 read=447739
      -> Parallel Seq Scan (metricarchive) | filter ((date_c >= (CURRENT_DATE - 800)) AND (date_c < (CURRENT_DATE - 799))) | rows=4566 (est 5552) loops=3 time=813.867 ms | removed by filter=5041421 | buffers hit=5615 read=447739
Planning 0.43 ms, execution 849 ms, I/O read 685 ms
```
</details>

<details><summary>day_btree: SQL and plan</summary>

```sql
DROP INDEX sc_archive_date_brin;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 800 AND date_c < current_date - 799;
```

```
Aggregate | rows=1 (est 1) loops=1 time=3.112 ms | buffers hit=546 read=0
  -> Index Scan (metricarchive_date_c) | cond ((date_c >= (CURRENT_DATE - 800)) AND (date_c < (CURRENT_DATE - 799))) | rows=13698 (est 13325) loops=1 time=2.144 ms | buffers hit=546 read=0
Planning 0.45 ms, execution 3.2 ms
```
</details>

<details><summary>day_brin: SQL and plan</summary>

```sql
DROP INDEX metricarchive_date_c;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 800 AND date_c < current_date - 799;
```

```
Aggregate | rows=1 (est 1) loops=1 time=17.969 ms | buffers hit=5637 read=0
  -> Bitmap Heap Scan (metricarchive) | rows=13698 (est 13325) loops=1 time=17.283 ms | buffers hit=5637 read=0
    -> Bitmap Index Scan (sc_archive_date_brin) | cond ((date_c >= (CURRENT_DATE - 800)) AND (date_c < (CURRENT_DATE - 799))) | rows=56100 (est 17247) loops=1 time=0.544 ms | buffers hit=27 read=0
Planning 0.42 ms, execution 18 ms
```
</details>

<details><summary>month_btree: SQL and plan</summary>

```sql
DROP INDEX sc_archive_date_brin;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 830 AND date_c < current_date - 800;
```

```
Aggregate | rows=1 (est 1) loops=1 time=41.973 ms | buffers hit=17284 read=0
  -> Gather | rows=3 (est 2) loops=1 time=41.963 ms | workers=2 | buffers hit=17284 read=0
    -> Aggregate | rows=1 (est 1) loops=3 time=34.876 ms | buffers hit=17284 read=0
      -> Parallel Index Scan (metricarchive_date_c) | cond ((date_c >= (CURRENT_DATE - 830)) AND (date_c < (CURRENT_DATE - 800))) | rows=137010 (est 164098) loops=3 time=24.809 ms | buffers hit=17284 read=0
Planning 0.45 ms, execution 42 ms
```
</details>

<details><summary>month_brin: SQL and plan</summary>

```sql
DROP INDEX metricarchive_date_c;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 830 AND date_c < current_date - 800;
```

```
Aggregate | rows=1 (est 1) loops=1 time=397.181 ms | buffers hit=8605 read=8808
  -> Gather | rows=3 (est 2) loops=1 time=397.117 ms | workers=2 | buffers hit=8605 read=8808
    -> Aggregate | rows=1 (est 1) loops=3 time=361.399 ms | buffers hit=8605 read=8808
      -> Parallel Bitmap Heap Scan (metricarchive) | rows=137010 (est 164098) loops=3 time=352.431 ms | buffers hit=8605 read=8808
        -> Bitmap Index Scan (sc_archive_date_brin) | cond ((date_c >= (CURRENT_DATE - 830)) AND (date_c < (CURRENT_DATE - 800))) | rows=173860 (est 400999) loops=1 time=223.553 ms | buffers hit=27 read=0
Planning 0.58 ms, execution 419 ms, I/O read 33 ms
```
</details>

## 18 Substring search: LIKE '%...%' vs trigram index

*Indexing (text search)*

> **Common advice:** A leading wildcard (LIKE '%...%') cannot use a normal index; a text-search index turns the full scan into milliseconds. For URL substrings PostgreSQL's pg_trgm trigram index is the fitting tool.

**Verdict:** Confirmed. LIKE '%dynamic-entity%' scanned all 5M rows (379 ms); a GIN trigram index made it 8.9 ms (42×), and ILIKE uses it too. Cost: a 184 MB index (18% of the table) and a 28 s build. Worth it behind a URL search box, not as a default.

<table>
<tr><th width="50%">❌ Before: <code>like_no_index</code><br><sub>url LIKE '%dynamic-entity%' (2.5k of 5M rows)</sub></th><th width="50%">✅ After: <code>like_trgm</code><br><sub>same query with the trigram index</sub><br><b>42× faster</b></th></tr>
<tr><td valign="top"><b>379 ms</b> &nbsp;·&nbsp; first run 448 ms<br>pages hit 384 / read 127,597 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM metric WHERE url LIKE '%dynamic-entity%';</pre><pre>Aggregate
   rows 1 (est 1), 292.971 ms
  -&gt; Gather
     rows 3 (est 2), 292.95 ms
    -&gt; Aggregate
       rows 1 (est 1), 273.433 ms
      -&gt; Parallel Seq Scan (metric)
         rows 825 (est 478), 273.193 ms</pre></td><td valign="top"><b>8.9 ms</b> &nbsp;·&nbsp; first run 21 ms<br>pages hit 2,936 / read 0 &nbsp;·&nbsp; 1 row<pre>SELECT count(*), avg(duration) FROM metric WHERE url LIKE '%dynamic-entity%';</pre><pre>Aggregate
   rows 1 (est 1), 8.832 ms
  -&gt; Bitmap Heap Scan (metric)
     rows 2475 (est 1147), 8.66 ms
    -&gt; Bitmap Index Scan (sc_metric_url_trgm)
       rows 2475 (est 1147), 5.88 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `like_no_index` | url LIKE '%dynamic-entity%' (2.5k of 5M rows) | 379 ms | 448 ms | Aggregate → Parallel Seq Scan (metric) | 384 / 127,597 | 1 |
| `like_trgm` | same query with the trigram index | 8.9 ms | 21 ms | Aggregate → Bitmap Heap Scan (metric) → Bitmap Index Scan (sc_metric_url_trgm) | 2,936 / 0 | 1 |
| `ilike_trgm` | case-insensitive ILIKE uses it too | 11 ms | 11 ms | Aggregate → Bitmap Heap Scan (metric) → Bitmap Index Scan (sc_metric_url_trgm) | 2,936 / 0 | 1 |

<details><summary>step: GIN trigram index on url (27.89 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_url_trgm ON metric USING gin (url gin_trgm_ops);
```
</details>

**Index size**

```
trigram_index_size | metric_table_size 
--------------------+-------------------
 201 MB             | 1000 MB
(1 row)
```

<details><summary>like_no_index: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric WHERE url LIKE '%dynamic-entity%';
```

```
Aggregate | rows=1 (est 1) loops=1 time=292.971 ms | buffers hit=384 read=127597
  -> Gather | rows=3 (est 2) loops=1 time=292.95 ms | workers=2 | buffers hit=384 read=127597
    -> Aggregate | rows=1 (est 1) loops=3 time=273.433 ms | buffers hit=384 read=127597
      -> Parallel Seq Scan (metric) | filter ((url)::text ~~ '%dynamic-entity%'::text) | rows=825 (est 478) loops=3 time=273.193 ms | removed by filter=1676681 | buffers hit=384 read=127597
Planning 0.48 ms, execution 313 ms, I/O read 184 ms
```
</details>

<details><summary>like_trgm: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric WHERE url LIKE '%dynamic-entity%';
```

```
Aggregate | rows=1 (est 1) loops=1 time=8.832 ms | buffers hit=2936 read=0
  -> Bitmap Heap Scan (metric) | rows=2475 (est 1147) loops=1 time=8.66 ms | buffers hit=2936 read=0
    -> Bitmap Index Scan (sc_metric_url_trgm) | cond ((url)::text ~~ '%dynamic-entity%'::text) | rows=2475 (est 1147) loops=1 time=5.88 ms | buffers hit=466 read=0
Planning 0.75 ms, execution 8.9 ms
```
</details>

<details><summary>ilike_trgm: SQL and plan</summary>

```sql
SELECT count(*), avg(duration) FROM metric WHERE url ILIKE '%Dynamic-Entity%';
```

```
Aggregate | rows=1 (est 1) loops=1 time=10.768 ms | buffers hit=2936 read=0
  -> Bitmap Heap Scan (metric) | rows=2475 (est 1147) loops=1 time=10.507 ms | buffers hit=2936 read=0
    -> Bitmap Index Scan (sc_metric_url_trgm) | cond ((url)::text ~~* '%Dynamic-Entity%'::text) | rows=2475 (est 1147) loops=1 time=5.413 ms | buffers hit=466 read=0
Planning 1.2 ms, execution 11 ms
```
</details>

## 19 Query Store (SQL Server) = pg_stat_statements + pgstat

*Monitoring (Query Store equivalent)*

> **Common advice:** A flight recorder for queries: performance over time, find the worst queries, spot regressions.

**Verdict:** The equivalent exists in two parts. pg_stat_statements is PostgreSQL's cumulative query store; the top of this list is the showcase's own heaviest work (parallel aggregates over the archive, index builds). It keeps no history: the pgstat tool (../pgstat) adds 15-minute snapshots, time windows and per-query trends, which covers the 'performance over time' and regression parts.

**Top statements in obp_showcase by total time (pg_stat_statements, what this showcase ran)**

```
calls | total_s | mean_ms |                                           query                                            
-------+---------+---------+--------------------------------------------------------------------------------------------
    14 |    32.5 |  2323.0 | EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT implementedbypartialfunction, count(*), avg
     1 |    27.8 | 27792.6 | CREATE INDEX sc_metric_url_trgm ON metric USING gin (url gin_trgm_ops)
    80 |    15.7 |   196.2 | SELECT * FROM metricarchive WHERE metricid = $1
     8 |     6.5 |   811.8 | EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT count(*), avg(duration) FROM metricarchive 
     1 |     5.8 |  5788.1 | CREATE INDEX sc_archive_lower_email ON metricarchive (lower(developeremail))
     2 |     5.0 |  2485.6 | CREATE INDEX sc_metric_user_date ON metric (userid, date_c)
     1 |     4.6 |  4637.3 | CREATE INDEX sc_archive_metricid ON metricarchive (metricid)
    15 |     4.6 |   303.8 | EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT count(*), avg(duration) FROM metricarchive 
     1 |     4.4 |  4386.8 | INSERT INTO sc_stale (url, duration, date_c, consumerid, correlationid, httpcode, verb) SE
     1 |     4.0 |  3985.8 | REFRESH MATERIALIZED VIEW CONCURRENTLY sc_metric_daily
(10 rows)
```

**History over time: ../pgstat keeps 15-minute snapshots (pgstat setup, then e.g.)**

```
command                                   
-----------------------------------------------------------------------------
 pgstat total 1h -d obp_showcase    -- what took the time in the last hour
 pgstat trend <queryid> 1w           -- did this query get slower this week?
 pgstat slow 1d -d obp_mapped        -- slowest statements yesterday
(3 rows)
```

## 20 Finale: tracing one request by correlation id

*Case study*

> **Common advice:** Combine the patterns on one real slow query and measure every step.

**Verdict:** One missing index was the whole story. Tracing a request scanned 20M rows: 1.15 s (1.81 s on the first run; 1.55 s under load in the load test). Indexing only metric left the archive scan (785 ms). With B-tree indexes on both tables the lookup takes 0.04 ms, 29,369× faster. Costs: 283 MB + 849 MB of index (a hash index on the archive is 513 MB, 40% smaller and just as fast for = lookups), and random UUID keys made 10,000 inserts 1.7× slower because each insert lands on a random index page. Recommendation: index metric.correlationid (loadtest/tuning/02_index_correlationid.sql), and hash-index metricarchive.correlationid if old requests are traced often.

<table>
<tr><th width="50%">❌ Before: <code>original</code><br><sub>SELECT * from both tables, no index (5M + 15M rows scanned)</sub></th><th width="50%">✅ After: <code>both_btree</code><br><sub>both tables through a B-tree index</sub><br><b>29,369× faster</b></th></tr>
<tr><td valign="top"><b>1.15 s</b> &nbsp;·&nbsp; first run 1.81 s<br>pages hit 3,114 / read 578,221 &nbsp;·&nbsp; 1 row<br><sub>after a session preamble (see details below)</sub><pre>SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;</pre><pre>Gather
   rows 1 (est 2), 1072.101 ms
  -&gt; Parallel Append
     rows 0 (est 2), 1054.548 ms
    -&gt; Parallel Seq Scan (metricarchive)
       rows 0 (est 1), 716.079 ms
    -&gt; Parallel Seq Scan (metric)
       rows 0 (est 1), 507.695 ms</pre></td><td valign="top"><b>0.04 ms</b> &nbsp;·&nbsp; first run 0.79 ms<br>pages hit 9 / read 0 &nbsp;·&nbsp; 1 row<br><sub>after a session preamble (see details below)</sub><pre>SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;</pre><pre>Append
   rows 1 (est 2), 0.025 ms
  -&gt; Index Scan (sc_metric_correlationid)
     rows 0 (est 1), 0.013 ms
  -&gt; Index Scan (sc_archive_correlationid)
     rows 1 (est 1), 0.012 ms</pre></td></tr>
</table>

**All cases**

| Case | What | Time | First run | Plan | Pages hit / read | Rows |
|---|---|---|---|---|---|---|
| `original` | SELECT * from both tables, no index (5M + 15M rows scanned) | 1.15 s | 1.81 s | Parallel Append → Parallel Seq Scan (metricarchive) → Parallel Seq Scan (metric) | 3,114 / 578,221 | 1 |
| `insert_no_index` | write cost baseline: 10,000 inserts into metric | 96 ms | 111 ms | ModifyTable (metric) → Subquery Scan → Index Scan (lt_tpl_metric_pkey) | 103,425 / 77 | 0 |
| `metric_indexed` | metric part is now an index lookup, the archive is still scanned | 785 ms | 771 ms | Append → Index Scan (sc_metric_correlationid) → Parallel Seq Scan (metricarchive) | 873 / 452,485 | 1 |
| `insert_with_index` | write cost: the same 10,000 inserts with the extra index | 160 ms | 159 ms | ModifyTable (metric) → Subquery Scan → Index Scan (lt_tpl_metric_pkey) | 136,855 / 6,582 | 0 |
| `both_btree` | both tables through a B-tree index | 0.04 ms | 0.79 ms | Append → Index Scan (sc_metric_correlationid) → Index Scan (sc_archive_correlationid) | 9 / 0 | 1 |
| `archive_hash` | archive through the hash index instead | 0.04 ms | 0.06 ms | Append → Index Scan (sc_metric_correlationid) → Index Scan (sc_archive_correlationid_hash) | 7 / 0 | 1 |

<details><summary>step: 1. B-tree index on metric.correlationid (the live table) (6.46 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_correlationid ON metric (correlationid);
```
</details>

<details><summary>step: 2. B-tree and hash index on metricarchive.correlationid (15M rows) to compare (46.99 s)</summary>

```sql
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_archive_correlationid ON metricarchive (correlationid);
CREATE INDEX sc_archive_correlationid_hash ON metricarchive USING hash (correlationid);
```
</details>

**Index cost: sizes (correlation ids are 36-character UUID strings)**

```
index             |     table     |  size  
-------------------------------+---------------+--------
 sc_metric_correlationid       | metric        | 283 MB
 sc_archive_correlationid_hash | metricarchive | 512 MB
 sc_archive_correlationid      | metricarchive | 853 MB
(3 rows)
```

<details><summary>original: SQL and plan</summary>

```sql
SELECT correlationid AS cid FROM metricarchive WHERE id >= 8000000 ORDER BY id LIMIT 1 \gset
-- @explain
SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;
```

```
Gather | rows=1 (est 2) loops=1 time=1072.101 ms | workers=2 | buffers hit=3114 read=578221
  -> Parallel Append | rows=0 (est 2) loops=3 time=1054.548 ms | buffers hit=3114 read=578221
    -> Parallel Seq Scan (metricarchive) | filter ((correlationid)::text = '21be684d-1345-4d86-ae27-8b41ae4c5e09'::text) | rows=0 (est 1) loops=3 time=716.079 ms | removed by filter=5045987 | buffers hit=388 read=452966
    -> Parallel Seq Scan (metric) | filter ((correlationid)::text = '21be684d-1345-4d86-ae27-8b41ae4c5e09'::text) | rows=0 (est 1) loops=2 time=507.695 ms | removed by filter=2516258 | buffers hit=2726 read=125255
Planning 0.32 ms, execution 1.09 s, I/O read 675 ms
```
</details>

<details><summary>insert_no_index: SQL and plan</summary>

```sql
INSERT INTO metric (url, duration, date_c, consumerid, implementedbypartialfunction, correlationid, httpcode, verb)
SELECT url, duration, localtimestamp, consumerid, implementedbypartialfunction, gen_random_uuid()::text, httpcode, verb
  FROM lt_tpl_metric WHERE k <= 10000;
```

```
ModifyTable (metric) | rows=0 (est 0) loops=1 time=87.869 ms | buffers hit=103425 read=77
  -> Subquery Scan | rows=10000 (est 9995) loops=1 time=22.617 ms | buffers hit=10348 read=0
    -> Index Scan (lt_tpl_metric_pkey) | cond (k <= 10000) | rows=10000 (est 9995) loops=1 time=17.49 ms | buffers hit=336 read=0
Planning 0.29 ms, execution 88 ms, I/O read 0.23 ms
```
</details>

<details><summary>metric_indexed: SQL and plan</summary>

```sql
SELECT correlationid AS cid FROM metricarchive WHERE id >= 8000000 ORDER BY id LIMIT 1 \gset
-- @explain
SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;
```

```
Append | rows=1 (est 2) loops=1 time=771.224 ms | buffers hit=873 read=452485
  -> Index Scan (sc_metric_correlationid) | cond ((correlationid)::text = '21be684d-1345-4d86-ae27-8b41ae4c5e09'::text) | rows=0 (est 1) loops=1 time=0.021 ms | buffers hit=4 read=0
  -> Gather | rows=1 (est 1) loops=1 time=771.198 ms | workers=2 | buffers hit=869 read=452485
    -> Parallel Seq Scan (metricarchive) | filter ((correlationid)::text = '21be684d-1345-4d86-ae27-8b41ae4c5e09'::text) | rows=0 (est 1) loops=3 time=755.109 ms | removed by filter=5045987 | buffers hit=869 read=452485
Planning 0.31 ms, execution 785 ms, I/O read 502 ms
```
</details>

<details><summary>insert_with_index: SQL and plan</summary>

```sql
INSERT INTO metric (url, duration, date_c, consumerid, implementedbypartialfunction, correlationid, httpcode, verb)
SELECT url, duration, localtimestamp, consumerid, implementedbypartialfunction, gen_random_uuid()::text, httpcode, verb
  FROM lt_tpl_metric WHERE k <= 10000;
```

```
ModifyTable (metric) | rows=0 (est 0) loops=1 time=165.941 ms | buffers hit=136855 read=6582
  -> Subquery Scan | rows=10000 (est 9995) loops=1 time=21.999 ms | buffers hit=10348 read=0
    -> Index Scan (lt_tpl_metric_pkey) | cond (k <= 10000) | rows=10000 (est 9995) loops=1 time=17.187 ms | buffers hit=336 read=0
Planning 0.29 ms, execution 166 ms, I/O read 17 ms
```
</details>

<details><summary>both_btree: SQL and plan</summary>

```sql
DROP INDEX sc_archive_correlationid_hash;
SELECT correlationid AS cid FROM metricarchive WHERE id >= 8000000 ORDER BY id LIMIT 1 \gset
-- @explain
SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;
```

```
Append | rows=1 (est 2) loops=1 time=0.025 ms | buffers hit=9 read=0
  -> Index Scan (sc_metric_correlationid) | cond ((correlationid)::text = '21be684d-1345-4d86-ae27-8b41ae4c5e09'::text) | rows=0 (est 1) loops=1 time=0.013 ms | buffers hit=4 read=0
  -> Index Scan (sc_archive_correlationid) | cond ((correlationid)::text = '21be684d-1345-4d86-ae27-8b41ae4c5e09'::text) | rows=1 (est 1) loops=1 time=0.012 ms | buffers hit=5 read=0
Planning 0.26 ms, execution 0.04 ms
```
</details>

<details><summary>archive_hash: SQL and plan</summary>

```sql
DROP INDEX sc_archive_correlationid;
SELECT correlationid AS cid FROM metricarchive WHERE id >= 8000000 ORDER BY id LIMIT 1 \gset
-- @explain
SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;
```

```
Append | rows=1 (est 2) loops=1 time=0.029 ms | buffers hit=7 read=0
  -> Index Scan (sc_metric_correlationid) | cond ((correlationid)::text = '21be684d-1345-4d86-ae27-8b41ae4c5e09'::text) | rows=0 (est 1) loops=1 time=0.012 ms | buffers hit=4 read=0
  -> Index Scan (sc_archive_correlationid_hash) | cond ((correlationid)::text = '21be684d-1345-4d86-ae27-8b41ae4c5e09'::text) | rows=1 (est 1) loops=1 time=0.017 ms | buffers hit=3 read=0
Planning 0.25 ms, execution 0.04 ms
```
</details>
