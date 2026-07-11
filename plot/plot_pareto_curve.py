"""Phase 7 — recall-latency / recall-IO Pareto for ours, from the D9 ef_final sweep (<name>.sweep.jsonl).
One line per checkpoint epoch; points = ef_final values.

  python3 plot/plot_pareto_curve.py ours_section sift_1m_r9010
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import style  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

RAW, FIG = "results/raw", "results/fig"
EPOCH_STYLE = {0: ("#0072b2", "o", "epoch 0"),
               25: ("#e69f00", "s", "epoch 25"),
               49: ("#d55e00", "^", "epoch 49")}


def main():
    name, cell = sys.argv[1], sys.argv[2]
    fp = f"{RAW}/{name}_{cell}.jsonl.sweep.jsonl"
    if not os.path.exists(fp):
        print(f"no sweep file: {fp}"); return
    # Tolerate `nan` recall on non-GT epochs (invalid JSON): sanitize then drop null-recall rows.
    rows = []
    for l in open(fp):
        if not l.strip():
            continue
        try:
            r = json.loads(l.replace("nan", "null").replace("-null", "null"))
        except Exception:
            continue
        if r.get("recall10") is not None:
            rows.append(r)
    by_epoch = {}
    for r in rows:
        by_epoch.setdefault(r["epoch"], []).append(r)

    for xkey, xlabel, tag in [("lat_mean_ms", "mean latency (ms)", "latency"),
                              ("query_io_per_query", "page accesses / query", "io")]:
        fig, ax = style.new_fig()
        for ep in sorted(by_epoch):
            pts = sorted(by_epoch[ep], key=lambda r: r[xkey])
            col, mk, lbl = EPOCH_STYLE.get(ep, ("gray", "x", f"epoch {ep}"))
            ax.plot([p[xkey] for p in pts], [p["recall10"] for p in pts],
                    marker=mk, color=col, label=lbl, markersize=4)
            for p in pts:  # annotate ef at the last epoch line
                if ep == max(by_epoch):
                    ax.annotate(str(p["ef_final"]), (p[xkey], p["recall10"]),
                                fontsize=6, ha="left", va="top")
        ax.set_xlabel(xlabel)
        ax.set_ylabel("recall@10")
        ax.legend(fontsize=7, frameon=False)
        out = f"{FIG}/recall_{tag}_curve__{cell}"
        style.save_fig(fig, out)
        print(f"[pareto] {out}.pdf")


if __name__ == "__main__":
    main()
