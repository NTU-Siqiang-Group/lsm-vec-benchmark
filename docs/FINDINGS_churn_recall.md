# Finding: recall collapse under churn — root cause & proposed fix

**Date:** 2026-06-29/30 · **System:** LSM-Vec SA-sketch (`sa-resident-sketch`) · **Workload:** SIFT 1M,
50-epoch streaming, ef_final=128 unless noted · **Figure:** `results/fig/churn_recall_attribution.pdf`

## TL;DR

Our method's headline claim — *recall stable under churn* — **does not hold as built.** Under a 90/10
insert/delete stream the recall@10 collapses **0.935 → 0.515** over 50 epochs (index 1.0M→1.4M). The
cause is **not** the resident sketch, **not** ef_final, and **not** insert quality. It is the **delete
path**: `deleteNode` removes a node's edges from the HNSW L0 graph but **never re-links the orphaned
neighbors**, so every delete punches a hole in local navigability and there is no repair. This is the
textbook HNSW deletion problem. The fix is DiskANN-style **neighbor re-linking on delete**
(`consolidate_deletes`). Inserts are fine — pure-insert recall is rock-stable at ~0.95 to 1.5M.

## Evidence (each row is a controlled experiment)

**1. recall decays under churn; ef_final lifts the floor, not the slope.**

| epoch | live_n | ef_final=16 | ef_final=128 |
|---|---|---|---|
| 0 | 1.008M | 0.685 | 0.935 |
| 10 | 1.088M | 0.551 | 0.780 |
| 20 | 1.168M | 0.461 | 0.675 |
| 30 | 1.248M | 0.402 | 0.602 |
| 40 | 1.328M | 0.361 | 0.550 |
| 49 | 1.400M | 0.334 | 0.515 |

Same slope, shifted up → not a search-budget problem. (efs/ef_search is a *no-op* recall knob in the
SA path; ef_final is the real L0 knob — base-recall calibration: ef_final 16→0.685, 64→0.885,
128→0.935, 256→0.960, 512→0.970.)

**2. Forcing SA rebuild does nothing → it's not sketch staleness.** ef_final=128 + a full
`rebuildAllSaClustersFromScratch` every 10 epochs gives the *same* curve (0.781/0.681/0.612/0.565/0.535).
Per-epoch instrumentation shows the sketch was never stale: `sketch_clusters` grows 353→527,
`cluster_blob_puts` ~1000/epoch, `sketch_route_hits` ~9900/epoch. The SA rebuild only refreshes the
**overlay**, not the underlying **L0 HNSW graph**.

**3. A fresh build on the identical 1.4M active set recovers fully → the structure was damaged, not the scale.**

| ef_final | fresh build @1.4M | streamed (churned) @1.4M |
|---|---|---|
| 64 | 0.892 | — |
| 128 | **0.947** | **0.535** |
| 256 | 0.974 | — |
| 512 | 0.986 | — |

Same vectors, same groundtruth, same ef_final: fresh 0.947 vs churned 0.535. The 0.41 gap is pure
incremental-churn damage.

**4. Attribution — deletes, not inserts.**

| epoch | R-INS (insert-only) | R-9010 (10% delete) |
|---|---|---|
| 0 | 0.953 | 0.935 |
| 10 | 0.951 | 0.780 |
| 20 | 0.950 | 0.675 |
| 30 | 0.948 | 0.602 |
| 40 | 0.946 | 0.550 |
| 49 | 0.945 | 0.515 |

Pure insert grows 1.0M→1.5M with recall **flat at ~0.95**. Deletes are the entire cause.

## Root cause (code)

`src/lsm_vec_index.cc::deleteNode` (≈ lines 2440–2530):
1. snapshots the embedding and installs a lazy ghost in the SA overlay (geometry only);
2. erases the node from `nodes_` and removes its L0 edges **both directions**
   (`db_->DeleteEdge(id, nb); db_->DeleteEdge(nb, id)`), evicts caches;
3. **stops there.** The deleted node's neighbors are left mutually disconnected.

So when X (with neighbors A,B,C) is deleted, the paths A↔B↔C that routed through X are severed and
never rebuilt. Over a stream of ~50k deletes the L0 graph fragments → greedy search from the SA entry
point can't reach the true neighbors within ef_final → recall decays. The SA overlay rebuild can't fix
this because the damage is in the base graph, and a from-scratch rebuild fixes it because it relays a
clean graph. All four experiments are consistent with exactly this and nothing else.

## Proposed fix

**DiskANN-style neighbor re-linking on delete** (`consolidate_deletes`). When removing X:
- gather X's L0 out-neighbors `N(X)`;
- for each in-neighbor A of X: drop edge A→X and add edges A→(N(X)\{A}), then prune A's neighbor list
  back to `m_max` using the **existing heuristic neighbor selection** (already used on insert);
- (optionally connect members of N(X) to each other under the same prune).

This preserves navigability with bounded degree and reuses code the method already has.

**Two styles** (open decision):
- **Eager** — do the re-link inside `deleteNode` on every delete. Simplest; small per-delete cost.
- **Periodic consolidate** — tombstone on delete, batch-repair every N ops (DiskANN cadence). Amortized
  cost; needs a batch pass + trigger threshold.

**Expected outcome:** recall under R-9010 should track the R-INS / fresh curve (~0.93–0.95) instead of
collapsing — i.e. the headline "stable under churn" becomes true, at the cost of some delete-time work.

**Not the fix (ruled out by evidence):** raising ef_final (slope unchanged), raising ef_construction
(inserts already fine), refreshing the SA sketch / lowering sa_rebuild_alpha (sketch never stale),
periodic full reindex (works but is the expensive sledgehammer; targeted re-link should suffice).

## Repro

```
# churn vs insert-only (the attribution):
driver/run_ours.sh work/sift_1m_r9010 ...            # R-9010  (ours_sift_1m_r9010_ef128_lazy.jsonl)
# work/sift_1m_rins trace + ef_final=128             # R-INS   (ours_sift_1m_rins.jsonl)
# fresh build on the final active set:
LSM-Vec-.../bench_streaming --trace work/sift_1m_active49 --calibrate "64,128,256,512"
```
Raw data: `results/raw/ours_sift_1m_{rins,r9010_ef128_lazy,r9010_ef128_rb10}.jsonl`,
`results/calibration_{sift_1m,active49}.txt`.
