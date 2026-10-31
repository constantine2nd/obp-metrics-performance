-- Pseudonymizes the rows copied from obp_mapped before they become templates for the generated data.
-- Readable, consistent labels (consumer-007, user-0003, ...), numbered by frequency so data distributions and
-- query results stay the same. UUIDs and e-mails inside URLs and response bodies are replaced with
-- random-salted values of the same length. No mapping is kept, so the originals cannot be recovered.
-- Called by 01_build_base.sh right after the copy.

\set ON_ERROR_STOP on
SET client_min_messages = warning;
BEGIN;

CREATE TEMP TABLE salt AS SELECT gen_random_uuid()::text AS s;

-- UUID -> salted pseudo-UUID (same shape), e-mail -> user@example.com, inside any text.
CREATE FUNCTION pg_temp.pseudo(t text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE m text; h text; salt text := (SELECT s FROM salt);
BEGIN
  IF t IS NULL OR t = '' THEN RETURN t; END IF;
  FOR m IN SELECT DISTINCT (regexp_matches(t, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', 'g'))[1] LOOP
    h := md5(salt || lower(m));
    t := replace(t, m, substr(h, 1, 8) || '-' || substr(h, 9, 4) || '-4' || substr(h, 14, 3) || '-8'
                       || substr(h, 18, 3) || '-' || substr(h, 21, 12));
  END LOOP;
  RETURN regexp_replace(t, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'user@example.com', 'g');
END $$;

-- old value -> label, most frequent first; one mapping per column across both tables.
CREATE FUNCTION pg_temp.labels(col text, prefix text, digits int, suffix text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($q$
    CREATE TEMP TABLE map_%1$s AS
    SELECT old, %2$L || lpad(row_number() OVER (ORDER BY n DESC, old)::text, %3$s, '0') || %4$L AS new
      FROM (SELECT %1$s AS old, count(*) AS n
              FROM (SELECT %1$s FROM metric UNION ALL SELECT %1$s FROM metricarchive) x
             WHERE %1$s <> '' GROUP BY 1) c;
    UPDATE metric t SET %1$s = m.new FROM map_%1$s m WHERE t.%1$s = m.old;
    UPDATE metricarchive t SET %1$s = m.new FROM map_%1$s m WHERE t.%1$s = m.old;$q$, col, prefix, digits, suffix);
END $$;

-- Replaces each mapped value where it appears as a whole URL path segment (e.g. /users/<name>/locks).
CREATE FUNCTION pg_temp.labels_in_urls(col text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record; tbl text;
BEGIN
  FOR r IN EXECUTE format('SELECT old, new FROM map_%s', col) LOOP
    FOREACH tbl IN ARRAY ARRAY['metric', 'metricarchive'] LOOP
      EXECUTE format($q$UPDATE %I SET url = CASE WHEN url LIKE %L THEN left(url, length(url) - %s) || %L ELSE url END
                                         WHERE url LIKE %L OR url LIKE %L$q$,
                     tbl, '%/' || r.old, length(r.old), r.new, '%/' || r.old, '%/' || r.old || '/%');
      EXECUTE format('UPDATE %I SET url = replace(url, %L, %L) WHERE url LIKE %L',
                     tbl, '/' || r.old || '/', '/' || r.new || '/', '%/' || r.old || '/%');
    END LOOP;
  END LOOP;
END $$;

SELECT pg_temp.labels('consumerid', 'consumer-', 3);
SELECT pg_temp.labels('userid', 'user-', 4);
SELECT pg_temp.labels('username', 'username-', 3);
SELECT pg_temp.labels_in_urls('username');
SELECT pg_temp.labels('appname', 'app-', 3);
SELECT pg_temp.labels('developeremail', 'developer-', 2, '@example.com');

UPDATE metric SET
  url = regexp_replace(pg_temp.pseudo(url), '/username/[^/?]+', '/username/username-other', 'g'), responsebody = pg_temp.pseudo(responsebody),
  consent_reference_id = pg_temp.pseudo(consent_reference_id), correlationid = gen_random_uuid()::text,
  sourceip = CASE WHEN sourceip <> '' THEN '192.0.2.10' ELSE sourceip END,
  targetip = CASE WHEN targetip <> '' THEN '192.0.2.20' ELSE targetip END;
UPDATE metricarchive SET
  url = regexp_replace(pg_temp.pseudo(url), '/username/[^/?]+', '/username/username-other', 'g'), responsebody = pg_temp.pseudo(responsebody),
  consent_reference_id = pg_temp.pseudo(consent_reference_id), correlationid = gen_random_uuid()::text,
  sourceip = CASE WHEN sourceip <> '' THEN '192.0.2.10' ELSE sourceip END,
  targetip = CASE WHEN targetip <> '' THEN '192.0.2.20' ELSE targetip END;

COMMIT;
-- The updates left the old row versions behind; rewrite the (still small) tables so they are gone for good.
VACUUM FULL metric;
VACUUM FULL metricarchive;
