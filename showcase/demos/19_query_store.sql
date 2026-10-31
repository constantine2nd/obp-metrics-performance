-- @title Query Store (SQL Server) = pg_stat_statements + pgstat
-- @category Monitoring (Query Store equivalent)
-- @tag equivalent
-- @claim A flight recorder for queries: performance over time, find the worst queries, spot regressions.
-- @verdict The equivalent exists in two parts. pg_stat_statements is PostgreSQL's cumulative query store; the top of this
-- @verdict list is the showcase's own heaviest work (parallel aggregates over the archive, index builds). It keeps no
-- @verdict history: the pgstat tool (../pgstat) adds 15-minute snapshots, time windows and per-query trends, which covers
-- @verdict the 'performance over time' and regression parts.

-- @info Top statements in obp_showcase by total time (pg_stat_statements, what this showcase ran)
SELECT calls, round(total_exec_time::numeric / 1000, 1) AS total_s, round(mean_exec_time::numeric, 1) AS mean_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 90) AS query
  FROM pg_stat_statements
 WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
 ORDER BY total_exec_time DESC LIMIT 10;

-- @info History over time: ../pgstat keeps 15-minute snapshots (pgstat setup, then e.g.)
SELECT 'pgstat total 1h -d obp_showcase    -- what took the time in the last hour' AS command
UNION ALL SELECT 'pgstat trend <queryid> 1w           -- did this query get slower this week?'
UNION ALL SELECT 'pgstat slow 1d -d obp_mapped        -- slowest statements yesterday';
