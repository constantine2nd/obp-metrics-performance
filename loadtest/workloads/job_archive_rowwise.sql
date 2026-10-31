-- Mirrors OBP's MetricsArchiveScheduler (obp-api/.../code/scheduler/MetricsArchiveScheduler.scala), per row:
-- look up by metricid (dedup in saveMetricsArchive), insert, look up by metricid again (verify), delete the source.
-- MetricArchive has no index on metricid, so each row costs two full scans of metricarchive
-- (obp_mapped: 1542 seq scans for 766 moved rows). Scenario: SCENARIOS=archive_rowwise CLIENTS=1
SELECT coalesce((SELECT id FROM metric WHERE date_c < localtimestamp - make_interval(days => :keep_days)
                  ORDER BY date_c LIMIT 1), -1) AS mid \gset
BEGIN;
SELECT * FROM metricarchive WHERE metricid = :mid;
INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail,
                           consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid,
                           responsebody, sourceip, targetip, consent_reference_id, apiinstanceid)
SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail,
       consumerid, appname, implementedinversion, verb, correlationid, httpcode, id,
       responsebody, sourceip, targetip, consent_reference_id, apiinstanceid
  FROM metric WHERE id = :mid;
SELECT * FROM metricarchive WHERE metricid = :mid;
DELETE FROM metric WHERE id = :mid;
END;
