-- Archive job, batched: move the oldest rows past retention to metricarchive, then expire old archive rows.
-- Runs as a rate-limited background client in the "mixed" scenario.
BEGIN;
WITH moved AS (
  DELETE FROM metric
   WHERE id IN (SELECT id FROM metric
                 WHERE date_c < localtimestamp - make_interval(days => :keep_days)
                 ORDER BY date_c LIMIT :archive_batch)
  RETURNING *)
INSERT INTO metricarchive (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail,
                           consumerid, appname, implementedinversion, verb, correlationid, httpcode, metricid,
                           responsebody, sourceip, targetip, consent_reference_id, apiinstanceid)
SELECT url, duration, username, date_c, userid, implementedbypartialfunction, developeremail,
       consumerid, appname, implementedinversion, verb, correlationid, httpcode, id,
       responsebody, sourceip, targetip, consent_reference_id, apiinstanceid
  FROM moved;
DELETE FROM metricarchive
 WHERE id IN (SELECT id FROM metricarchive
               WHERE date_c < localtimestamp - make_interval(days => :expire_days)
               ORDER BY date_c LIMIT :expire_batch);
END;
