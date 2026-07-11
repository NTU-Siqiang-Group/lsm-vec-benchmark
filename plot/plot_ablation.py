"""Ablation figures (Phase 2 SA-routing, Phase 3 layout). Reads raw per-epoch JSONL for a set of
ours-variants and emits a multi-panel grouped-bar figure + a .dat. Self-contained (one-off figures,
not part of the standard family pipeline).

Usage:
  python3 plot/plot_ablation.py phase2 sift_1m_r9010
  python3 plot/plot_ablation.py phase3 sift_1m_r9010
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import style  # noqa: E402

RAW = "results/raw"
FIG = "results/fig"
DAT = "results/dat"

# Wong-palette-ish distinct colors for variants.
VARIANT = {
    "ours_section": {"label": "SA-route (ours)", "color": "#d55e00"},
    "ours_no_sa":   {"label": "no SA-route",     "color": "#56b4e9"},
    "ours_append":  {"label": "append",          "color": "#009e73"},
    "ours_random":  {"label": "random",          "color": "#cc79a7"},
    "lsm-vec-basic":{"label": "basic HNSW",       "color": "#000000"},
}

PHASES = {
    "phase2": {
        "name": "sa_routing_ablation",
        "variants": ["ours_section", "ours_no_sa", "lsm-vec-basic"],
        "title": "SA-routing ablation",
    },
    "phase3": {
        "name": "reordering_ablation",
        "variants": ["ours_section", "ours_append", "ours_random"],
        "title": "vector-layout (reordering) ablation",
    },
}

# (json_key, panel_label, aggregation) — aggregation: 'last' end-of-stream, 'mean' over epochs, 'peakmem'
PANELS = [
    ("recall10", "recall@10 (end)", "last"),
    ("query_page_miss_per_query", "vector-page reads / query", "last"),
    ("lat_p99_ms", "P99 latency (ms)", "mean"),
]


def load(variant, cell):
    fp = f"{RAW}/{variant}_{cell}.jsonl"
    if not os.path.exists(fp):
        return None
    rows = [json.loads(l) for l in open(fp) if l.strip()]
    if not rows:
        return None
    out = {}
    for key, _, agg in PANELS:
        if agg == "last":
            # last epoch with a non-null value
            vals = [r.get(key) for r in rows if r.get(key) is not None]
            out[key] = vals[-1] if vals else float("nan")
        else:  # mean
            vals = [r.get(key) for r in rows if r.get(key) is not None]
            out[key] = sum(vals) / len(vals) if vals else float("nan")
    return out


def main():
    phase = sys.argv[1]
    cell = sys.argv[2]
    spec = PHASES[phase]
    variants = [v for v in spec["variants"] if load(v, cell) is not None]
    data = {v: load(v, cell) for v in variants}

    import matplotlib.pyplot as plt
    n = len(PANELS)
    fig, axes = plt.subplots(1, n, figsize=(2.4 * n, 2.4))
    if n == 1:
        axes = [axes]
    for ax, (key, plabel, _) in zip(axes, PANELS):
        labels = [VARIANT.get(v, {}).get("label", v) for v in variants]
        colors = [VARIANT.get(v, {}).get("color", "gray") for v in variants]
        vals = [data[v].get(key, float("nan")) for v in variants]
        ax.bar(range(len(vals)), vals, color=colors, edgecolor="black", linewidth=0.4)
        ax.set_xticks(range(len(labels)))
        ax.set_xticklabels(labels, rotation=30, ha="right", fontsize=8)
        ax.set_ylabel(plabel, fontsize=9)
        # annotate values
        for i, v in enumerate(vals):
            if v == v:
                ax.text(i, v, f"{v:.3f}" if key == "recall10" else f"{v:.0f}" if "miss" in key else f"{v:.2f}",
                        ha="center", va="bottom", fontsize=7)
        ax.margins(y=0.18)
    fig.suptitle(f"{spec['title']} — {cell}", fontsize=10)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    out = f"{FIG}/{spec['name']}__{cell}"
    fig.savefig(out + ".pdf", bbox_inches="tight")
    fig.savefig(out + ".svg", bbox_inches="tight")
    plt.close(fig)

    # .dat table
    os.makedirs(DAT, exist_ok=True)
    datp = f"{DAT}/{spec['name']}__{cell}.dat"
    with open(datp, "w") as f:
        cols = ["variant"] + [k for k, _, _ in PANELS]
        f.write("# " + spec["name"] + " " + cell + "\n")
        f.write("\t".join(cols) + "\n")
        for v in variants:
            f.write("\t".join([v] + [f"{data[v].get(k, float('nan')):.6g}" for k, _, _ in PANELS]) + "\n")
    print(f"[ablation] {out}.pdf + .svg  ({', '.join(variants)})")
    for v in variants:
        print(f"    {v:14} " + "  ".join(f"{k.split('_')[0]}={data[v].get(k):.4g}" for k, _, _ in PANELS))


if __name__ == "__main__":
    main()
