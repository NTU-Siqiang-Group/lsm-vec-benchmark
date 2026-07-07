"""Shared paper-ready Matplotlib style (runbook §10.3).

- Vector output (PDF + SVG), Type-42/TrueType fonts (never Type-3 — venues reject).
- Serif/Times-like family, ~9-10pt legible at single-column width.
- Colorblind-safe palette (Wong) with a distinct linestyle + marker per system so
  figures survive B/W printing.
- No figure title (captions live in LaTeX). save_fig() writes both .pdf and .svg.
"""
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

# Embed TrueType (Type-42), never Type-3.
matplotlib.rcParams.update({
    "pdf.fonttype": 42,
    "ps.fonttype": 42,
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Nimbus Roman", "DejaVu Serif"],
    "font.size": 9,
    "axes.titlesize": 9,
    "axes.labelsize": 9,
    "legend.fontsize": 8,
    "xtick.labelsize": 8,
    "ytick.labelsize": 8,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linewidth": 0.4,
    "lines.linewidth": 1.3,
    "lines.markersize": 4,
    "figure.dpi": 150,
})

# Wong colorblind-safe palette.
_WONG = {
    "black":  "#000000",
    "orange": "#E69F00",
    "skyblue": "#56B4E9",
    "green":  "#009E73",
    "yellow": "#F0E442",
    "blue":   "#0072B2",
    "vermil": "#D55E00",
    "purple": "#CC79A7",
}

# Per-system visual identity: color + linestyle + marker (B/W-safe).
SYSTEM_STYLE = {
    "ours":          {"color": _WONG["vermil"], "linestyle": "-",  "marker": "o", "label": "LSM-Vec (ours)"},
    "spfresh":       {"color": _WONG["blue"],   "linestyle": "--", "marker": "s", "label": "SPFresh"},
    "spannplus":     {"color": _WONG["green"],  "linestyle": "-.", "marker": "^", "label": "SPANN+"},
    "diskann_ip":    {"color": _WONG["orange"], "linestyle": ":",  "marker": "D", "label": "DiskANN (in-place)"},
    "diskann_merge": {"color": _WONG["purple"], "linestyle": (0, (3, 1, 1, 1)), "marker": "v", "label": "DiskANN (merge)"},
    # ablations of ours (no SA tree):
    "lsm-vec-no-sa": {"color": _WONG["skyblue"], "linestyle": "--", "marker": "P", "label": "LSM-Vec no-SA (flat shape)"},
    "lsm-vec-basic": {"color": _WONG["black"],   "linestyle": ":",  "marker": "x", "label": "LSM-Vec basic (full HNSW)"},
}

# Canonical system order for legends.
SYSTEM_ORDER = ["ours", "lsm-vec-no-sa", "lsm-vec-basic",
                "spfresh", "spannplus", "diskann_ip", "diskann_merge"]

# Single-column figure size (inches). Slightly wider than the strict 3.3" so 7 overlaid
# series + an out-of-axes legend stay legible.
SINGLE_COL = (4.0, 2.7)


def system_style(system):
    return SYSTEM_STYLE.get(
        system, {"color": "gray", "linestyle": "-", "marker": "x", "label": system})


def new_fig(figsize=SINGLE_COL):
    fig, ax = plt.subplots(figsize=figsize)
    return fig, ax


def legend_left(ax, n_series=0):
    """Place a single-column (vertical) legend OUTSIDE the axes, to the LEFT, at a legible size.
    bbox_inches='tight' in save_fig captures it."""
    ax.legend(loc="center right", bbox_to_anchor=(-0.34, 0.5), ncol=1,
              frameon=False, fontsize=9, handlelength=2.8, labelspacing=0.8,
              handletextpad=0.6, borderaxespad=0.0)


# Back-compat alias.
legend_below = legend_left


def save_fig(fig, out_path_noext):
    """Write both <out>.pdf and <out>.svg with tight bbox."""
    fig.savefig(out_path_noext + ".pdf", bbox_inches="tight")
    fig.savefig(out_path_noext + ".svg", bbox_inches="tight")
    plt.close(fig)
