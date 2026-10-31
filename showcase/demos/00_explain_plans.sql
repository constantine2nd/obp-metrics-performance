-- @title Reading an execution plan
-- @category Execution plans
-- @tag confirmed
-- @claim EXPLAIN shows the plan without running the query; EXPLAIN ANALYZE runs it and adds real timings.
-- @claim Watch estimated vs actual rows, scan types (Seq Scan vs Index Scan), join methods and the costliest node.
-- @verdict Confirmed. The plan shows the query walking metric_date_c backwards and filtering by consumer: thousands of rows
-- @verdict are read and thrown away to return 50 (Rows Removed by Filter). BUFFERS adds where the pages came from: hit =
-- @verdict already in shared_buffers, read = requested from the OS or the disk. A cold first run reads, a repeat hits; that
-- @verdict explains most 'same query, different speed' puzzles (compare 'First run' with 'Time' in every table of this
-- @verdict report).

-- @info 1. EXPLAIN: the plan the optimizer picked, estimates only (the query is not executed)
EXPLAIN
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days'
 ORDER BY date_c DESC LIMIT 50;

-- @info 2. EXPLAIN (ANALYZE, BUFFERS): executed; actual rows, time per node and pages (hit = cache, read = disk/OS)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days'
 ORDER BY date_c DESC LIMIT 50;

-- @case metrics_list : GET /management/metrics for one consumer, last 30 days, newest 50
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days'
 ORDER BY date_c DESC LIMIT 50;
