-- GET /management/aggregate-metrics: count / avg / min / max duration over a recent period.
\set days random_exponential(1, 30, 2.0)
\set f random(1, 2)
\if :f = 1
SELECT count(*), avg(duration), min(duration), max(duration)
  FROM metric WHERE date_c >= localtimestamp - make_interval(days => :days);
\else
\set c random(1, :n_consumer)
SELECT val AS v FROM lt_values WHERE kind = 'consumer' AND k = :c \gset
SELECT count(*), avg(duration), min(duration), max(duration)
  FROM metric WHERE consumerid = :v AND date_c >= localtimestamp - make_interval(days => :days);
\endif
