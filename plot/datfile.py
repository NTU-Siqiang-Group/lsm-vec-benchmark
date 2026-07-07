"""Canonical .dat read/write (runbook §10.2).

A .dat is a whitespace-delimited tidy table with a self-describing provenance
header — gnuplot/numpy-loadable, diffable, version-controlled. One .dat per figure;
the plotter slices by the `system` column.
"""
import os


def write_dat(path, experiment, columns, rows, source="", cmd="", git_sha="",
              generated=""):
    """rows: list of dicts keyed by column name (values stringified, NaN/None -> 'nan')."""
    os.makedirs(os.path.dirname(path), exist_ok=True)

    def cell(v):
        if v is None:
            return "nan"
        if isinstance(v, float):
            return "nan" if v != v else repr(v)
        return str(v)

    widths = [max(len(c), *(len(cell(r.get(c))) for r in rows)) if rows else len(c)
              for c in columns]
    with open(path, "w") as f:
        f.write(f"# experiment: {experiment}\n")
        f.write(f"# generated : {generated}   git:{git_sha}   cmd: {cmd}\n")
        f.write(f"# source    : {source}\n")
        f.write(f"# columns   : {' '.join(columns)}\n")
        for r in rows:
            f.write("  ".join(cell(r.get(c)).ljust(w)
                              for c, w in zip(columns, widths)).rstrip() + "\n")


def read_dat(path):
    """-> (meta: dict, columns: list[str], rows: list[dict[str,str]])."""
    meta, columns, rows = {}, [], []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            if line.startswith("#"):
                body = line[1:].strip()
                if body.startswith("columns"):
                    columns = body.split(":", 1)[1].split()
                elif ":" in body:
                    k, v = body.split(":", 1)
                    meta[k.strip()] = v.strip()
                continue
            parts = line.split()
            if columns and len(parts) == len(columns):
                rows.append(dict(zip(columns, parts)))
    return meta, columns, rows


def rows_by_system(rows, system_col="system"):
    """Group rows by the system column, preserving insertion order."""
    out = {}
    for r in rows:
        out.setdefault(r[system_col], []).append(r)
    return out


def fnan(s):
    """Parse a float cell, returning float('nan') for 'nan'/'null'/''."""
    if s is None:
        return float("nan")
    s = s.strip()
    if s in ("nan", "null", ""):
        return float("nan")
    return float(s)
