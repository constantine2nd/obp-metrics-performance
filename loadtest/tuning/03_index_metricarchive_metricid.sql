-- OBP's archive job looks up metricarchive.metricid twice per archived row (MetricsArchiveScheduler);
-- without this index each lookup is a full scan. Upstream fix: Index(metricId) in MetricArchive.dbIndexes.
SET maintenance_work_mem = '1GB';
CREATE INDEX IF NOT EXISTS metricarchive_metricid ON metricarchive (metricid);
