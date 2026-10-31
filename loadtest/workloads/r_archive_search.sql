-- Search old metrics: a 1-30 day window somewhere in the archive, by consumer or by URL.
\set from_days random(:metric_days + 1, :metric_days + :archive_days)
\set span random_exponential(1, 30, 2.0)
\set to_days :from_days - :span
\set f random(1, 2)
\if :f = 1
\set c random(1, :n_archive_consumer)
SELECT val AS v FROM lt_values WHERE kind = 'archive_consumer' AND k = :c \gset
SELECT * FROM metricarchive
 WHERE consumerid = :v
   AND date_c BETWEEN localtimestamp - make_interval(days => :from_days) AND localtimestamp - make_interval(days => :to_days)
 ORDER BY date_c DESC LIMIT 50;
\else
\set c random(1, :n_archive_url)
SELECT val AS v FROM lt_values WHERE kind = 'archive_url' AND k = :c \gset
SELECT * FROM metricarchive
 WHERE url = :v
   AND date_c BETWEEN localtimestamp - make_interval(days => :from_days) AND localtimestamp - make_interval(days => :to_days)
 ORDER BY date_c DESC LIMIT 50;
\endif
