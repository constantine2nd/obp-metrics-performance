-- @title Substring search: LIKE '%...%' vs trigram index
-- @category Indexing (text search)
-- @tag confirmed
-- @claim A leading wildcard (LIKE '%...%') cannot use a normal index; a text-search index turns the full scan into milliseconds.
-- @claim For URL substrings PostgreSQL's pg_trgm trigram index is the fitting tool.
-- @verdict Confirmed. LIKE '%dynamic-entity%' scanned all 5M rows ({t:like_no_index}); a GIN trigram index made it
-- @verdict {t:like_trgm} ({x:like_no_index/like_trgm}), and ILIKE uses it too. Cost: a 184 MB index (18% of the table) and
-- @verdict a 28 s build. Worth it behind a URL search box, not as a default.
-- @compare like_no_index like_trgm

-- @case like_no_index : url LIKE '%dynamic-entity%' (2.5k of 5M rows)
SELECT count(*), avg(duration) FROM metric WHERE url LIKE '%dynamic-entity%';

-- @step GIN trigram index on url
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_url_trgm ON metric USING gin (url gin_trgm_ops);

-- @case like_trgm : same query with the trigram index
SELECT count(*), avg(duration) FROM metric WHERE url LIKE '%dynamic-entity%';

-- @case ilike_trgm : case-insensitive ILIKE uses it too
SELECT count(*), avg(duration) FROM metric WHERE url ILIKE '%Dynamic-Entity%';

-- @info Index size
SELECT pg_size_pretty(pg_relation_size('sc_metric_url_trgm')) AS trigram_index_size,
       pg_size_pretty(pg_table_size('metric')) AS metric_table_size;

-- @cleanup
DROP INDEX IF EXISTS sc_metric_url_trgm;
