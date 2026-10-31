-- @title BRIN index for time series (PostgreSQL's answer to columnstore-style scans)
-- @category Indexing (columnstore alternative)
-- @tag tradeoff
-- @claim Columnstore indexes make analytical scans over millions of rows 10-100x faster with ~10x compression.
-- @claim PostgreSQL has no columnstore; for append-only time series like metricarchive a BRIN index is the tiny alternative.
-- @verdict BRIN is the size champion, not the speed champion. On metricarchive.date_c it is 136 kB vs 326 MB for the B-tree
-- @verdict (2,400x smaller) and makes one day {x:day_no_index/day_brin} faster than a full scan. The B-tree is still
-- @verdict faster: {t:day_btree} vs {t:day_brin} for a day, {t:month_btree} vs {t:month_brin} for 30 days. BRIN suits a
-- @verdict rarely queried, append-only archive; keep the B-tree for hot queries. It is not a columnstore: PostgreSQL has no
-- @verdict columnar storage without extensions.
-- @compare day_no_index day_brin

-- @setup
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_archive_date_brin ON metricarchive USING brin (date_c);

-- @info Sizes: B-tree vs BRIN on metricarchive.date_c (15M rows)
SELECT indexrelname AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_stat_user_indexes WHERE indexrelname IN ('metricarchive_date_c', 'sc_archive_date_brin');

-- @case day_no_index rollback : one day in the archive, no date index
DROP INDEX metricarchive_date_c;
DROP INDEX sc_archive_date_brin;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 800 AND date_c < current_date - 799;

-- @case day_btree rollback : one day, B-tree only
DROP INDEX sc_archive_date_brin;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 800 AND date_c < current_date - 799;

-- @case day_brin rollback : one day, BRIN only
DROP INDEX metricarchive_date_c;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 800 AND date_c < current_date - 799;

-- @case month_btree rollback : 30 days, B-tree only
DROP INDEX sc_archive_date_brin;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 830 AND date_c < current_date - 800;

-- @case month_brin rollback : 30 days, BRIN only
DROP INDEX metricarchive_date_c;
-- @explain
SELECT count(*), avg(duration) FROM metricarchive WHERE date_c >= current_date - 830 AND date_c < current_date - 800;

-- @cleanup
DROP INDEX IF EXISTS sc_archive_date_brin;
