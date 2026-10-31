#!/usr/bin/env python3
"""Summarize one pgbench run directory into summary.json and print a one-line result.

Reads pgbench.txt (pgbench stdout) for throughput and the sampled transaction logs (txlog*)
for latency percentiles, overall and per workload script.
Usage: summarize.py <run_dir> <scenario> <clients>
"""
import glob
import json
import os
import re
import sys


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    i = min(len(sorted_values) - 1, round(p / 100 * (len(sorted_values) - 1)))
    return round(sorted_values[i] / 1000, 2)  # us -> ms


def main():
    run_dir, scenario, clients = sys.argv[1], sys.argv[2], int(sys.argv[3])
    text = open(os.path.join(run_dir, "pgbench.txt")).read()

    def grab(pattern, cast=float):
        m = re.search(pattern, text, re.M)
        return cast(m.group(1)) if m else None

    # Script names in the order pgbench numbers them (0-based in the log).
    names = [os.path.basename(p) for p in re.findall(r"^SQL script \d+: (\S+)", text, re.M)]
    if not names:
        names = [os.path.basename(grab(r"^transaction type: (\S+)", str) or "script")]
    script_tps = [float(t) for t in re.findall(r"^ - \d+ transactions \([\d.]+% of total, tps = ([\d.]+)\)", text, re.M)]

    # Log line: client_id transaction_no latency_us script_no epoch epoch_us [schedule_lag]
    lat_all, lat_by_script = [], {}
    for path in glob.glob(os.path.join(run_dir, "txlog*")):
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) < 4 or not parts[2].isdigit():
                    continue
                lat = int(parts[2])
                lat_all.append(lat)
                lat_by_script.setdefault(int(parts[3]), []).append(lat)
    lat_all.sort()

    scripts = {}
    for i, name in enumerate(names):
        lats = sorted(lat_by_script.get(i, []))
        scripts[name] = {
            "tps": script_tps[i] if i < len(script_tps) else grab(r"^tps = ([\d.]+)"),
            "p50_ms": percentile(lats, 50), "p95_ms": percentile(lats, 95), "p99_ms": percentile(lats, 99),
            "samples": len(lats),
        }

    summary = {
        "scenario": scenario, "clients": clients,
        "tps": grab(r"^tps = ([\d.]+)"),
        "transactions": grab(r"^number of transactions actually processed: (\d+)", int),
        "latency_avg_ms": grab(r"^latency average = ([\d.]+) ms"),
        "p50_ms": percentile(lat_all, 50), "p95_ms": percentile(lat_all, 95), "p99_ms": percentile(lat_all, 99),
        "scripts": scripts,
    }
    with open(os.path.join(run_dir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(f"tps {summary['tps']:>9.1f}   p50 {summary['p50_ms']} ms   p95 {summary['p95_ms']} ms   "
          f"p99 {summary['p99_ms']} ms")


if __name__ == "__main__":
    main()
