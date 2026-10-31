-- consent_reference_id is indexed twice on both tables; every insert maintains the extra copy for nothing.
DROP INDEX IF EXISTS idx_metric_consent_reference_id;
DROP INDEX IF EXISTS idx_metricarchive_consent_reference_id;
