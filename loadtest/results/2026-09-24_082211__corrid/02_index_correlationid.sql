-- Lookups by correlation id (r_lookup.sql) scan the whole metric table without this.
SET maintenance_work_mem = '1GB';
CREATE INDEX IF NOT EXISTS metric_correlationid ON metric (correlationid);
