-- @title OFFSET vs keyset pagination
-- @category Query pattern
-- @tag confirmed
-- @claim OFFSET gets slower the deeper you page, because skipped rows are still read. Keyset pagination
-- @claim ("rows after the last one seen") is equally fast on page 1 and page 1000.
-- @verdict Confirmed exactly. OFFSET grows with depth: page 1 {t:offset_page_1}, page 1,000 {t:offset_page_1000}, page
-- @verdict 50,000 {t:offset_page_50000} (1M index entries read and discarded). Keyset stays at {t:keyset_page_50000} at any
-- @verdict depth, {x:offset_page_50000/keyset_page_50000} faster at page 50,000. OBP's /management/metrics pages with
-- @verdict offset/limit, so deep pages get slow.
-- @compare offset_page_50000 keyset_page_50000

-- @setup
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_metric_date_id ON metric (date_c DESC, id DESC);

-- @case offset_page_1 : page 1 of all metrics, 20 per page
SELECT id, date_c, url, duration FROM metric ORDER BY date_c DESC, id DESC LIMIT 20 OFFSET 0;

-- @case offset_page_1000 : page 1,000 (OFFSET 19,980)
SELECT id, date_c, url, duration FROM metric ORDER BY date_c DESC, id DESC LIMIT 20 OFFSET 19980;

-- @case offset_page_50000 : page 50,000 (OFFSET 999,980)
SELECT id, date_c, url, duration FROM metric ORDER BY date_c DESC, id DESC LIMIT 20 OFFSET 999980;

-- @case keyset_page_1000 : page 1,000 via WHERE (date_c, id) < last row of page 999
SELECT date_c AS last_date, id AS last_id FROM metric ORDER BY date_c DESC, id DESC OFFSET 19979 LIMIT 1 \gset
-- @explain
SELECT id, date_c, url, duration FROM metric
 WHERE (date_c, id) < (:'last_date', :last_id) ORDER BY date_c DESC, id DESC LIMIT 20;

-- @case keyset_page_50000 : page 50,000 via WHERE (date_c, id) < last row of page 49,999
SELECT date_c AS last_date, id AS last_id FROM metric ORDER BY date_c DESC, id DESC OFFSET 999979 LIMIT 1 \gset
-- @explain
SELECT id, date_c, url, duration FROM metric
 WHERE (date_c, id) < (:'last_date', :last_id) ORDER BY date_c DESC, id DESC LIMIT 20;

-- @cleanup
DROP INDEX IF EXISTS sc_metric_date_id;
