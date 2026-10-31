-- @title Estimated vs actual rows: stale statistics
-- @category Execution plans
-- @tag confirmed
-- @claim If the database thinks it is processing 100 rows but actually processes 100,000, its optimization decisions
-- @claim will be terrible. Large discrepancies often point to outdated statistics.
-- @verdict Confirmed, dramatically. With statistics from before the new consumer's 1M rows, the planner estimated a few
-- @verdict hundred rows, fetched all 1,000,000 through the consumer index and sorted them ({t:stale}). After ANALYZE (0.2
-- @verdict s) it expects 1M rows, walks the date index backwards and stops after 20 ({t:fresh}): {x:stale/fresh} faster.
-- @verdict Autovacuum re-analyzes only after about 10% of a table changes, so bulk loads and new tenants can outrun it: run
-- @verdict ANALYZE after big loads.
-- @compare stale fresh

-- @setup
SET maintenance_work_mem = '1GB';
DROP TABLE IF EXISTS sc_stale;
-- Half of metric, with autovacuum (and so auto-ANALYZE) switched off for this table.
CREATE TABLE sc_stale WITH (autovacuum_enabled = false) AS SELECT * FROM metric WHERE id % 2 = 0;
CREATE INDEX sc_stale_consumer ON sc_stale (consumerid);
CREATE INDEX sc_stale_date ON sc_stale (date_c);
ANALYZE sc_stale;
-- After the last ANALYZE a new consumer (a bot, a partner's load test) makes 1M calls.
INSERT INTO sc_stale (url, duration, date_c, consumerid, correlationid, httpcode, verb)
SELECT '/obp/v5.1.0/banks', 20, localtimestamp - g * interval '1 second', 'new-bot', gen_random_uuid()::text, 200, 'GET'
  FROM generate_series(1, 1000000) g;

-- @case stale : latest 20 calls of the new consumer, statistics from before its 1M rows
SELECT id, date_c, url, httpcode FROM sc_stale WHERE consumerid = 'new-bot' ORDER BY date_c DESC LIMIT 20;

-- @step ANALYZE
ANALYZE sc_stale;

-- @case fresh : same query after ANALYZE
SELECT id, date_c, url, httpcode FROM sc_stale WHERE consumerid = 'new-bot' ORDER BY date_c DESC LIMIT 20;

-- @cleanup
DROP TABLE IF EXISTS sc_stale;
