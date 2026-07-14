"""Exp 1 (SA-routing case study): routing trajectory + target-hit progress from a visit trace.
Computes dist_to_target offline from the trace's base/pool vectors + GT (target = GT top-1).

  python3 plot/plot_exp1_routing.py <trace.jsonl> <trace_dir> <epoch> <tag>
    e.g. plot/plot_exp1_routing.py results/raw/exp1_trace_sift_1m.jsonl work/sift_1m_r9010 49 sift_1m
"""
import json
import os
import sys
from collections import defaultdict

import numpy as np

sys.path.insert(0, "driver")
sys.path.insert(0, "plot")
from gen_workload import read_fbin, read_gt  # noqa: E402
import style  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

FIG = "results/fig"
VAR = {"sa": ("#d55e00", "SA-Guided"), "nosa": ("#0072b2", "No SA")}


def main():
    trace_jsonl, trace_dir, epoch, tag = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    base = read_fbin(f"{trace_dir}/base.fbin")
    pool = read_fbin(f"{trace_dir}/pool.fbin")
    allv = np.vstack([base, pool]).astype(np.float32)     # global id -> vector
    gt_ids, _ = read_gt(f"{trace_dir}/gt/epoch_{epoch:03d}.gt100")
    target = gt_ids[:, 0].astype(np.int64)                # top-1 global id per query

    rows = [json.loads(l) for l in open(trace_jsonl) if l.strip()]
    efs = sorted(set(r["ef"] for r in rows))
    # group -> list of (rank, node)
    G = defaultdict(list)
    for r in rows:
        G[(r["ef"], r["variant"], r["qid"])].append((r["rank"], r["node"]))

    XMAX = 500  # focus on the early trajectory
    for ef in efs:
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(6.2, 2.5))
        dat_curves = {}  # var -> (x, median_traj, hit_frac)
        for var, (col, lbl) in VAR.items():
            qids = sorted(set(qid for (e, v, qid) in G if e == ef and v == var))
            traj, hit_rank = [], []
            for qid in qids:
                vis = sorted(G[(ef, var, qid)])
                nodes = np.array([n for _, n in vis], dtype=np.int64)
                tgt = target[qid]
                dt = np.linalg.norm(allv[nodes] - allv[tgt], axis=1)     # dist visited-node -> target
                best = np.minimum.accumulate(dt)
                init = best[0] if best[0] > 0 else 1.0
                traj.append(best / init)
                hr = np.where(nodes == tgt)[0]
                hit_rank.append(hr[0] + 1 if len(hr) else np.inf)         # 1-based rank target first hit
            # trajectory: median + 25-75 band, padded with last value to a common length
            L = min(XMAX, max(len(c) for c in traj))
            M = np.full((len(traj), L), np.nan)
            for i, c in enumerate(traj):
                m = min(len(c), L)
                M[i, :m] = c[:m]
                if m < L:
                    M[i, m:] = c[-1]
            x = np.arange(1, L + 1)
            ax1.plot(x, np.nanmedian(M, 0), color=col, label=lbl)
            ax1.fill_between(x, np.nanpercentile(M, 25, 0), np.nanpercentile(M, 75, 0),
                             color=col, alpha=0.18)
            # target-hit progress: fraction of queries with target hit by visit k
            hit_rank = np.array(hit_rank, dtype=float)
            frac = np.array([(hit_rank <= k).mean() for k in x])
            ax2.plot(x, frac, color=col, label=lbl)
            dat_curves[var] = (x, np.nanmedian(M, 0), frac)
        # compact .dat (downsampled every 5 visits) for the results repo (493MB raw trace stays local)
        if "sa" in dat_curves and "nosa" in dat_curves:
            os.makedirs("results/dat", exist_ok=True)
            xs = dat_curves["sa"][0]
            with open(f"results/dat/exp1_routing__{tag}_ef{ef}.dat", "w") as f:
                f.write(f"# exp1 SA-routing case study {tag} ef_final={ef}; "
                        f"sa_visits/q={np.mean([len(G[(ef,'sa',q)]) for q in set(qq for (e,v,qq) in G if e==ef and v=='sa')]):.0f} "
                        f"nosa_visits/q={np.mean([len(G[(ef,'nosa',q)]) for q in set(qq for (e,v,qq) in G if e==ef and v=='nosa')]):.0f}\n")
                f.write("visit\tsa_traj_median\tsa_hit_frac\tnosa_traj_median\tnosa_hit_frac\n")
                for i in range(0, len(xs), 5):
                    f.write(f"{xs[i]}\t{dat_curves['sa'][1][i]:.4f}\t{dat_curves['sa'][2][i]:.4f}\t"
                            f"{dat_curves['nosa'][1][i]:.4f}\t{dat_curves['nosa'][2][i]:.4f}\n")
        ax1.set_xlabel("visited vectors"); ax1.set_ylabel("norm. best dist-to-target")
        ax1.legend(fontsize=8, frameon=False)
        ax2.set_xlabel("visited vectors"); ax2.set_ylabel("frac. queries target hit")
        ax2.legend(fontsize=8, frameon=False)
        fig.suptitle(f"SA-routing case study — {tag}, ef_final={ef}", fontsize=10)
        fig.tight_layout(rect=[0, 0, 1, 0.93])
        out = f"{FIG}/exp1_routing__{tag}_ef{ef}"
        fig.savefig(out + ".pdf", bbox_inches="tight"); fig.savefig(out + ".svg", bbox_inches="tight")
        plt.close(fig)
        # quick numeric summary
        print(f"[exp1] ef={ef}: wrote {out}.pdf")
        for var in ("sa", "nosa"):
            qids = [qid for (e, v, qid) in G if e == ef and v == var]
            nv = np.mean([len(G[(ef, var, q)]) for q in set(qids)])
            print(f"    {var:5} mean visits/query = {nv:.0f}")


if __name__ == "__main__":
    main()
