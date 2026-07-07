#!/usr/bin/env python3
"""Temporary PRESENTATION figures: only 3 methods — LSM-Vec (= our no-SA variant, relabeled),
SPFresh, SPANN+ — written to results/fig_temp/. Reuses the existing per-cell .dat files, filtered
to those systems. Run from anywhere: python3 plot/make_temp_figs.py [cell]  (default sift_1m_r9010).
"""
import importlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
sys.path.insert(0, HERE)

import style  # noqa: E402
from datfile import read_dat, write_dat  # noqa: E402
import experiments as E  # noqa: E402

CELL = sys.argv[1] if len(sys.argv) > 1 else "sift_1m_r9010"
KEEP = ["lsm-vec-no-sa", "spfresh", "spannplus"]

# Present the no-SA variant AS the headline "LSM-Vec" (prominent solid vermil circle).
style.SYSTEM_STYLE["lsm-vec-no-sa"] = {
    "color": style._WONG["vermil"], "linestyle": "-", "marker": "o", "label": "LSM-Vec"}
style.SYSTEM_ORDER[:] = KEEP  # in-place so the imported references in the plotters see it

FIG = os.path.join(ROOT, "results", "fig_temp")
DAT = os.path.join(ROOT, "results", "dat_temp")
os.makedirs(FIG, exist_ok=True)
os.makedirs(DAT, exist_ok=True)

n = 0
for e in E.all_experiments():
    if not e["name"].endswith("__" + CELL):
        continue
    src = os.path.join(ROOT, "results", "dat", e["name"] + ".dat")
    if not os.path.exists(src):
        continue
    meta, cols, rows = read_dat(src)
    rows = [r for r in rows if r.get("system") in KEEP]
    if not rows:
        continue
    dst = os.path.join(DAT, e["name"] + ".dat")
    write_dat(dst, e["name"], cols, rows, source="fig_temp (LSM-Vec/SPFresh/SPANN+)")
    mod, fn, opts = e["plot"]
    getattr(importlib.import_module(mod), fn)(dst, os.path.join(FIG, e["name"]), **opts)
    print("wrote results/fig_temp/" + e["name"] + ".pdf")
    n += 1
print(f"done: {n} figures -> results/fig_temp/  (LSM-Vec, SPFresh, SPANN+)")
