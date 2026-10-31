-- @title Implicit type conversion
-- @category Anti-pattern
-- @tag different
-- @claim Comparing a column with a value of another type converts the column on every row and kills index usage.
-- @verdict Different in PostgreSQL, and mostly safer. Comparing a varchar column with an integer is an error, not a silent
-- @verdict conversion, and a quoted '4000000' against a bigint column is typed as bigint and uses the index. The real trap
-- @verdict is a numeric value: id = 4000000.0 converts every id to numeric and scans all 5M rows ({t:numeric_literal} vs
-- @verdict {t:int_literal}, {x:numeric_literal/int_literal}). Explicit casts on the column (id::text) do the same. Watch
-- @verdict for BigDecimal/numeric parameters from Java.
-- @compare numeric_literal int_literal

-- @info varchar column compared with an integer: PostgreSQL refuses instead of converting silently
SELECT count(*) FROM metric WHERE consumerid = 7;

-- @case int_literal : id = 4000000 (bigint column, integer value)
SELECT id, date_c, url FROM metric WHERE id = 4000000;

-- @case string_literal : id = '4000000' (quoted literal is typed as bigint, index still used)
SELECT id, date_c, url FROM metric WHERE id = '4000000';

-- @case numeric_literal : id = 4000000.0 (numeric value: the column is converted to numeric)
SELECT id, date_c, url FROM metric WHERE id = 4000000.0;

-- @case cast_column : id::text = '4000000' (explicit cast on the column)
SELECT id, date_c, url FROM metric WHERE id::text = '4000000';
