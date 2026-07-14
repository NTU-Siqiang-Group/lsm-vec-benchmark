"""Phase 4 (disk) + Phase 6 (memory + cache) figures for ours. Reads raw per-epoch JSONL.

  python3 plot/plot_breakdown.py disk   sift_1m_r9010   # ours disk components (stacked) + baseline totals
  python3 plot/plot_breakdown.py mem    sift_1m_r9010   # ours memory components (stacked) + 'other'
  python3 plot/plot_breakdown.py cache  sift_1m_r9010   # cache sensitivity (small/default/large)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import style  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

RAW, FIG, DAT = "results/raw", "results/fig", "results/dat"


def rows(name, cell):
    fp = f"{RAW}/{name}_{cell}.jsonl"
    if not os.path.exists(fp):
        return None
    return [json.loads(l) for l in open(fp) if l.strip()]


def last(name, cell, keys):
    r = rows(name, cell)
    if not r:
        return None
    e = r[-1]
    return {k: e.get(k, 0.0) or 0.0 for k in keys}


def peak_rss(name, cell):
    fp = f"{RAW}/{name}_{cell}.mem.jsonl"
    if not os.path.exists(fp):
        return 0.0
    m = [json.loads(l) for l in open(fp) if l.strip()]
    return max((x.get("rss_mb", 0) for x in m if x.get("epoch", -9) >= 0), default=0.0)


DISK_COMPS = [("disk_graph_mb", "graph LSM", "#0072b2"),
              ("disk_vector_mb", "vectors (SQ8)", "#d55e00"),
              ("disk_wal_mb", "WAL", "#999999"),
              ("disk_meta_mb", "meta", "#000000")]
MEM_COMPS = [("mem_upper_hnsw_mb", "upper HNSW", "#0072b2"),
             ("mem_sa_sketch_mb", "SA sketch", "#d55e00"),
             ("mem_graph_cache_mb", "graph cache", "#009e73"),
             ("mem_vec_cache_mb", "vec cache", "#56b4e9"),
             ("mem_update_buf_mb", "update buf", "#e69f00"),
             ("__other__", "other/alloc", "#cccccc")]


def stacked(kind, cell):
    comps = DISK_COMPS if kind == "disk" else MEM_COMPS
    if kind == "disk":
        systems = ["ours_section", "spfresh", "spannplus", "diskann_merge"]
    else:
        systems = ["ours_section"]
    fig, ax = style.new_fig()
    xs, labels = [], []
    for i, s in enumerate(systems):
        r = rows(s, cell)
        xs.append(i)
        labels.append({"ours_section": "ours"}.get(s, s.replace("_", "\n")))
        if r is None:
            continue
        e = r[-1]
        has_breakdown = e.get(comps[0][0]) is not None  # only ours emits disk_graph_mb / mem_* fields
        if kind == "disk" and not has_breakdown:
            tot = e.get("disk_mb", 0)                    # baseline: single total bar
            ax.bar(i, tot, color="#bbbbbb", edgecolor="black", linewidth=0.4)
            ax.text(i, tot, f"{tot/1000:.1f}G", ha="center", va="bottom", fontsize=7)
            continue
        bottom = 0.0
        for key, lbl, col in comps:
            if key == "__other__":
                v = max(0.0, peak_rss(s, cell) - bottom)
            else:
                v = e.get(key, 0.0) or 0.0
            ax.bar(i, v, bottom=bottom, color=col, edgecolor="black", linewidth=0.3,
                   label=lbl if i == 0 else None)
            bottom += v
        ax.text(i, bottom, f"{bottom/1000:.1f}G", ha="center", va="bottom", fontsize=7)
    ax.set_xticks(xs)
    ax.set_xticklabels(labels, fontsize=8)
    ax.set_ylabel("disk (MB)" if kind == "disk" else "memory (MB)")
    ax.legend(fontsize=7, frameon=False, ncol=2)
    out = f"{FIG}/{'disk_usage_final' if kind=='disk' else 'memory_breakdown'}__{cell}"
    style.save_fig(fig, out)
    print(f"[breakdown] {out}.pdf")


def cache(cell):
    variants = [("ours_cache_small", "small\n(2048p)", 2048),
                ("ours_section", "default\n(~8192p)", 8192),
                ("ours_cache_large", "large\n(32768p)", 32768)]
    variants = [(n, l, p) for n, l, p in variants if rows(n, cell)]
    fig, ax = style.new_fig()
    labels, p99s, misses, recs = [], [], [], []
    for n, l, _ in variants:
        r = rows(n, cell)
        p99s.append(sum(x.get("lat_p99_ms", 0) for x in r) / len(r))
        misses.append(r[-1].get("query_page_miss_per_query", 0))
        rc = [x.get("recall10") for x in r if x.get("recall10") is not None]
        recs.append(rc[-1] if rc else float("nan"))
        labels.append(l)
    x = range(len(labels))
    ax.plot(x, p99s, "-o", color="#d55e00", label="P99 latency (ms)")
    ax.set_ylabel("P99 latency (ms)", color="#d55e00")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, fontsize=8)
    ax2 = ax.twinx()
    ax2.plot(x, misses, "--s", color="#0072b2", label="page reads/q")
    ax2.set_ylabel("vector-page reads / query", color="#0072b2")
    for i, rc in enumerate(recs):
        ax.annotate(f"r={rc:.3f}", (i, p99s[i]), fontsize=6, ha="center", va="bottom")
    out = f"{FIG}/cache_sensitivity__{cell}"
    style.save_fig(fig, out)
    print(f"[breakdown] {out}.pdf  (p99={['%.2f'%v for v in p99s]}, miss={['%.0f'%v for v in misses]})")


if __name__ == "__main__":
    kind, cell = sys.argv[1], sys.argv[2]
    if kind == "cache":
        cache(cell)
    else:
        stacked(kind, cell)
