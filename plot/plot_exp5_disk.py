"""Exp 5 (disk usage breakdown): per-system stacked disk footprint by component, from the final index
directories, + a compression disclosure table. Each system uses architecture-appropriate components,
colored by a shared semantic scheme (data=orange, index/graph=blue, routing=green, WAL=gray, meta=black).

  python3 plot/plot_exp5_disk.py <cell>   # e.g. sift_1m_r9010
"""
import os
import sys

sys.path.insert(0, "plot")
import style  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
import matplotlib.patches as mpatches  # noqa: E402

FIG, DAT = "results/fig", "results/dat"
GB = 1024.0 ** 3

# semantic color per component key
COL = {"data": "#d55e00", "pq": "#e69f00", "graph": "#0072b2", "index": "#0072b2",
       "routing": "#009e73", "wal": "#999999", "meta": "#000000"}


def walk(path):
    """-> list of (relname, size_bytes) for all regular files under path."""
    out = []
    for root, _, files in os.walk(path):
        for fn in files:
            fp = os.path.join(root, fn)
            try:
                out.append((os.path.relpath(fp, path), os.path.getsize(fp)))
            except OSError:
                pass
    return out


def classify(system, files):
    """-> ordered list of (label, color_key, bytes) components for the stack."""
    comp = {}
    def add(label, ck, b):
        comp.setdefault(label, [ck, 0]); comp[label][1] += b
    for name, sz in files:
        base = os.path.basename(name)
        if system in ("ours", "ours_capfix"):
            if base.startswith("vector.log"):        add("vectors (SQ8)", "data", sz)
            elif base.endswith(".sst"):              add("graph LSM", "graph", sz)
            elif base.endswith(".log"):              add("WAL", "wal", sz)
            else:                                    add("meta", "meta", sz)
        elif system == "diskann_merge":
            if base == "idx_disk.index":             add("disk index (graph+vec)", "graph", sz)
            elif "pq_" in base:                      add("PQ vectors", "pq", sz)
            else:                                    add("meta (tags/samples)", "meta", sz)
        else:  # spfresh / spannplus
            if base.endswith(".blob"):               add("posting store (KV, float32)", "data", sz)
            elif base.endswith(".log"):              add("WAL", "wal", sz)
            elif "SPTAGHead" in base or "head_index" in name or base == "vectors.bin":
                add("head index (routing)", "routing", sz)
            elif base.endswith(".sst"):              add("KV SST", "data", sz)
            else:                                    add("meta", "meta", sz)
    # order: data-ish first (bottom), then index, routing, wal, meta
    order = ["data", "graph", "index", "pq", "routing", "wal", "meta"]
    items = sorted(comp.items(), key=lambda kv: order.index(kv[1][0]))
    return [(lbl, ck, b) for lbl, (ck, b) in items]


def main():
    cell = sys.argv[1]
    dirs = {
        "ours":          f"work/ours_db_{cell}",
        "diskann_merge": f"work/diskann_merge_{cell}_idx",
        "spfresh":       f"work/spfresh_{cell}/store",
        "spannplus":     f"work/spannplus_{cell}/store",
    }
    labels = {"ours": "ours", "diskann_merge": "DiskANN\nmerge", "spfresh": "SPFresh", "spannplus": "SPANN+"}
    fig, ax = style.new_fig()
    seen = {}
    rows = []
    for i, (sysname, d) in enumerate(dirs.items()):
        if not os.path.isdir(d):
            print(f"  [skip] {sysname}: {d} missing"); continue
        comps = classify(sysname, walk(d))
        bottom = 0.0
        for lbl, ck, b in comps:
            gb = b / GB
            ax.bar(i, gb, bottom=bottom, color=COL[ck], edgecolor="black", linewidth=0.3)
            bottom += gb
            rows.append((sysname, lbl, gb))
            seen[lbl] = COL[ck]
        ax.text(i, bottom, f"{bottom:.2f}G", ha="center", va="bottom", fontsize=7)
    ax.set_xticks(range(len(dirs)))
    ax.set_xticklabels([labels[s] for s in dirs], fontsize=8)
    ax.set_ylabel("disk footprint (GiB)")
    handles = [mpatches.Patch(color=c, label=l) for l, c in seen.items()]
    ax.legend(handles=handles, fontsize=6.5, frameon=False, ncol=1, loc="upper left")
    style.save_fig(fig, f"{FIG}/exp5_disk_breakdown__{cell}")
    print(f"[exp5] {FIG}/exp5_disk_breakdown__{cell}.pdf")
    os.makedirs(DAT, exist_ok=True)
    with open(f"{DAT}/exp5_disk_breakdown__{cell}.dat", "w") as f:
        f.write("# exp5 disk breakdown " + cell + "\nsystem\tcomponent\tGiB\n")
        for s, l, g in rows:
            f.write(f"{s}\t{l}\t{g:.4f}\n")
    for s, l, g in rows:
        print(f"    {s:14} {l:32} {g:7.3f} GiB")


if __name__ == "__main__":
    main()
