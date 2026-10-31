-- @title Materialized view for dashboard aggregations
-- @category Query pattern
-- @tag confirmed
-- @claim Pre-compute expensive aggregations that can be slightly stale; queries read the result instantly.
-- @claim Refresh periodically, CONCURRENTLY to keep readers working.
-- @verdict Confirmed. A daily materialized view (69,620 rows, 11 MB, built from 5M rows / 1.4 GB) answers the 365-day
-- @verdict top-APIs query in {t:mv_365} instead of {t:raw_365} ({x:raw_365/mv_365}) and the 7-day one {x:raw_7/mv_7}
-- @verdict faster. A full REFRESH takes {t:refresh} ({t:refresh_concurrently} CONCURRENTLY, which does not block readers),
-- @verdict so refreshing every few minutes is cheap.
-- @compare raw_365 mv_365

-- @setup
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

-- @info Materialized view: rows and size vs the metric table
SELECT (SELECT count(*) FROM sc_metric_daily) AS mv_rows,
       pg_size_pretty(pg_total_relation_size('sc_metric_daily')) AS mv_size,
       (SELECT reltuples::bigint FROM pg_class WHERE relname = 'metric') AS metric_rows,
       pg_size_pretty(pg_total_relation_size('metric')) AS metric_size;

-- @case raw_7 : top 10 APIs over 7 days from metric
SELECT implementedbypartialfunction, count(*) AS calls, sum(duration) / count(*) AS avg_ms
  FROM metric WHERE date_c >= current_date - 7 GROUP BY 1 ORDER BY calls DESC LIMIT 10;

-- @case mv_7 : same from the materialized view
SELECT fn, sum(calls) AS calls, sum(total_duration) / sum(calls) AS avg_ms
  FROM sc_metric_daily WHERE day >= current_date - 7 GROUP BY 1 ORDER BY calls DESC LIMIT 10;

-- @case raw_365 : top 10 APIs over a year from metric
SELECT implementedbypartialfunction, count(*) AS calls, sum(duration) / count(*) AS avg_ms
  FROM metric WHERE date_c >= current_date - 365 GROUP BY 1 ORDER BY calls DESC LIMIT 10;

-- @case mv_365 : same from the materialized view
SELECT fn, sum(calls) AS calls, sum(total_duration) / sum(calls) AS avg_ms
  FROM sc_metric_daily WHERE day >= current_date - 365 GROUP BY 1 ORDER BY calls DESC LIMIT 10;

-- @case refresh script repeat=1 : REFRESH MATERIALIZED VIEW (blocks readers while it runs)
REFRESH MATERIALIZED VIEW sc_metric_daily;

-- @case refresh_concurrently script repeat=1 : REFRESH ... CONCURRENTLY (readers keep working, slower)
REFRESH MATERIALIZED VIEW CONCURRENTLY sc_metric_daily;

-- @cleanup
DROP MATERIALIZED VIEW IF EXISTS sc_metric_daily;
