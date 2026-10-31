-- @title Stored generated column
-- @category Indexing (generated columns)
-- @tag confirmed
-- @claim Store a computed value as a generated column and index it; trades storage for query speed.
-- @verdict Confirmed, though in PostgreSQL an expression index does the same without storing a column. The generated column
-- @verdict + index took the query from {t:expression_no_index} to {t:generated_column}
-- @verdict ({x:expression_no_index/generated_column}), like the expression index in demo 13, but added 39 MB to a 423 MB
-- @verdict table (+9%) and rewrote the whole table. Use a generated column when the value is also selected or reused in
-- @verdict many queries.
-- @compare expression_no_index generated_column

-- @setup
DROP TABLE IF EXISTS sc_gen;
CREATE TABLE sc_gen AS SELECT id, url, duration, date_c FROM metric;
ANALYZE sc_gen;

-- @info Table size before (copy of metric with 4 columns)
SELECT pg_size_pretty(pg_table_size('sc_gen')) AS table_size;

-- @case expression_no_index : split_part(url, '/', 3) = 'v4.0.0', computed for every row
SELECT count(*), avg(duration) FROM sc_gen WHERE split_part(url, '/', 3) = 'v4.0.0';

-- @step add STORED generated column api_version + index (rewrites the table)
SET maintenance_work_mem = '1GB';
ALTER TABLE sc_gen ADD COLUMN api_version text GENERATED ALWAYS AS (split_part(url, '/', 3)) STORED;
CREATE INDEX sc_gen_api_version ON sc_gen (api_version);
ANALYZE sc_gen;

-- @case generated_column : WHERE api_version = 'v4.0.0'
SELECT count(*), avg(duration) FROM sc_gen WHERE api_version = 'v4.0.0';

-- @info Table size after: the stored value costs space in every row
SELECT pg_size_pretty(pg_table_size('sc_gen')) AS table_size,
       pg_size_pretty(pg_relation_size('sc_gen_api_version')) AS index_size;

-- @cleanup
DROP TABLE IF EXISTS sc_gen;
