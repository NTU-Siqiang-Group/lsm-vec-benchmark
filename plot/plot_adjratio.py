"""Addendum: refined adjacent-ratio sweep. Reads the ours_ar<ratio> runs + build logs, plots the
memory/routing tradeoff vs adjacent-layer ratio (paper default ~3000 in the middle).

  python3 plot/plot_adjratio.py sift_200k_r9010
"""
import json
import math
import os
import re
import sys

sys.path.insert(0, "plot")
import style  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

RAW, FIG, DAT, LOGD = "results/raw", "results/fig", "results/dat", "logs/adjratio"
RATIOS = [750, 1500, 3000, 6000, 12000]
NBASE = 200000


def sections_from_log(name):
    """#on-disk sections (= graph-aware groups) from the build log's 'per-section sections=N'."""
    lg = f"{LOGD}/{name}.log"
    if not os.path.exists(lg):
        return None
    m = re.findall(r"per-section sections=(\d+)", open(lg).read())
    return int(m[-1]) if m else None


def row(cell, ar):
    name = f"ours_ar{ar}"
    fp = f"{RAW}/{name}_{cell}.jsonl"
    if not os.path.exists(fp):
        return None
    r = [json.loads(l) for l in open(fp) if l.strip()]
    e = r[-1]
    rc = [x["recall10"] for x in r if x.get("recall10") is not None]
    mfp = fp.replace(".jsonl", ".mem.jsonl")
    peak = 0
    if os.path.exists(mfp):
        m = [json.loads(l) for l in open(mfp) if l.strip()]
        peak = max((x.get("rss_mb", 0) for x in m if x.get("epoch", -9) >= 0), default=0)
    sec = sections_from_log(name)
    return dict(recall=rc[-1] if rc else float("nan"),
                sketch_mb=e.get("mem_sa_sketch_mb", 0),
                rss=peak, sections=sec,
                sec_size=(NBASE / sec) if sec else float("nan"),
                lat=sum(x.get("lat_mean_ms", 0) for x in r) / len(r))


def main():
    cell = sys.argv[1]
    data = {ar: row(cell, ar) for ar in RATIOS if row(cell, ar)}
    ars = [ar for ar in RATIOS if ar in data]
    panels = [("recall", "recall@10", "%.3f"),
              ("sections", "# sections", "%.0f"),
              ("sketch_mb", "SA sketch (MB)", "%.1f"),
              ("rss", "workload RSS (MB)", "%.0f")]
    fig, axes = plt.subplots(1, 4, figsize=(9.2, 2.4))
    for ax, (key, ylab, fmt) in zip(axes, panels):
        ys = [data[ar][key] for ar in ars]
        ax.plot(ars, ys, "-o", color="#0072b2")
        ax.set_xscale("log")
        ax.set_xticks(ars); ax.set_xticklabels([str(a) for a in ars], fontsize=7, rotation=30)
        ax.set_xlabel("adjacent-layer ratio", fontsize=8)
        ax.set_ylabel(ylab, fontsize=9)
        # mark the paper default (~3000)
        if 3000 in ars:
            ax.axvline(3000, color="#d55e00", ls=":", lw=0.8)
    fig.suptitle("Adjacent-ratio sweep (paper default ≈3000, dotted) — " + cell, fontsize=10)
    fig.tight_layout(rect=[0, 0, 1, 0.92])
    out = f"{FIG}/param_adjratio__{cell}"
    fig.savefig(out + ".pdf", bbox_inches="tight"); fig.savefig(out + ".svg", bbox_inches="tight")
    plt.close(fig)

    os.makedirs(DAT, exist_ok=True)
    with open(f"{DAT}/param_adjratio__{cell}.dat", "w") as f:
        f.write("# adjacent-ratio sweep " + cell + " (sa_layer_mult = 1/ln(adj_ratio))\n")
        f.write("adj_ratio\tsa_layer_mult\trecall10\tsections\tsec_size\tsketch_mb\trss_mb\tlat_ms\n")
        for ar in ars:
            d = data[ar]
            f.write(f"{ar}\t{1/math.log(ar):.4f}\t{d['recall']:.4f}\t{d['sections']}\t"
                    f"{d['sec_size']:.0f}\t{d['sketch_mb']:.3f}\t{d['rss']:.0f}\t{d['lat']:.3f}\n")
    print(f"[adjratio] {out}.pdf")
    for ar in ars:
        d = data[ar]
        print(f"    ratio={ar:>6} mult={1/math.log(ar):.4f}  recall={d['recall']:.4f} "
              f"sections={d['sections']} sec_size={d['sec_size']:.0f} sketch={d['sketch_mb']:.1f}MB rss={d['rss']:.0f}MB")


if __name__ == "__main__":
    main()
