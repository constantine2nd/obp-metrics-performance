-- Write path: OBP logs one metric row per API call.
\set k random(1, :n_tpl_metric)
INSERT INTO metric (url, duration, username, date_c, userid, implementedbypartialfunction, developeremail,
                    consumerid, appname, implementedinversion, verb, correlationid, httpcode, responsebody,
                    sourceip, targetip, consent_reference_id, apiinstanceid)
SELECT url, duration, username, localtimestamp, userid, implementedbypartialfunction, developeremail,
       consumerid, appname, implementedinversion, verb, gen_random_uuid()::text, httpcode, responsebody,
       sourceip, targetip, consent_reference_id, apiinstanceid
  FROM lt_tpl_metric WHERE k = :k;
