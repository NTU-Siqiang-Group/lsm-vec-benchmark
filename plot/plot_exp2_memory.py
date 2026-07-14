"""Exp 2 (memory usage breakdown over time). Left: LSM-Vec memory composition over epochs (stacked
area from the D7 per-epoch mem_* components + allocator/runtime residual = RSS - sum). Right: total RSS
over time, ours vs SPFresh (SPFresh's internal split is not instrumented — shown as total, attributed
qualitatively to its float32 in-memory posting cache; see the disk breakdown, RESULTS 11.2).

  python3 plot/plot_exp2_memory.py <cell>   # e.g. sift_1m_r9010
"""
import json
import os
import sys

sys.path.insert(0, "plot")
import style  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

RAW, FIG = "results/raw", "results/fig"
COMPS = [("mem_upper_hnsw_mb", "upper HNSW", "#0072b2"),
         ("mem_sa_sketch_mb", "SA sketch", "#d55e00"),
         ("mem_graph_cache_mb", "graph cache", "#009e73"),
         ("mem_vec_cache_mb", "vec cache", "#56b4e9"),
         ("mem_update_buf_mb", "update buf", "#e69f00"),
         ("__residual__", "allocator/runtime", "#cccccc")]


def rss_series(name, cell):
    fp = f"{RAW}/{name}_{cell}.mem.jsonl"
    if not os.path.exists(fp):
        return [], []
    m = [json.loads(l) for l in open(fp) if l.strip()]
    wl = [x for x in m if x.get("epoch", -9) >= 0]
    if not wl:
        return [], []
    t0 = wl[0].get("t_sec", 0)
    return [x.get("t_sec", 0) - t0 for x in wl], [x.get("rss_mb", 0) for x in wl]


def main():
    cell = sys.argv[1]
    r = [json.loads(l) for l in open(f"{RAW}/ours_section_{cell}.jsonl") if l.strip()]
    epochs = [x["epoch"] for x in r]
    series = {}
    for key, lbl, col in COMPS:
        if key == "__residual__":
            idsum = [sum(x.get(k, 0) or 0 for k, _, _ in COMPS if k != "__residual__") for x in r]
            series[key] = [max(0.0, x["rss_mb"] - s) for x, s in zip(r, idsum)]
        else:
            series[key] = [x.get(key, 0) or 0 for x in r]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(6.6, 2.6))
    ax1.stackplot(epochs, *[series[k] for k, _, _ in COMPS],
                  labels=[l for _, l, _ in COMPS], colors=[c for _, _, c in COMPS])
    ax1.set_xlabel("epoch"); ax1.set_ylabel("RSS (MB)")
    ax1.legend(fontsize=6, frameon=False, loc="upper left", ncol=2)
    ax1.set_title("ours — memory composition", fontsize=9)

    for name, col, lbl in [("ours_section", "#d55e00", "ours"), ("spfresh", "#0072b2", "SPFresh")]:
        t, rss = rss_series(name, cell)
        if t:
            ax2.plot([i / max(1, len(rss) - 1) for i in range(len(rss))],
                     [v / 1024 for v in rss], color=col, label=lbl)
    ax2.set_xlabel("workload progress"); ax2.set_ylabel("RSS (GiB)")
    ax2.legend(fontsize=8, frameon=False); ax2.set_title("total RSS over time", fontsize=9)
    fig.suptitle(f"Memory breakdown over time (Exp 2) — {cell}", fontsize=10)
    fig.tight_layout(rect=[0, 0, 1, 0.93])
    out = f"{FIG}/exp2_memory_time__{cell}"
    fig.savefig(out + ".pdf", bbox_inches="tight"); fig.savefig(out + ".svg", bbox_inches="tight")
    plt.close(fig)
    e = r[-1]
    idsum = sum(e.get(k, 0) or 0 for k, _, _ in COMPS if k != "__residual__")
    print(f"[exp2] {out}.pdf")
    print(f"    ours end RSS={e['rss_mb']:.0f}MB: identified={idsum:.0f} (SA sketch={e.get('mem_sa_sketch_mb',0):.0f}), "
          f"residual={e['rss_mb']-idsum:.0f}")


if __name__ == "__main__":
    main()
