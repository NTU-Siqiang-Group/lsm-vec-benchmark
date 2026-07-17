"""Refine DiskANN per-epoch insert latency to include merge stalls, reconstructed from existing data
(no re-run). The driver's `ins_ops_s` times only the in-memory delta-insert loop and excludes the
StreamingMerge that blocks foreground inserts. This recovers, per epoch:

    epoch_wall (from mem.jsonl per-epoch t_sec) - query_time (q_n / qps) - delta_insert_time
      = merge_s   (~0 on non-merge epochs, ~the merge duration on merge epochs)

and emits per-epoch insert latency WITH the merge folded in:
    ins_lat_merged_ms = 1000 * (delta_insert_time + merge_s) / n_inserts

Validated on sift_10m flush: residual ~0 on non-merge epochs, ~210 s on the merge epochs (which match
the run log's "triggering StreamingMerge" lines exactly). Emits dat/diskann_ins_latency_epoch__<cell>.dat.

  python3 plot/refine_diskann_insert_latency.py <name> <cell>
    e.g. plot/refine_diskann_insert_latency.py diskann_merge_flush sift_10m_r9010
"""
import json
import os
import sys

RAW, DAT, LOGD = "results/raw", "results/dat", "logs"
INS_PER = {"1m": 9000, "10m": 90000}
QN = 10000


# A merge epoch is detected from the DATA: its reconstructed merge_s (residual wall after subtracting
# query + delta-insert) is large. Merges cost ~60-220 s; non-merge residual is a few seconds of noise,
# so a 10 s floor cleanly separates them (self-consistent, no dependence on log-file paths).
MERGE_S_FLOOR = 10.0


def main():
    name, cell = sys.argv[1], sys.argv[2]
    scale = "10m" if "10m" in cell else "1m"
    ins_per = INS_PER[scale]
    r = [json.loads(l) for l in open(f"{RAW}/{name}_{cell}.jsonl") if l.strip()]
    m = [json.loads(l) for l in open(f"{RAW}/{name}_{cell}.mem.jsonl") if l.strip()]
    first_t = {}
    for x in m:
        e = x.get("epoch", -9)
        if e >= 0 and e not in first_t:
            first_t[e] = x["t_sec"]
    last_t = m[-1]["t_sec"]

    os.makedirs(DAT, exist_ok=True)
    out = f"{DAT}/diskann_ins_latency_epoch__{name}__{cell}.dat"
    rows = []
    for e in range(len(r)):
        if e not in first_t:
            continue
        wall = first_t.get(e + 1, last_t) - first_t[e]
        qps = max(r[e].get("qps", 1), 1e-9)
        insops = max(r[e].get("ins_ops_s", 1), 1e-9)
        q_s = QN / qps
        dins_s = ins_per / insops                       # delta-insert time (merge excluded)
        merge_s = max(0.0, wall - q_s - dins_s)          # residual ~ merge time
        lat_delta = 1000.0 * dins_s / ins_per            # ms/insert, delta only
        lat_merged = 1000.0 * (dins_s + merge_s) / ins_per  # ms/insert, merge folded in
        rows.append((e, lat_delta, merge_s, lat_merged, merge_s > MERGE_S_FLOOR))
    with open(out, "w") as f:
        f.write(f"# DiskANN per-epoch insert latency, merge folded in (reconstructed) — {name} {cell}\n")
        f.write("epoch\tins_lat_delta_ms\tmerge_s\tins_lat_merged_ms\tis_merge_epoch\n")
        for e, ld, ms, lm, mk in rows:
            f.write(f"{e}\t{ld:.4f}\t{ms:.1f}\t{lm:.4f}\t{int(mk)}\n")
    nmerge = sum(1 for *_, mk in rows if mk)
    peak = max((lm for *_, lm, _ in rows), default=0)
    base = sorted(lm for _, _, _, lm, mk in rows if not mk)
    med_base = base[len(base) // 2] if base else 0
    print(f"[refine] {out}  ({nmerge} merge epochs; insert lat base~{med_base:.3f}ms, merge-epoch peak {peak:.3f}ms)")


if __name__ == "__main__":
    main()
