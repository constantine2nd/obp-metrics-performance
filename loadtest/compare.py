#!/usr/bin/env python3
"""Compare load test results: throughput and latency per scenario/clients, first label = baseline.

Usage: compare.py <label> [<label> ...] [--scripts]
  --scripts  also show p95 latency per workload script
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# every run.sh scenario writes a folder under results/
ROOTS = [os.path.join(HERE, "results")]


def resolve(name):
    """A run is stored as <root>/<timestamp>__<label>. Accept either the folder name or the label,
    in which case the newest run with that label, in either root, wins."""
    if any(os.path.isdir(os.path.join(r, name)) for r in ROOTS):
        return name
    matches = sorted(os.path.basename(p) for r in ROOTS for p in glob.glob(os.path.join(r, "*__" + name))
                     if os.path.isdir(p))
    if not matches:
        return name
    return matches[-1]


def load(label):
    label = resolve(label)
    runs = {}
    for path in [p for r in ROOTS for p in glob.glob(os.path.join(r, label, "*", "summary.json"))]:
        s = json.load(open(path))
        runs[(s["scenario"], s["clients"])] = s
    if not runs:
        sys.exit(f"no results in results/{label}")
    return runs


def delta(new, old, higher_is_better):
    if new is None or not old:
        return ""
    pct = (new - old) / old * 100
    good = pct > 0 if higher_is_better else pct < 0
    return f"{pct:+.0f}%{'' if abs(pct) < 5 else (' ✓' if good else ' ✗')}"


def fmt(v, width):
    return f"{'-' if v is None else v:>{width}}"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_scripts = "--scripts" in sys.argv
    if not args:
        sys.exit(__doc__)
    data = {label: load(label) for label in args}
    resolved = {label: resolve(label) for label in args}
    base = args[0]
    order = {"read": 0, "write": 1, "mixed": 2}
    keys = sorted({k for runs in data.values() for k in runs}, key=lambda k: (order.get(k[0], 9), k[0], k[1]))

    header = f"{'scenario':<18}{'clients':>7}"
    for label in args:
        header += f" | {label[:22]:>22} {'tps':>9} {'p95 ms':>8}"
    shown = [f"{l:<12} {resolved[l]}" for l in args if resolved[l] != l]
    if shown:
        print("\n".join(shown))
    print(header)
    print("-" * len(header))
    for key in keys:
        line = f"{key[0]:<18}{key[1]:>7}"
        b = data[base].get(key, {})
        for label in args:
            s = data[label].get(key)
            if not s:
                line += f" | {'(no run)':>22} {'':>9} {'':>8}"
                continue
            d = "" if label == base else f"tps {delta(s['tps'], b.get('tps'), True)} p95 {delta(s['p95_ms'], b.get('p95_ms'), False)}"
            line += f" | {d:>22} {fmt(round(s['tps'], 1), 9)} {fmt(s['p95_ms'], 8)}"
        print(line)

        if show_scripts:
            for script in sorted({n for label in args for n in data[label].get(key, {}).get("scripts", {})}):
                sline = f"{'  ' + script:<25}"
                for label in args:
                    sc = data[label].get(key, {}).get("scripts", {}).get(script)
                    bsc = b.get("scripts", {}).get(script, {})
                    d = "" if label == base or not sc else f"p95 {delta(sc['p95_ms'], bsc.get('p95_ms'), False)}"
                    sline += f" | {d:>22} {fmt(sc and round(sc['tps'], 1), 9)} {fmt(sc and sc['p95_ms'], 8)}"
                print(sline)
    print("\n✓/✗ = better/worse by 5% or more vs", base)


if __name__ == "__main__":
    main()
