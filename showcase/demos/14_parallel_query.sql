-- @title Parallel query
-- @category PostgreSQL feature
-- @tag confirmed
-- @claim PostgreSQL can split large scans and aggregations across CPU cores (Parallel Seq Scan, Parallel Aggregate).
-- @verdict Confirmed, with diminishing returns. Aggregating 15M archive rows took {t:workers_0} on one core, {t:workers_2}
-- @verdict with 2 workers (the default), {t:workers_4} with 4 and {t:workers_6} with 6: each extra worker helps less,
-- @verdict because reading 3.5 GB becomes the limit, not CPU. max_parallel_workers_per_gather = 4 on this 4-core / 8-thread
-- @verdict machine helps big reports.
-- @compare workers_0 workers_4

-- Top 10 APIs over the whole archive: 15M rows, 3.6 GB.

-- @case workers_0 : max_parallel_workers_per_gather = 0 (one core)
SET max_parallel_workers_per_gather = 0;
-- @explain
SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

-- @case workers_2 : = 2 (the default)
SET max_parallel_workers_per_gather = 2;
-- @explain
SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

-- @case workers_4 : = 4
SET max_parallel_workers_per_gather = 4;
-- @explain
SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

-- @case workers_6 : = 6
SET max_parallel_workers_per_gather = 6;
-- @explain
SELECT implementedbypartialfunction, count(*), avg(duration) FROM metricarchive GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
