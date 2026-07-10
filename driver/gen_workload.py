#!/usr/bin/env python3
"""Generate a shared streaming-benchmark trace (runbook §4).

Produces the trace described in bench/driver/trace_format.md for one
(dataset, scale, ratio) cell. The SAME trace drives every system under test, so
insert/delete sequences are byte-identical across ours / SPFresh / SPANN+ / DiskANN.

Split (per runbook §4):
  base = first N vectors of the dataset (the initial index).
  pool = a DISJOINT 0.5N vectors from the tail (the source of all inserts).
  queries = the dataset's held-out query file, fixed for the whole run.
  n_epochs = 50; ops_per_epoch = 1% of N.
  R-INS : each epoch inserts 1%·N pool vectors, no deletes.
  R-9010: each epoch = 0.9%·N inserts + 0.1%·N deletes (uniform over live ids).
  groundtruth: top-100 vs the ACTIVE set, computed every `gt_interval` epochs.

Examples:
  # Synthetic smoke trace (no dataset needed):
  gen_workload.py --synthetic --dim 32 --scale 2000 --ratio r9010 \
      --n-epochs 5 --gt-interval 1 --seed 1 --out work/synth_2k_r9010

  # Real SIFT 1M, 90/10:
  gen_workload.py --dataset sift --scale 1000000 --ratio r9010 \
      --base-file sift_base.fvecs --query-file sift_query.fvecs \
      --n-epochs 50 --gt-interval 10 --seed 1 --out work/sift_1m_r9010
"""
import argparse
import json
import os
import struct
import subprocess
import sys

import numpy as np


# --------------------------------------------------------------------------- #
# Vector-file readers / writers
# --------------------------------------------------------------------------- #
def read_fbin(path, count=None):
    """DiskANN .fbin: int32 n, int32 d, then n*d float32. Reads at most `count` rows."""
    with open(path, "rb") as f:
        n, d = struct.unpack("ii", f.read(8))
        if count is not None:
            n = min(n, count)
        return np.fromfile(f, dtype=np.float32, count=n * d).reshape(n, d)


def read_fvecs(path, count=None):
    """.fvecs: per row int32 d, then d float32. Reads at most `count` rows."""
    with open(path, "rb") as f:
        d = struct.unpack("i", f.read(4))[0]
        f.seek(0)
        row_i32 = d + 1
        rows = count if count is not None else -1
        a = np.fromfile(f, dtype=np.int32,
                        count=(rows * row_i32 if rows > 0 else -1))
        a = a.reshape(-1, row_i32)
        return a[:, 1:].view(np.float32).astype(np.float32)


def read_bvecs(path, count=None):
    """.bvecs: per row int32 d, then d uint8 (SIFT/BIGANN base+query). At most `count` rows."""
    with open(path, "rb") as f:
        d = struct.unpack("i", f.read(4))[0]
        f.seek(0)
        row_bytes = d + 4
        nbytes = count * row_bytes if count is not None else -1
        a = np.fromfile(f, dtype=np.uint8, count=nbytes)
        a = a.reshape(-1, row_bytes)
        return a[:, 4:].astype(np.float32)


def read_i8bin(path, count=None):
    """DiskANN .i8bin: int32 n, int32 d, then n*d int8 (SPACEV/MSSPACEV base+query)."""
    with open(path, "rb") as f:
        n, d = struct.unpack("ii", f.read(8))
        if count is not None:
            n = min(n, count)
        a = np.fromfile(f, dtype=np.int8, count=n * d).reshape(n, d)
        return a.astype(np.float32)


def read_vectors(path, count=None):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".fbin":
        return read_fbin(path, count)
    if ext == ".fvecs":
        return read_fvecs(path, count)
    if ext == ".bvecs":
        return read_bvecs(path, count)
    if ext == ".i8bin":
        return read_i8bin(path, count)
    raise ValueError(f"unknown vector file extension: {ext} ({path})")


def write_fbin(path, arr):
    arr = np.ascontiguousarray(arr, dtype=np.float32)
    n, d = arr.shape
    with open(path, "wb") as f:
        f.write(struct.pack("ii", n, d))
        arr.tofile(f)


def write_u32(path, ids):
    np.ascontiguousarray(ids, dtype=np.uint32).tofile(path)


def write_gt(path, ids, dists):
    """DiskANN groundtruth: uint32 nq, uint32 K, nq*K uint32 ids, nq*K float32 dists."""
    nq, K = ids.shape
    with open(path, "wb") as f:
        f.write(struct.pack("II", nq, K))
        np.ascontiguousarray(ids, dtype=np.uint32).tofile(f)
        np.ascontiguousarray(dists, dtype=np.float32).tofile(f)


# --------------------------------------------------------------------------- #
# Groundtruth
# --------------------------------------------------------------------------- #
def brute_force_gt(active_vecs, active_ids, queries, K, q_batch=1000,
                   base_chunk=200_000):
    """Top-K by squared L2. active_vecs[i] has global id active_ids[i].

    Double-chunked (queries × active set) to bound the distance-matrix memory, so
    it scales to ~1M active without an 8GB intermediate. For 10M+ prefer
    --gt-method diskann.
    """
    nq = queries.shape[0]
    K = min(K, active_vecs.shape[0])
    base2 = (active_vecs * active_vecs).sum(1)  # |b|^2, reused across query batches
    out_ids = np.zeros((nq, K), dtype=np.uint32)
    out_dists = np.zeros((nq, K), dtype=np.float32)
    for qs in range(0, nq, q_batch):
        qe = min(qs + q_batch, nq)
        qb = queries[qs:qe]
        nb = qe - qs
        q2 = (qb * qb).sum(1)[:, None]
        best_d = np.full((nb, K), np.inf, dtype=np.float32)
        best_i = np.zeros((nb, K), dtype=np.int64)
        for s in range(0, active_vecs.shape[0], base_chunk):
            e = min(s + base_chunk, active_vecs.shape[0])
            block = active_vecs[s:e]
            d = (q2 - 2.0 * qb @ block.T + base2[s:e][None, :]).astype(np.float32)
            local = np.broadcast_to(np.arange(s, e), (nb, e - s))
            cat_d = np.concatenate([best_d, d], axis=1)
            cat_i = np.concatenate([best_i, local], axis=1)
            part = np.argpartition(cat_d, K - 1, axis=1)[:, :K]
            best_d = np.take_along_axis(cat_d, part, axis=1)
            best_i = np.take_along_axis(cat_i, part, axis=1)
        order = np.lexsort((active_ids[best_i], best_d), axis=1)
        best_d = np.take_along_axis(best_d, order, axis=1)
        best_i = np.take_along_axis(best_i, order, axis=1)
        out_ids[qs:qe] = active_ids[best_i].astype(np.uint32)
        out_dists[qs:qe] = best_d
    return out_ids, out_dists


def read_gt(path):
    """Read a DiskANN groundtruth file -> (ids[nq,K], dists[nq,K])."""
    with open(path, "rb") as f:
        nq, K = struct.unpack("II", f.read(8))
        ids = np.fromfile(f, dtype=np.uint32, count=nq * K).reshape(nq, K)
        dists = np.fromfile(f, dtype=np.float32, count=nq * K).reshape(nq, K)
    return ids, dists


def diskann_gt(active_fbin, query_fbin, out_gt, K, dtype, diskann_bin, active_ids):
    """Shell out to DiskANN compute_groundtruth (production scale), then remap the
    positional ids it emits (0..|active|-1, into active_fbin) back to stable GLOBAL ids."""
    cmd = [diskann_bin, "--data_type", dtype, "--dist_fn", "l2",
           "--base_file", active_fbin, "--query_file", query_fbin,
           "--gt_file", out_gt, "--K", str(K)]
    subprocess.run(cmd, check=True)
    pos_ids, dists = read_gt(out_gt)
    global_ids = active_ids[pos_ids]  # positional -> global
    write_gt(out_gt, global_ids, dists)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", default="synthetic")
    ap.add_argument("--scale", type=int, required=True, help="N = base index size")
    ap.add_argument("--ratio", choices=["rins", "r9010"], required=True)
    ap.add_argument("--n-epochs", type=int, default=50)
    ap.add_argument("--gt-interval", type=int, default=10)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True, help="output trace directory")
    ap.add_argument("--metric", default="l2")
    # real-dataset inputs
    ap.add_argument("--base-file", help="dataset vectors (.fvecs/.bvecs/.fbin)")
    ap.add_argument("--query-file", help="query vectors (.fvecs/.bvecs/.fbin)")
    ap.add_argument("--pool-frac", type=float, default=0.5,
                    help="pool size as a fraction of N (default 0.5)")
    ap.add_argument("--max-queries", type=int, default=0,
                    help="if >0 and the query file has more rows, deterministically "
                         "subsample to this many queries (seeded; e.g. SPACEV 29316 -> 10000)")
    # synthetic
    ap.add_argument("--synthetic", action="store_true",
                    help="generate random vectors instead of reading a dataset")
    ap.add_argument("--dim", type=int, default=128, help="synthetic dim")
    ap.add_argument("--n-queries", type=int, default=200, help="synthetic query count")
    # groundtruth
    ap.add_argument("--gt-method", choices=["bruteforce", "diskann"], default="bruteforce")
    ap.add_argument("--diskann-gt-bin",
                    default="diskann/build/apps/utils/compute_groundtruth")
    ap.add_argument("--gt-dtype", default="float", help="DiskANN data_type for gt")
    ap.add_argument("--gt-K", type=int, default=100)
    args = ap.parse_args()

    N = args.scale
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(os.path.join(args.out, "gt"), exist_ok=True)

    n_pool = int(round(args.pool_frac * N))

    # ----- load / generate base, pool, queries -----
    if args.synthetic:
        dim = args.dim
        all_vecs = rng.standard_normal((N + n_pool, dim)).astype(np.float32)
        base = all_vecs[:N]
        pool = all_vecs[N:N + n_pool]
        queries = rng.standard_normal((args.n_queries, dim)).astype(np.float32)
    else:
        if not args.base_file or not args.query_file:
            ap.error("--base-file and --query-file are required unless --synthetic")
        data = read_vectors(args.base_file, count=N + n_pool)
        if data.shape[0] < N + n_pool:
            ap.error(f"dataset has {data.shape[0]} rows, need {N + n_pool} "
                     f"(base {N} + pool {n_pool})")
        dim = data.shape[1]
        base = data[:N]
        pool = data[N:N + n_pool]          # disjoint tail
        queries = read_vectors(args.query_file)

    # Optional deterministic query subsample (e.g. SPACEV ships 29,316; subsample to match
    # SIFT's 10k for comparable latency/QPS and bounded runtime). Uses a dedicated RNG so the
    # epoch ins/del stream is unaffected. The chosen indices are recorded in the manifest.
    if args.max_queries and queries.shape[0] > args.max_queries:
        qrng = np.random.default_rng(args.seed + 100003)
        qsel = np.sort(qrng.choice(queries.shape[0], size=args.max_queries, replace=False))
        queries = queries[qsel]

    base_ids = np.arange(0, N, dtype=np.uint32)
    pool_ids = np.arange(N, N + n_pool, dtype=np.uint32)

    write_fbin(os.path.join(args.out, "base.fbin"), base)
    write_u32(os.path.join(args.out, "base.ids.u32"), base_ids)
    write_fbin(os.path.join(args.out, "pool.fbin"), pool)
    write_u32(os.path.join(args.out, "pool.ids.u32"), pool_ids)
    write_fbin(os.path.join(args.out, "query.fbin"), queries)

    # id -> vector for gt materialization (concatenated base+pool space)
    all_ids_vecs = np.concatenate([base, pool], axis=0)  # row r -> global id r

    ops = max(1, N // 100)  # 1% of N
    if args.ratio == "rins":
        ins_per, del_per = ops, 0
    else:  # r9010
        ins_per = max(1, int(round(0.9 * ops)))
        del_per = max(0, ops - ins_per)

    live = set(int(x) for x in base_ids)
    pool_cursor = 0
    n_epochs = args.n_epochs

    for k in range(n_epochs):
        # deletes: uniform over current live ids (before this epoch's inserts)
        dels = np.empty(0, dtype=np.uint32)
        if del_per > 0 and len(live) > del_per:
            live_arr = np.fromiter(live, dtype=np.uint32, count=len(live))
            dels = rng.choice(live_arr, size=del_per, replace=False).astype(np.uint32)
        # inserts: next fresh pool ids
        take = min(ins_per, n_pool - pool_cursor)
        inss = pool_ids[pool_cursor:pool_cursor + take]
        pool_cursor += take

        for d in dels:
            live.discard(int(d))
        for a in inss:
            live.add(int(a))

        stem = os.path.join(args.out, f"epoch_{k:03d}")
        write_u32(stem + ".ins.u32", inss)
        write_u32(stem + ".del.u32", dels)

        is_ckpt = (k % args.gt_interval == 0) or (k == n_epochs - 1)
        if is_ckpt:
            active_ids = np.fromiter(sorted(live), dtype=np.uint32, count=len(live))
            gt_path = os.path.join(args.out, "gt", f"epoch_{k:03d}.gt100")
            if args.gt_method == "diskann":
                active_fbin = os.path.join(args.out, "gt", f"active_{k:03d}.fbin")
                write_fbin(active_fbin, all_ids_vecs[active_ids])
                # DiskANN emits positional ids into active_fbin; diskann_gt remaps them
                # back to stable global ids via active_ids.
                diskann_gt(active_fbin, os.path.join(args.out, "query.fbin"),
                           gt_path, args.gt_K, args.gt_dtype, args.diskann_gt_bin,
                           active_ids)
                # The active-set snapshot is only needed to compute this checkpoint's gt;
                # delete it immediately so they don't accumulate (at 100M each is ~60GB).
                try:
                    os.remove(active_fbin)
                except OSError:
                    pass
            else:
                ids, dists = brute_force_gt(all_ids_vecs[active_ids], active_ids,
                                            queries, args.gt_K)
                write_gt(gt_path, ids, dists)
        if take < ins_per:
            print(f"WARNING: pool exhausted at epoch {k} "
                  f"(wanted {ins_per}, got {take})", file=sys.stderr)

    manifest = {
        "dataset": args.dataset,
        "dim": int(dim),
        "metric": args.metric,
        "scale": int(N),
        "ratio": args.ratio,
        "n_base": int(N),
        "n_pool": int(n_pool),
        "n_queries": int(queries.shape[0]),
        "n_epochs": int(n_epochs),
        "ops_per_epoch": int(ops),
        "ins_per_epoch": int(ins_per),
        "del_per_epoch": int(del_per),
        "gt_interval": int(args.gt_interval),
        "gt_method": args.gt_method,
        "seed": int(args.seed),
        "delete_policy": "uniform_live",
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"wrote trace to {args.out}: N={N} pool={n_pool} epochs={n_epochs} "
          f"ins/ep={ins_per} del/ep={del_per} queries={queries.shape[0]}")


if __name__ == "__main__":
    main()
