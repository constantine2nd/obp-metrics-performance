-- GET /management/metrics: one filter + recent date range, newest first, paged by 50.
\set f random(1, 3)
\set days random_exponential(1, 30, 2.0)
\set off 50 * random(0, 4)
\if :f = 1
\set c random(1, :n_consumer)
SELECT val AS v FROM lt_values WHERE kind = 'consumer' AND k = :c \gset
SELECT * FROM metric
 WHERE consumerid = :v AND date_c >= localtimestamp - make_interval(days => :days)
 ORDER BY date_c DESC LIMIT 50 OFFSET :off;
\elif :f = 2
\set c random(1, :n_function)
SELECT val AS v FROM lt_values WHERE kind = 'function' AND k = :c \gset
SELECT * FROM metric
 WHERE implementedbypartialfunction = :v AND date_c >= localtimestamp - make_interval(days => :days)
 ORDER BY date_c DESC LIMIT 50 OFFSET :off;
\else
SELECT * FROM metric
 WHERE httpcode >= 400 AND date_c >= localtimestamp - make_interval(days => :days)
 ORDER BY date_c DESC LIMIT 50 OFFSET :off;
\endif
