-- @title OR across different columns vs UNION
-- @category Anti-pattern
-- @tag myth
-- @claim OR across different columns often prevents index usage; UNION lets each part use its own index.
-- @verdict A myth for PostgreSQL, true in one case. OR across two indexed columns is answered with a BitmapOr of both
-- @verdict indexes: {t:or_count} vs {t:union_count} for the UNION. OR with an unindexed column does force a full scan
-- @verdict ({t:or_unindexed}). UNION helps for 'newest N' queries where each side reads its own (column, date_c) index in
-- @verdict order: {t:or_latest_rare} vs {t:union_latest_rare} ({x:or_latest_rare/union_latest_rare}), a small absolute
-- @verdict gain.
-- @compare or_latest_rare union_latest_rare

-- @case or_count : consumerid = X OR userid = Y, both columns indexed
SELECT count(*), avg(duration) FROM metric
 WHERE consumerid = 'consumer-010' OR userid = 'user-0002';

-- @case union_count : the same as UNION of two queries
SELECT count(*), avg(duration) FROM (
  SELECT id, duration FROM metric WHERE consumerid = 'consumer-010'
  UNION
  SELECT id, duration FROM metric WHERE userid = 'user-0002') u;

-- @case or_unindexed : consumerid = X OR correlationid = Y, correlationid has no index
SELECT count(*), avg(duration) FROM metric
 WHERE consumerid = 'consumer-010' OR correlationid = '00000000-0000-0000-0000-000000000000';

-- @step indexes that also cover the sort order
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_consumer_date ON metric (consumerid, date_c);
CREATE INDEX sc_metric_user_date ON metric (userid, date_c);

-- @case or_latest : newest 20 calls of consumer X or user Y
SELECT id, date_c, url FROM metric
 WHERE consumerid = 'consumer-010' OR userid = 'user-0002'
 ORDER BY date_c DESC LIMIT 20;

-- @case union_latest : newest 20 of each side, merged
SELECT id, date_c, url FROM (
  (SELECT id, date_c, url FROM metric WHERE consumerid = 'consumer-010' ORDER BY date_c DESC LIMIT 20)
  UNION
  (SELECT id, date_c, url FROM metric WHERE userid = 'user-0002' ORDER BY date_c DESC LIMIT 20)
) u ORDER BY date_c DESC LIMIT 20;

-- @case or_latest_rare : newest 20 calls of a rare consumer OR a rare user (~800 matching rows in 5M)
SELECT id, date_c, url FROM metric
 WHERE consumerid = 'consumer-036' OR userid = 'user-0077'
 ORDER BY date_c DESC LIMIT 20;

-- @case union_latest_rare : same as UNION of two index lookups
SELECT id, date_c, url FROM (
  (SELECT id, date_c, url FROM metric WHERE consumerid = 'consumer-036' ORDER BY date_c DESC LIMIT 20)
  UNION
  (SELECT id, date_c, url FROM metric WHERE userid = 'user-0077' ORDER BY date_c DESC LIMIT 20)
) u ORDER BY date_c DESC LIMIT 20;

-- @cleanup
DROP INDEX IF EXISTS sc_metric_consumer_date;
DROP INDEX IF EXISTS sc_metric_user_date;
