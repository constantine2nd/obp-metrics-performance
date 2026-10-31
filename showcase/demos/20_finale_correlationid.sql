-- @title Finale: tracing one request by correlation id
-- @category Case study
-- @tag confirmed
-- @claim Combine the patterns on one real slow query and measure every step.
-- @verdict One missing index was the whole story. Tracing a request scanned 20M rows: {t:original} ({first:original} on the
-- @verdict first run; 1.55 s under load in the load test). Indexing only metric left the archive scan ({t:metric_indexed}).
-- @verdict With B-tree indexes on both tables the lookup takes {t:both_btree}, {x:original/both_btree} faster. Costs: 283
-- @verdict MB + 849 MB of index (a hash index on the archive is 513 MB, 40% smaller and just as fast for = lookups), and
-- @verdict random UUID keys made 10,000 inserts {x:insert_with_index/insert_no_index} slower because each insert lands on a
-- @verdict random index page. Recommendation: index metric.correlationid (loadtest/tuning/02_index_correlationid.sql), and
-- @verdict hash-index metricarchive.correlationid if old requests are traced often.
-- @compare original both_btree

-- Support gets a correlation id from a customer complaint. The request can be recent (metric) or old
-- (metricarchive), so both tables are searched. The load test found the metric part to be the slowest query:
-- 1.55 s mean, 70% of all read time (loadtest/results/check_full). No index exists on correlationid.

-- @case original : SELECT * from both tables, no index (5M + 15M rows scanned)
SELECT correlationid AS cid FROM metricarchive WHERE id >= 8000000 ORDER BY id LIMIT 1 \gset
-- @explain
SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;

-- @case insert_no_index rollback : write cost baseline: 10,000 inserts into metric
INSERT INTO metric (url, duration, date_c, consumerid, implementedbypartialfunction, correlationid, httpcode, verb)
SELECT url, duration, localtimestamp, consumerid, implementedbypartialfunction, gen_random_uuid()::text, httpcode, verb
  FROM lt_tpl_metric WHERE k <= 10000;

-- @step 1. B-tree index on metric.correlationid (the live table)
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_correlationid ON metric (correlationid);

-- @case metric_indexed : metric part is now an index lookup, the archive is still scanned
SELECT correlationid AS cid FROM metricarchive WHERE id >= 8000000 ORDER BY id LIMIT 1 \gset
-- @explain
SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;

-- @case insert_with_index rollback : write cost: the same 10,000 inserts with the extra index
INSERT INTO metric (url, duration, date_c, consumerid, implementedbypartialfunction, correlationid, httpcode, verb)
SELECT url, duration, localtimestamp, consumerid, implementedbypartialfunction, gen_random_uuid()::text, httpcode, verb
  FROM lt_tpl_metric WHERE k <= 10000;

-- @step 2. B-tree and hash index on metricarchive.correlationid (15M rows) to compare
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_archive_correlationid ON metricarchive (correlationid);
CREATE INDEX sc_archive_correlationid_hash ON metricarchive USING hash (correlationid);

-- @case both_btree rollback : both tables through a B-tree index
DROP INDEX sc_archive_correlationid_hash;
SELECT correlationid AS cid FROM metricarchive WHERE id >= 8000000 ORDER BY id LIMIT 1 \gset
-- @explain
SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;

-- @case archive_hash rollback : archive through the hash index instead
DROP INDEX sc_archive_correlationid;
SELECT correlationid AS cid FROM metricarchive WHERE id >= 8000000 ORDER BY id LIMIT 1 \gset
-- @explain
SELECT * FROM (
  SELECT 'metric' AS source, id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metric WHERE correlationid = :'cid'
  UNION ALL
  SELECT 'metricarchive', id, date_c, url, verb, httpcode, duration, consumerid, userid,
         implementedbypartialfunction, responsebody FROM metricarchive WHERE correlationid = :'cid') t;

-- @info Index cost: sizes (correlation ids are 36-character UUID strings)
SELECT indexrelname AS index, relname AS "table", pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_stat_user_indexes
 WHERE indexrelname IN ('sc_metric_correlationid', 'sc_archive_correlationid', 'sc_archive_correlationid_hash')
 ORDER BY pg_relation_size(indexrelid);

-- @cleanup
DROP INDEX IF EXISTS sc_metric_correlationid;
DROP INDEX IF EXISTS sc_archive_correlationid;
DROP INDEX IF EXISTS sc_archive_correlationid_hash;
VACUUM metric;
