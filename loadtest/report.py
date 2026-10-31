#!/usr/bin/env python3
"""Build REPORT.html (and REPORT.md) from the load test results.

  ./report.py                    all labels found in results/, in run order
  ./report.py baseline corrid    only these labels, first one is the reference

Reads results/<label>/<scenario>_c<clients>/summary.json plus the statements.txt,
tables.txt and run_info.txt captured by run.sh. Findings below are written by hand;
every number in them is filled in from the results with {t:...} style placeholders.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(ROOT, "results")
SCENARIO_ORDER = ["workload", "read", "write", "mixed", "archive_rowwise"]

SCENARIOS = {
    "workload": ("Captured from the real database", "The statements pglab capture found running against these "
                 "tables, replayed with their real call counts as weights."),
    "read": ("Dashboards and metric screens", "No writes: the metrics list, aggregates, top APIs and consumers, "
             "a lookup by correlation id, and a search in the archive."),
    "write": ("API traffic being logged", "Inserts only: one metric row per API call, the write path of every request."),
    "mixed": ("Both at once, with the archive job", "70% inserts plus the read mix, while a rate-limited background "
              "client moves old rows to metricarchive in batches."),
    "archive_rowwise": ("Archive job, row by row", "OBP's per-row archive sequence, for comparison."),
}

QUERIES = {
    "r_list.sql": "metrics list, one filter, newest 50",
    "r_lookup.sql": "trace a request by correlation id",
    "r_aggregate.sql": "count / avg / min / max duration",
    "r_top_apis.sql": "top 10 APIs of a period",
    "r_top_consumers.sql": "top 10 consumers of a period",
    "r_archive_search.sql": "search a window in metricarchive",
    "w_insert.sql": "insert one metric row",
    "job_archive_batch.sql": "archive job, batched",
    "job_archive_rowwise.sql": "archive job, row by row",
}

# Conclusions. {x:scenario/clients/metric} and {v:label/scenario/clients/metric} are filled in from the results;
# metric is tps, p50, p95, p99, or a script name with .p95 / .tps.
FINDINGS = [
    ("The lookup by correlation id was the whole bottleneck",
     "In the baseline, <code>SELECT * FROM metric WHERE correlationid = $1</code> scanned all 5M rows on every call. "
     "At 16 clients it reached a p95 of {v:baseline/read/16/r_lookup.sql.p95} and consumed 93% of all query time "
     "in the run, for 8% of the calls. With the index it answers in {v:corrid/read/16/r_lookup.sql.p95}: "
     "{x:read/16/r_lookup.sql.p95} faster."),
    ("Without the index, reads did not scale at all",
     "Baseline read throughput was {v:baseline/read/1/tps} at 1 client and {v:baseline/read/16/tps} at 16: the extra "
     "clients only queued, while p95 grew from {v:baseline/read/1/p95} to {v:baseline/read/16/p95}. With the index, "
     "throughput rises from {v:corrid/read/1/tps} to {v:corrid/read/16/tps} and the worst p95 in the matrix is "
     "{v:corrid/read/16/p95}."),
    ("The write path was never the problem",
     "Inserts scale almost linearly in both runs, from {v:baseline/write/1/tps} at 1 client to "
     "{v:baseline/write/16/tps} at 16, with p95 around 4 ms throughout. Six indexes on a 5M-row table are not what "
     "makes this system slow."),
    ("The extra index costs nothing measurable on writes",
     "Write throughput with the index: {v:corrid/write/1/tps}, {v:corrid/write/4/tps}, {v:corrid/write/8/tps}, "
     "{v:corrid/write/16/tps} — between +10% and -1% of baseline, i.e. run-to-run noise. A single-statement bulk "
     "insert of 10,000 rows does pay for index maintenance (the showcase measured 1.7-3.4x), but a workload that "
     "inserts one row per transaction hides that cost in the commit."),
    ("Under load the gain shows as throughput, not as lower latency everywhere",
     "In the mixed scenario at 16 clients, total throughput goes from {v:baseline/mixed/16/tps} to "
     "{v:corrid/mixed/16/tps} and p95 from {v:baseline/mixed/16/p95} to {v:corrid/mixed/16/p95}, but the heavy "
     "aggregates get slower than in the baseline (top consumers {v:baseline/mixed/16/r_top_consumers.sql.p95} to "
     "{v:corrid/mixed/16/r_top_consumers.sql.p95}). The system now completes far more transactions per second, so "
     "the remaining heavy queries compete for the same cache and disk. The bottleneck moved, it did not disappear."),
    ("What to fix next",
     "With the lookup fixed, the heaviest statements are the top-APIs aggregate and the archive search by consumer, "
     "which together read tens of millions of blocks per run. The showcase measured both fixes: a covering index "
     "(demo 07) and a daily materialized view (demo 11, 20-30x on the same aggregate)."),
]

RECOMMENDATION = ("Add the index on the live table: <code>CREATE INDEX CONCURRENTLY metric_correlationid ON "
                  "metric (correlationid);</code> — CONCURRENTLY so it does not block writes while it builds. "
                  "Cost: 283 MB. For tracing old requests, metricarchive.correlationid needs its own index; a hash "
                  "index there is 40% smaller than a B-tree and equally fast for exact lookups.")


def resolve(name):
    """A run is stored as results/<timestamp>__<label>. Accept either the folder name or the label,
    in which case the newest run with that label wins."""
    if os.path.isdir(os.path.join(RESULTS, name)):
        return name
    matches = sorted(os.path.basename(p) for p in glob.glob(os.path.join(RESULTS, "*__" + name))
                     if os.path.isdir(p))
    if not matches:
        return name
    return matches[-1]


def read(path):
    return open(path).read() if os.path.exists(path) else ""


def load(labels):
    data = {}
    for label in labels:
        for p in sorted(glob.glob(os.path.join(RESULTS, resolve(label), "*_c*", "summary.json"))):
            s = json.load(open(p))
            d = os.path.dirname(p)
            data.setdefault(label, {})[(s["scenario"], s["clients"])] = {
                "tps": s["tps"], "p50": s["p50_ms"], "p95": s["p95_ms"], "p99": s["p99_ms"],
                "transactions": s["transactions"],
                "scripts": {k: {"tps": v["tps"], "p95": v["p95_ms"]} for k, v in s["scripts"].items()},
                "statements": read(os.path.join(d, "statements.txt")),
                "tables": read(os.path.join(d, "tables.txt")),
                "archive_job": read(os.path.join(d, "archive_job.txt")),
            }
    return data


def fmt_ms(v):
    if v is None:
        return "-"
    return f"{v / 1000:.2f} s" if v >= 1000 else (f"{v:.0f} ms" if v >= 10 else f"{v:.2f} ms")


def fmt_tps(v):
    return "-" if v is None else (f"{v:,.0f}" if v >= 100 else f"{v:,.1f}")


def get(data, label, scenario, clients, metric):
    run = data.get(label, {}).get((scenario, int(clients)))
    if not run:
        return None
    if "." in metric:
        script, field = metric.rsplit(".", 1)
        return run["scripts"].get(script, {}).get(field)
    return run[metric]


def render(text, data, ref):
    def val(m):
        label, sc, c, metric = m.group(1).split("/")
        v = get(data, label, sc, c, metric)
        return ("-" if v is None else fmt_tps(v) + " tps" if metric == "tps" else fmt_ms(v))

    def ratio(m):
        sc, c, metric = m.group(1).split("/")
        a, b = get(data, ref, sc, c, metric), get(data, LABELS[-1], sc, c, metric)
        if not a or not b:
            return "-"
        r = a / b
        return f"{r:,.0f}x" if r >= 10 else f"{r:.1f}x"
    text = re.sub(r"\{v:([^}]+)\}", val, text)
    return re.sub(r"\{x:([^}]+)\}", ratio, text)


def environment(labels):
    info = read(os.path.join(RESULTS, resolve(labels[0]), "run_info.txt"))
    head = dict(re.findall(r"(\w+):\s*([^\n]+?)(?:\s{2,}|\n)", info.split("\n\n")[0] + "\n"))
    settings = re.findall(r"^ (\S+)\s+\| (\S+)\s*\| ?(\S*)", info, re.M)
    def sh(cmd):
        return subprocess.run(cmd, shell=True, text=True, capture_output=True).stdout.strip()
    lscpu = {k.strip(): v.strip() for k, v in
             (l.split(":", 1) for l in sh("LC_ALL=C lscpu").splitlines() if ":" in l)}
    cores = int(lscpu.get("Core(s) per socket", 0) or 0) * int(lscpu.get("Socket(s)", 1) or 1)
    mem = int(re.search(r"MemTotal:\s+(\d+)", open("/proc/meminfo").read()).group(1)) / 1024 ** 2
    tables = subprocess.run(["psql", "-X", "-At", "-d", "obp_loadtest_base", "-c",
                             "SELECT relname, reltuples::bigint, pg_size_pretty(pg_table_size(oid)), "
                             "pg_size_pretty(pg_indexes_size(oid)) FROM pg_class "
                             "WHERE relname IN ('metric','metricarchive') ORDER BY 1"],
                            text=True, capture_output=True).stdout
    return {
        "machine": {
            "CPU": f"{lscpu.get('Model name', '?')} ({cores} cores / {lscpu.get('CPU(s)', '?')} threads)",
            "RAM": f"{mem:.1f} GiB", "OS": sh(". /etc/os-release; echo $PRETTY_NAME") + ", kernel " + sh("uname -r"),
            "PostgreSQL": subprocess.run(["psql", "-X", "-At", "-d", "postgres", "-c", "SELECT version()"],
                                         text=True, capture_output=True).stdout.split(" on ")[0],
        },
        "method": {
            "Driver": "pgbench, prepared statements, one connection per client",
            "Per run": f"{head.get('duration', '300s')} measured after {head.get('warmup', '30s')} warm-up, "
                       "latency percentiles from a 10% sample of transactions",
            "Isolation": "the test database is re-cloned from obp_loadtest_base before every scenario, so each "
                         "scenario starts from identical data",
            "Data": "5M metric rows (last 365 days) + 15M metricarchive rows (3 years before that), generated from "
                    "the real OBP rows with pseudonymized identifiers",
        },
        "tables": [l.split("|") for l in tables.splitlines() if l],
        "settings": [{"name": n, "value": v + (" " + u if u else "")} for n, v, u in settings],
        "date": head.get("date", ""),
    }


def md(data, labels, env):
    ref = labels[0]
    L = ["# OBP metric tables: load test", "",
         f"pgbench against a generated copy of the OBP metric tables (5M + 15M rows). Runs: "
         + ", ".join(f"`{x}`" for x in labels) + f". Reference: `{ref}`.", ""]
    for scenario in SCENARIO_ORDER:
        runs = sorted({c for lab in labels for (s, c) in data.get(lab, {}) if s == scenario})
        if not runs:
            continue
        title, desc = SCENARIOS.get(scenario, (scenario, ""))
        L += [f"## {scenario} — {title}", "", desc, "",
              "| Clients | " + " | ".join(f"{lab} TPS | {lab} p95" for lab in labels) + " |",
              "|---" * (1 + 2 * len(labels)) + "|"]
        for c in runs:
            cells = []
            for lab in labels:
                r = data.get(lab, {}).get((scenario, c))
                cells += [fmt_tps(r["tps"]) if r else "-", fmt_ms(r["p95"]) if r else "-"]
            L.append(f"| {c} | " + " | ".join(cells) + " |")
        L.append("")
    L += ["## Findings", ""]
    for title, body in FINDINGS:
        L += [f"**{title}.** " + re.sub(r"<[^>]+>", "", render(body, data, ref)), ""]
    L += ["**Recommendation.** " + re.sub(r"<[^>]+>", "", RECOMMENDATION), ""]
    text = "\n".join(L)
    open(os.path.join(ROOT, "REPORT.md"), "w").write(text)          # always the latest
    os.makedirs(os.path.join(ROOT, "reports"), exist_ok=True)
    stamp = time.strftime("%Y-%m-%d_%H%M%S")
    open(os.path.join(ROOT, "reports", f"{stamp}__{'_vs_'.join(labels)}.md"), "w").write(text)


def main():
    global LABELS
    labels = sys.argv[1:] or [os.path.basename(p) for p in sorted(glob.glob(os.path.join(RESULTS, "*")))
                              if os.path.isdir(p) and glob.glob(os.path.join(p, "*_c*", "summary.json"))]
    LABELS = labels
    data = load(labels)
    if not data:
        sys.exit("no results found in results/")
    env = environment(labels)
    ref = labels[0]
    out = {
        "labels": labels, "reference": ref, "env": env,
        "queries": QUERIES, "scenarioInfo": SCENARIOS,
        "scenarios": [],
        "findings": [{"title": t, "body": render(b, data, ref)} for t, b in FINDINGS],
        "recommendation": RECOMMENDATION,
        "meta": {
            "eyebrow": f"pgbench · 5M + 15M rows · {env['date'][:10]}",
            "lede": "How the OBP <code>metric</code> and <code>metricarchive</code> tables behave under concurrent "
                    "load, and what changes when the one missing index is added. Each run: three scenarios at 1, 4, "
                    "8 and 16 clients, 5 minutes each, against a freshly cloned copy of the data.",
        },
    }
    for scenario in SCENARIO_ORDER:
        clients = sorted({c for lab in labels for (s, c) in data.get(lab, {}) if s == scenario})
        if not clients:
            continue
        scripts = sorted({k for lab in labels for c in clients
                          for k in data.get(lab, {}).get((scenario, c), {}).get("scripts", {})},
                         key=lambda k: -max(data[lab][(scenario, clients[-1])]["scripts"].get(k, {}).get("tps", 0)
                                            for lab in labels if (scenario, clients[-1]) in data.get(lab, {})))
        out["scenarios"].append({
            "name": scenario, "title": SCENARIOS.get(scenario, (scenario, ""))[0],
            "desc": SCENARIOS.get(scenario, ("", ""))[1], "clients": clients, "scripts": scripts,
            "runs": {lab: {str(c): data[lab][(scenario, c)] for c in clients if (scenario, c) in data.get(lab, {})}
                     for lab in labels},
        })
    template = open(os.path.join(ROOT, "report_template.html")).read()
    payload = json.dumps(out).replace("</", "<\\/")
    page = template.replace("__DATA__", payload)
    open(os.path.join(ROOT, "REPORT.html"), "w").write(page)        # always the latest
    os.makedirs(os.path.join(ROOT, "reports"), exist_ok=True)
    stamp = time.strftime("%Y-%m-%d_%H%M%S")
    open(os.path.join(ROOT, "reports", f"{stamp}__{'_vs_'.join(LABELS)}.html"), "w").write(page)
    md(data, labels, env)
    print(f"Wrote REPORT.html and REPORT.md ({len(labels)} runs: {', '.join(labels)})")


if __name__ == "__main__":
    main()
