-- @title Covering index for a frequent query
-- @category Indexing
-- @tag confirmed
-- @claim A covering index holds every column the query needs, so the database never touches the table.
-- @claim Filter columns first, then sort columns, then the selected ones. Costs space and write speed.
-- @verdict Confirmed, with a trade-off. The covering index (date_c INCLUDE function, version, duration) turned the top-APIs
-- @verdict query into an index-only scan: {t:date_index} to {t:covering} ({x:date_index/covering}). Price: 299 MB vs 108 MB
-- @verdict for the plain date index, and 10,000 inserts took {pct:insert_after/insert_before} time. Worth it for a
-- @verdict dashboard query that runs constantly, not for every query.
-- @compare date_index covering

-- @case date_index : top 10 APIs of the last 30 days with the existing index on date_c
SELECT implementedbypartialfunction, implementedinversion, count(*) AS calls, avg(duration) AS avg_ms
  FROM metric WHERE date_c >= localtimestamp - interval '30 days'
 GROUP BY 1, 2 ORDER BY calls DESC LIMIT 10;

-- @case insert_before rollback : write cost: 10,000 inserts, 6 indexes on metric
INSERT INTO metric (url, duration, date_c, consumerid, implementedbypartialfunction, implementedinversion, correlationid, httpcode, verb)
SELECT url, duration, localtimestamp, consumerid, implementedbypartialfunction, implementedinversion, gen_random_uuid()::text, httpcode, verb
  FROM lt_tpl_metric WHERE k <= 10000;

-- @step covering index: date_c + INCLUDE the grouped and averaged columns
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_date_covering ON metric (date_c)
  INCLUDE (implementedbypartialfunction, implementedinversion, duration);
VACUUM metric;

-- @case covering : same query, answered from the covering index only
SELECT implementedbypartialfunction, implementedinversion, count(*) AS calls, avg(duration) AS avg_ms
  FROM metric WHERE date_c >= localtimestamp - interval '30 days'
 GROUP BY 1, 2 ORDER BY calls DESC LIMIT 10;

-- @info Index sizes: plain date index vs covering index
SELECT indexrelname AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_stat_user_indexes WHERE indexrelname IN ('metric_date_c', 'sc_metric_date_covering');

-- @case insert_after rollback : the same 10,000 inserts with the covering index as a 7th index
INSERT INTO metric (url, duration, date_c, consumerid, implementedbypartialfunction, implementedinversion, correlationid, httpcode, verb)
SELECT url, duration, localtimestamp, consumerid, implementedbypartialfunction, implementedinversion, gen_random_uuid()::text, httpcode, verb
  FROM lt_tpl_metric WHERE k <= 10000;

-- @cleanup
DROP INDEX IF EXISTS sc_metric_date_covering;
VACUUM metric;
