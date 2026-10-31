-- GET /management/metrics/top-consumers: busiest consumers over a recent period.
\set days random_exponential(1, 30, 2.0)
SELECT consumerid, appname, developeremail, count(*) AS calls
  FROM metric WHERE date_c >= localtimestamp - make_interval(days => :days)
 GROUP BY consumerid, appname, developeremail
 ORDER BY calls DESC LIMIT 10;
