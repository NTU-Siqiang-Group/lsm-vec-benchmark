# Plan: lazy-ghost deletes — keep deleted nodes in the L0 graph, clean up opportunistically

**Status:** proposed (no code changed) · **Motivates:** `docs/FINDINGS_churn_recall.md` (recall collapses
0.94→0.52 under 10% deletes; root cause = `deleteNode` removes L0 edges without re-linking → graph
fragments) · **Author idea:** keep deletes fully lazy; never do eager rewiring; reclaim ghosts only as a
side effect of insert-time pruning.

## Core idea (the user's design)

Instead of DiskANN-style eager neighbor re-linking (which the user rightly noted is awkward — a node
with 10 neighbors shouldn't spawn 45 edges), do the opposite — **do nothing structural on delete**:

1. **Delete = ghostify, don't unlink.** On delete, mark the id as a **ghost** and **leave the node and
   all its L0 edges in the graph**. The ghost stays a real geometric waypoint, so the paths that routed
   through it are preserved — **no hole is punched, no fragmentation.** The ghost is filtered out of
   query *results* (never returned in the k-NN) but is still **traversed** during search to reach the
   live nodes behind it.
2. **No eager rewiring, no periodic full consolidation.** Cleanup is purely opportunistic: HNSW insert
   already prunes a node's neighbor list when its degree exceeds `m_max` (the existing "exceed M →
   reconstruct" path). Piggyback on that — when that prune fires, **prefer evicting ghost neighbors**.
   So ghosts get reclaimed gradually, but *only* in regions that are still seeing inserts. A node is
   never proactively reconstructed just because a neighbor became a ghost.

This is the natural extension of the method's existing **lazy-ghost philosophy in the SA overlay**
(`docs/sa-hnsw-deletion-strategy.md`) down to the **HNSW L0 graph**, which today is *not* lazy (it hard-
deletes edges — the bug).

## Why it fixes the recall collapse

The collapse is caused by **edge removal fragmenting navigability** (proven: R-INS with no deletes is
flat ~0.95; a fresh rebuild on the churned set recovers 0.947; forcing SA-overlay rebuild does nothing
because the damage is in the base graph). If we **stop removing edges**, the graph never fragments, so
greedy L0 search keeps reaching the true neighbors. Ghosts cost a little search budget and memory, but
navigability — the thing that actually drives recall — is preserved. Expected: R-9010 recall tracks the
R-INS / fresh curve (~0.93–0.95) instead of collapsing to 0.52.

## Cost trade-off (vs eager re-linking)

| | eager re-link (consolidate) | **lazy ghost (this plan)** |
|---|---|---|
| work per delete | O(deg²) distance evals (prune each in-neighbor) | ~O(1) (flip a flag) |
| edges touched | bounded, but real churn each delete | none |
| memory | shrinks on delete | **grows** until ghosts reclaimed |
| search overhead | none after consolidate | traverses ghosts (budget + latency) |
| recall under churn | restored | restored (to validate) |

The lazy approach trades **memory + a little search overhead** for **near-zero delete cost** and far
simpler code. Good fit for the net-growing workloads in the runbook (R-9010 = 90% insert), where
inserts continuously drive ghost cleanup in hot regions.

## Implementation phases (staged so we validate the cheap core first)

### Phase 1 — ghostify on delete (the minimal change that should fix recall)
In `src/lsm_vec_index.cc::deleteNode`:
- **Do NOT** remove the node's L0 edges (skip the `GetAllEdges` + `DeleteEdge(id,nb)/DeleteEdge(nb,id)`
  loop) and **do NOT** erase it from neighbors' adjacency lists.
- **Do NOT** `vector_storage_->deleteVector(id)` — the ghost's embedding must remain readable so search
  can compute distances while traversing it. (Keep the vector; reuse the SA snapshot path if cheaper.)
- **Keep** `deleted_ids_.insert(id)` (already there) so results are filtered.
- Keep the existing SA-overlay lazy-ghost maintenance (`maintainSaClustersAfterDelete`) — it already
  treats the id as a geometry-only ghost; this just makes L0 consistent with it.
- Entry-point case: if the deleted id is the global entry point, pick a live replacement but **leave the
  ghost in the graph** (don't unlink it).

Then verify the **result-filtering** invariant holds on every search path: `searchLayer` /
`knnSearchSA` may **traverse** ghosts (use them as waypoints) but must **never return** a ghost id in
the final top-k. Today `deleted_ids_` is filtered at the k-NN boundary (`src/lsm_vec_index.cc` ~3051)
and SA routing already rejects ghosts as entry points (`isValidSaRouteTarget`) — confirm both still hold
when ghosts retain edges. Add/extend a unit test: delete an id, confirm it never appears in results but
its former neighbors are still mutually reachable.

**Validation gate:** re-run R-9010 SIFT 1M at ef_final=128 → recall should track ~0.93 (vs 0.515 today).
Also record RSS (ghost retention) and query latency (ghost traversal). If recall recovers, the core
hypothesis is confirmed before we build any cleanup.

### Phase 2 — opportunistic ghost reclamation via insert-time prune
When an insert pushes a node `N`'s L0 degree over `m_max` and the existing heuristic prune runs, make it
**ghost-aware**: among `N`'s candidates, **evict ghosts before live nodes** (e.g. treat a ghost as
strictly lower priority, or only keep a ghost if no live neighbor provides comparable connectivity).
When a ghost ends up with **no remaining in-edges** (no live node points to it), it can be **fully
reclaimed**: free its vector slot, drop it from `deleted_ids_` / storage. This bounds memory growth in
hot regions without any periodic pass.
- Needs a cheap way to know a ghost has no live in-edges (reverse-edge check or a small refcount).
- Open knob: how aggressively to prefer ghost eviction (too aggressive re-introduces holes; too timid
  lets ghosts linger). Tune empirically against the Phase-1 recall/RSS curve.

### Phase 3 — optional cold-region sweep / memory cap (only if Phase 2 is insufficient)
A cheap background sweep that reclaims ghosts in regions with no recent inserts, or a hard cap on ghost
fraction that triggers a localized cleanup. Likely unnecessary for net-growing workloads; revisit if
RSS grows unacceptably at 10M/100M or under delete-heavy ratios.

## Risks / open questions

- **Memory growth:** ghosts persist until reclaimed; under delete-heavy or cold-region churn, unbounded
  until Phase 2/3. Quantify RSS-vs-epoch in Phase 1.
- **Search overhead:** traversing ghosts spends distance evals and ef_final budget. If ghosts cluster
  densely, latency/recall could suffer — watch the latency curve and query-IO in Phase 1.
- **Degree budget:** ghosts count toward neighbors' `m_max`; a heavily-churned node could spend its
  budget on ghosts. Phase 2's ghost-first eviction is the mitigation.
- **Upper layers:** the bulk of nodes/deletes are at L0; if a deleted node also lives in upper layers,
  decide whether to ghostify there too (few nodes, but entry-point/navigation matters). Default: same
  lazy treatment.
- **Vector retention:** keeping ghost vectors costs disk/slots; coordinate with the SA lazy-ghost slot
  allocator so we don't double-store.

## Files / functions to touch

- `src/lsm_vec_index.cc::deleteNode` — stop unlinking; keep vector; keep ghost in graph (Phase 1).
- `src/lsm_vec_index.cc` search/result path (`searchLayer`/`knnSearchSA`, ~3051 filter) — confirm ghosts
  are traversed but never returned (Phase 1).
- heuristic neighbor selection / prune (used on insert) — ghost-aware eviction + reclamation (Phase 2).
- `deleted_ids_` bookkeeping + vector-slot reclamation (Phase 2).
- gtest: delete-then-reachable + never-returned (Phase 1); ghost reclamation (Phase 2).

## Validation matrix

Re-run on `work/sift_1m_r9010` at ef_final=128, compare to the recorded baselines:
- recall-vs-epoch should move from the 0.94→0.52 collapse to a flat ~0.93–0.95 (≈ R-INS / fresh).
- RSS-vs-epoch and latency-vs-epoch: quantify the lazy-ghost overhead.
- Then the R-9010 "recall stable under churn" headline holds, and we can resume the baseline comparison
  showing the fixed method.
