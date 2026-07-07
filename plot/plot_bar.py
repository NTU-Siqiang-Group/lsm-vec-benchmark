"""Grouped-bar plotter (e.g. peak RSS or on-disk size per system). Pure function of a .dat."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import style  # noqa: E402
from datfile import read_dat, rows_by_system, fnan  # noqa: E402
from style import SYSTEM_ORDER, system_style  # noqa: E402


def plot(dat_path, out_path, y="peak_rss_mb", ylabel="peak RSS (MB)"):
    """One bar per system using the (single) row's y value, or the max over rows."""
    _, _, rows = read_dat(dat_path)
    by_sys = rows_by_system(rows)
    systems = [s for s in SYSTEM_ORDER if s in by_sys] + \
              [s for s in by_sys if s not in SYSTEM_ORDER]
    fig, ax = style.new_fig()
    labels, vals, colors = [], [], []
    for s in systems:
        vs = [fnan(r.get(y)) for r in by_sys[s]]
        vs = [v for v in vs if v == v]
        if not vs:
            continue
        st = system_style(s)
        labels.append(st["label"])
        vals.append(max(vs))
        colors.append(st["color"])
    ax.bar(range(len(vals)), vals, color=colors, edgecolor="black", linewidth=0.4)
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, rotation=30, ha="right")
    ax.set_ylabel(ylabel)
    style.save_fig(fig, out_path)
