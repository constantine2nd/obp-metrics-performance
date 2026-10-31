-- @title Row-by-row vs batch: the archive job
-- @category Query pattern
-- @tag confirmed
-- @claim Individual operations in loops are death by a thousand cuts; one set-based statement is often 10-100x faster.
-- @verdict Confirmed, and confirmed in OBP's code. Moving 10,000 rows one at a time (20,000 statements) took {t:row_by_row}
-- @verdict vs {t:batch_client} as one DELETE ... RETURNING + INSERT ({x:row_by_row/batch_client}). OBP's
-- @verdict MetricsArchiveScheduler does worse: per row it looks the archive row up by metricId twice (dedup in
-- @verdict saveMetricsArchive, then a verify) and MetricArchive declares no index on metricId, so every archived row costs
-- @verdict two full scans of metricarchive: {div:row_by_row_checked/10} per row at 15M rows, so one scheduled batch of
-- @verdict 10,000 rows would take hours instead of fitting its 10-minute interval. With an index on metricId the same 10
-- @verdict rows took {t:row_by_row_checked_indexed}. It matches the counters in the source OBP database: 1,542 scans of
-- @verdict metricarchive for the 766-row run on 2026-08-19. Fix: add Index(metricId) to MetricArchive.dbIndexes.
-- @compare row_by_row batch_client

-- Moving the 10,000 oldest metric rows to metricarchive, like the OBP archive job. Every case rolls back.

-- @case row_by_row script rollback repeat=3 : INSERT + DELETE per row, 20,000 statements
SELECT format('INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid) SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM metric WHERE id = %s', id),
       format('DELETE FROM metric WHERE id = %s', id)
  FROM (SELECT id FROM metric ORDER BY date_c LIMIT 10000) x \gexec

-- @case batch_client script rollback : one statement: DELETE ... RETURNING feeding the INSERT
WITH moved AS (
  DELETE FROM metric WHERE id IN (SELECT id FROM metric ORDER BY date_c LIMIT 10000) RETURNING *)
INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid)
SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM moved;

-- @case batch_server rollback : server-side plan of the batch statement
WITH moved AS (
  DELETE FROM metric WHERE id IN (SELECT id FROM metric ORDER BY date_c LIMIT 10000) RETURNING *)
INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid)
SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM moved;

-- OBP's MetricsArchiveScheduler (obp-api/src/main/scala/code/scheduler/MetricsArchiveScheduler.scala) per row:
-- saveMetricsArchive() looks the row up by metricId (dedup), inserts it, the scheduler looks it up by metricId
-- again (verify), then deletes the source row. MetricArchive declares no index on metricId.

-- @case row_by_row_checked script rollback repeat=1 : 10 rows the OBP way: 2 lookups by metricid (no index) + INSERT + DELETE per row
SELECT format('SELECT * FROM metricarchive WHERE metricid = %s', id),
       format('INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid) SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM metric WHERE id = %s', id),
       format('SELECT * FROM metricarchive WHERE metricid = %s', id),
       format('DELETE FROM metric WHERE id = %s', id)
  FROM (SELECT id FROM metric ORDER BY date_c LIMIT 10) x \gexec

-- @step index on metricarchive.metricid
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_archive_metricid ON metricarchive (metricid);

-- @case row_by_row_checked_indexed script rollback repeat=3 : the same 10 rows the OBP way, with the index
SELECT format('SELECT * FROM metricarchive WHERE metricid = %s', id),
       format('INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid) SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail, consumerid, appname, implementedinversion, verb, correlationid, httpcode, id, responsebody, sourceip, targetip, consent_reference_id, apiinstanceid FROM metric WHERE id = %s', id),
       format('SELECT * FROM metricarchive WHERE metricid = %s', id),
       format('DELETE FROM metric WHERE id = %s', id)
  FROM (SELECT id FROM metric ORDER BY date_c LIMIT 10) x \gexec

-- @cleanup
DROP INDEX IF EXISTS sc_archive_metricid;
VACUUM metric;
VACUUM metricarchive;
