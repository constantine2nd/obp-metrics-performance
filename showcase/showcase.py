#!/usr/bin/env python3
"""Run query-optimization demos against obp_showcase and write REPORT.md.

  ./showcase.py                 run all demos in demos/, then write the report
  ./showcase.py 03 p3_keyset    run demos whose file name contains one of the arguments
  ./showcase.py --report        only rebuild REPORT.md / REPORT.html from results/*.json
  ./showcase.py --env           re-collect results/environment.json (machine, settings, dataset)

Demo file format (demos/NN_name.sql), blocks run top to bottom:

  -- @title   Function wrapped around a column in WHERE
  -- @category Anti-pattern              (kind of advice: anti-pattern, indexing, PostgreSQL feature, ...)
  -- @claim   ...                        (the common advice being tested; may repeat for more lines)
  -- @verdict ...                        (our conclusion; may repeat; {t:case} {x:a/b} {pct:a/b} {first:case}
                                         {pages:case} {div:case/N} are filled in from the run)
  -- @tag     confirmed                  (confirmed|partly|myth|different|tradeoff|equivalent, for the HTML page)
  -- @compare bad good                   (case labels for the summary table; default first vs last; none = no comparison)
  -- @setup                              SQL run once before the cases (timed)
  -- @step <label>                       SQL run once at this point (timed)
  -- @case <label> [script] [rollback] [repeat=N] : <description>
       Default: the SQL after an optional "-- @explain" line is measured with
       EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON); SQL before it is a preamble in the same session.
       script   = measure wall-clock time of the whole block run by psql (client side, results discarded)
       rollback = wrap in BEGIN ... ROLLBACK so the case can modify data and be repeated
  -- @info <label>                       run SQL once and include its output in the report
  -- @cleanup                            SQL run at the end, also after a failure
"""
import glob
import json
import os
import re
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
DB = os.environ.get("SHOWCASE_DB", "obp_showcase")
REPEAT = int(os.environ.get("REPEAT", "5"))
SLOW_MS = 2000          # cases slower than this on the first run are repeated only 2 more times
RESULTS = os.path.join(ROOT, "results")

BLOCK_RE = re.compile(r"^-- @(setup|step|case|info|cleanup)\b(.*)$")
HEADER_RE = re.compile(r"^-- @(title|category|claim|verdict|compare|tag)\s+(.*)$")


# ---------------------------------------------------------------- parsing

def parse_demo(path):
    demo = {"file": os.path.basename(path), "title": "", "category": "", "claim": [], "verdict": [],
            "compare": None, "tag": "", "blocks": []}
    block = None
    for line in open(path):
        line = line.rstrip("\n")
        h = HEADER_RE.match(line)
        if h and block is None:
            key, val = h.groups()
            if key in ("claim", "verdict"):
                demo[key].append(val)
            elif key == "compare":
                demo[key] = val.split()
            else:
                demo[key] = val
            continue
        b = BLOCK_RE.match(line)
        if b:
            kind, rest = b.group(1), b.group(2).strip()
            block = {"kind": kind, "sql": []}
            if kind == "case":
                spec, _, desc = rest.partition(" : ")
                words = spec.split()
                block.update(label=words[0], script="script" in words, rollback="rollback" in words,
                             desc=desc.strip(), repeat=REPEAT)
                for w in words:
                    if w.startswith("repeat="):
                        block["repeat"] = int(w.split("=", 1)[1])
            else:
                block["label"] = rest or kind
            demo["blocks"].append(block)
            continue
        if block is not None:
            block["sql"].append(line)
    for block in demo["blocks"]:
        sql = "\n".join(block["sql"]).strip()
        if block["kind"] == "case" and "-- @explain" in sql:
            pre, _, query = sql.partition("-- @explain")
            block["preamble"], block["query"] = pre.strip(), query.strip()
        else:
            block["preamble"], block["query"] = "", sql
        block["sql"] = sql
    return demo


# ---------------------------------------------------------------- psql helpers

def psql(script, tuples=True, check=True):
    args = ["psql", "-X", "-q", "-v", f"ON_ERROR_STOP={1 if check else 0}", "-d", DB]
    if tuples:
        args.insert(1, "-At")
    p = subprocess.run(args, input=script, text=True, capture_output=True)
    if check and p.returncode:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip())
    return p


def timed(script):
    t0 = time.perf_counter()
    psql(script)
    return (time.perf_counter() - t0) * 1000


PSQL_OVERHEAD_MS = None


def psql_overhead():
    """Median cost of starting psql + connecting, subtracted from script-mode timings."""
    global PSQL_OVERHEAD_MS
    if PSQL_OVERHEAD_MS is None:
        PSQL_OVERHEAD_MS = statistics.median(timed("SELECT 1;") for _ in range(7))
    return PSQL_OVERHEAD_MS


# ---------------------------------------------------------------- plans

def node_label(n):
    s = n["Node Type"]
    if n.get("Parallel Aware"):
        s = "Parallel " + s
    if n.get("Scan Direction") == "Backward":
        s += " Backward"
    if "Index Name" in n:
        s += f" ({n['Index Name']})"
    elif "Relation Name" in n:
        s += f" ({n['Relation Name']})"
    return s


def walk(n):
    yield n
    for c in n.get("Plans", []):
        yield from walk(c)


def plan_summary(plan):
    """Main operations, e.g. 'Limit → Index Scan Backward (metric_date_c)'."""
    skip = {"Gather Merge", "Gather", "Result", "Materialize", "Memoize"}
    labels = []
    for n in walk(plan):
        if n["Node Type"] in skip and n.get("Plans"):
            continue
        lab = node_label(n)
        if lab not in labels:
            labels.append(lab)
    return " → ".join(labels[:6]) + (" → …" if len(labels) > 6 else "")


def plan_text(plan, depth=0):
    n = plan
    parts = [node_label(n)]
    if "Index Cond" in n:
        parts.append(f"cond {n['Index Cond']}")
    if "Filter" in n:
        parts.append(f"filter {n['Filter']}")
    parts.append(f"rows={n.get('Actual Rows')} (est {n.get('Plan Rows')}) loops={n.get('Actual Loops')} "
                 f"time={n.get('Actual Total Time')} ms")
    if n.get("Rows Removed by Filter"):
        parts.append(f"removed by filter={n['Rows Removed by Filter']}")
    if "Heap Fetches" in n:
        parts.append(f"heap fetches={n['Heap Fetches']}")
    if "Sort Method" in n:
        parts.append(f"sort={n['Sort Method']} {n.get('Sort Space Used')}kB {n.get('Sort Space Type')}")
    if n.get("Workers Launched") is not None:
        parts.append(f"workers={n['Workers Launched']}")
    parts.append(f"buffers hit={n.get('Shared Hit Blocks', 0)} read={n.get('Shared Read Blocks', 0)}")
    lines = ["  " * depth + ("-> " if depth else "") + " | ".join(parts)]
    for c in n.get("Plans", []):
        lines.extend(plan_text(c, depth + 1))
    return lines


def explain_once(block):
    script = ["\\o /dev/null"]
    if block["rollback"]:
        script.append("BEGIN;")
    if block["preamble"]:
        script.append(block["preamble"])
    script.append("\\o")
    script.append("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + block["query"])
    if block["rollback"]:
        script += ["\\o /dev/null", "ROLLBACK;"]
    out = psql("\n".join(script) + "\n").stdout
    j = json.loads(out[out.index("["):])[0]
    p = j["Plan"]
    return {
        "ms": j["Execution Time"], "planning_ms": j["Planning Time"],
        "hit": p.get("Shared Hit Blocks", 0), "read": p.get("Shared Read Blocks", 0),
        "io_ms": p.get("I/O Read Time"), "rows": p.get("Actual Rows"), "width": p.get("Plan Width"),
        "temp": p.get("Temp Written Blocks", 0),
        "heap_fetches": sum(n.get("Heap Fetches", 0) for n in walk(p)),
        "plan": plan_summary(p), "plan_text": "\n".join(plan_text(p)),
    }


def run_case(block):
    runs = []
    target = block["repeat"]
    while len(runs) < target:
        if block["script"]:
            body = block["sql"]
            if block["rollback"]:
                body = f"BEGIN;\n{body}\nROLLBACK;"
            ms = timed("\\o /dev/null\n" + body + "\n") - psql_overhead()
            runs.append({"ms": max(ms, 0.0)})
        else:
            runs.append(explain_once(block))
        if len(runs) == 1 and runs[0]["ms"] > SLOW_MS:
            target = min(target, 3)
    res = dict(runs[-1]) if not block["script"] else {}
    res.update(label=block["label"], desc=block["desc"], mode="script" if block["script"] else "explain",
               first_ms=runs[0]["ms"], median_ms=statistics.median(r["ms"] for r in runs), runs=len(runs),
               sql=block["sql"])
    if not block["script"]:
        res["first_read"] = runs[0]["read"]
        res["first_hit"] = runs[0]["hit"]
    return res


# ---------------------------------------------------------------- running

def run_demo(path):
    demo = parse_demo(path)
    name = os.path.splitext(demo["file"])[0]
    print(f"== {name}: {demo['title']}")
    out = {k: demo[k] for k in ("file", "title", "category", "claim", "verdict", "compare")}
    out["sections"] = []
    cleanup = [b for b in demo["blocks"] if b["kind"] == "cleanup"]
    try:
        for b in demo["blocks"]:
            kind = b["kind"]
            if kind == "cleanup":
                continue
            if kind in ("setup", "step"):
                ms = timed(b["sql"] + "\n")
                print(f"   {kind:<7} {b['label']:<28} {fmt_ms(ms):>10}")
                out["sections"].append({"kind": kind, "label": b["label"], "ms": ms, "sql": b["sql"]})
            elif kind == "info":
                p = psql(b["sql"] + "\n", tuples=False, check=False)
                text = (p.stdout + p.stderr).strip()
                out["sections"].append({"kind": "info", "label": b["label"], "sql": b["sql"], "output": text})
                print(f"   info    {b['label']}")
            else:
                r = run_case(b)
                r["kind"] = "case"
                out["sections"].append(r)
                extra = "" if r["mode"] == "script" else f"  {r['plan']}"
                print(f"   case    {r['label']:<28} {fmt_ms(r['median_ms']):>10}{extra}")
    finally:
        for b in cleanup:
            psql(b["sql"] + "\n", check=False)
    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(RESULTS, name + ".json"), "w") as f:
        json.dump(out, f, indent=1)


# ---------------------------------------------------------------- environment

ENV_FILE = os.path.join(RESULTS, "environment.json")
SETTINGS = ["shared_buffers", "effective_cache_size", "work_mem", "maintenance_work_mem", "random_page_cost",
            "max_worker_processes", "max_parallel_workers", "max_parallel_workers_per_gather", "jit",
            "track_io_timing", "synchronous_commit", "max_wal_size", "checkpoint_timeout", "autovacuum",
            "pg_stat_statements.track"]


WHY = {   # how each setting relates to the measured results
    "shared_buffers": "PostgreSQL's cache: decides 'hit' vs 'read' in every plan (demos 00, 12)",
    "effective_cache_size": "planner's guess of total cache (shared_buffers + OS); higher favours index scans",
    "work_mem": "per sort / hash step; top-N sorts and aggregates (01, 07, 11) fit in 4 MB here",
    "maintenance_work_mem": "index build speed; the demos set 1 GB in their own session",
    "random_page_cost": "4 is the spinning-disk default; on NVMe ~1.1 is common and shifts plans to index scans",
    "max_worker_processes": "upper limit for parallel workers (demo 14)",
    "max_parallel_workers": "parallel workers available to all queries (demo 14)",
    "max_parallel_workers_per_gather": "workers per query: parallel scans in 04, 06, 11, 17; varied 0-6 in demo 14",
    "jit": "compiles expressions of large queries; adds start-up time to big aggregates (11, 14)",
    "track_io_timing": "adds I/O read time to BUFFERS output and pg_stat_statements",
    "synchronous_commit": "each commit waits for the WAL flush; affects the insert cases (07, 10, 20)",
    "max_wal_size": "checkpoint distance; matters for index builds and bulk writes",
    "checkpoint_timeout": "checkpoint interval; a checkpoint during a case can add write time",
    "autovacuum": "keeps statistics fresh; demo 01 turns it off for its own table to show stale statistics",
    "pg_stat_statements.track": "which statements pg_stat_statements records (demo 19)",
}


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, text=True, capture_output=True).stdout.strip()
    except OSError:
        return ""


def rows(sql):
    return [line.split("|") for line in psql(sql + "\n").stdout.splitlines() if line]


def collect_environment():
    """Machine, PostgreSQL and dataset facts, saved with the results so the report describes the run."""
    lscpu = dict(l.split(":", 1) for l in sh("LC_ALL=C lscpu").splitlines() if ":" in l)
    lscpu = {k.strip(): v.strip() for k, v in lscpu.items()}
    cores = int(lscpu.get("Core(s) per socket", "0") or 0) * int(lscpu.get("Socket(s)", "1") or 1)
    mem_kb = int(re.search(r"MemTotal:\s+(\d+)", open("/proc/meminfo").read()).group(1))
    disks = []
    for l in sh("lsblk -d -n -P -o NAME,MODEL,SIZE,ROTA,TYPE").splitlines():
        f = dict(re.findall(r'(\w+)="([^"]*)"', l))
        if f.get("TYPE") == "disk" and not f["NAME"].startswith(("zram", "loop")):
            disks.append(f"{f['MODEL'].strip() or f['NAME']} {f['SIZE']} ({'HDD' if f['ROTA'] == '1' else 'SSD'})")
    os_name = re.search(r'PRETTY_NAME="([^"]+)"', open("/etc/os-release").read())
    env = {
        "collected": time.strftime("%Y-%m-%d %H:%M"),
        "machine": {
            "CPU": f"{lscpu.get('Model name', '?')} ({cores} cores / {lscpu.get('CPU(s)', '?')} threads)",
            "RAM": f"{mem_kb / 1024 ** 2:.1f} GiB usable",
            "Disk": ", ".join(disks) or "?",
            "OS": f"{os_name.group(1) if os_name else '?'}, kernel {sh('uname -r')}",
        },
        "postgres": {
            "Server": psql("SELECT version();").stdout.strip().split(" on ")[0],
            "Client": sh("psql --version"),
            "Extensions": ", ".join(f"{n} {v}" for n, v in rows(
                "SELECT extname, extversion FROM pg_extension WHERE extname <> 'plpgsql' ORDER BY 1")),
            "Database": f"{DB}, " + psql(f"SELECT pg_size_pretty(pg_database_size('{DB}'));").stdout.strip(),
        },
        "settings": [{"name": n, "value": v, "source": src, "why": WHY.get(n, "")} for n, v, src in rows(
            "SELECT name, current_setting(name), source FROM pg_settings WHERE name IN ("
            + ", ".join(f"'{n}'" for n in SETTINGS) + ") ORDER BY name")],
        "tables": [{"table": t, "rows": int(float(r)), "data": d, "indexes": i, "index_count": int(n), "from": f, "to": to}
                   for t, r, d, i, n, f, to in rows("""
            SELECT c.relname, c.reltuples, pg_size_pretty(pg_table_size(c.oid)), pg_size_pretty(pg_indexes_size(c.oid)),
                   (SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid),
                   CASE c.relname WHEN 'metric' THEN (SELECT min(date_c)::date FROM metric)
                                  ELSE (SELECT min(date_c)::date FROM metricarchive) END,
                   CASE c.relname WHEN 'metric' THEN (SELECT max(date_c)::date FROM metric)
                                  ELSE (SELECT max(date_c)::date FROM metricarchive) END
              FROM pg_class c WHERE c.relname IN ('metric', 'metricarchive') ORDER BY 1""")],
        "method": {
            "Timing": f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON), median of {REPEAT} runs "
                      f"(3 when the first run takes over {SLOW_MS / 1000:.0f} s); first run reported separately",
            "Client timing": "psql wall clock, results discarded, minus psql start-up "
                             f"({psql_overhead():.0f} ms, measured each run)",
            "Isolation": "each demo creates its own indexes/tables and drops them afterwards; "
                         "data-changing cases run in BEGIN ... ROLLBACK",
            "Runner": f"showcase.py, Python {sys.version.split()[0]}",
        },
    }
    env["memory"] = collect_memory()
    os.makedirs(RESULTS, exist_ok=True)
    with open(ENV_FILE, "w") as f:
        json.dump(env, f, indent=1)
    return env


def collect_memory():
    """RAM, OS page cache, PostgreSQL memory settings vs data sizes, and cache statistics of the showcase run."""
    mi = {k: int(v) * 1024 for k, v in re.findall(r"^(\w+):\s+(\d+) kB", open("/proc/meminfo").read(), re.M)}
    (sb, ecs, wm, mwm, db_b, m_b, a_b) = [int(v) for v in psql(f"""SELECT
        pg_size_bytes(current_setting('shared_buffers')), pg_size_bytes(current_setting('effective_cache_size')),
        pg_size_bytes(current_setting('work_mem')), pg_size_bytes(current_setting('maintenance_work_mem')),
        pg_database_size('{DB}'), pg_total_relation_size('metric'), pg_total_relation_size('metricarchive');""").stdout.split("|")]
    hit, read, read_ms, tmp_files, tmp_bytes = [float(v or 0) for v in psql(f"""SELECT blks_hit, blks_read,
        blk_read_time, temp_files, temp_bytes FROM pg_stat_database WHERE datname = '{DB}';""").stdout.split("|")]
    return {
        "sizes": [   # bytes, for the chart: kind = memory or data
            {"label": "RAM (usable)", "bytes": mi["MemTotal"], "kind": "memory"},
            {"label": "OS page cache (at collection)", "bytes": mi.get("Cached", 0) + mi.get("Buffers", 0), "kind": "memory"},
            {"label": "effective_cache_size (planner assumption)", "bytes": ecs, "kind": "memory"},
            {"label": "shared_buffers (PostgreSQL cache)", "bytes": sb, "kind": "memory"},
            {"label": f"{DB} database", "bytes": db_b, "kind": "data"},
            {"label": "metricarchive + indexes", "bytes": a_b, "kind": "data"},
            {"label": "metric + indexes", "bytes": m_b, "kind": "data"},
        ],
        "shared_buffers": sb, "effective_cache_size": ecs, "work_mem": wm, "maintenance_work_mem": mwm,
        "ram": mi["MemTotal"], "ram_available": mi.get("MemAvailable", 0),
        "page_cache": mi.get("Cached", 0) + mi.get("Buffers", 0), "swap": mi.get("SwapTotal", 0),
        "db_bytes": db_b,
        "run": {"pages_hit": int(hit), "pages_read": int(read), "read_ms": read_ms,
                "hit_ratio": hit / (hit + read) if hit + read else None,
                "ms_per_read": read_ms / read if read else None,
                "temp_files": int(tmp_files), "temp_bytes": int(tmp_bytes)},
    }


def human(b):
    for unit, size in (("GB", 1024 ** 3), ("MB", 1024 ** 2), ("kB", 1024)):
        if b >= size:
            v = b / size
            return f"{v:.1f} {unit}" if v < 10 else f"{v:,.0f} {unit}"
    return f"{b} B"


def memory_facts(m):
    """(label, value, explanation) rows shared by the Markdown and HTML reports."""
    r = m["run"]
    rows = [
        ("RAM", f"{human(m['ram'])} usable, {human(m['ram_available'])} available at collection",
         "everything not used by programs acts as the OS page cache"),
        ("OS page cache", human(m["page_cache"]),
         "file pages the kernel keeps in RAM; PostgreSQL's 'read' pages are often served from here"),
        ("shared_buffers", f"{human(m['shared_buffers'])} = {m['shared_buffers'] // 8192:,} pages of 8 kB",
         f"PostgreSQL's own cache; the data is {m['db_bytes'] / m['shared_buffers']:.0f}× larger. "
         f"Common starting point: 25% of RAM ≈ {human(m['ram'] // 4)}"),
        ("effective_cache_size", human(m["effective_cache_size"]),
         "not allocated: tells the planner how much cache (shared_buffers + OS) to expect, which favours index scans"),
        ("work_mem", human(m["work_mem"]),
         "memory per sort / hash step before it spills to temp files"),
        ("maintenance_work_mem", human(m["maintenance_work_mem"]),
         "for CREATE INDEX and VACUUM; the demos raise it to 1 GB for their index builds"),
    ]
    if r["hit_ratio"] is not None:
        rows.append(("Cache hit ratio", f"{r['hit_ratio'] * 100:.1f}%",
                     f"since {DB} was created, all runs including setup and index builds: "
                     f"{r['pages_hit']:,} pages from shared_buffers, {r['pages_read']:,} requested from the OS "
                     f"({human(r['pages_read'] * 8192)}). Large scans bypass shared_buffers (a 256 kB ring) "
                     "so they don't evict it, which keeps this ratio low"))
    if r["ms_per_read"] is not None:
        rows.append(("Avg read time per page", f"{r['ms_per_read'] * 1000:.1f} µs",
                     "from track_io_timing; a few µs means the OS page cache, NVMe random reads take ~50-100 µs"))
    rows.append(("Temp files", f"{r['temp_files']:,} files, {human(r['temp_bytes'])}",
                 "same period. Mostly index builds and the materialized view build/refresh (demo 11: sorting 5M rows "
                 "with 4 MB work_mem). Two measured cases spill a little: 02 star_index (~3 MB per run, sorting whole "
                 "rows) and 05 union_count (~1 MB, UNION de-duplication); a larger work_mem keeps them in memory"))
    return rows


BUFFERS_GUIDE = [
    ("shared hit", "page found in shared_buffers: no system call, fastest"),
    ("shared read", "page requested from the OS: served from the OS page cache (µs) or the disk (tens of µs+)"),
    ("dirtied / written", "pages this query changed / had to write out itself to free a buffer"),
    ("I/O Timings: read", "time spent in those reads (needs track_io_timing = on)"),
    ("temp read / written", "sort or hash data spilled to disk because it did not fit in work_mem"),
    ("first run vs median", "the first run shows a cold cache, later runs find the pages already cached"),
]


def load_environment():
    if os.path.exists(ENV_FILE):
        return json.load(open(ENV_FILE))
    try:
        return collect_environment()
    except Exception:   # database gone and no saved copy
        return None


REPRODUCE = [
    "cd ../loadtest && ./01_build_base.sh   # obp_loadtest_base: copy of obp_mapped metric tables, "
    "scaled to 5M + 15M rows (~3 min)",
    "cd ../showcase && ./00_setup.sh                           # obp_showcase: clone of the base (~20 s) + pg_trgm, pg_buffercache",
    "./showcase.py                                             # all demos (~4 min), writes REPORT.md and REPORT.html",
    "./99_cleanup.sh --yes                                     # drop obp_showcase afterwards (6.5 GB)",
]


# ---------------------------------------------------------------- report

def fmt_ms(ms):
    if ms is None:
        return "-"
    if ms >= 1000:
        return f"{ms / 1000:.2f} s"
    if ms >= 10:
        return f"{ms:.0f} ms"
    if ms >= 1:
        return f"{ms:.1f} ms"
    return f"{ms:.2f} ms"


def fmt_blocks(n):
    if n is None:
        return "-"
    mb = n * 8 / 1024
    return f"{n:,}" + (f" ({mb:,.0f} MB)" if mb >= 1 else "")


def cases(d):
    return [s for s in d["sections"] if s["kind"] == "case"]


def speedup(d):
    cs = {c["label"]: c for c in cases(d)}
    if len(cs) < 2 or d.get("compare") == ["none"]:
        return None, None, None
    a, b = d["compare"] if d.get("compare") else (cases(d)[0]["label"], cases(d)[-1]["label"])
    ca, cb = cs.get(a), cs.get(b)
    if not ca or not cb or not cb["median_ms"]:
        return ca, cb, None
    return ca, cb, ca["median_ms"] / cb["median_ms"]


def fmt_speed(x):
    if x is None:
        return "-"
    if x >= 1.5:
        return f"**{x:,.0f}× faster**" if x >= 10 else f"**{x:.1f}× faster**"
    if x <= 1 / 1.5:
        return f"{1 / x:.1f}× slower"
    return "≈ same"


PLACEHOLDER_RE = re.compile(r"\{(t|first|x|pct|pages|div):([A-Za-z0-9_]+)(?:/([A-Za-z0-9_]+))?\}")


def render_numbers(text, d):
    """Fills measured values into verdict text, so it always matches this run:
    {t:case} median time, {first:case} first-run time, {x:a/b} ratio a/b, {pct:a/b} change of a vs b,
    {pages:case} pages hit + read, {div:case/N} median time divided by N."""
    cs = {c["label"]: c for c in cases(d)}

    def sub(m):
        kind, a, b = m.groups()
        ca = cs.get(a)
        if not ca:
            return m.group(0)
        if kind == "t":
            return fmt_ms(ca["median_ms"])
        if kind == "first":
            return fmt_ms(ca["first_ms"])
        if kind == "pages":
            return f"{ca.get('hit', 0) + ca.get('read', 0):,}"
        if kind == "div":
            return fmt_ms(ca["median_ms"] / float(b))
        cb = cs.get(b)
        if not cb or not cb["median_ms"]:
            return m.group(0)
        r = ca["median_ms"] / cb["median_ms"]
        if kind == "pct":
            return f"{(r - 1) * 100:+.0f}%"
        return f"{r:,.0f}×" if r >= 10 else f"{r:.1f}×"
    return PLACEHOLDER_RE.sub(sub, text)


def md_escape(s):
    return s.replace("|", "\\|")


def html(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def compact_plan(plan_text):
    """Plan tree with just node, actual/estimated rows and time, narrow enough for half a page."""
    out = []
    for line in plan_text.splitlines():
        parts = line.split(" | ")
        stats = next((p for p in parts if p.startswith("rows=")), "")
        m = re.match(r"rows=(\S+) \(est (\S+)\) loops=\S+ time=(\S+) ms", stats)
        indent = len(line) - len(line.lstrip())
        node = parts[0].strip()
        out.append(" " * indent + node + (f"\n{' ' * (indent + 3)}rows {m[1]} (est {m[2]}), {m[3]} ms" if m else ""))
    return "\n".join(out)


def side_by_side(d):
    """Two-column HTML table comparing the compared pair (before | after); renders inside Markdown."""
    cs = cases(d)
    if d.get("compare") == ["none"]:
        pair, heads = cs[:2], ("A", "B")
    else:
        a, b, _ = speedup(d)
        pair, heads = [a, b], ("❌ Before", "✅ After")
    if len(pair) < 2 or not all(pair):
        return []
    _, _, x = speedup(d)

    def cell(c):
        client = c["mode"] == "script"
        rows = [f"<b>{fmt_ms(c['median_ms'])}</b>" + (" <i>client</i>" if client else "")
                + f" &nbsp;·&nbsp; first run {fmt_ms(c['first_ms'])}"]
        if not client:
            rows.append(f"pages hit {c['hit']:,} / read {c['read']:,} &nbsp;·&nbsp; {c['rows']:,} row{'' if c['rows'] == 1 else 's'}")
        pre, sep, query = c["sql"].partition("-- @explain")
        if sep:
            rows.append("<br><sub>after a session preamble (see details below)</sub>")
        rows.append(f"<pre>{html((query if sep else pre).strip())}</pre>")
        if not client:
            rows.append(f"<pre>{html(compact_plan(c['plan_text']))}</pre>")
        return "<br>".join(rows[:2]) + "".join(rows[2:])

    speed = re.sub(r"\*\*(.*?)\*\*", r"<b>\1</b>", fmt_speed(x)) if x else ""
    return ["<table>",
            f"<tr><th width=\"50%\">{heads[0]}: <code>{pair[0]['label']}</code><br><sub>{html(pair[0]['desc'])}</sub></th>"
            f"<th width=\"50%\">{heads[1]}: <code>{pair[1]['label']}</code><br><sub>{html(pair[1]['desc'])}</sub>"
            + (f"<br>{speed}" if speed else "") + "</th></tr>",
            f"<tr><td valign=\"top\">{cell(pair[0])}</td><td valign=\"top\">{cell(pair[1])}</td></tr>",
            "</table>", ""]


def env_markdown(env):
    L = ["## Test environment", "", f"*Collected {env['collected']} (automatically at the end of every `./showcase.py` run, or with `--env`).*", "",
         "| Machine | |", "|---|---|"]
    L += [f"| {k} | {md_escape(v)} |" for k, v in env["machine"].items()]
    L += ["", "| PostgreSQL | |", "|---|---|"] + [f"| {k} | {md_escape(v)} |" for k, v in env["postgres"].items()]
    if env.get("memory"):
        L += ["", "### Memory and caching", "", "| | Value | What it means |", "|---|---|---|"]
        L += [f"| {k} | {md_escape(v)} | {md_escape(e)} |" for k, v, e in memory_facts(env["memory"])]
        L += ["", "Sizes: " + ", ".join(f"{x['label']} {human(x['bytes'])}" for x in env["memory"]["sizes"]) + ".",
              "", "**Reading BUFFERS** (one page = 8 kB)", "", "| Term | Meaning |", "|---|---|"]
        L += [f"| {k} | {v} |" for k, v in BUFFERS_GUIDE]
    L += ["", "| Setting | Value | Source | Why it matters here |", "|---|---|---|---|"]
    L += [f"| `{s['name']}` | {s['value']} | {s['source']} | {md_escape(s.get('why', ''))} |" for s in env["settings"]]
    L += ["", "| Table | Rows | Data | Indexes | Dates |", "|---|---|---|---|---|"]
    L += [f"| `{t['table']}` | {t['rows']:,} | {t['data']} | {t['indexes']} ({t['index_count']}) | {t['from']} → {t['to']} |"
          for t in env["tables"]]
    L += ["", "The rows are generated from the real `obp_mapped` rows (same mix of consumers, URLs, API functions, "
          "verbs and HTTP codes) with new correlation ids, varied durations and dates spread over the period.", "",
          "| Method | |", "|---|---|"] + [f"| {k} | {md_escape(v)} |" for k, v in env["method"].items()]
    L += ["", "**Reproduce**", "", "```bash", *REPRODUCE, "```", ""]
    return L


def write_report():
    demos = []
    for p in sorted(glob.glob(os.path.join(RESULTS, "*.json"))):
        if p == ENV_FILE:
            continue
        d = json.load(open(p))
        src = os.path.join(ROOT, "demos", d["file"])
        if os.path.exists(src):   # text may have been edited after the run
            d.update({k: v for k, v in parse_demo(src).items() if k in ("title", "category", "claim", "verdict", "compare", "tag")})
        d["verdict"] = [render_numbers(" ".join(d["verdict"]), d)] if d.get("verdict") else []
        demos.append(d)
    L = ["# Query optimization patterns on real OBP metric data", "",
         "Common SQL optimization advice (anti-patterns, indexing and query patterns, database-specific features) "
         "tested on `obp_showcase`: 5M `metric` + 15M `metricarchive` rows modelled on the real OBP rows. "
         "Each claim is confirmed or corrected with measurements.",
         "",
         f"PostgreSQL 14 on a 4-core / 8-thread laptop CPU, 16 GB RAM, NVMe, `shared_buffers` = 128 MB (default); full details under [Test environment](#test-environment). Times are the median of up to "
         f"{REPEAT} runs from `EXPLAIN (ANALYZE, BUFFERS)` (server-side execution time) unless marked *client*: "
         "those are measured end to end through psql, including result transfer, minus the psql start-up time. "
         "“First run” shows cache effects. Pages count from cache as *hit*; *read* came from the OS, which may "
         "itself have cached them.",
         "", "Regenerate: `./showcase.py` (all) or `./showcase.py <demo>`; details per demo below.", "",
         "## Summary", "",
         "| # | Pattern | Category | Before → after | Result | Verdict |",
         "|---|---|---|---|---|---|"]
    for d in demos:
        a, b, x = speedup(d)
        num = d["file"].split("_")[0]
        ba = f"{fmt_ms(a['median_ms'])} → {fmt_ms(b['median_ms'])}" if a and b else "-"
        verdict = " ".join(d["verdict"]).split(". ")[0].rstrip(".") if d["verdict"] else "(not yet reviewed)"
        L.append(f"| {num} | [{md_escape(d['title'])}](#{anchor(d)}) | {md_escape(d.get('category', ''))} | {ba} | "
                 f"{fmt_speed(x)} | {md_escape(verdict)} |")
    L.append("")
    env = load_environment()
    if env:
        L += env_markdown(env)

    for d in demos:
        L += [f"## {d['file'].split('_')[0]} {d['title']}", ""]
        if d.get("category"):
            L += [f"*{d['category']}*", ""]
        if d["claim"]:
            L += ["> **Common advice:** " + " ".join(d["claim"]), ""]
        if d["verdict"]:
            L += ["**Verdict:** " + " ".join(d["verdict"]), ""]
        cs = cases(d)
        L += side_by_side(d)
        if cs:
            L += ["**All cases**", "",
                  "| Case | What | Time | First run | Plan | Pages hit / read | Rows |",
                  "|---|---|---|---|---|---|---|"]
            for c in cs:
                if c["mode"] == "script":
                    L.append(f"| `{c['label']}` | {md_escape(c['desc'])} | {fmt_ms(c['median_ms'])} *client* | "
                             f"{fmt_ms(c['first_ms'])} | - | - | - |")
                else:
                    L.append(f"| `{c['label']}` | {md_escape(c['desc'])} | {fmt_ms(c['median_ms'])} | "
                             f"{fmt_ms(c['first_ms'])} | {md_escape(c['plan'])} | "
                             f"{c['hit']:,} / {c['read']:,} | {c['rows']:,} |")
            L.append("")
        for s in d["sections"]:
            if s["kind"] in ("setup", "step"):
                L += [f"<details><summary>{s['kind']}: {s['label']} ({fmt_ms(s['ms'])})</summary>", "",
                      "```sql", s["sql"], "```", "</details>", ""]
            elif s["kind"] == "info":
                L += [f"**{s['label']}**", "", "```", s["output"], "```", ""]
        for c in cs:
            L += [f"<details><summary>{c['label']}: SQL" + (" and plan" if c["mode"] == "explain" else "")
                  + "</summary>", "", "```sql", c["sql"], "```"]
            if c["mode"] == "explain":
                L += ["", "```", c["plan_text"],
                      f"Planning {fmt_ms(c['planning_ms'])}, execution {fmt_ms(c['ms'])}"
                      + (f", I/O read {fmt_ms(c['io_ms'])}" if c.get("io_ms") else ""), "```"]
            L += ["</details>", ""]
    text = "\n".join(L)
    with open(os.path.join(ROOT, "REPORT.md"), "w") as f:          # always the latest
        f.write(text)
    os.makedirs(os.path.join(ROOT, "reports"), exist_ok=True)
    stamp = time.strftime("%Y-%m-%d_%H%M%S")
    with open(os.path.join(ROOT, "reports", stamp + ".md"), "w") as f:
        f.write(text)
    write_html(demos)
    print(f"Wrote REPORT.md and REPORT.html ({len(demos)} demos)")


def write_html(demos):
    """REPORT.html: report_template.html with the results embedded as JSON (charts are drawn in the page)."""
    out = []
    for d in demos:
        cs = []
        for c in cases(d):
            pre, sep, query = c["sql"].partition("-- @explain")
            cs.append({
                "label": c["label"], "desc": c["desc"], "mode": c["mode"],
                "median_ms": c["median_ms"], "first_ms": c["first_ms"],
                "hit": c.get("hit"), "read": c.get("read"), "rows": c.get("rows"),
                "plan": c.get("plan"), "plan_text": c.get("plan_text"),
                "plan_compact": compact_plan(c["plan_text"]) if c.get("plan_text") else "",
                "planning_ms": c.get("planning_ms"), "io_ms": c.get("io_ms"),
                "sql_query": (query if sep else pre).strip(), "sql_full": c["sql"], "has_preamble": bool(sep and pre.strip()),
            })
        a, b, x = speedup(d)
        neutral = d.get("compare") == ["none"]
        pair = None
        if neutral and len(cs) >= 2:
            pair = cs[:2]
        elif a and b:
            pair = [next(c for c in cs if c["label"] == a["label"]), next(c for c in cs if c["label"] == b["label"])]
        num = d["file"].split("_")[0]
        title = d["title"]
        out.append({
            "num": num, "title": title, "short": re.split(r" \(|: ", title)[0],
            "category": d.get("category", ""), "claim": " ".join(d["claim"]), "verdict": " ".join(d["verdict"]),
            "tag": d.get("tag", ""), "speedup": x, "pair": pair, "neutralPair": neutral, "cases": cs,
            "steps": [{"kind": s["kind"], "label": s["label"], "ms": s["ms"], "sql": s["sql"]}
                      for s in d["sections"] if s["kind"] in ("setup", "step")],
            "infos": [{"label": s["label"], "output": s["output"]} for s in d["sections"] if s["kind"] == "info"],
        })
    meta = {
        "eyebrow": "PostgreSQL 14 · 5M metric + 15M metricarchive rows · obp_showcase",
        "lede": "Common SQL optimization advice (anti-patterns, indexing and query patterns, database-specific "
                "features) tested on data modelled on real OBP API metrics. "
                "Each claim is confirmed or corrected with measurements: median of up to "
                f"{REPEAT} runs of <code>EXPLAIN (ANALYZE, BUFFERS)</code> on a 4-core / 8-thread laptop with 16 GB RAM and NVMe, "
                "<code>shared_buffers</code> at the 128 MB default.",
        "footer": "Times are server-side execution time unless marked <i>client</i> (end to end through psql, "
                  "including result transfer, minus psql start-up). A page is 8 kB; <i>hit</i> = found in PostgreSQL's "
                  "cache, <i>read</i> = requested from the OS, which may itself have cached it. Exact times vary by about "
                  "±30% between runs; ratios, sizes and plans were stable. Regenerate with <code>./showcase.py</code> "
                  "in <code>showcase/</code>.",
    }
    env = load_environment()
    if env and env.get("memory"):
        env["memory_facts"] = [list(r) for r in memory_facts(env["memory"])]
        env["buffers_guide"] = [list(r) for r in BUFFERS_GUIDE]
    data = json.dumps({"meta": meta, "env": env, "reproduce": REPRODUCE, "demos": out}).replace("</", "<\\/")
    template = open(os.path.join(ROOT, "report_template.html")).read()
    page = template.replace("__DATA__", data)
    with open(os.path.join(ROOT, "REPORT.html"), "w") as f:        # always the latest
        f.write(page)
    os.makedirs(os.path.join(ROOT, "reports"), exist_ok=True)
    with open(os.path.join(ROOT, "reports", time.strftime("%Y-%m-%d_%H%M%S") + ".html"), "w") as f:
        f.write(page)


def anchor(d):
    t = f"{d['file'].split('_')[0]} {d['title']}".lower()
    return re.sub(r"[^a-z0-9 _-]", "", t).replace(" ", "-")


def main():
    args = sys.argv[1:]
    if args == ["--env"]:
        collect_environment()
        args = ["--report"]
    if args != ["--report"]:
        files = sorted(glob.glob(os.path.join(ROOT, "demos", "*.sql")))
        if args:
            files = [f for f in files if any(a in os.path.basename(f) for a in args)]
            if not files:
                sys.exit("no demo matches " + " ".join(args))
        for f in files:
            run_demo(f)
        collect_environment()   # after the demos, so the cache statistics cover this run
    write_report()


if __name__ == "__main__":
    main()
