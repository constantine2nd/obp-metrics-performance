-- @title SELECT * vs only the needed columns
-- @category Anti-pattern
-- @tag partly
-- @claim SELECT * transfers more data and prevents covering indexes: with only indexed columns the database can
-- @claim answer from the index without touching the table.
-- @verdict Partly confirmed, with a delayed side effect. **SELECT * has a delayed side effect that no test can catch when
-- @verdict the code is written: its cost depends on columns that do not exist yet. When a column is added to the table
-- @verdict later, for example a large text or JSON field, every SELECT * starts reading, transferring and decoding it and
-- @verdict gets slower, without any change to the query and without a new deployment of the code that runs it.** Measured
-- @verdict below: after a migration added a ~2 kB JSON column (table 82 MB to 905 MB), the unchanged SELECT * for one
-- @verdict consumer's 30 days went from {t:wide_star_before} to {t:wide_star_after} ({x:wide_star_after/wide_star_before}
-- @verdict slower), while the explicit-column query stayed at {t:wide_columns_after}. EXPLAIN ANALYZE hides most of it
-- @verdict ({t:wide_star_before_server} to {t:wide_star_after_server}): it never fetches the out-of-line (TOAST) values,
-- @verdict which only happens when rows are really sent to the client. Sending all columns of 96k rows took
-- @verdict {x:star_client/columns_client} longer than 4 columns (rows average 203 vs 83 bytes). The bigger win is the
-- @verdict covering effect: with only indexed columns the query became an Index Only Scan, {t:star_index} to
-- @verdict {t:columns_index_only} ({x:star_index/columns_index_only}), reading {pages:columns_index_only} pages instead of
-- @verdict {pages:star_index}. metric rows are narrow; with large responsebody values the transfer gap grows.
-- @compare star_index columns_index_only

-- @setup
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_consumer_date_incl ON metric (consumerid, date_c) INCLUDE (duration, httpcode);
VACUUM metric;

-- @info Row width: all columns vs the 4 needed ones (average bytes per row, 1% sample)
SELECT round(avg(pg_column_size(m.*))) AS all_columns_bytes,
       round(avg(pg_column_size(ROW(m.id, m.date_c, m.url, m.duration)))) AS four_columns_bytes
  FROM metric m TABLESAMPLE SYSTEM (1);

-- @case star_client script : SELECT * of the last 7 days (~96k rows) sent to the client
SELECT * FROM metric WHERE date_c >= localtimestamp - interval '7 days';

-- @case columns_client script : same rows, only id, date_c, url, duration
SELECT id, date_c, url, duration FROM metric WHERE date_c >= localtimestamp - interval '7 days';

-- @case star_index : SELECT * for one consumer, last 30 days (index + table)
SELECT * FROM metric WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- @case columns_index_only : only columns that are in the index -> Index Only Scan
SELECT date_c, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- Delayed side effect: the same unchanged SELECT * before and after a later migration adds a wide column.
-- Uses a copy of the last 30 days of metric, so the real table is not rewritten.

-- @step copy of the last 30 days of metric (~410k rows) with its index
SET maintenance_work_mem = '1GB';
DROP TABLE IF EXISTS sc_wide;
CREATE TABLE sc_wide AS SELECT * FROM metric WHERE date_c >= localtimestamp - interval '30 days';
CREATE INDEX sc_wide_consumer_date ON sc_wide (consumerid, date_c);
VACUUM ANALYZE sc_wide;

-- @info Table size before the migration
SELECT pg_size_pretty(pg_table_size('sc_wide')) AS table_incl_toast, (SELECT count(*) FROM sc_wide) AS rows;

-- @case wide_star_before script : SELECT * for one consumer, 30 days, sent to the client (before)
SELECT * FROM sc_wide WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- @case wide_columns_before script : the same rows, only the 5 needed columns (before)
SELECT id, date_c, url, duration, httpcode FROM sc_wide
 WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- @case wide_star_before_server : server side of SELECT * (before)
SELECT * FROM sc_wide WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- @step a later migration adds a JSON column (~2 kB per row), no query changes
ALTER TABLE sc_wide ADD COLUMN details text;
UPDATE sc_wide SET details = (SELECT '{"request":{"headers":{},"body":"' || string_agg(md5(sc_wide.id::text || g), '')
                                     || '"},"response":{"status":200}}' FROM generate_series(1, 60) g);
VACUUM FULL sc_wide;
ANALYZE sc_wide;

-- @info Table size after the migration (the new values are stored out of line in the TOAST table)
SELECT pg_size_pretty(pg_table_size('sc_wide')) AS table_incl_toast,
       pg_size_pretty(pg_relation_size((SELECT reltoastrelid FROM pg_class WHERE relname = 'sc_wide'))) AS toast_part,
       round(avg(length(details))) AS avg_details_chars
  FROM sc_wide;

-- @case wide_star_after script : the SAME SELECT * after the migration, sent to the client
SELECT * FROM sc_wide WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- @case wide_columns_after script : the SAME explicit-column query after the migration
SELECT id, date_c, url, duration, httpcode FROM sc_wide
 WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- @case wide_star_after_server : server side of the same SELECT * (after)
SELECT * FROM sc_wide WHERE consumerid = 'consumer-004' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC;

-- @cleanup
DROP INDEX IF EXISTS sc_metric_consumer_date_incl;
DROP TABLE IF EXISTS sc_wide;
