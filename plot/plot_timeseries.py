"""Time-series plotters (runbook §10.5: recall_epoch, latency_epoch, insert_tput_epoch, mem_time).

Pure functions of a .dat file. The orchestrator passes presentation options
(which column is y, labels, etc.) from the experiment registry.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import style  # noqa: E402
from datfile import read_dat, rows_by_system, fnan  # noqa: E402
from style import SYSTEM_ORDER, system_style  # noqa: E402


def _ordered_systems(by_sys):
    known = [s for s in SYSTEM_ORDER if s in by_sys]
    extra = [s for s in by_sys if s not in SYSTEM_ORDER]
    return known + extra


def _series(rows, x, y):
    xs, ys = [], []
    for r in rows:
        xv, yv = fnan(r.get(x)), fnan(r.get(y))
        if xv == xv and yv == yv:  # drop NaN (e.g. recall only at gt checkpoints)
            xs.append(xv)
            ys.append(yv)
    return xs, ys


def plot(dat_path, out_path, y="recall10", ylabel="recall@10",
         x="epoch", xlabel="epoch", logy=False, ylim=None):
    """Single metric vs x, systems overlaid."""
    _, _, rows = read_dat(dat_path)
    by_sys = rows_by_system(rows)
    fig, ax = style.new_fig()
    systems = [s for s in _ordered_systems(by_sys) if _series(by_sys[s], x, y)[0]]
    for s in systems:
        st = system_style(s)
        xs, ys = _series(by_sys[s], x, y)
        # markers + full linewidth so systems stay clearly distinguishable even when
        # the curves overlap (e.g. mem_time's flat RSS lines). ~10 markers per series.
        ax.plot(xs, ys, color=st["color"], linestyle=st["linestyle"], linewidth=1.4,
                marker=st["marker"], markevery=max(1, len(xs) // 10), markersize=4.5,
                label=st["label"])
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.margins(x=0.02)
    if logy:
        ax.set_yscale("log")
    if ylim:
        ax.set_ylim(*ylim)
    style.legend_left(ax)
    style.save_fig(fig, out_path)


def plot_dual(dat_path, out_path, y_top="lat_p99_ms", y_bottom="lat_p50_ms",
              ylabel_top="P99 latency (ms)", ylabel_bottom="P50 latency (ms)",
              x="epoch", xlabel="epoch", logy=True):
    """Two stacked panels sharing x (latency_epoch: P99 top, P50 bottom)."""
    import matplotlib.pyplot as plt
    _, _, rows = read_dat(dat_path)
    by_sys = rows_by_system(rows)
    fig, (ax_top, ax_bot) = plt.subplots(
        2, 1, sharex=True, figsize=(style.SINGLE_COL[0], style.SINGLE_COL[1] * 1.6))
    systems = [s for s in _ordered_systems(by_sys)
               if _series(by_sys[s], x, y_top)[0] or _series(by_sys[s], x, y_bottom)[0]]
    for s in systems:
        st = system_style(s)
        for ax, ycol in ((ax_top, y_top), (ax_bot, y_bottom)):
            xs, ys = _series(by_sys[s], x, ycol)
            if not xs:
                continue
            ax.plot(xs, ys, color=st["color"], linestyle=st["linestyle"],
                    marker=st["marker"], markevery=max(1, len(xs) // 12),
                    label=st["label"])
    if logy:
        ax_top.set_yscale("log")
        ax_bot.set_yscale("log")
    else:
        # linear scale anchored at 0
        ax_top.set_ylim(bottom=0)
        ax_bot.set_ylim(bottom=0)
    ax_top.set_ylabel(ylabel_top)
    ax_bot.set_ylabel(ylabel_bottom)
    ax_bot.set_xlabel(xlabel)
    # one shared vertical legend outside, to the LEFT, spanning both panels
    handles, labels = ax_top.get_legend_handles_labels()
    fig.legend(handles, labels, loc="center right", bbox_to_anchor=(-0.02, 0.5),
               bbox_transform=fig.transFigure, frameon=False, fontsize=9,
               handlelength=2.8, labelspacing=0.8, handletextpad=0.6)
    style.save_fig(fig, out_path)
