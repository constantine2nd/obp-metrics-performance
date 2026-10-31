-- GET /management/metrics/top-apis: most called endpoints over a recent period.
\set days random_exponential(1, 30, 2.0)
SELECT implementedbypartialfunction, implementedinversion, count(*) AS calls, avg(duration) AS avg_duration
  FROM metric WHERE date_c >= localtimestamp - make_interval(days => :days)
 GROUP BY implementedbypartialfunction, implementedinversion
 ORDER BY calls DESC LIMIT 10;
