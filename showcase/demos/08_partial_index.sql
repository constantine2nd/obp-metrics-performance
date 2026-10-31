-- @title Partial index for a filtered subset
-- @category Indexing
-- @tag confirmed
-- @claim Index only the rows you query: smaller, fits in memory better, faster, and does not slow down writes of other rows.
-- @verdict Confirmed. The partial index on error rows is 8.9 MB vs 151 MB for the full (httpcode, date_c) index, 17x
-- @verdict smaller, and at least as fast ({t:partial_index} vs {t:full_index}; {t:no_index} without either). The consumer
-- @verdict index without NULLs is 13 MB vs 34 MB. Small indexes stay in the 128 MB cache and cost nothing when rows outside
-- @verdict the predicate are written.
-- @compare no_index partial_index

-- @setup
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_http_date ON metric (httpcode, date_c);
CREATE INDEX sc_metric_errors_date ON metric (date_c) WHERE httpcode >= 400;
CREATE INDEX sc_metric_consumer_notnull ON metric (consumerid) WHERE consumerid IS NOT NULL;
VACUUM ANALYZE metric;

-- @info Sizes: 8% of calls are errors, 61% have no consumer id
SELECT indexrelname AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       CASE indexrelname WHEN 'sc_metric_http_date' THEN 'full (httpcode, date_c)'
                         WHEN 'sc_metric_errors_date' THEN 'partial: WHERE httpcode >= 400'
                         WHEN 'metric_consumerid' THEN 'full, includes NULLs'
                         ELSE 'partial: WHERE consumerid IS NOT NULL' END AS kind
  FROM pg_stat_user_indexes
 WHERE indexrelname IN ('sc_metric_http_date', 'sc_metric_errors_date', 'metric_consumerid', 'sc_metric_consumer_notnull')
 ORDER BY indexrelname;

-- @case no_index rollback : errors per day, last 30 days, without either error index
DROP INDEX sc_metric_http_date;
DROP INDEX sc_metric_errors_date;
-- @explain
SELECT date_trunc('day', date_c) AS day, count(*) FROM metric
 WHERE httpcode >= 400 AND date_c >= localtimestamp - interval '30 days' GROUP BY 1 ORDER BY 1;

-- @case full_index rollback : same with the full (httpcode, date_c) index
DROP INDEX sc_metric_errors_date;
-- @explain
SELECT date_trunc('day', date_c) AS day, count(*) FROM metric
 WHERE httpcode >= 400 AND date_c >= localtimestamp - interval '30 days' GROUP BY 1 ORDER BY 1;

-- @case partial_index rollback : same with the partial index (only error rows)
DROP INDEX sc_metric_http_date;
-- @explain
SELECT date_trunc('day', date_c) AS day, count(*) FROM metric
 WHERE httpcode >= 400 AND date_c >= localtimestamp - interval '30 days' GROUP BY 1 ORDER BY 1;

-- @cleanup
DROP INDEX IF EXISTS sc_metric_http_date;
DROP INDEX IF EXISTS sc_metric_errors_date;
DROP INDEX IF EXISTS sc_metric_consumer_notnull;
