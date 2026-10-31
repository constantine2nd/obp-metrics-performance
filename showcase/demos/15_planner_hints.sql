-- @title Optimizer hints (MySQL) vs the PostgreSQL planner
-- @category Planner (MySQL-style hints)
-- @tag different
-- @claim Force index usage or join order when the optimizer makes a bad choice; use sparingly.
-- @verdict PostgreSQL has no hints, and here it did not need them. The planner's choice ({t:planner_choice}) beat the
-- @verdict alternatives it had rejected: bitmap scan + sort {t:no_index_scan}, full scan {t:seqscan_only}. The enable_*
-- @verdict switches are an experiment tool to see those alternatives, not a production fix; when the planner picks badly,
-- @verdict fix statistics (demo 01) or indexes first. The pg_hint_plan extension exists if hints are really needed.
-- @compare seqscan_only planner_choice

-- PostgreSQL has no hints (the pg_hint_plan extension adds them). The enable_* settings switch plan types off
-- for one session: useful to see what the planner rejected, not for production.

-- @case planner_choice : the metrics list query, plan chosen by the planner
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC LIMIT 50;

-- @case no_index_scan : enable_indexscan = off (planner falls back to a bitmap scan on consumerid + sort)
SET enable_indexscan = off;
-- @explain
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC LIMIT 50;

-- @case seqscan_only : all index access off: the plan a missing index would give
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_indexonlyscan = off;
-- @explain
SELECT id, date_c, url, duration, httpcode FROM metric
 WHERE consumerid = 'consumer-010' AND date_c >= localtimestamp - interval '30 days' ORDER BY date_c DESC LIMIT 50;
