#!/usr/bin/env python3
"""bench.py — single controller for the results pipeline (runbook §10.4).

raw JSONL (per-epoch metrics + RSS-vs-time)  ->  one canonical .dat per figure
->  paper-ready .pdf/.svg. Idempotent and resumable: `run` aggregates+plots from
existing raw; `plot` re-renders from existing dat/raw without re-running anything.

Subcommands:
  bench.py list                  list experiments + status (raw? dat? fig?)
  bench.py run  <name|all>       aggregate raw -> dat -> fig
  bench.py plot <name|all>       re-aggregate + re-plot from existing raw/dat
  bench.py clean <name|all>      remove that experiment's dat + fig (raw kept)
"""
import argparse
import datetime
import importlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "plot"))

import experiments as exp_registry  # noqa: E402
from plot.datfile import write_dat  # noqa: E402

RAW = os.path.join(HERE, "results", "raw")
DAT = os.path.join(HERE, "results", "dat")
FIG = os.path.join(HERE, "results", "fig")

EPOCH_COLS = ["epoch", "system", "recall10", "lat_mean_ms", "lat_p50_ms",
              "lat_p99_ms", "qps", "ins_ops_s", "del_ops_s", "rss_mb",
              "disk_mb", "query_io_per_query"]
MEM_COLS = ["epoch_frac", "system", "rss_mb", "t_sec", "epoch"]


def git_sha():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=HERE,
            stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return "nogit"


def cell_tag(e):
    return f"{e['ds']}_{e['scale']}_{e['ratio']}"


def raw_jsonl(system, e):
    return os.path.join(RAW, f"{system}_{cell_tag(e)}.jsonl")


def raw_mem(system, e):
    return os.path.join(RAW, f"{system}_{cell_tag(e)}.mem.jsonl")


def read_jsonl(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def present_systems(e, source):
    out = []
    for s in e["systems"]:
        p = raw_mem(s, e) if source == "mem" else raw_jsonl(s, e)
        if os.path.exists(p):
            out.append(s)
    return out


def build_time_s(system, e):
    """Base index build time = duration of the epoch=-1 phase in the .mem.jsonl stream."""
    p = raw_mem(system, e)
    if not os.path.exists(p):
        return None
    neg = [x["t_sec"] for x in read_jsonl(p) if x.get("epoch", 0) == -1]
    return round(max(neg), 1) if neg else None


def peak_rss_mb(system, e):
    # Peak RSS over the WORKLOAD phase only (epoch>=0): insert/update/query after build.
    # The transient build-phase peak (epoch=-1) is deliberately excluded — we report the
    # steady-state serving footprint, not the one-shot construction spike.
    p = raw_mem(system, e)
    if not os.path.exists(p):
        return None
    vals = [x.get("rss_mb", 0) for x in read_jsonl(p) if x.get("epoch", -1) >= 0]
    return round(max(vals), 1) if vals else None


# --------------------------------------------------------------------------- #
# Aggregation: raw -> rows for the .dat
# --------------------------------------------------------------------------- #
def aggregate_epoch(e):
    rows = []
    for s in e["systems"]:
        p = raw_jsonl(s, e)
        if not os.path.exists(p):
            continue
        for r in read_jsonl(p):
            row = {"system": s}
            for c in EPOCH_COLS:
                if c == "system":
                    continue
                row[c] = r.get(c, None)
            rows.append(row)
    return EPOCH_COLS, rows


def aggregate_mem(e):
    rows = []
    for s in e["systems"]:
        p = raw_mem(s, e)
        if not os.path.exists(p):
            continue
        # Workload-only: drop build-phase (epoch=-1) samples so the mem curve shows the
        # serving footprint (insert/update/query), not the build ramp.
        samples = [x for x in read_jsonl(p) if x.get("epoch", -1) >= 0]
        # epoch_frac = epoch + (within-epoch sample position)/(count in epoch),
        # so systems with different wall-clock align on epoch progress.
        from collections import Counter, defaultdict
        counts = Counter(x.get("epoch", -1) for x in samples)
        seen = defaultdict(int)
        for x in samples:
            ep = x.get("epoch", -1)
            n = counts[ep]
            frac = seen[ep] / n if n else 0.0
            seen[ep] += 1
            rows.append({
                "epoch_frac": round(ep + frac, 5),
                "system": s,
                "rss_mb": x.get("rss_mb"),
                "t_sec": x.get("t_sec"),
                "epoch": ep,
            })
    return MEM_COLS, rows


SUMMARY_COLS = ["system", "build_time_s", "mean_ins_ops_s", "mean_del_ops_s",
                "peak_rss_mb", "end_recall10"]

# Per-(system, cell) scalar corrections. Cell = "<ds>_<scale>_<ratio>".
# diskann_merge @ sift_1m_r9010 (merge_every=10000, single-thread, see memory
# diskann-merge-window-and-reuse):
#  - build_time_s: this run REUSED a cached base index (restore ~1s), so the .mem.jsonl epoch=-1
#    phase understates the build; inject the real single-thread base build (649s).
#  - mean_ins_ops_s: raw ins_ops_s (~15792) measures only delta-insert-loop speed and EXCLUDES the
#    ~508s StreamingMerge cost (25 merges). Report the AMORTIZED sustained rate incl. merge:
#    450k inserts / (28s insert + 508s merge) = 839/s (≈ ours 790/s). Every other system's insert
#    metric already includes its full write path, so this keeps the bar apples-to-apples.
# (Re-baseline 2026-07-06: diskann_merge now runs merge_every=30M @4-thread build, so its
#  build time comes from the real epoch=-1 phase and insert is the raw delta rate (merges=0 →
#  no merge cost to amortize). The prior 10k-window override is removed.)
SUMMARY_OVERRIDES = {}


def aggregate_summary(e):
    """Per-system scalars: build time, mean insert/delete throughput, peak RSS, end recall."""
    rows = []
    for s in e["systems"]:
        p = raw_jsonl(s, e)
        if not os.path.exists(p):
            continue
        epochs = read_jsonl(p)
        ins = [r["ins_ops_s"] for r in epochs if r.get("ins_ops_s", 0)]
        dels = [r["del_ops_s"] for r in epochs if r.get("del_ops_s", 0)]
        rec = [r["recall10"] for r in epochs if r.get("recall10") is not None]
        row = {
            "system": s,
            "build_time_s": build_time_s(s, e),
            "mean_ins_ops_s": round(sum(ins) / len(ins), 1) if ins else None,
            "mean_del_ops_s": round(sum(dels) / len(dels), 1) if dels else None,
            "peak_rss_mb": peak_rss_mb(s, e),
            "end_recall10": rec[-1] if rec else None,
        }
        cell = f'{e["ds"]}_{e["scale"]}_{e["ratio"]}'
        row.update(SUMMARY_OVERRIDES.get((s, cell), {}))
        rows.append(row)
    return SUMMARY_COLS, rows


def aggregate(e):
    if e["source"] == "mem":
        return aggregate_mem(e)
    if e["source"] == "summary":
        return aggregate_summary(e)
    return aggregate_epoch(e)


# --------------------------------------------------------------------------- #
# run / plot / clean
# --------------------------------------------------------------------------- #
def do_aggregate_and_plot(e, do_plot=True):
    columns, rows = aggregate(e)
    have = present_systems(e, e["source"])
    if not rows:
        print(f"  [skip] {e['name']}: no raw inputs present "
              f"(expected systems: {', '.join(e['systems'])})")
        return False
    dat_path = os.path.join(DAT, e["name"] + ".dat")
    src = ", ".join(os.path.basename(raw_jsonl(s, e) if e["source"] == "epoch"
                                     else raw_mem(s, e)) for s in have)
    write_dat(dat_path, e["name"], columns, rows,
              source=src, cmd=f"bench.py run {e['name']}", git_sha=git_sha(),
              generated=datetime.datetime.now(datetime.timezone.utc)
              .strftime("%Y-%m-%dT%H:%M:%SZ"))
    print(f"  [dat ] {e['name']}.dat  ({len(rows)} rows, systems: {', '.join(have)})")
    if do_plot:
        mod_name, fn_name, opts = e["plot"]
        mod = importlib.import_module(mod_name)
        fn = getattr(mod, fn_name)
        out = os.path.join(FIG, e["name"])
        fn(dat_path, out, **opts)
        print(f"  [fig ] {e['name']}.pdf + .svg")
    return True


def cmd_list(_):
    print(f"{'experiment':<42} raw  dat fig")
    for e in exp_registry.all_experiments():
        have = present_systems(e, e["source"])
        dat = os.path.exists(os.path.join(DAT, e["name"] + ".dat"))
        fig = os.path.exists(os.path.join(FIG, e["name"] + ".pdf"))
        print(f"{e['name']:<42} {len(have)}/{len(e['systems'])}  "
              f"{'Y' if dat else '-'}   {'Y' if fig else '-'}")


def _resolve(names):
    if names == ["all"]:
        return exp_registry.all_experiments()
    out = []
    for n in names:
        e = exp_registry.find_experiment(n)
        if not e:
            print(f"unknown experiment: {n}", file=sys.stderr)
            sys.exit(2)
        out.append(e)
    return out


def cmd_run(args):
    for e in _resolve(args.names):
        do_aggregate_and_plot(e, do_plot=True)


def cmd_plot(args):
    for e in _resolve(args.names):
        do_aggregate_and_plot(e, do_plot=True)


def cmd_clean(args):
    for e in _resolve(args.names):
        for p in (os.path.join(DAT, e["name"] + ".dat"),
                  os.path.join(FIG, e["name"] + ".pdf"),
                  os.path.join(FIG, e["name"] + ".svg")):
            if os.path.exists(p):
                os.remove(p)
                print(f"  removed {os.path.basename(p)}")


def main():
    for d in (RAW, DAT, FIG):
        os.makedirs(d, exist_ok=True)
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(func=cmd_list)
    for name in ("run", "plot", "clean"):
        p = sub.add_parser(name)
        p.add_argument("names", nargs="+", help="experiment name(s) or 'all'")
        p.set_defaults(func={"run": cmd_run, "plot": cmd_plot, "clean": cmd_clean}[name])
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
