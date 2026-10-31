#!/usr/bin/env python3
"""Builds IMPROVEMENTS.html and IMPROVEMENTS.md: every change these measurements suggest,
with what it buys, what it costs, and how confident we are.

Evidence comes from three places, all in this folder:
  showcase/REPORT.html   21 query-pattern demos on 5M + 15M rows
  loadtest/REPORT.html   pgbench, 3 scenarios x 1/4/8/16 clients, baseline vs the correlationid index
  the OBP-API source     what the code actually does

Run: ./improvements.py
"""
import html
import os

ROOT = os.path.dirname(os.path.abspath(__file__))

INTRO = ("Everything below was measured on this machine against a copy of the OBP metric tables, scaled to "
         "5M <code>metric</code> and 15M <code>metricarchive</code> rows and pseudonymized. Each item says what it "
         "buys, what it costs and how sure we are: <b>measured</b> means it was run in one of the two reports, "
         "<b>estimated</b> means the reasoning is sound but nobody ran it here.")

GROUPS = [
    ("indexes", "Indexes", "Cheap to apply, easy to undo, and this is where the measured wins are."),
    ("code", "Application and job changes", "Need a code change in OBP; larger wins than any setting."),
    ("settings", "Server settings", "One restart or reload; affects every database on the instance."),
    ("situational", "Situational", "Only worth it if the matching feature or query pattern actually exists."),
    ("rejected", "Tried and not recommended", "Common advice that did not hold up on this data."),
]

ITEMS = [
    dict(id="corrid", tool="observe → diagnose (missing-index) → explain (seq-scan) → loadtest run + compare", group="indexes", priority=1, confidence="measured",
         title="Index metric.correlationid",
         what="<code>CREATE INDEX CONCURRENTLY metric_correlationid ON metric (correlationid);</code>",
         evidence=[
             "Load test, read scenario at 16 clients: throughput 31 → 219 tps (7.0x), p95 4.16 s → 307 ms (-93%)",
             "The lookup itself: p95 4.95 s → 15 ms (323x); it was 93% of all query time in the baseline run",
             "Mixed scenario (inserts + reads + archive job) at 4 clients: 88 → 358 tps (4.1x)",
         ],
         pros=["The single biggest win measured anywhere in this work",
               "Makes reads scale with clients again; without it throughput is flat at ~30 tps no matter the load",
               "Speeds up every other read too, because the full scans no longer flush the cache",
               "No code change, and reversible with one DROP INDEX"],
         cons=["283 MB of disk on a 5M-row table",
               "Random UUID keys mean every insert writes to a random index page: measurable (1.7-3.4x) on a "
               "single-statement bulk insert of 10,000 rows, but <b>not</b> measurable in the load test "
               "(one row per transaction, +10% to -1% across all client counts)",
               "CREATE INDEX without CONCURRENTLY would block writes for the ~6 s build"]),
    dict(id="archive-corrid", tool="diagnose (missing-index), explain (seq-scan)", group="indexes", priority=2, confidence="measured",
         title="Index metricarchive.correlationid, as a hash index",
         what="<code>CREATE INDEX CONCURRENTLY metricarchive_correlationid ON metricarchive USING hash "
              "(correlationid);</code>",
         evidence=["Showcase demo 20: tracing one request across both tables 0.88 s → 0.04 ms once both tables are "
                   "indexed; with only metric indexed the archive scan still costs ~0.75 s",
                   "Hash index 512 MB vs B-tree 853 MB on 15M rows, same lookup speed"],
         pros=["Support can trace an old request in milliseconds instead of a second per attempt",
               "Hash is 40% smaller than B-tree because it stores a 4-byte hash, not the 36-character UUID"],
         cons=["512 MB of disk",
               "Hash supports equality only: no ranges, no ORDER BY, no prefix search, no unique constraint",
               "Only worth it if old requests are actually traced; the archive is otherwise written and read by date"]),
    dict(id="metricid", tool="diagnose (seq-scan on metricarchive), then the OBP source", group="indexes", priority=1, confidence="measured",
         title="Index metricarchive.metricid (upstream fix)",
         what="Add <code>Index(metricId)</code> to <code>MetricArchive.dbIndexes</code>. Submitted as "
              "<a href=\"https://github.com/OpenBankProject/OBP-API/pull/2918\">OBP-API PR #2918</a>; Schemifier "
              "creates it at boot on existing deployments.",
         evidence=["The archive job looks each row up by metricId twice (dedup in saveMetricsArchive, verify before "
                   "delete) and no index existed: two full scans of metricarchive per archived row",
                   "Showcase demo 10 at 15M archive rows: ~1.57 s per row without the index, ~0.8 ms with it",
                   "Matches the real database: 1,542 scans of metricarchive for the 766-row run on 2026-08-19"],
         pros=["Without it, archiving cost grows with the archive: a 10,000-row batch would need hours at 15M rows, "
               "against a 10-minute scheduler interval, so the job falls permanently behind",
               "One line, no behaviour change, no migration needed"],
         cons=["Index build blocks writes to metricarchive at boot (seconds per few million rows); only the archive "
               "job writes there",
               "Disk cost grows with the archive, a few hundred MB at 15M rows"]),
    dict(id="dup-indexes", tool="diagnose (duplicate-index)", group="indexes", priority=2, confidence="measured",
         title="Drop the duplicate consent_reference_id indexes",
         what="Both tables carry two identical indexes on <code>consent_reference_id</code>: one from "
              "<code>dbIndexes</code>, one created explicitly by <code>MigrationOfMetricConsentReferenceId</code>. "
              "Drop one of each and remove the duplicate from the migration.",
         evidence=["Sizes on the test data: 33 MB (metric) + 100 MB (metricarchive) wasted per duplicate",
                   "Every insert and every archived row maintains both copies for no benefit"],
         pros=["Frees 133 MB and removes pure write overhead", "No query loses anything: the surviving index is identical"],
         cons=["Needs care upstream so the migration does not recreate it on the next deploy",
               "The write saving was not isolated in a benchmark; index maintenance per row is small"]),
    dict(id="archive-batch", tool="observe during an archive run, then the OBP source", group="code", priority=1, confidence="measured",
         title="Archive in batches instead of row by row",
         what="Replace the per-row copy/verify/delete loop in <code>MetricsArchiveScheduler</code> with one "
              "<code>DELETE ... RETURNING</code> feeding an <code>INSERT</code>, in batches.",
         evidence=["Showcase demo 10: moving 10,000 rows took 1.49 s row by row (20,000 statements) against 213 ms "
                   "as one DELETE ... RETURNING feeding an INSERT: about 7x",
                   "With OBP's per-row metricid lookups on top, the same work costs 1.57 s per row at 15M archive "
                   "rows until the metricid index exists",
                   "Load test, mixed scenario: the batched job moved ~324k rows in 5 minutes while foreground traffic "
                   "kept running"],
         pros=["About 7x less time for the same work, and the cost stops depending on archive size",
               "Fewer round trips and less lock churn than 2 statements per row"],
         cons=["A real code change in the scheduler, with its own tests",
               "A batch holds its rows in one transaction: batch size needs a sane limit (1,000-5,000)",
               "The per-row verify step disappears; the copy is then trusted inside one transaction, which is what "
               "makes it atomic anyway",
               "Adding the metricid index (above) already removes most of the pain, so this is the second step"]),
    dict(id="keyset", tool="explain (top-n-sort)", group="code", priority=2, confidence="measured",
         title="Keyset pagination for /management/metrics",
         what="Replace <code>LIMIT ... OFFSET n</code> with a seek condition on the last row seen: "
              "<code>WHERE (date_c, id) &lt; (:last_date, :last_id) ORDER BY date_c DESC, id DESC LIMIT 20</code>.",
         evidence=["Showcase demo 09: page 1 0.03 ms, page 1,000 3.1 ms, page 50,000 241 ms with OFFSET; keyset stays "
                   "at 0.04 ms at any depth"],
         pros=["Deep pages stop being slow; cost no longer grows with page number",
               "Less load on the database from bots and scripts that walk the whole metrics list"],
         cons=["API change: the client must pass the last seen values instead of an offset, so it cannot jump to "
               "page N directly",
               "Only pays off for deep paging; the first few pages are already fast"]),
    dict(id="projections", tool="diagnose (toast), explain (filter-waste)", group="code", priority=2, confidence="measured",
         title="Stop selecting every column in hot paths",
         what="List the columns each screen needs, or use ORM projections, instead of loading the full entity.",
         evidence=["Showcase demo 02: with only indexed columns the query becomes an Index Only Scan, 33 ms → 1.5 ms "
                   "(22x), reading 89 pages instead of 15,366",
                   "Same demo: after a migration adds a ~2 kB JSON column, the unchanged SELECT * goes from 30 ms to "
                   "144 ms while the explicit-column query does not move"],
         pros=["Immune to later schema growth, which is the part no test catches",
               "Enables index-only scans, which nothing else can",
               "Less data over the network per request"],
         cons=["Touches many call sites, and ORM projections are more code than loading an entity",
               "The gain on narrow rows is small today; it grows when wide columns are added later"]),
    dict(id="mv", tool="explain (slow), loadtest run + compare", group="code", priority=3, confidence="measured",
         title="Pre-compute the dashboard aggregates",
         what="A daily materialized view over metric (day, function, version, consumer: calls, total duration, "
              "errors), refreshed every few minutes with <code>REFRESH MATERIALIZED VIEW CONCURRENTLY</code>.",
         evidence=["Showcase demo 11: 365-day top-APIs 663 ms → 30 ms (22x), 7-day 26x; the view is 11 MB against "
                   "1.4 GB of table; a full refresh takes 2.9 s (4.0 s concurrently)",
                   "Load test: after the correlationid fix, the top-APIs aggregate is the heaviest statement left"],
         pros=["Turns the slowest remaining dashboard queries into millisecond lookups",
               "Cheap to keep current, and CONCURRENTLY does not block readers"],
         cons=["Data is as stale as the refresh interval; not suitable for live per-request views",
               "Another object to maintain, and the aggregate shape has to match what the API offers",
               "Refresh costs CPU and temp files (work_mem matters here)"]),
    dict(id="shared-buffers", tool="diagnose (shared-buffers, cache-hit)", group="settings", priority=2, confidence="estimated",
         title="Raise shared_buffers from the 128 MB default",
         what="<code>ALTER SYSTEM SET shared_buffers = '4GB';</code> then restart. Common starting point is 25% of RAM.",
         evidence=["Showcase demo 12: shared_buffers holds 2% of the 6.4 GB of data; the same query costs 28 ms cold "
                   "and 9.5 ms once cached, and a large query evicts everything else",
                   "Load test baseline read run: 159M blocks read from the OS in 5 minutes"],
         pros=["More of the working set stays in PostgreSQL's own cache, so fewer system calls",
               "Helps every query, no code change"],
         cons=["<b>Not measured here.</b> On this machine the OS page cache already absorbs most reads (average read "
               "1.4 µs), so the gain may be smaller than expected",
               "Needs a restart, and the memory is reserved whether used or not",
               "Too large a value can hurt: double buffering with the OS cache, and longer checkpoints"]),
    dict(id="work-mem", tool="diagnose (temp-files), explain (sort-spill)", group="settings", priority=3, confidence="measured",
         title="Raise work_mem for the aggregate and refresh paths",
         what="Default is 4 MB. Set it per session or per role for reporting queries, e.g. "
              "<code>SET work_mem = '64MB';</code> before the materialized view refresh.",
         evidence=["Showcase run: 7 GB of temp files, mostly the materialized view build and refresh sorting 5M rows",
                   "Two measured cases spilled to disk: SELECT * with a sort (~3 MB per run) and a UNION de-duplication"],
         pros=["Sorts and hashes stay in memory instead of spilling to disk",
               "Can be set narrowly, for one role or one session, instead of globally"],
         cons=["Multiplied per sort node and per connection: a global increase can exhaust RAM under load",
               "Only helps queries that actually spill; the everyday metric queries here do not"]),
    dict(id="parallel", tool="not covered by a check: measured by hand in the showcase", group="settings", priority=3, confidence="measured",
         title="Allow more parallel workers per query",
         what="<code>max_parallel_workers_per_gather</code> is 2. Setting it to 4 helps large aggregates.",
         evidence=["Showcase demo 14, aggregating 15M archive rows: 3.83 s with 1 worker, 1.99 s with 2, 1.88 s with "
                   "4, 1.61 s with 6"],
         pros=["Faster reports and archive-wide aggregates", "Reload only, no restart"],
         cons=["Diminishing returns past 4 workers: the scan becomes I/O bound, not CPU bound",
               "Each parallel query occupies several worker slots, so many concurrent reports can starve each other",
               "The load test's queries are mostly small; this helps reporting, not the API path"]),
    dict(id="random-page-cost", tool="loadtest run + compare, one setting at a time", group="settings", priority=3, confidence="estimated",
         title="Lower random_page_cost for SSD storage",
         what="<code>random_page_cost</code> is 4, a spinning-disk default. On NVMe, 1.1 is the usual choice.",
         evidence=["The storage here is an NVMe SSD; measured average read time per page is 1.4 µs",
                   "Several demos show the planner switching to sequential scans where an index scan was available"],
         pros=["The planner stops over-estimating the cost of index scans, which suits this workload",
               "Reload only, and easy to revert"],
         cons=["<b>Not measured here.</b> No before/after run was done with this setting",
               "Affects every query on the instance: some plans will change, not all for the better",
               "Should be tested with the load test before being applied anywhere real"]),
    dict(id="autovacuum", tool="diagnose (dead-rows)", group="settings", priority=2, confidence="measured",
         title="Tune autovacuum for the metric table",
         what="Lower <code>autovacuum_vacuum_scale_factor</code> for this table, e.g. "
              "<code>ALTER TABLE metric SET (autovacuum_vacuum_scale_factor = 0.02);</code>",
         evidence=["Load test, mixed scenario at 16 clients: 298,000 dead rows in metric after 5 minutes, autovacuum "
                   "never ran during the run",
                   "Default scale factor 0.2 means a 5M-row table waits for 1M dead rows before a vacuum"],
         pros=["Keeps the table from bloating between archive runs, which delete in bulk",
               "Keeps statistics fresher, which matters after big deletes (see showcase demo 01)"],
         cons=["More frequent vacuums cost I/O while running",
               "The archive job's bulk deletes will still create bursts of dead rows"]),
    dict(id="covering", tool="explain (filter-waste)", group="situational", priority=3, confidence="measured",
         title="Covering index for the top-APIs query",
         what="<code>CREATE INDEX ... ON metric (date_c) INCLUDE (implementedbypartialfunction, "
              "implementedinversion, duration);</code>",
         evidence=["Showcase demo 07: 50-116 ms → 36-41 ms (1.3-3x), answered from the index alone",
                   "Cost: 299 MB against 108 MB for the plain date index; 10,000 inserts ~20% slower"],
         pros=["Turns a dashboard query into an index-only scan"],
         cons=["Three times the size of the plain date index, on the table that receives every insert",
               "The materialized view (above) solves the same query far better; pick one, not both"]),
    dict(id="partial", tool="diagnose (missing-index), explain", group="situational", priority=3, confidence="measured",
         title="Partial index for error dashboards",
         what="<code>CREATE INDEX ... ON metric (date_c) WHERE httpcode &gt;= 400;</code>",
         evidence=["Showcase demo 08: 8.9 MB against 151 MB for the full (httpcode, date_c) index, and at least as "
                   "fast (9-12 ms vs 15-16 ms; 29-87 ms with no index)"],
         pros=["17x smaller than the full index, so it stays cached",
               "Costs nothing when rows outside the predicate are written"],
         cons=["Only used by queries whose WHERE matches the predicate",
               "Worth it only if an error view is actually queried regularly"]),
    dict(id="trigram", tool="explain (seq-scan on a LIKE filter)", group="situational", priority=4, confidence="measured",
         title="Trigram index for URL substring search",
         what="<code>CREATE INDEX ... ON metric USING gin (url gin_trgm_ops);</code>",
         evidence=["Showcase demo 18: LIKE '%dynamic-entity%' 379 ms → 8.9 ms (42x), and ILIKE uses it too",
                   "Cost: 184 MB (18% of the table), 28 s to build"],
         pros=["Makes a search box over URLs usable"],
         cons=["Large index and slower writes, for a feature that may not exist",
               "Only add it if users really search URLs by substring"]),
    dict(id="brin", tool="not covered by a check: an index-size trade-off, measured by hand", group="situational", priority=4, confidence="measured",
         title="BRIN instead of B-tree on metricarchive.date_c",
         what="<code>CREATE INDEX ... ON metricarchive USING brin (date_c);</code> and drop the B-tree.",
         evidence=["Showcase demo 17: 136 kB against 326 MB (2,400x smaller); one day 762 ms → 14 ms without any "
                   "index, but the B-tree is still faster: 3.4-4.6 ms vs 14-18 ms for a day, 40-46 ms vs 265-498 ms "
                   "for a month"],
         pros=["Almost free in disk terms, and good enough for an archive that is rarely queried",
               "Works because the archive is append-only and ordered by date"],
         cons=["3-10x slower than the B-tree for the same query",
               "Only sensible if archive queries are rare and index size matters"]),
    dict(id="partitioning", tool="not covered by a check: a design change, measure with loadtest", group="situational", priority=3, confidence="estimated",
         title="Partition metricarchive by month",
         what="Range partitioning on <code>date_c</code>, so expiring old data becomes DROP PARTITION.",
         evidence=["The archive job currently deletes expired rows with a bulk DELETE, which rewrites index entries "
                   "and leaves dead rows behind"],
         pros=["Expiry becomes instant and creates no bloat",
               "Queries for one month touch one partition"],
         cons=["<b>Not measured here.</b> No partitioned variant was benchmarked",
               "A real migration of a 15M-row table, plus application and job changes",
               "Every index becomes per-partition; queries without a date filter get slower"]),
    dict(id="or-union", tool="showcase demo 05 (myth check)", group="rejected", priority=None, confidence="measured",
         title="Rewriting OR as UNION",
         what="Common advice says OR across columns prevents index use and should be rewritten as UNION.",
         evidence=["Showcase demo 05: OR across two indexed columns is answered with a BitmapOr of both indexes, "
                   "158 ms against 194 ms for the UNION rewrite",
                   "UNION only wins for 'newest N' queries where each side reads its own index in order, and there "
                   "both finish in about 1 ms"],
         pros=["None worth the rewrite on PostgreSQL"],
         cons=["More SQL to maintain for no measured gain",
               "The real fix for a slow OR is an index on the column that lacks one"]),
    dict(id="hints", tool="showcase demo 15 (myth check)", group="rejected", priority=None, confidence="measured",
         title="Forcing plans (hints, enable_* switches)",
         what="MySQL-style optimizer hints have no PostgreSQL equivalent; enable_seqscan and friends exist only as "
              "session switches.",
         evidence=["Showcase demo 15: the planner's own choice (0.7-5.6 ms) beat every alternative it had rejected "
                   "(bitmap + sort 19-32 ms, full scan 190-242 ms)"],
         pros=["Useful as a debugging tool to see which plan was rejected"],
         cons=["Not a production fix: a forced plan stops adapting when the data changes",
               "When the planner is wrong, the cause is usually stale statistics or a missing index"]),
    dict(id="explain-only", tool="explain and pg_stat_statements both see what EXPLAIN hides", group="rejected", priority=None, confidence="measured",
         title="Trusting EXPLAIN ANALYZE alone",
         what="Not a change to make, a habit to drop: EXPLAIN ANALYZE does not send rows to a client.",
         evidence=["Showcase demo 02: after a wide column is added, EXPLAIN reports 7.8 → 10.2 ms while the client "
                   "sees 10.5 → 123 ms, because large values live out of line and EXPLAIN never fetches them",
                   "pg_stat_statements did show it: 111 ms against EXPLAIN's 19 ms"],
         pros=["EXPLAIN stays the right tool for plan shape, row estimates and buffers"],
         cons=["It hides everything that happens while delivering rows",
               "Use client-side timings or pg_stat_statements for the real cost; PostgreSQL 17 adds "
               "EXPLAIN (ANALYZE, SERIALIZE) for this"]),
]

PRIORITY_LABEL = {1: "Do first", 2: "Worth doing", 3: "Later / if needed", 4: "Only on demand", None: "Skip"}
CONF_LABEL = {"measured": "measured here", "estimated": "estimated, not measured"}


def strip_tags(s):
    import re
    return re.sub(r"<[^>]+>", "", s).replace("&gt;", ">").replace("&lt;", "<").replace("&amp;", "&")


def write_md():
    L = ["# OBP metric tables: measured improvements", "", strip_tags(INTRO), "",
         "| # | Change | Priority | Confidence | Measured effect | Main cost | How to find it |",
         "|---|---|---|---|---|---|---|"]
    for i, it in enumerate(ITEMS, 1):
        L.append(f"| {i} | {strip_tags(it['title'])} | {PRIORITY_LABEL[it['priority']]} | "
                 f"{CONF_LABEL[it['confidence']]} | {strip_tags(it['evidence'][0])} | {strip_tags(it['cons'][0])} | "
                 f"{it.get('tool', '')} |")
    L += ["", "## Repeating this on any table", "",
          "The same path that produced this list, as commands. Steps 1-3 are read-only and safe against a live "
          "database; the rest only touch a copy.", "", "```bash", "git clone https://github.com/constantine2nd/postgresql-lab && cd postgresql-lab/pglab",
          "./observe.py  -d proddb --role appuser          # 1. trigger the slow action: what ran, which tables",
          "./diagnose.py -d proddb -t <table>              # 2. duplicate, unused and missing indexes, bloat, cache",
          "./capture.py  -d proddb -t <table> -o wl/       # 3. the statements that really run, with their weights",
          "./clone.py --from proddb -t <table> --to lab --anonymize --scale-to 5000000",
          "psql -d lab -f wl/prepare.sql",
          "./explain.py -w wl/ -d lab                      # 4. what is wrong with each plan, and what to try",
          "./replay.py baseline --workload wl/ --db lab",
          "./replay.py fixed    --workload wl/ --db lab --apply fix.sql",
          "./compare.py baseline fixed --scripts          # 5. did it help, and what did it cost", "```", "",
          "For a table that does not exist yet: `seed.py --rows 1000000 --values col=N` fills it from the column "
          "types, then `explain.py --sql expected_queries.sql` shows the plans at that size.", "",
          "The *How to find it* column above names the check that surfaces each item. See [pglab's README](https://github.com/constantine2nd/postgresql-lab/blob/main/pglab/README.md).", ""]
    for key, name, desc in GROUPS:
        items = [i for i in ITEMS if i["group"] == key]
        if not items:
            continue
        L += [f"## {name}", "", desc, ""]
        for it in items:
            L += [f"### {strip_tags(it['title'])}", "",
                  f"*{PRIORITY_LABEL[it['priority']]} · {CONF_LABEL[it['confidence']]} · "
                  f"found with: {it.get('tool', '-')}*", "",
                  strip_tags(it["what"]), "", "**Evidence**", ""]
            L += [f"- {strip_tags(e)}" for e in it["evidence"]]
            L += ["", "**Pros**", ""] + [f"- {strip_tags(p)}" for p in it["pros"]]
            L += ["", "**Cons and trade-offs**", ""] + [f"- {strip_tags(c)}" for c in it["cons"]] + [""]
    open(os.path.join(ROOT, "IMPROVEMENTS.md"), "w").write("\n".join(L))


def write_html():
    css = open(os.path.join(ROOT, "showcase", "report_template.html")).read()
    css = css[css.index("<style>"):css.index("</style>") + 8]
    rows = "".join(
        f'<tr><td class="num-cell">{i}</td><td><a href="#{it["id"]}">{it["title"]}</a></td>'
        f'<td><span class="pill p{it["priority"] or 0}">{PRIORITY_LABEL[it["priority"]]}</span></td>'
        f'<td><span class="pill c-{it["confidence"]}">{CONF_LABEL[it["confidence"]]}</span></td>'
        f'<td>{it["evidence"][0]}</td><td>{it["cons"][0]}</td>'
        f'<td class="tool">{it.get("tool", "")}</td></tr>'
        for i, it in enumerate(ITEMS, 1))
    sections = ""
    for key, name, desc in GROUPS:
        items = [i for i in ITEMS if i["group"] == key]
        if not items:
            continue
        sections += f'<section class="panel" id="g-{key}" style="margin-top:28px"><h2>{name}</h2><p class="sub">{desc}</p>'
        for it in items:
            sections += (
                f'<article class="item" id="{it["id"]}">'
                f'<div class="item-head"><h3>{it["title"]}</h3>'
                f'<span class="pill p{it["priority"] or 0}">{PRIORITY_LABEL[it["priority"]]}</span>'
                f'<span class="pill c-{it["confidence"]}">{CONF_LABEL[it["confidence"]]}</span></div>'
                f'<p class="what">{it["what"]}</p>'
                f'<p class="tool-line">Find it with: <span class="tool">{it.get("tool", "-")}</span></p>'
                f'<div class="evidence"><h4>Evidence</h4><ul>' + "".join(f"<li>{e}</li>" for e in it["evidence"]) + "</ul></div>"
                f'<div class="pc"><div class="pros"><h4>Pros</h4><ul>' + "".join(f"<li>{p}</li>" for p in it["pros"]) + "</ul></div>"
                f'<div class="cons"><h4>Cons and trade-offs</h4><ul>' + "".join(f"<li>{c}</li>" for c in it["cons"]) + "</ul></div></div>"
                "</article>")
        sections += "</section>"
    extra = """
<style>
.item { border-top: 1px solid var(--rule); padding: 18px 0 4px; display: grid; grid-template-columns: minmax(0,1fr); gap: 10px; }
.item:first-of-type { border-top: none; }
.item-head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
.item-head h3 { margin: 0; font-size: 18px; font-weight: 600; }
.pill { font-size: 11.5px; font-weight: 500; padding: 2px 9px; border-radius: 999px; white-space: nowrap; }
.pill.p1 { color: var(--serious); background: var(--serious-bg); }
.pill.p2 { color: var(--warn); background: var(--warn-bg); }
.pill.p3, .pill.p4 { color: var(--info); background: var(--info-bg); }
.pill.p0 { color: var(--ink-3); background: var(--rule-soft); }
.pill.c-measured { color: var(--good); background: var(--good-bg); }
.pill.c-estimated { color: var(--warn); background: var(--warn-bg); }
.what { margin: 0; color: var(--ink); }
.evidence h4, .pc h4 { font-size: 11px; letter-spacing: .08em; text-transform: uppercase; color: var(--ink-3); margin: 0 0 4px; font-weight: 600; }
.evidence ul, .pc ul { margin: 0; padding-left: 18px; color: var(--ink-2); font-size: 14px; }
.evidence li, .pc li { margin: 0 0 3px; }
.pc { display: grid; grid-template-columns: minmax(0,1fr); gap: 12px; }
@media (min-width: 820px) { .pc { grid-template-columns: minmax(0,1fr) minmax(0,1fr); } }
.pros, .cons { border-left: 3px solid var(--good); padding-left: 12px; }
.cons { border-left-color: var(--serious); }
table a { text-decoration: none; }
.tool { font-family: "IBM Plex Mono", monospace; font-size: 12px; color: var(--ink-2); }
.tool-line { margin: -4px 0 0; font-size: 13px; color: var(--ink-3); }
</style>
"""
    body = f"""
<div class="shell">
  <nav class="toc" aria-label="Groups"><h2>Groups</h2><ol>""" + "".join(
        f'<li><a href="#g-{k}"><span class="n">▸</span><span>{n}</span><span class="x"></span></a></li>'
        for k, n, _ in GROUPS) + """</ol></nav>
  <main>
    <header class="top">
      <div class="eyebrow">PostgreSQL 14 · 5M metric + 15M metricarchive rows · measured on this machine</div>
      <h1>What to change in the OBP metric database, and what it costs</h1>
      <p class="lede">""" + INTRO + """</p>
      <div class="stats">
        <div class="stat"><b>7.0×</b><span>read throughput from one index</span></div>
        <div class="stat"><b>323×</b><span>faster request tracing</span></div>
        <div class="stat"><b>±0%</b><span>its cost on inserts</span></div>
        <div class="stat"><b>{n_measured}</b><span>of {n_total} items measured, not estimated</span></div>
      </div>
    </header>
    <section class="panel">
      <h2>All suggestions</h2>
      <p class="sub">Sorted by topic, not by priority. Click a row for the full trade-off.</p>
      <div class="table-wrap"><table><thead><tr><th class="num-cell">#</th><th>Change</th><th>Priority</th>
      <th>Confidence</th><th>Strongest measured effect</th><th>Main cost</th>
      <th>How to find it</th></tr></thead>
      <tbody>""" + rows + """</tbody></table></div>
    </section>
    """ + sections + """
    <section class="panel" style="margin-top:28px"><h2>Where the evidence comes from</h2>
      <dl class="kv">
        <dt>showcase/</dt><dd>21 query-pattern demos (execution plans, indexing, pagination, batching, caching) on
          5M + 15M rows; each claim confirmed or corrected with measurements.</dd>
        <dt>loadtest/</dt><dd>pgbench: read, write and mixed scenarios at 1, 4, 8 and 16 clients, 5 minutes each,
          run twice: baseline and with the correlationid index.</dd>
        <dt><a href="https://github.com/constantine2nd/postgresql-lab">pglab</a></dt><dd>The tools these findings were made with, now generic and in their own repository: <code>observe</code>
          (which statements one action runs), <code>diagnose</code> (structural problems, read-only),
          <code>capture</code> (the real workload), <code>clone</code> (a pseudonymized, scaled copy),
          <code>seed</code> (rows for a table that has none yet) and <code>explain</code> (what is wrong with
          each plan). The "How to find it" column above names the check that surfaces each item.</dd>
        <dt>OBP-API source</dt><dd>MetricsArchiveScheduler, MappedMetrics and the metric migrations, read to confirm
          what the code does per archived row.</dd>
        <dt>Machine</dt><dd>Laptop, Core i7-11390H (4 cores / 8 threads), 16 GB RAM, NVMe SSD, PostgreSQL 14 with
          default memory settings. A server with more RAM would show smaller cache effects and larger parallel gains.</dd>
      </dl>
    </section>
    <section class="panel" style="margin-top:28px"><h2>Repeating this on any table</h2>
      <p class="sub">The same path that produced this list, as commands. Steps 1-3 are read-only and safe
        against a live database; the rest only touch a copy.</p>
      <pre>git clone https://github.com/constantine2nd/postgresql-lab &amp;&amp; cd postgresql-lab/pglab
./observe.py  -d proddb --role appuser          # 1. trigger the slow action: what ran, which tables
./diagnose.py -d proddb -t &lt;table&gt;              # 2. duplicate, unused and missing indexes, bloat, cache
./capture.py  -d proddb -t &lt;table&gt; -o wl/       # 3. the statements that really run, with their weights
./clone.py --from proddb -t &lt;table&gt; --to lab --anonymize --scale-to 5000000
psql -d lab -f wl/prepare.sql
./explain.py -w wl/ -d lab                      # 4. what is wrong with each plan, and what to try
./replay.py baseline --workload wl/ --db lab
./replay.py fixed    --workload wl/ --db lab --apply fix.sql
./compare.py baseline fixed --scripts          # 5. did it help, and what did it cost</pre>
      <p class="sub" style="margin-top:10px">For a table that does not exist yet:
        <code>seed.py --rows 1000000 --values col=N</code> fills it from the column types, then
        <code>explain.py --sql expected_queries.sql</code> shows the plans at that size.</p>
    </section>
    <footer>Every number here came from a run on the generated copy, never from production. Regenerate this page with
      <code>./improvements.py</code> in the repository root.</footer>
  </main>
</div>
""".replace("{n_measured}", str(len([i for i in ITEMS if i["confidence"] == "measured"]))).replace("{n_total}", str(len(ITEMS)))
    head = ('<meta charset="utf-8">\n<title>OBP Metric Database Improvements</title>\n'
            '<link rel="preconnect" href="https://fonts.googleapis.com">\n'
            '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
            '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&'
            'family=IBM+Plex+Sans:wght@400;500;600&display=swap">\n')
    open(os.path.join(ROOT, "IMPROVEMENTS.html"), "w").write(head + css + extra + body)


if __name__ == "__main__":
    write_md()
    write_html()
    print(f"Wrote IMPROVEMENTS.html and IMPROVEMENTS.md ({len(ITEMS)} items)")
