-- @title EXPLAIN BUFFERS: cache vs disk
-- @category PostgreSQL feature
-- @tag confirmed
-- @claim "shared hit" is data found in cache, "shared read" came from disk. If most pages are read, the working set
-- @claim does not fit in memory. A query served from cache can be 100x faster than one hitting disk.
-- @verdict Confirmed, with nuance. The small query (7.5k pages) read everything on its first run
-- @verdict ({first:small_working_set}), then found all pages in the 128 MB cache ({t:small_working_set}). The large one
-- @verdict needs 69.5k pages (550 MB): it read them on every run ({t:large_working_set}) and pushed everything else out of
-- @verdict shared_buffers. Those reads mostly came from the OS page cache (16 GB RAM); from the disk itself they would be
-- @verdict slower. shared_buffers is at the 128 MB default: raising it (e.g. 4 GB) is the cheapest win on this machine.
-- @compare none

-- @info shared_buffers and what occupies it right now (pg_buffercache)
SELECT current_setting('shared_buffers') AS shared_buffers;
SELECT c.relname, count(*) AS buffers, pg_size_pretty(count(*) * 8192) AS size
  FROM pg_buffercache b JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
 WHERE b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
 GROUP BY c.relname ORDER BY count(*) DESC LIMIT 6;

-- @case small_working_set : one archive URL, 7.5k rows spread over 3 years (~7.5k pages = 60 MB, fits in 128 MB)
SELECT count(*), avg(duration) FROM metricarchive WHERE url = '/obp/v5.1.0/management/metrics?offset=2&limit=1';

-- @case large_working_set : another URL, 72k rows (~70k pages = 550 MB, does not fit)
SELECT count(*), avg(duration) FROM metricarchive WHERE url = '/berlin-group/v1.3/consents';

-- @info shared_buffers afterwards: the large query pushed other pages out
SELECT c.relname, count(*) AS buffers, pg_size_pretty(count(*) * 8192) AS size
  FROM pg_buffercache b JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
 WHERE b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
 GROUP BY c.relname ORDER BY count(*) DESC LIMIT 6;
