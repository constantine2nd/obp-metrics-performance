-- Scales the copied metric tables up to lt.n_metric / lt.n_archive rows.
-- Rows are cloned from the real rows (same mix of consumers, URLs, functions, verbs, HTTP codes),
-- with new correlation ids, varied durations and dates spread evenly over the target period.
-- Called by 01_build_base.sh, which sets the lt.* settings.

\set ON_ERROR_STOP on
SET client_min_messages = notice;
SET maintenance_work_mem = '1GB';
SET max_parallel_maintenance_workers = 4;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Templates: the real rows, numbered 1..N, used as the source for cloning and for w_insert.sql.
CREATE TABLE lt_tpl_metric  AS SELECT row_number() OVER (ORDER BY id) AS k, * FROM metric;
CREATE TABLE lt_tpl_archive AS SELECT row_number() OVER (ORDER BY id) AS k, * FROM metricarchive;
ALTER TABLE lt_tpl_metric  ADD PRIMARY KEY (k);
ALTER TABLE lt_tpl_archive ADD PRIMARY KEY (k);

-- Parameter pools for the workload scripts (picked by random k).
CREATE TABLE lt_values (kind text, k int, val text, PRIMARY KEY (kind, k));
INSERT INTO lt_values
SELECT kind, row_number() OVER (PARTITION BY kind ORDER BY val), val
  FROM (SELECT DISTINCT 'consumer' AS kind, consumerid AS val FROM metric WHERE consumerid <> ''
        UNION SELECT DISTINCT 'function', implementedbypartialfunction FROM metric WHERE implementedbypartialfunction <> ''
        UNION SELECT DISTINCT 'archive_consumer', consumerid FROM metricarchive WHERE consumerid <> ''
        UNION SELECT DISTINCT 'archive_url', url FROM metricarchive WHERE url <> '') v;

-- Secondary indexes are dropped for the bulk load and rebuilt afterwards (much faster).
CREATE TABLE lt_saved_indexes AS
SELECT i.indexrelid::regclass::text AS name, pg_get_indexdef(i.indexrelid) AS def
  FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid
 WHERE t.relname IN ('metric', 'metricarchive') AND NOT i.indisprimary;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT name FROM lt_saved_indexes LOOP
    EXECUTE 'DROP INDEX ' || r.name;
  END LOOP;
END $$;

-- metric: n_metric rows over the last metric_days days.
DO $$
DECLARE
  n      bigint    := current_setting('lt.n_metric')::bigint;
  t_to   timestamp := localtimestamp;
  t_from timestamp := localtimestamp - make_interval(days => current_setting('lt.metric_days')::int);
  ntpl   bigint    := (SELECT count(*) FROM lt_tpl_metric);
  chunk  bigint    := 500000;
  lo     bigint    := 1;
BEGIN
  WHILE lo <= n LOOP
    INSERT INTO metric (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail,
                        consumerid, appname, implementedinversion, verb, correlationid, httpcode, responsebody,
                        sourceip, targetip, consent_reference_id, apiinstanceid)
    SELECT t.url, (t.duration * (0.5 + random()))::bigint, t.username,
           t_from + (t_to - t_from) * (g::float8 / n),
           t.userid, t.implementedbypartialfunction, t.developeremail, t.consumerid, t.appname,
           t.implementedinversion, t.verb, gen_random_uuid()::text, t.httpcode, t.responsebody,
           t.sourceip, t.targetip, t.consent_reference_id, t.apiinstanceid
      FROM generate_series(lo, least(lo + chunk - 1, n)) g
      JOIN lt_tpl_metric t ON t.k = 1 + (g * 2654435761) % ntpl;
    COMMIT;
    RAISE NOTICE '% metric: % / % rows', to_char(clock_timestamp(), 'HH24:MI:SS'), least(lo + chunk - 1, n), n;
    lo := lo + chunk;
  END LOOP;
END $$;

-- metricarchive: n_archive rows over the archive_days days before the metric period.
DO $$
DECLARE
  n      bigint    := current_setting('lt.n_archive')::bigint;
  t_to   timestamp := localtimestamp - make_interval(days => current_setting('lt.metric_days')::int);
  t_from timestamp := localtimestamp - make_interval(days => current_setting('lt.metric_days')::int
                                                          + current_setting('lt.archive_days')::int);
  ntpl   bigint    := (SELECT count(*) FROM lt_tpl_archive);
  chunk  bigint    := 500000;
  lo     bigint    := 1;
BEGIN
  WHILE lo <= n LOOP
    INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction,
                               developeremail, consumerid, appname, implementedinversion, verb, correlationid,
                               httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id,
                               apiinstanceid)
    SELECT t.url, (t.duration * (0.5 + random()))::bigint, t.username,
           t_from + (t_to - t_from) * (g::float8 / n),
           t.userid, t.implementedbypartialfunction, t.developeremail, t.consumerid, t.appname,
           t.implementedinversion, t.verb, gen_random_uuid()::text, t.httpcode, 100000000 + g,
           t.responsebody, t.sourceip, t.targetip, t.consent_reference_id, t.apiinstanceid
      FROM generate_series(lo, least(lo + chunk - 1, n)) g
      JOIN lt_tpl_archive t ON t.k = 1 + (g * 2654435761) % ntpl;
    COMMIT;
    RAISE NOTICE '% metricarchive: % / % rows', to_char(clock_timestamp(), 'HH24:MI:SS'), least(lo + chunk - 1, n), n;
    lo := lo + chunk;
  END LOOP;
END $$;

-- Rebuild the original indexes.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT name, def FROM lt_saved_indexes ORDER BY name LOOP
    EXECUTE r.def;
    RAISE NOTICE '% index %', to_char(clock_timestamp(), 'HH24:MI:SS'), r.name;
  END LOOP;
END $$;

\echo 'vacuum + analyze ...'
VACUUM (ANALYZE) metric;
VACUUM (ANALYZE) metricarchive;
ANALYZE lt_tpl_metric, lt_tpl_archive, lt_values;
CHECKPOINT;

SELECT relname AS "table", to_char(reltuples, 'FM999,999,999') AS rows,
       pg_size_pretty(pg_table_size(oid)) AS data, pg_size_pretty(pg_indexes_size(oid)) AS indexes
  FROM pg_class WHERE relname IN ('metric', 'metricarchive') ORDER BY 1;
