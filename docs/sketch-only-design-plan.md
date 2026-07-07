# Sketch-only SA-HNSW — drop the RocksDB SA-overlay, maintain only the resident sketch

**Date:** 2026-07-06
**Status:** Phase A + B IMPLEMENTED & VALIDATED (`--sa-sketch-only`, gated flag). Commits aa9d081
(buildSaTreeTopH + tests), 1382c9d (sketch-only build/insert/query), 73e2e18 (bounding fixes).
**Validated result — 1M SIFT (bulk @4t, ef_final=64):** overlay `ours` recall 0.926 / ins 687/s / RSS
1025MB → **sketch-only recall 0.927 / ins 865/s (+26%) / RSS 730MB (−295MB, −29%)**; no-sa floor 641MB.
Recall unchanged, `sa_tree` CF eliminated. 200K A/B: recall identical, ins +67%, RSS −60MB. Phase C
(drop query fallback / trim persist) and Phase D (optional rebalance) remain optional follow-ups.
**Motivation:** at 1M SIFT, `ours` uses ~1025 MB workload RSS vs `lsm-vec-no-sa` 641 MB — a ~380 MB gap.
The clean per-component diff (see `chat_history.md` / diagnostic commit `759655a`) showed the gap is **not**
the sketch: the resident SQ8 sketch is only ~25 MB. The gap is the cost of **maintaining the full SA-tree
overlay in the RocksDB `sa_tree` column family** — 66 MB of memtables + 174 MB of SST churning through
compaction + ~230 MB of glibc heap high-water from the SA maintenance path's **139 reads/insert** (vs 7 for
no-sa). Insert throughput suffers for the same reason (687/s vs no-sa 897/s).

This plan removes that overlay entirely and makes the **resident top-H sketch the sole, incrementally
maintained SA structure**, delegating fine retrieval to the HNSW L0 graph (which we already maintain).

---

## 1. Why this is sound (not just an optimization hack)

The query path already routes on the resident sketch only:
- `knnSearchSA` (`src/lsm_vec_index.cc` ~2860) takes the **resident-sketch fast path**: if
  `residentSketch(root)` (`lsm_vec_index.h:571`) returns a sketch, it routes on the in-RAM pruned tree and
  **skips the RocksDB read entirely**. Routing descends at most `sa_route_max_steps_ = hops = 4` levels
  (`saRouteBeam`, `src/sa_tree.cc:253`), then hands off to a small-budget HNSW `searchLayer` at L0.
- The **full SA-tree in the `sa_tree` CF is only used for two things**: (a) as the source to *build/rebuild*
  the sketch (`buildTopHPrunedTree`, `src/lsm_vec_index.cc:5359`), and (b) as a *fallback* when the sketch is
  missing for a cluster.

So the full tree's deeper levels (nodes beyond hop H, ~88% of each ~2800-member cluster) are **never touched
by routing** — they are redundant with the HNSW L0 graph, which already provides fine local search. We are
paying full-tree write/read/compaction cost to maintain data the query never reads.

**Sketch-only** = keep exactly the part routing uses (top-H structure + SQ8 embeddings, in RAM), maintain it
incrementally, and let HNSW L0 do what the deep tree was nominally for.

---

## 2. Current vs proposed architecture

| | Current (overlay + derived sketch) | Proposed (sketch-only) |
|---|---|---|
| Full per-cluster SA-tree | built + persisted in `sa_tree` CF; rebuilt on threshold | **removed** |
| Membership (member→root) | persisted in `sa_tree` CF (`putSaTreeMemberToRocks`) | **removed** (derived from HNSW L1 at insert time; not persisted) |
| Resident sketch (`sa_l0_sketch_`) | **derived** from full tree via `buildTopHPrunedTree` | **primary structure**, maintained incrementally |
| Resident SQ8 buffer (`sa_l0_buffer_`) | populated during rebuild | maintained alongside the sketch |
| Insert SA cost | pending → threshold → full-tree rebuild in RocksDB (139 reads/insert) | **incremental sketch insert, 0 RocksDB `sa_tree` writes** |
| Query routing | sketch fast-path; full-tree fallback | sketch only; **fallback = HNSW L0 entry** (no tree read) |
| Persist/restore | full-tree blobs + membership + sketch blobs | **sketch blobs only** (optional, for reopen) |

---

## 3. Data structures

**Keep (already resident):**
- `sa_l0_sketch_ : unordered_map<node_id_t, SaTree>` (`lsm_vec_index.h:556`) — per-cluster-root pruned top-H
  tree: `SaTreeNode{ id, children[], radius, parent_dist }` (drop `pairwise_child_dists`/`pivot_sketch` as
  today — `buildTopHPrunedTree` already omits them).
- `sa_l0_buffer_ : unordered_map<node_id_t, vector<uint8_t>>` (`lsm_vec_index.h:555`) — SQ8 embeddings for
  sketch nodes (already SQ8, commit `c96e598`).

**Add (small, RAM):**
- `sketch_depth_[root]` or per-node depth cached in the sketch (needed to enforce the H-hop bound on insert).
  Can be recomputed by BFS but caching depth avoids repeated walks.
- Optional per-cluster `sketch_dirty_count_[root]` — inserts-since-last-rebalance, to trigger periodic
  rebalance (§5.6).

**Remove (RocksDB `sa_tree` CF writers/readers):**
- `putSaTreeClusterToRocks`, `putSaTreeMemberToRocks`, `getSaTreeClusterFromRocks`,
  `getSaTreeMemberClusterRootFromRocks`, `rebuildSaTreeOnSaTreeRocks`, the `sa_l0_pending_` /
  `sa_l0_treecount_` accumulators, and the membership CF traffic. (The CF itself can stay for the
  **sketch** persist blobs, or be dropped entirely if we make sketch persistence a separate small store.)

---

## 4. The core new algorithm — incremental top-H sketch insert

On inserting L0 node `x` (embedding `vx`) whose cluster root is `r` (nearest L1 node, computed during the
normal HNSW insert descent — no persisted membership needed):

```
insertIntoSketch(r, x, vx):
  S = sa_l0_sketch_[r]                      # the resident top-H tree; if absent, seed it (§5.1)
  # 1. descend S from root by nearest child, tracking depth
  cur = S.root; depth = 0
  loop:
    if cur has no children or depth == H:   # reached a leaf or the H-hop frontier
        break
    c* = argmin_{c in cur.children} dist(vx, embedding(c.id))     # embeddings from sa_l0_buffer_ (SQ8) 
    if dist(vx, embedding(c*.id)) >= dist(vx, embedding(cur.id)): # x is closer to cur than any child
        break                                                     # x attaches under cur
    cur = c*; depth += 1
  # 2. placement
  if depth < H:
      if cur.children.size() < max_children:
          add x as a child leaf of cur (radius 0); store SQ8(vx) in sa_l0_buffer_[x]
      else:
          split cur's children (§5.3) then attach x
      updateRadiiUpward(cur, dist(vx, embedding(ancestor.id)))    # §5.2
  else:
      # depth == H: x belongs deeper than the sketch materializes → DO NOT add to sketch.
      # x is still inserted into the HNSW L0 graph (unchanged), so it stays retrievable.
      updateRadiiUpward(cur, dist(vx, embedding(cur.id)))         # extend frontier radius to cover x
```

Cost: O(H · max_children) distance evals per insert (H=4, max_children=4 → ≤16 dist evals), all on
**resident SQ8 embeddings** — no disk, no RocksDB. This replaces the 139 reads/insert.

### 5.1 Build / seed
- `bulkBuild` already builds the HNSW graph + clusters. Instead of `rebuildAllSaClustersFromScratch` +
  `buildSaL0HopBuffer` (which build full trees then prune), build the **sketch directly**: for each L1 root,
  gather its L0 members' nearest-neighbours, run the existing `buildSaTree` **but cap the recursion at depth
  H** (a `buildSaTreeTopH` variant of `src/sa_tree.cc`), producing the sketch straight away. No full tree, no
  RocksDB write.

### 5.2 Radius maintenance
- On every insert that touches a node's subtree, `radius = max(radius, dist(node, x))` walking up to the
  root. Monotonic (never shrinks on delete) → **conservative over-estimate** → pruning stays *correct*
  (never prunes a region that might contain the NN), just slightly less selective over time. §5.6 rebalance
  tightens it.

### 5.3 Fanout split (keeping it a valid ≤max_children tree within H)
- When a node exceeds `max_children`, split its children into two groups by the existing SA-tree partition
  rule (nearest-of-two-pivots, as `buildSaTree` does) and insert an intermediate node. Bounded local
  operation. If splitting would push depth beyond H at the frontier, instead **stop materializing** (treat as
  the `depth==H` case) — the HNSW L0 graph covers the overflow.

### 5.4 Delete
- Unchanged from today's lazy-ghost: if the deleted id is in the sketch, mark it a ghost (negative
  `sa_node_id_t`), keep geometry for routing, filter from results. If it's deeper than H, it was never in the
  sketch → no-op. Reuses the existing ghost machinery.

### 5.5 Query
- `knnSearchSA`: route on `sa_l0_sketch_[r]` (the fast path we already have). **Remove the full-tree
  fallback**: on a sketch miss (e.g. ghost root, or a cluster with no sketch yet), fall back to the **HNSW L0
  entry point** (the cluster root's L0 neighbourhood) instead of reading a RocksDB tree. This deletes the
  `getSaTreeClusterFromRocks` read from the query path.

### 5.6 Periodic rebalance (optional, off the hot path)
- Because inserts accumulate approximation (monotonic radii, unsplit frontier), optionally rebuild a
  cluster's sketch from scratch every N inserts to that cluster (analogous to today's threshold rebuild, but
  **in RAM from the sketch's own members + a bounded vector read**, not a RocksDB full-tree round-trip).
  Members are re-derived from the HNSW L1→L0 assignment. Cheap and rare. Can be disabled to measure the
  approximation's standalone quality.

---

## 6. Code changes (file:line)

**Add:**
- `src/sa_tree.cc`: `buildSaTreeTopH(...)` — `buildSaTree` variant capped at depth H (for build/rebalance).
- `src/lsm_vec_index.cc`: `insertIntoSketch(root, id, vec)` (§4), `updateSketchRadiiUpward(...)`,
  `splitSketchNode(...)`, `seedSketchForCluster(root)`.
- `include/lsm_vec_index.h`: declarations + optional `sketch_depth_` cache.

**Modify:**
- `insertNode` L0 SA-maintenance block (`src/lsm_vec_index.cc` ~2339): replace the
  `putSaTreeMemberToRocks` + `sa_l0_pending_` accumulation + threshold `rebuildSaTree` with a single
  `insertIntoSketch(root, nodeId, vec)` call. Gate on a new `sa_sketch_only_` flag.
- `buildSaL0HopBuffer` / `refreshSaL0BufferForCluster` (`5405`/`5427`): in sketch-only mode, build the sketch
  directly (§5.1) instead of deriving from a full tree.
- `knnSearchSA` fallback (~2960): sketch-miss → HNSW L0 entry, not `getSaTreeClusterFromRocks` (§5.5).
- `deleteNode`: unchanged (ghost path already sketch-aware); just skip the RocksDB membership erase.
- `persistSaSketchToRocks` / `restoreSaSketchFromRocks` (`6890`/`6949`): keep (they already persist the
  *sketch* blobs); stop persisting full-tree cluster blobs + membership.

**Remove / bypass (in sketch-only mode):**
- `rebuildSaTreeOnSaTreeRocks`, `putSaTreeClusterToRocks`, `putSaTreeMemberToRocks`,
  `getSaTreeClusterFromRocks`, `getSaTreeMemberClusterRootFromRocks`, `sa_l0_pending_`, `sa_l0_treecount_`.
  Keep the code (guarded) for the legacy overlay mode / A-B comparison.

**Config (`include/config.h`, `bestConfigOptions`):**
- `bool sa_sketch_only = false;` — new mode flag. Wire `--sa-sketch-only` into `bench_streaming.cc`.
- `int sa_rebalance_every = 0;` — 0 = never (pure incremental); N>0 = periodic per-cluster rebalance.

---

## 7. Expected impact

- **RSS:** removes the `sa_tree` CF write path → drops the 66 MB memtables + 174 MB SST churn + ~230 MB heap
  high-water. Projected `ours` workload RSS: ~1025 MB → **≈ no-sa (641 MB) + sketch (25 MB) ≈ 670 MB** — the
  ~380 MB gap largely closed.
- **Insert throughput:** removes 139→~7 reads/insert; adds ≤16 in-RAM SQ8 dist evals. Projected: 687/s →
  **≈ no-sa (~900/s)**.
- **Build:** faster (no full-tree construction + RocksDB writes; direct top-H build).
- **Recall / latency:** the open question — routing now uses an *incrementally* maintained sketch instead of
  one derived from periodic optimal full-tree rebuilds. Expected ≈ neutral (fine retrieval still by HNSW L0),
  but **must be validated** (§8).

---

## 8. Risks & validation

| Risk | Mitigation / test |
|---|---|
| Incremental sketch routes worse than rebuild-derived sketch → recall drop | A/B on the 1M R-9010 churn trace: sketch-only vs current overlay, same ef_final. Gate adoption on recall staying in band (≥ current end-recall 0.926). |
| Monotonic radii over-inflate → weaker pruning → higher latency | Measure latency vs current; enable `sa_rebalance_every` if it drifts. |
| Frontier (depth==H) overflow relies entirely on HNSW L0 | Already the case at query time (routing stops at H). Verify L0 `ef_final` budget suffices. |
| Sketch-miss fallback quality (HNSW L0 entry vs tree) | Measure recall on clusters with ghost roots / cold sketches. |
| Loss of persisted "source of truth" for reopen | Persist sketch blobs (already implemented); rebalance can rebuild from HNSW L1 membership if a sketch is lost. |

**Validation protocol:** implement behind `--sa-sketch-only`, run the 200K dev-loop first
(`driver/dev200k_test.sh` — build/RSS/recall/latency), confirm RSS drops toward no-sa + sketch and recall
holds; then the 1M cell. Compare against the current overlay `ours` numbers head-to-head.

---

## 9. Phased rollout

1. **Phase A — build-side:** `buildSaTreeTopH` + direct sketch build in `buildSaL0HopBuffer` (sketch-only
   build, still overlay-maintained on insert). Verify recall unchanged, build faster. Low risk.
2. **Phase B — incremental insert:** `insertIntoSketch` + radii + split; bypass the RocksDB overlay on
   insert behind `--sa-sketch-only`. This is where the RSS + insert wins land. Validate on 200K then 1M.
3. **Phase C — query fallback + persist trim:** remove full-tree fallback / membership; sketch-only persist.
4. **Phase D — optional rebalance** (`sa_rebalance_every`) if quality drifts under long churn.

Phase B is the payoff; Phases A/C/D are supporting. Each phase is independently measurable on the 200K
dev-loop and committed separately (per the AsterVec-adoption cadence).
