-- @title N+1 queries vs one query
-- @category Anti-pattern
-- @tag confirmed
-- @claim One query for a list, then one query per item: with 100 items that is 101 queries when 1 or 2 would do.
-- @verdict Confirmed, but the cost is round trips, not the database. 1,001 queries took {t:n_plus_1} vs {t:lateral_client}
-- @verdict for one LATERAL query ({x:n_plus_1/lateral_client}) over a local Unix socket, where a round trip costs well
-- @verdict under 0.1 ms. Over a network with 1 ms latency the N+1 version would add about 1 s; an ORM talking to a remote
-- @verdict database pays that on every page load.
-- @compare n_plus_1 lateral_client

-- @setup
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_user_date ON metric (userid, date_c);

-- Typical ORM screen: the latest 1000 failed calls, and for each one the same user's previous call.

-- @case n_plus_1 script : 1 query for the failed calls + 1 query per call for the previous call (1000 round trips)
SELECT format('SELECT id, date_c, url, httpcode FROM metric WHERE userid = %L AND date_c < %L '
              'ORDER BY date_c DESC LIMIT 1', userid, date_c)
  FROM (SELECT userid, date_c FROM metric WHERE httpcode >= 400 AND userid IS NOT NULL
         ORDER BY date_c DESC LIMIT 1000) f \gexec

-- @case lateral_client script : the same data in one query with a LATERAL join (1 round trip)
SELECT f.id, f.date_c, f.url, p.id AS prev_id, p.date_c AS prev_date, p.url AS prev_url, p.httpcode AS prev_code
  FROM (SELECT id, userid, date_c, url FROM metric WHERE httpcode >= 400 AND userid IS NOT NULL
         ORDER BY date_c DESC LIMIT 1000) f
  LEFT JOIN LATERAL (SELECT id, date_c, url, httpcode FROM metric m
                      WHERE m.userid = f.userid AND m.date_c < f.date_c
                      ORDER BY m.date_c DESC LIMIT 1) p ON true;

-- @case lateral_server : server-side execution time of the single query
SELECT f.id, f.date_c, f.url, p.id AS prev_id, p.date_c AS prev_date, p.url AS prev_url, p.httpcode AS prev_code
  FROM (SELECT id, userid, date_c, url FROM metric WHERE httpcode >= 400 AND userid IS NOT NULL
         ORDER BY date_c DESC LIMIT 1000) f
  LEFT JOIN LATERAL (SELECT id, date_c, url, httpcode FROM metric m
                      WHERE m.userid = f.userid AND m.date_c < f.date_c
                      ORDER BY m.date_c DESC LIMIT 1) p ON true;

-- @cleanup
DROP INDEX IF EXISTS sc_metric_user_date;
