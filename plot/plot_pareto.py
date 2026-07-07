"""Recall-vs-latency Pareto plotter (runbook §10.5 recall_latency_pareto).

One point per system at end-of-stream: x = mean latency, y = recall@10.
Pure function of a .dat with columns including the x/y metrics + system.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import style  # noqa: E402
from datfile import read_dat, rows_by_system, fnan  # noqa: E402
from style import SYSTEM_ORDER, system_style  # noqa: E402


def plot(dat_path, out_path, x="lat_mean_ms", y="recall10",
         xlabel="mean query latency (ms)", ylabel="recall@10", logx=True):
    _, _, rows = read_dat(dat_path)
    by_sys = rows_by_system(rows)
    systems = [s for s in SYSTEM_ORDER if s in by_sys] + \
              [s for s in by_sys if s not in SYSTEM_ORDER]
    fig, ax = style.new_fig()
    for s in systems:
        # take the last row that has both x and y (end-of-stream)
        xv = yv = float("nan")
        for r in by_sys[s]:
            a, b = fnan(r.get(x)), fnan(r.get(y))
            if a == a and b == b:
                xv, yv = a, b
        if xv != xv or yv != yv:
            continue
        st = system_style(s)
        ax.scatter([xv], [yv], color=st["color"], marker=st["marker"],
                   s=40, edgecolor="black", linewidth=0.4, label=st["label"], zorder=3)
    if logx:
        ax.set_xscale("log")
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.margins(0.08)
    style.legend_below(ax, len([s for s in systems if s in by_sys]))
    style.save_fig(fig, out_path)
