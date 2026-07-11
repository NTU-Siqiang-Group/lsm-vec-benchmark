"""Phase 8 — SA/section parameter sensitivity. Reads the per-run raw JSONL produced by
run_phase8_param_200k.sh.

  python3 plot/plot_param.py heatmap sift_200k_r9010     # top_H x beam heatmap
  python3 plot/plot_param.py lines   sift_200k_r9010     # layer_mult / alpha / min_cluster line sweeps
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import style  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

RAW, FIG = "results/raw", "results/fig"


def last(name, cell):
    fp = f"{RAW}/{name}_{cell}.jsonl"
    if not os.path.exists(fp):
        return None
    r = [json.loads(l) for l in open(fp) if l.strip()]
    if not r:
        return None
    e = r[-1]
    rc = [x.get("recall10") for x in r if x.get("recall10") is not None]
    return {"recall": rc[-1] if rc else float("nan"),
            "pmiss": e.get("query_page_miss_per_query", 0),
            "p99": sum(x.get("lat_p99_ms", 0) for x in r) / len(r),
            "ins": sum(x.get("ins_ops_s", 0) for x in r if x.get("ins_ops_s", 0) > 0) / max(1, sum(1 for x in r if x.get("ins_ops_s", 0) > 0))}


def heatmap(cell):
    Hs, Bs = [2, 3, 4, 5], [1, 2, 4, 8]
    import numpy as np
    miss = np.full((len(Bs), len(Hs)), np.nan)
    rec = np.full((len(Bs), len(Hs)), np.nan)
    for i, B in enumerate(Bs):
        for j, H in enumerate(Hs):
            d = last(f"ours_h{H}_b{B}", cell)
            if d:
                miss[i, j] = d["pmiss"]; rec[i, j] = d["recall"]
    fig, ax = style.new_fig()
    im = ax.imshow(miss, origin="lower", aspect="auto", cmap="viridis_r")
    ax.set_xticks(range(len(Hs))); ax.set_xticklabels(Hs)
    ax.set_yticks(range(len(Bs))); ax.set_yticklabels(Bs)
    ax.set_xlabel("sketch depth (top-H)"); ax.set_ylabel("beam")
    for i in range(len(Bs)):
        for j in range(len(Hs)):
            if rec[i, j] == rec[i, j]:
                ax.text(j, i, f"{rec[i,j]:.3f}", ha="center", va="center", fontsize=6, color="w")
    fig.colorbar(im, ax=ax, label="vector-page reads / query")
    out = f"{FIG}/sa_sketch_beam_heatmap__{cell}"
    style.save_fig(fig, out)
    print(f"[param] {out}.pdf")


def lines(cell):
    groups = [("layer ratio", "layer_mult", [("ours_lm0.0625", 0.0625), ("ours_lm0.125", 0.125), ("ours_lm0.25", 0.25)]),
              ("rebuild alpha", "alpha", [("ours_alpha0.1", 0.1), ("ours_alpha0.2", 0.2), ("ours_alpha0.3", 0.3), ("ours_alpha0.5", 0.5)]),
              ("min cluster size", "min_cluster", [("ours_mc8", 8), ("ours_mc16", 16), ("ours_mc32", 32), ("ours_mc64", 64)])]
    for title, tag, items in groups:
        items = [(n, x) for n, x in items if last(n, cell)]
        if not items:
            continue
        xs = [x for _, x in items]
        rec = [last(n, cell)["recall"] for n, _ in items]
        miss = [last(n, cell)["pmiss"] for n, _ in items]
        fig, ax = style.new_fig()
        ax.plot(range(len(xs)), rec, "-o", color="#d55e00", label="recall@10")
        ax.set_ylabel("recall@10", color="#d55e00")
        ax.set_xticks(range(len(xs))); ax.set_xticklabels([str(x) for x in xs])
        ax.set_xlabel(title)
        ax2 = ax.twinx()
        ax2.plot(range(len(xs)), miss, "--s", color="#0072b2", label="page reads/q")
        ax2.set_ylabel("vector-page reads / query", color="#0072b2")
        out = f"{FIG}/param_{tag}__{cell}"
        style.save_fig(fig, out)
        print(f"[param] {out}.pdf")


if __name__ == "__main__":
    kind, cell = sys.argv[1], sys.argv[2]
    heatmap(cell) if kind == "heatmap" else lines(cell)
