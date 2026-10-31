# OBP metric tables: measured improvements

Everything below was measured on this machine against a copy of the OBP metric tables, scaled to 5M metric and 15M metricarchive rows and pseudonymized. Each item says what it buys, what it costs and how sure we are: measured means it was run in one of the two reports, estimated means the reasoning is sound but nobody ran it here.

| # | Change | Priority | Confidence | Measured effect | Main cost | How to find it |
|---|---|---|---|---|---|---|
| 1 | Index metric.correlationid | Do first | measured here | Load test, read scenario at 16 clients: throughput 31 → 219 tps (7.0x), p95 4.16 s → 307 ms (-93%) | 283 MB of disk on a 5M-row table | observe → diagnose (missing-index) → explain (seq-scan) → loadtest run + compare |
| 2 | Index metricarchive.correlationid, as a hash index | Worth doing | measured here | Showcase demo 20: tracing one request across both tables 0.88 s → 0.04 ms once both tables are indexed; with only metric indexed the archive scan still costs ~0.75 s | 512 MB of disk | diagnose (missing-index), explain (seq-scan) |
| 3 | Index metricarchive.metricid (upstream fix) | Do first | measured here | The archive job looks each row up by metricId twice (dedup in saveMetricsArchive, verify before delete) and no index existed: two full scans of metricarchive per archived row | Index build blocks writes to metricarchive at boot (seconds per few million rows); only the archive job writes there | diagnose (seq-scan on metricarchive), then the OBP source |
| 4 | Drop the duplicate consent_reference_id indexes | Worth doing | measured here | Sizes on the test data: 33 MB (metric) + 100 MB (metricarchive) wasted per duplicate | Needs care upstream so the migration does not recreate it on the next deploy | diagnose (duplicate-index) |
| 5 | Archive in batches instead of row by row | Do first | measured here | Showcase demo 10: moving 10,000 rows took 1.49 s row by row (20,000 statements) against 213 ms as one DELETE ... RETURNING feeding an INSERT: about 7x | A real code change in the scheduler, with its own tests | observe during an archive run, then the OBP source |
| 6 | Keyset pagination for /management/metrics | Worth doing | measured here | Showcase demo 09: page 1 0.03 ms, page 1,000 3.1 ms, page 50,000 241 ms with OFFSET; keyset stays at 0.04 ms at any depth | API change: the client must pass the last seen values instead of an offset, so it cannot jump to page N directly | explain (top-n-sort) |
| 7 | Stop selecting every column in hot paths | Worth doing | measured here | Showcase demo 02: with only indexed columns the query becomes an Index Only Scan, 33 ms → 1.5 ms (22x), reading 89 pages instead of 15,366 | Touches many call sites, and ORM projections are more code than loading an entity | diagnose (toast), explain (filter-waste) |
| 8 | Pre-compute the dashboard aggregates | Later / if needed | measured here | Showcase demo 11: 365-day top-APIs 663 ms → 30 ms (22x), 7-day 26x; the view is 11 MB against 1.4 GB of table; a full refresh takes 2.9 s (4.0 s concurrently) | Data is as stale as the refresh interval; not suitable for live per-request views | explain (slow), loadtest run + compare |
| 9 | Raise shared_buffers from the 128 MB default | Worth doing | estimated, not measured | Showcase demo 12: shared_buffers holds 2% of the 6.4 GB of data; the same query costs 28 ms cold and 9.5 ms once cached, and a large query evicts everything else | Not measured here. On this machine the OS page cache already absorbs most reads (average read 1.4 µs), so the gain may be smaller than expected | diagnose (shared-buffers, cache-hit) |
| 10 | Raise work_mem for the aggregate and refresh paths | Later / if needed | measured here | Showcase run: 7 GB of temp files, mostly the materialized view build and refresh sorting 5M rows | Multiplied per sort node and per connection: a global increase can exhaust RAM under load | diagnose (temp-files), explain (sort-spill) |
| 11 | Allow more parallel workers per query | Later / if needed | measured here | Showcase demo 14, aggregating 15M archive rows: 3.83 s with 1 worker, 1.99 s with 2, 1.88 s with 4, 1.61 s with 6 | Diminishing returns past 4 workers: the scan becomes I/O bound, not CPU bound | not covered by a check: measured by hand in the showcase |
| 12 | Lower random_page_cost for SSD storage | Later / if needed | estimated, not measured | The storage here is an NVMe SSD; measured average read time per page is 1.4 µs | Not measured here. No before/after run was done with this setting | loadtest run + compare, one setting at a time |
| 13 | Tune autovacuum for the metric table | Worth doing | measured here | Load test, mixed scenario at 16 clients: 298,000 dead rows in metric after 5 minutes, autovacuum never ran during the run | More frequent vacuums cost I/O while running | diagnose (dead-rows) |
| 14 | Covering index for the top-APIs query | Later / if needed | measured here | Showcase demo 07: 50-116 ms → 36-41 ms (1.3-3x), answered from the index alone | Three times the size of the plain date index, on the table that receives every insert | explain (filter-waste) |
| 15 | Partial index for error dashboards | Later / if needed | measured here | Showcase demo 08: 8.9 MB against 151 MB for the full (httpcode, date_c) index, and at least as fast (9-12 ms vs 15-16 ms; 29-87 ms with no index) | Only used by queries whose WHERE matches the predicate | diagnose (missing-index), explain |
| 16 | Trigram index for URL substring search | Only on demand | measured here | Showcase demo 18: LIKE '%dynamic-entity%' 379 ms → 8.9 ms (42x), and ILIKE uses it too | Large index and slower writes, for a feature that may not exist | explain (seq-scan on a LIKE filter) |
| 17 | BRIN instead of B-tree on metricarchive.date_c | Only on demand | measured here | Showcase demo 17: 136 kB against 326 MB (2,400x smaller); one day 762 ms → 14 ms without any index, but the B-tree is still faster: 3.4-4.6 ms vs 14-18 ms for a day, 40-46 ms vs 265-498 ms for a month | 3-10x slower than the B-tree for the same query | not covered by a check: an index-size trade-off, measured by hand |
| 18 | Partition metricarchive by month | Later / if needed | estimated, not measured | The archive job currently deletes expired rows with a bulk DELETE, which rewrites index entries and leaves dead rows behind | Not measured here. No partitioned variant was benchmarked | not covered by a check: a design change, measure with loadtest |
| 19 | Rewriting OR as UNION | Skip | measured here | Showcase demo 05: OR across two indexed columns is answered with a BitmapOr of both indexes, 158 ms against 194 ms for the UNION rewrite | More SQL to maintain for no measured gain | showcase demo 05 (myth check) |
| 20 | Forcing plans (hints, enable_* switches) | Skip | measured here | Showcase demo 15: the planner's own choice (0.7-5.6 ms) beat every alternative it had rejected (bitmap + sort 19-32 ms, full scan 190-242 ms) | Not a production fix: a forced plan stops adapting when the data changes | showcase demo 15 (myth check) |
| 21 | Trusting EXPLAIN ANALYZE alone | Skip | measured here | Showcase demo 02: after a wide column is added, EXPLAIN reports 7.8 → 10.2 ms while the client sees 10.5 → 123 ms, because large values live out of line and EXPLAIN never fetches them | It hides everything that happens while delivering rows | explain and pg_stat_statements both see what EXPLAIN hides |

## Repeating this on any table

The same path that produced this list, as commands. Steps 1-3 are read-only and safe against a live database; the rest only touch a copy.

```bash
git clone https://github.com/constantine2nd/postgresql-lab && cd postgresql-lab/pglab
./observe.py  -d proddb --role appuser          # 1. trigger the slow action: what ran, which tables
./diagnose.py -d proddb -t <table>              # 2. duplicate, unused and missing indexes, bloat, cache
./capture.py  -d proddb -t <table> -o wl/       # 3. the statements that really run, with their weights
./clone.py --from proddb -t <table> --to lab --anonymize --scale-to 5000000
psql -d lab -f wl/prepare.sql
./explain.py -w wl/ -d lab                      # 4. what is wrong with each plan, and what to try
./replay.py baseline --workload wl/ --db lab
./replay.py fixed    --workload wl/ --db lab --apply fix.sql
./compare.py baseline fixed --scripts          # 5. did it help, and what did it cost
```

For a table that does not exist yet: `seed.py --rows 1000000 --values col=N` fills it from the column types, then `explain.py --sql expected_queries.sql` shows the plans at that size.

The *How to find it* column above names the check that surfaces each item. See [pglab's README](https://github.com/constantine2nd/postgresql-lab/blob/main/pglab/README.md).

## Indexes

Cheap to apply, easy to undo, and this is where the measured wins are.

### Index metric.correlationid

*Do first · measured here · found with: observe → diagnose (missing-index) → explain (seq-scan) → loadtest run + compare*

CREATE INDEX CONCURRENTLY metric_correlationid ON metric (correlationid);

**Evidence**

- Load test, read scenario at 16 clients: throughput 31 → 219 tps (7.0x), p95 4.16 s → 307 ms (-93%)
- The lookup itself: p95 4.95 s → 15 ms (323x); it was 93% of all query time in the baseline run
- Mixed scenario (inserts + reads + archive job) at 4 clients: 88 → 358 tps (4.1x)

**Pros**

- The single biggest win measured anywhere in this work
- Makes reads scale with clients again; without it throughput is flat at ~30 tps no matter the load
- Speeds up every other read too, because the full scans no longer flush the cache
- No code change, and reversible with one DROP INDEX

**Cons and trade-offs**

- 283 MB of disk on a 5M-row table
- Random UUID keys mean every insert writes to a random index page: measurable (1.7-3.4x) on a single-statement bulk insert of 10,000 rows, but not measurable in the load test (one row per transaction, +10% to -1% across all client counts)
- CREATE INDEX without CONCURRENTLY would block writes for the ~6 s build

### Index metricarchive.correlationid, as a hash index

*Worth doing · measured here · found with: diagnose (missing-index), explain (seq-scan)*

CREATE INDEX CONCURRENTLY metricarchive_correlationid ON metricarchive USING hash (correlationid);

**Evidence**

- Showcase demo 20: tracing one request across both tables 0.88 s → 0.04 ms once both tables are indexed; with only metric indexed the archive scan still costs ~0.75 s
- Hash index 512 MB vs B-tree 853 MB on 15M rows, same lookup speed

**Pros**

- Support can trace an old request in milliseconds instead of a second per attempt
- Hash is 40% smaller than B-tree because it stores a 4-byte hash, not the 36-character UUID

**Cons and trade-offs**

- 512 MB of disk
- Hash supports equality only: no ranges, no ORDER BY, no prefix search, no unique constraint
- Only worth it if old requests are actually traced; the archive is otherwise written and read by date

### Index metricarchive.metricid (upstream fix)

*Do first · measured here · found with: diagnose (seq-scan on metricarchive), then the OBP source*

Add Index(metricId) to MetricArchive.dbIndexes. Submitted as OBP-API PR #2918; Schemifier creates it at boot on existing deployments.

**Evidence**

- The archive job looks each row up by metricId twice (dedup in saveMetricsArchive, verify before delete) and no index existed: two full scans of metricarchive per archived row
- Showcase demo 10 at 15M archive rows: ~1.57 s per row without the index, ~0.8 ms with it
- Matches the real database: 1,542 scans of metricarchive for the 766-row run on 2026-08-19

**Pros**

- Without it, archiving cost grows with the archive: a 10,000-row batch would need hours at 15M rows, against a 10-minute scheduler interval, so the job falls permanently behind
- One line, no behaviour change, no migration needed

**Cons and trade-offs**

- Index build blocks writes to metricarchive at boot (seconds per few million rows); only the archive job writes there
- Disk cost grows with the archive, a few hundred MB at 15M rows

### Drop the duplicate consent_reference_id indexes

*Worth doing · measured here · found with: diagnose (duplicate-index)*

Both tables carry two identical indexes on consent_reference_id: one from dbIndexes, one created explicitly by MigrationOfMetricConsentReferenceId. Drop one of each and remove the duplicate from the migration.

**Evidence**

- Sizes on the test data: 33 MB (metric) + 100 MB (metricarchive) wasted per duplicate
- Every insert and every archived row maintains both copies for no benefit

**Pros**

- Frees 133 MB and removes pure write overhead
- No query loses anything: the surviving index is identical

**Cons and trade-offs**

- Needs care upstream so the migration does not recreate it on the next deploy
- The write saving was not isolated in a benchmark; index maintenance per row is small

## Application and job changes

Need a code change in OBP; larger wins than any setting.

### Archive in batches instead of row by row

*Do first · measured here · found with: observe during an archive run, then the OBP source*

Replace the per-row copy/verify/delete loop in MetricsArchiveScheduler with one DELETE ... RETURNING feeding an INSERT, in batches.

**Evidence**

- Showcase demo 10: moving 10,000 rows took 1.49 s row by row (20,000 statements) against 213 ms as one DELETE ... RETURNING feeding an INSERT: about 7x
- With OBP's per-row metricid lookups on top, the same work costs 1.57 s per row at 15M archive rows until the metricid index exists
- Load test, mixed scenario: the batched job moved ~324k rows in 5 minutes while foreground traffic kept running

**Pros**

- About 7x less time for the same work, and the cost stops depending on archive size
- Fewer round trips and less lock churn than 2 statements per row

**Cons and trade-offs**

- A real code change in the scheduler, with its own tests
- A batch holds its rows in one transaction: batch size needs a sane limit (1,000-5,000)
- The per-row verify step disappears; the copy is then trusted inside one transaction, which is what makes it atomic anyway
- Adding the metricid index (above) already removes most of the pain, so this is the second step

### Keyset pagination for /management/metrics

*Worth doing · measured here · found with: explain (top-n-sort)*

Replace LIMIT ... OFFSET n with a seek condition on the last row seen: WHERE (date_c, id) < (:last_date, :last_id) ORDER BY date_c DESC, id DESC LIMIT 20.

**Evidence**

- Showcase demo 09: page 1 0.03 ms, page 1,000 3.1 ms, page 50,000 241 ms with OFFSET; keyset stays at 0.04 ms at any depth

**Pros**

- Deep pages stop being slow; cost no longer grows with page number
- Less load on the database from bots and scripts that walk the whole metrics list

**Cons and trade-offs**

- API change: the client must pass the last seen values instead of an offset, so it cannot jump to page N directly
- Only pays off for deep paging; the first few pages are already fast

### Stop selecting every column in hot paths

*Worth doing · measured here · found with: diagnose (toast), explain (filter-waste)*

List the columns each screen needs, or use ORM projections, instead of loading the full entity.

**Evidence**

- Showcase demo 02: with only indexed columns the query becomes an Index Only Scan, 33 ms → 1.5 ms (22x), reading 89 pages instead of 15,366
- Same demo: after a migration adds a ~2 kB JSON column, the unchanged SELECT * goes from 30 ms to 144 ms while the explicit-column query does not move

**Pros**

- Immune to later schema growth, which is the part no test catches
- Enables index-only scans, which nothing else can
- Less data over the network per request

**Cons and trade-offs**

- Touches many call sites, and ORM projections are more code than loading an entity
- The gain on narrow rows is small today; it grows when wide columns are added later

### Pre-compute the dashboard aggregates

*Later / if needed · measured here · found with: explain (slow), loadtest run + compare*

A daily materialized view over metric (day, function, version, consumer: calls, total duration, errors), refreshed every few minutes with REFRESH MATERIALIZED VIEW CONCURRENTLY.

**Evidence**

- Showcase demo 11: 365-day top-APIs 663 ms → 30 ms (22x), 7-day 26x; the view is 11 MB against 1.4 GB of table; a full refresh takes 2.9 s (4.0 s concurrently)
- Load test: after the correlationid fix, the top-APIs aggregate is the heaviest statement left

**Pros**

- Turns the slowest remaining dashboard queries into millisecond lookups
- Cheap to keep current, and CONCURRENTLY does not block readers

**Cons and trade-offs**

- Data is as stale as the refresh interval; not suitable for live per-request views
- Another object to maintain, and the aggregate shape has to match what the API offers
- Refresh costs CPU and temp files (work_mem matters here)

## Server settings

One restart or reload; affects every database on the instance.

### Raise shared_buffers from the 128 MB default

*Worth doing · estimated, not measured · found with: diagnose (shared-buffers, cache-hit)*

ALTER SYSTEM SET shared_buffers = '4GB'; then restart. Common starting point is 25% of RAM.

**Evidence**

- Showcase demo 12: shared_buffers holds 2% of the 6.4 GB of data; the same query costs 28 ms cold and 9.5 ms once cached, and a large query evicts everything else
- Load test baseline read run: 159M blocks read from the OS in 5 minutes

**Pros**

- More of the working set stays in PostgreSQL's own cache, so fewer system calls
- Helps every query, no code change

**Cons and trade-offs**

- Not measured here. On this machine the OS page cache already absorbs most reads (average read 1.4 µs), so the gain may be smaller than expected
- Needs a restart, and the memory is reserved whether used or not
- Too large a value can hurt: double buffering with the OS cache, and longer checkpoints

### Raise work_mem for the aggregate and refresh paths

*Later / if needed · measured here · found with: diagnose (temp-files), explain (sort-spill)*

Default is 4 MB. Set it per session or per role for reporting queries, e.g. SET work_mem = '64MB'; before the materialized view refresh.

**Evidence**

- Showcase run: 7 GB of temp files, mostly the materialized view build and refresh sorting 5M rows
- Two measured cases spilled to disk: SELECT * with a sort (~3 MB per run) and a UNION de-duplication

**Pros**

- Sorts and hashes stay in memory instead of spilling to disk
- Can be set narrowly, for one role or one session, instead of globally

**Cons and trade-offs**

- Multiplied per sort node and per connection: a global increase can exhaust RAM under load
- Only helps queries that actually spill; the everyday metric queries here do not

### Allow more parallel workers per query

*Later / if needed · measured here · found with: not covered by a check: measured by hand in the showcase*

max_parallel_workers_per_gather is 2. Setting it to 4 helps large aggregates.

**Evidence**

- Showcase demo 14, aggregating 15M archive rows: 3.83 s with 1 worker, 1.99 s with 2, 1.88 s with 4, 1.61 s with 6

**Pros**

- Faster reports and archive-wide aggregates
- Reload only, no restart

**Cons and trade-offs**

- Diminishing returns past 4 workers: the scan becomes I/O bound, not CPU bound
- Each parallel query occupies several worker slots, so many concurrent reports can starve each other
- The load test's queries are mostly small; this helps reporting, not the API path

### Lower random_page_cost for SSD storage

*Later / if needed · estimated, not measured · found with: loadtest run + compare, one setting at a time*

random_page_cost is 4, a spinning-disk default. On NVMe, 1.1 is the usual choice.

**Evidence**

- The storage here is an NVMe SSD; measured average read time per page is 1.4 µs
- Several demos show the planner switching to sequential scans where an index scan was available

**Pros**

- The planner stops over-estimating the cost of index scans, which suits this workload
- Reload only, and easy to revert

**Cons and trade-offs**

- Not measured here. No before/after run was done with this setting
- Affects every query on the instance: some plans will change, not all for the better
- Should be tested with the load test before being applied anywhere real

### Tune autovacuum for the metric table

*Worth doing · measured here · found with: diagnose (dead-rows)*

Lower autovacuum_vacuum_scale_factor for this table, e.g. ALTER TABLE metric SET (autovacuum_vacuum_scale_factor = 0.02);

**Evidence**

- Load test, mixed scenario at 16 clients: 298,000 dead rows in metric after 5 minutes, autovacuum never ran during the run
- Default scale factor 0.2 means a 5M-row table waits for 1M dead rows before a vacuum

**Pros**

- Keeps the table from bloating between archive runs, which delete in bulk
- Keeps statistics fresher, which matters after big deletes (see showcase demo 01)

**Cons and trade-offs**

- More frequent vacuums cost I/O while running
- The archive job's bulk deletes will still create bursts of dead rows

## Situational

Only worth it if the matching feature or query pattern actually exists.

### Covering index for the top-APIs query

*Later / if needed · measured here · found with: explain (filter-waste)*

CREATE INDEX ... ON metric (date_c) INCLUDE (implementedbypartialfunction, implementedinversion, duration);

**Evidence**

- Showcase demo 07: 50-116 ms → 36-41 ms (1.3-3x), answered from the index alone
- Cost: 299 MB against 108 MB for the plain date index; 10,000 inserts ~20% slower

**Pros**

- Turns a dashboard query into an index-only scan

**Cons and trade-offs**

- Three times the size of the plain date index, on the table that receives every insert
- The materialized view (above) solves the same query far better; pick one, not both

### Partial index for error dashboards

*Later / if needed · measured here · found with: diagnose (missing-index), explain*

CREATE INDEX ... ON metric (date_c) WHERE httpcode >= 400;

**Evidence**

- Showcase demo 08: 8.9 MB against 151 MB for the full (httpcode, date_c) index, and at least as fast (9-12 ms vs 15-16 ms; 29-87 ms with no index)

**Pros**

- 17x smaller than the full index, so it stays cached
- Costs nothing when rows outside the predicate are written

**Cons and trade-offs**

- Only used by queries whose WHERE matches the predicate
- Worth it only if an error view is actually queried regularly

### Trigram index for URL substring search

*Only on demand · measured here · found with: explain (seq-scan on a LIKE filter)*

CREATE INDEX ... ON metric USING gin (url gin_trgm_ops);

**Evidence**

- Showcase demo 18: LIKE '%dynamic-entity%' 379 ms → 8.9 ms (42x), and ILIKE uses it too
- Cost: 184 MB (18% of the table), 28 s to build

**Pros**

- Makes a search box over URLs usable

**Cons and trade-offs**

- Large index and slower writes, for a feature that may not exist
- Only add it if users really search URLs by substring

### BRIN instead of B-tree on metricarchive.date_c

*Only on demand · measured here · found with: not covered by a check: an index-size trade-off, measured by hand*

CREATE INDEX ... ON metricarchive USING brin (date_c); and drop the B-tree.

**Evidence**

- Showcase demo 17: 136 kB against 326 MB (2,400x smaller); one day 762 ms → 14 ms without any index, but the B-tree is still faster: 3.4-4.6 ms vs 14-18 ms for a day, 40-46 ms vs 265-498 ms for a month

**Pros**

- Almost free in disk terms, and good enough for an archive that is rarely queried
- Works because the archive is append-only and ordered by date

**Cons and trade-offs**

- 3-10x slower than the B-tree for the same query
- Only sensible if archive queries are rare and index size matters

### Partition metricarchive by month

*Later / if needed · estimated, not measured · found with: not covered by a check: a design change, measure with loadtest*

Range partitioning on date_c, so expiring old data becomes DROP PARTITION.

**Evidence**

- The archive job currently deletes expired rows with a bulk DELETE, which rewrites index entries and leaves dead rows behind

**Pros**

- Expiry becomes instant and creates no bloat
- Queries for one month touch one partition

**Cons and trade-offs**

- Not measured here. No partitioned variant was benchmarked
- A real migration of a 15M-row table, plus application and job changes
- Every index becomes per-partition; queries without a date filter get slower

## Tried and not recommended

Common advice that did not hold up on this data.

### Rewriting OR as UNION

*Skip · measured here · found with: showcase demo 05 (myth check)*

Common advice says OR across columns prevents index use and should be rewritten as UNION.

**Evidence**

- Showcase demo 05: OR across two indexed columns is answered with a BitmapOr of both indexes, 158 ms against 194 ms for the UNION rewrite
- UNION only wins for 'newest N' queries where each side reads its own index in order, and there both finish in about 1 ms

**Pros**

- None worth the rewrite on PostgreSQL

**Cons and trade-offs**

- More SQL to maintain for no measured gain
- The real fix for a slow OR is an index on the column that lacks one

### Forcing plans (hints, enable_* switches)

*Skip · measured here · found with: showcase demo 15 (myth check)*

MySQL-style optimizer hints have no PostgreSQL equivalent; enable_seqscan and friends exist only as session switches.

**Evidence**

- Showcase demo 15: the planner's own choice (0.7-5.6 ms) beat every alternative it had rejected (bitmap + sort 19-32 ms, full scan 190-242 ms)

**Pros**

- Useful as a debugging tool to see which plan was rejected

**Cons and trade-offs**

- Not a production fix: a forced plan stops adapting when the data changes
- When the planner is wrong, the cause is usually stale statistics or a missing index

### Trusting EXPLAIN ANALYZE alone

*Skip · measured here · found with: explain and pg_stat_statements both see what EXPLAIN hides*

Not a change to make, a habit to drop: EXPLAIN ANALYZE does not send rows to a client.

**Evidence**

- Showcase demo 02: after a wide column is added, EXPLAIN reports 7.8 → 10.2 ms while the client sees 10.5 → 123 ms, because large values live out of line and EXPLAIN never fetches them
- pg_stat_statements did show it: 111 ms against EXPLAIN's 19 ms

**Pros**

- EXPLAIN stays the right tool for plan shape, row estimates and buffers

**Cons and trade-offs**

- It hides everything that happens while delivering rows
- Use client-side timings or pg_stat_statements for the real cost; PostgreSQL 17 adds EXPLAIN (ANALYZE, SERIALIZE) for this
