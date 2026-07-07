"""Experiment registry (runbook §10.4/§10.5).

Each figure family + matrix cell = one experiment = one dat/<name>.dat = one
fig/<name>.pdf. Names are `<family>__<ds>_<scale>_<ratio>`.
"""

# Matrix axes.
DATASETS = ["sift", "spacev"]
SCALES = ["1m", "10m", "100m"]
RATIOS = ["rins", "r9010"]

# Systems we PLOT. DiskANN-IP (fully in-memory) is intentionally EXCLUDED: comparing on-disk methods
# (ours, its ablations, SPFresh, SPANN+, DiskANN-merge — all paged/file-I/O) against a fully in-memory
# index is unfair to the on-disk methods. Its raw data is kept in results/raw but not plotted.
ALL_SYSTEMS = ["ours", "lsm-vec-no-sa", "lsm-vec-basic",
               "spfresh", "spannplus", "diskann_merge"]


def systems_for_scale(scale):
    # At 1m: ours + the two ablations + the on-disk baselines. At 10m/100m: carry the core on-disk
    # systems (DiskANN-merge is the on-disk DiskANN; the ablations are 1m-only unless run larger).
    if scale == "1m":
        return ALL_SYSTEMS
    return ["ours", "spfresh", "spannplus", "diskann_merge"]


# Figure families. source: 'epoch' (per-epoch JSONL), 'mem' (RSS-vs-time JSONL), or
# 'summary' (per-system scalars: build time, mean throughput, peak RSS).
# plot: (module_name, fn_name, options) — options forwarded to the pure plotter.
FAMILIES = {
    "recall_epoch": {
        "source": "epoch",
        "plot": ("plot_timeseries", "plot",
                 {"y": "recall10", "ylabel": "recall@10", "x": "epoch", "xlabel": "epoch"}),
        "desc": "recall@10 vs epoch — the recall-stability headline",
    },
    "latency_epoch": {
        "source": "epoch",
        "plot": ("plot_timeseries", "plot_dual",
                 {"y_top": "lat_p99_ms", "y_bottom": "lat_p50_ms",
                  "ylabel_top": "P99 latency (ms)", "ylabel_bottom": "P50 latency (ms)",
                  "logy": False}),
        "desc": "query latency vs epoch (P99 top / P50 bottom), linear y from 0",
    },
    "insert_tput_epoch": {
        "source": "epoch",
        "plot": ("plot_timeseries", "plot",
                 {"y": "ins_ops_s", "ylabel": "insert throughput (ops/s)",
                  "x": "epoch", "xlabel": "epoch"}),
        "desc": "insert throughput vs epoch",
    },
    "mem_time": {
        "source": "mem",
        "plot": ("plot_timeseries", "plot",
                 {"y": "rss_mb", "ylabel": "process RSS (MB)",
                  "x": "epoch_frac", "xlabel": "epoch progress"}),
        "desc": "real-time DRAM (RSS) vs time, SPFresh Fig-5 style",
    },
    "recall_latency_pareto": {
        "source": "epoch",
        "plot": ("plot_pareto", "plot",
                 {"x": "lat_mean_ms", "y": "recall10"}),
        "desc": "recall@10 vs mean latency at end-of-stream",
    },
    "build_time": {
        "source": "summary",
        "plot": ("plot_bar", "plot",
                 {"y": "build_time_s", "ylabel": "base index build time (s)"}),
        "desc": "base index build time per system (from the epoch=-1 RSS phase)",
    },
    "insert_tput": {
        "source": "summary",
        "plot": ("plot_bar", "plot",
                 {"y": "mean_ins_ops_s", "ylabel": "mean insert throughput (ops/s)"}),
        "desc": "mean insert throughput per system (NB: thread counts differ — footnote)",
    },
}

# NOTE: the two ablations of ours (lsm-vec-no-sa / lsm-vec-basic) are plotted INSIDE the main
# families (they're in ALL_SYSTEMS), so they compare directly against all baselines — no separate
# ablation figures.

# (DiskANN in-place vs merge head-to-head removed — DiskANN-IP is excluded as an unfair
#  in-memory comparison; only the on-disk DiskANN-merge is kept.)
DISKANN_FAMILY = {}


def all_experiments():
    """-> list of dicts: {name, family, source, plot, ds, scale, ratio, systems}."""
    exps = []
    for fam, spec in FAMILIES.items():
        for ds in DATASETS:
            for scale in SCALES:
                for ratio in RATIOS:
                    exps.append({
                        "name": f"{fam}__{ds}_{scale}_{ratio}",
                        "family": fam, "source": spec["source"], "plot": spec["plot"],
                        "ds": ds, "scale": scale, "ratio": ratio,
                        "systems": systems_for_scale(scale),
                    })
    # DiskANN variant comparison: 1m only.
    for fam, spec in DISKANN_FAMILY.items():
        for ds in DATASETS:
            for ratio in RATIOS:
                exps.append({
                    "name": f"{fam}__{ds}_1m_{ratio}",
                    "family": fam, "source": spec["source"], "plot": spec["plot"],
                    "ds": ds, "scale": "1m", "ratio": ratio,
                    "systems": spec["systems"],
                })
    return exps


def find_experiment(name):
    for e in all_experiments():
        if e["name"] == name:
            return e
    return None
