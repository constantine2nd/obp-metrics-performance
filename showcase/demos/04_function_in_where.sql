-- @title Function wrapped around a column in WHERE
-- @category Anti-pattern
-- @tag confirmed
-- @claim Wrapping a column in a function makes indexes useless: rewrite as a range, or index the computed value.
-- @verdict Confirmed. date_c::date = day forced a parallel scan of all 5M rows ({t:cast_date}); the equivalent range used
-- @verdict the date index ({t:range}, {x:cast_date/range} faster). lower(developeremail) scanned all 15M archive rows
-- @verdict ({t:lower_email}); an expression index brought it to {t:lower_email_indexed}, about the speed of the plain
-- @verdict column ({t:plain_email}; the rest is fetching 160k matching rows). PostgreSQL offers both fixes: rewrite as a
-- @verdict range, or index the expression.
-- @compare cast_date range

-- @case cast_date : calls on one day with date_c::date = day
SELECT count(*), avg(duration) FROM metric WHERE date_c::date = current_date - 30;

-- @case range : same day as a range on the raw column
SELECT count(*), avg(duration) FROM metric WHERE date_c >= current_date - 30 AND date_c < current_date - 29;

-- @case lower_email : metricarchive, lower(developeremail) = '...' (15M rows)
SELECT count(*), avg(duration) FROM metricarchive WHERE lower(developeremail) = 'developer-02@example.com';

-- @case plain_email : same without the function (uses metricarchive_developeremail)
SELECT count(*), avg(duration) FROM metricarchive WHERE developeremail = 'developer-02@example.com';

-- @step expression index on lower(developeremail)
SET maintenance_work_mem = '1GB';
CREATE INDEX sc_archive_lower_email ON metricarchive (lower(developeremail));
ANALYZE metricarchive;

-- @case lower_email_indexed : lower(developeremail) = '...' with the expression index
SELECT count(*), avg(duration) FROM metricarchive WHERE lower(developeremail) = 'developer-02@example.com';

-- @cleanup
DROP INDEX IF EXISTS sc_archive_lower_email;
