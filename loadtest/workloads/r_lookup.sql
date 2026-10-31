-- Trace one request: pick an existing row, then look it up by correlation id (no index on it today).
\set id random(1, :max_metric_id)
SELECT coalesce((SELECT correlationid FROM metric WHERE id >= :id ORDER BY id LIMIT 1), '-') AS corr \gset
SELECT * FROM metric WHERE correlationid = :corr;
