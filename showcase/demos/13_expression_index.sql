-- @title Expression index
-- @category Indexing
-- @tag confirmed
-- @claim Index the result of a function so queries filtering on that expression can use an index.
-- @verdict Confirmed. split_part(url, '/', 3) = 'v4.0.0' scanned all 5M rows ({t:function_no_index}); with a 33 MB
-- @verdict expression index it took {t:expression_index} ({x:function_no_index/expression_index}). Run ANALYZE after
-- @verdict creating it so the planner gets statistics for the expression.
-- @compare function_no_index expression_index

-- @case function_no_index : calls to a rare API version, split_part(url, '/', 3) = 'v4.0.0'
SELECT count(*), avg(duration) FROM metric WHERE split_part(url, '/', 3) = 'v4.0.0';

-- @step expression index + ANALYZE (expression indexes get their own statistics)
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_api_version ON metric ((split_part(url, '/', 3)));
ANALYZE metric;

-- @case expression_index : same query with the expression index
SELECT count(*), avg(duration) FROM metric WHERE split_part(url, '/', 3) = 'v4.0.0';

-- @info Index size
SELECT pg_size_pretty(pg_relation_size('sc_metric_api_version')) AS expression_index_size;

-- @cleanup
DROP INDEX IF EXISTS sc_metric_api_version;
ANALYZE metric;
