# AsterVec-adoption — detailed implementation plan

**Date:** 2026-07-05
**Companion to:** `docs/astervec-optimizations-report.md` (the inventory/analysis). This document is the
**implementation plan**: for every point it lists (1) exactly which code is touched (file:line, function,
nature of change) and (2) the expected impact (metric + rough magnitude + recall risk). Multi-thread is a
separate, comprehensive Part.

## Testing & build methodology (decided 2026-07-05)

This governs everything below.

- **Build phase → multi-thread, ALL methods uniformly 4 threads.** Rationale: single-thread build is
  intractable at 10M/100M. Because *every* system builds at 4 threads, build-time stays apples-to-apples, so
  MT build does **not** violate the fairness rule.
- **Query + Insert phase → single-thread, ALL methods.** These remain strictly serial (the existing
  fairness regime for latency/throughput/recall is unchanged).
- **Follow-up (a):** after MT build works, try **in-memory (bulk) build** to further cut build time.
- **This stage's build goal (b):** just get **multi-thread build** working and re-baseline. In-memory build
  is the next step, not this one.

Consequence: the 1M `ours` cell (and all baselines) will be **re-built at 4 threads** and re-measured; the
query/insert/recall numbers stay single-thread and should be unchanged by the build-side work (modulo the
bulk-build graph change, which is gated separately and re-calibrated).

---

# Part 1 — S-effort optimizations (independent, fairness-safe)

Each is a standalone change, measurable on the existing 1M single-thread-query cell, keeps ours single-thread
for query/insert.

## 1.1 `LSMVEC_DIO_FROM_START` — open RocksGraph in Direct I/O

**Goal:** stop the OS page cache from double-buffering RocksDB SST blocks → lower RSS (our headline metric).

**Code touched:**
- `src/lsm_vec_index.cc:160-176` — the block that configures `options_` (a `rocksdb::Options`) and then
  constructs `db_ = std::make_unique<rocksdb::RocksGraph>(options_, ...)` at :171. Inject, right before the
  ctor:
  ```cpp
  if (const char* e = std::getenv("LSMVEC_DIO_FROM_START"); e && std::atoi(e) != 0) {
      options_.use_direct_reads = true;
      options_.use_direct_io_for_flush_and_compaction = true;
      LOG(INFO) << "[dio] opening RocksGraph in Direct I/O (LSMVEC_DIO_FROM_START)";
  }
  ```
  Note the existing block already sets `options_.max_background_jobs`, `compression = kNoCompression`, and a
  32 MB block cache (`NewLRUCache(32*1024*1024)`) — the DIO flags sit alongside these.
- Optional: also gate the block cache size down under DIO (Direct I/O + small block cache is the
  low-DRAM operating point). Leave as a second knob `LSMVEC_BLOCK_CACHE_MB` if we want a Pareto sweep.

**Impact:** RSS ↓ (removes SST OS-cache duplication; magnitude depends on how much of the 1.1 GB is
Aster/RocksDB OS-cache vs heap — to be measured). Query latency may rise slightly (Direct I/O reads bypass
page cache) — this gives a **DRAM-vs-latency Pareto point** rather than a strict win. No recall impact.
**Effort: S** (~6 lines, env-gated, default off).

## 1.2 `malloc_trim` — return idle heap to the OS after big allocations

**Goal:** the one-shot SA rebuild allocates/frees large scratch; glibc keeps freed arenas → RSS reads high.
`malloc_trim(0)` hands them back, so `mem_sampler.py` records our true resident footprint.

**Code touched:**
- New tiny helper (guarded): in `src/lsm_vec_db.cc`, add `void LSMVecDB::TrimMemory()`:
  ```cpp
  void LSMVecDB::TrimMemory() {
  #ifdef __GLIBC__
      malloc_trim(0);   // #include <malloc.h>
  #endif
  }
  ```
  declare in `include/lsm_vec_db.h`.
- Call sites in `test/bench_common.h::buildBase()` — after the SA build block (:490, right after
  `buildSaL0HopBuffer(cfg_.hops)`), and in `applyEpoch()` after each epoch's writes (so between-epoch RSS
  samples are clean). Also call once after `rebuildAllSaClustersFromScratch()`.

**Impact:** RSS ↓ (especially the post-build sample and between-epoch samples — the flat part of the
`mem_time` curve). Purely a measurement-honesty/fairness win; no effect on recall/latency/throughput.
**Effort: S.**

## 1.3 `EdgeLRUCache` drop-on-hit — stop splicing the LRU list on every read

**Goal:** remove the per-`get()` list splice (a write to list pointers on every cache hit) on the hot
`getEdgesCached` path.

**Code touched:**
- `include/lsm_vec_index.h:31-33` — `EdgeLRUCache::get()`. Remove the splice:
  ```cpp
  const std::vector<node_id_t>* get(node_id_t id) {
      auto it = map_.find(id);
      if (it == map_.end()) { ++misses_; return nullptr; }
      ++hits_;
      // DROP-ON-HIT: no lru_list_.splice(...) here — reads no longer reorder the list.
      return &it->second->second;
  }
  ```
  `put()` still moves-to-front on insert/update, so recency is approximated by insertion order (coarser LRU,
  but eliminates read-side pointer churn). Keep `erase()`/eviction as-is.

**Impact:** query + build latency ↓ slightly (fewer pointer writes / better cache behaviour on hits). LRU
quality is marginally coarser → hit-rate could dip a hair; monitor `hits()/misses()`. No recall impact.
**Effort: S.** Low-risk; revert if hit-rate regresses materially.

## 1.4 In-memory (bulk) build wiring — *serial first, then MT (Part 3.3)*

Listed here because the serial wiring is S and shares the `buildBase` edit; **but per the methodology this is
the follow-up (a), after MT build (Part 3.2) is in**. Full detail in **Part 3.3**. Summary of the wiring:
- Add `bool bulk_build` to the `bench_common.h` Config; parse `--bulk-build` in `bench_streaming.cc`.
- In `buildBase()` replace the Insert loop (`test/bench_common.h:460-465`) with a branch:
  `db_->BulkBuild(Span<float>(base.data), base.n, BulkBuildOptions{...})`, then run the existing
  `rebuildAllSaClustersFromScratch()` + `buildSaL0HopBuffer()` block (mandatory — bulk build emits no SA
  overlay).
- Re-calibrate `ef_final`, verify recall@10 ∈ [0.93, 0.96].

---

# Part 2 — SQ8 for the resident SA L0 buffer

**Goal:** the resident top-H L0 embedding buffer `sa_l0_buffer_` is currently **float32** and is one of the
two dominant RAM consumers. Quantizing it to SQ8 cuts it ~3.76× (on float datasets). This is the one
remaining place SQ8 lowers **our** DRAM.

**Current state (verified):**
- `include/lsm_vec_index.h:553` — `std::unordered_map<node_id_t, std::vector<float>> sa_l0_buffer_;`
  (id → owned float32 embedding, top-H of each L0 cluster root).
- Footprint accounting: `saL0BufferEmbeddingBytes()` = `size() * dim * sizeof(float)` (:366-367).
- Write site: `addSaClusterTopHToBuffer()` (`src/lsm_vec_index.cc:5326`, `emplace(hid, scratch)` at :5340).
- Read sites: `:396-397` (set embedding), `:582-583` (`saL0BufferContains…`/access), `:594` (VA
  classification), persist path `src/lsm_vec_index.cc:6903-6904` (collect embeddings into sketch blob), and
  the routing distance path where the buffered float vector feeds `dist(query, child.id)`.
- **Reusable primitive:** `PagedVectorStorage::quantize()` / `dequantize()` are **static** methods
  (`include/disk_vector.h:380`, `:400`); record = `[min:f32][max:f32][uint8[dim]]`,
  `recordSize = dim + 2*sizeof(float)`.

**Code touched:**
1. **Extract the SQ8 codec** so it isn't tied to `PagedVectorStorage`. Move/alias `quantize`/`dequantize`
   into a small standalone header (e.g. `include/sq8.h`) or make them free functions; `PagedVectorStorage`
   keeps using them. (Avoids a layering dependency of the index on the storage class.)
2. **Change the buffer's value type** at `lsm_vec_index.h:553`:
   `std::unordered_map<node_id_t, std::vector<char>> sa_l0_buffer_;` where each value is a `recordSize`-byte
   SQ8 record (or a fixed `std::array`/packed struct). Update `saL0BufferEmbeddingBytes()` (:366-367) to
   `size() * (dim + 2*sizeof(float))`.
3. **Quantize on write** — in `addSaClusterTopHToBuffer` (:5340) and the setter at :396-397: run
   `sq8::quantize(embedding.data(), dim, record.data())` before storing.
4. **Dequantize on read** — introduce an accessor `bool getSaL0BufferEmbedding(id, float* out)` that finds
   the record and `sq8::dequantize(...)`. Route every consumer through it: the routing distance path, the
   persist path (:6903), and any VA classification. Use a `thread_local` scratch `float[dim]` to avoid
   per-call allocation (important: this buffer exists to be fast).
5. **Persist path** (`:6896-6904`): the sketch blob currently stores float embeddings — either store SQ8
   records directly (smaller on-disk sketch too) or dequantize on the way out. Pick storing SQ8 for
   consistency + smaller blobs; bump the sketch blob version.

**Impact:**
- **DRAM ↓**: `sa_l0_buffer_` shrinks ~3.76× **on float32 datasets**. First measure `saL0BufferNodeCount()`
  × dim to know the absolute MB (instrument before/after). On **SIFT this is ~neutral** (native uint8;
  128 B raw vs 136 B SQ8) — the win shows on SPACEV/GIST/deep. Worth building now so the float-dataset cells
  land with the smaller footprint.
- **Recall:** SQ8 is lossy; our disk path already runs SQ8-without-rerank at recall 0.93–0.96, so routing on
  SQ8-quantized buffer embeddings should be recall-safe. **Verify** recall@10 unchanged after the switch.
- **Latency:** per-access `dequantize` adds a few hundred flops on the routing hot path; the `thread_local`
  scratch keeps it allocation-free. Expect negligible-to-small latency cost. Measure.

**Effort: M** (codec extraction + value-type change + dequant at ~4 read sites + persist-format bump +
recall check).

---

# Part 3 — Multi-thread (comprehensive)

Multi-thread is a first-class goal, split into three scopes. **Scope A (MT build)** is this stage's target
(methodology item b). **Scope B (bulk build)** is the follow-up accelerator (item a). **Scope C (concurrent
serving)** is designed here in full but implemented/tested later as its own experiment — it is **not**
activated in the current query/insert-single-thread cells.

## 3.1 Scope map & invariants

| Scope | What runs multi-thread | In current cells? | Effort |
|---|---|---|---|
| A. MT streaming/graph **build** | base-index construction (all methods, 4 threads) | ✅ yes (build only) | S–M |
| B. In-memory **bulk** build MT | RNND + phase D/E parallel | follow-up (a) | S on top of A |
| C. Concurrent **query/insert serving** | insert + search under sharded locks | ❌ later, separate experiment | L |

**Hard invariant for A & B:** layer-0 Aster/RocksGraph edge writes stay **serialized** (RocksDB WriteThread
serializes them anyway; naive parallel writes add contention + races). Parallelism lives in the
distance-heavy phases (RNND neighbor updates, upper-layer stitch), not the LSM writes.

## 3.2 Scope A — multi-thread BUILD (this stage)

**Two build paths exist; we make both honor a thread count:**

### A1. Un-pin the bulk-build thread count
- `src/lsm_vec_bulk_build.cc:373` — replace `const int nthreads = 1; // serial port` with
  `const int nthreads = opts.num_threads > 0 ? opts.num_threads : 1;`. RNND already consumes it
  (`rnnd.num_threads = nthreads;` :384) and is genuinely thread-safe (per-`Nhood` `std::mutex` +
  `parallel_for` over an `atomic<int>` cursor in `src/lsm_vec_rnn_descent.cc`).
- `include/lsm_vec_db.h:48` — change `int num_threads = 1;` default (or leave default 1 and always pass an
  explicit value from the harness).
- Phase D/E (`bulkLoadLayer0`, `addPointUpperLayersOnly`) already contain `parallel_for` blocks gated by
  `nthreads`; they light up once the pin is removed. **Keep `AddEdgeBatch` serial** (it already notes
  "WriteThread serialises this anyway").

### A2. Parallelize the streaming build path (the one the harness uses today)
The current `buildBase()` uses a **per-row `db_->Insert()` loop** (`bench_common.h:460-465`), which is
serial. Two options:
- **(preferred) Switch the harness to bulk build** for the base-load (Scope B) — this is the cleanest MT
  build and is the follow-up we want anyway. Then "MT build" = "bulk build with `num_threads=4`".
- **(fallback, if we must keep streaming Insert for base)** partition base ids into 4 contiguous chunks and
  run one `Insert`-worker thread per chunk (AsterVec's `build_worker` pattern). This requires the concurrent
  insert path (Scope C) to be at least minimally thread-safe — which our current index is **not**. So this
  fallback effectively pulls in Scope C. **Recommendation: do MT build via bulk build (A1 + Scope B), not via
  parallel streaming Insert.**

### A3. Plumb the thread count through the harness + drivers
- `test/bench_streaming.cc` — parse `--build-threads N` (default 4), store in Config.
- `test/bench_common.h` — Config field `int build_threads = 4;`; pass into `BulkBuildOptions{.num_threads =
  cfg_.build_threads}` in `buildBase()`.
- `driver/run_ours.sh` — accept/forward `--build-threads 4`.
- **Baselines (uniform 4-thread build):**
  - SPFresh: `driver/run_spfresh.sh` already parameterizes `THREADS` → set `NumberOfThreads=4`,
    `AppendThreadNum=4` for the **build** portion (keep insert/query single-thread per methodology — verify
    SPFresh lets build and update thread counts differ; if not, note the coupling).
  - DiskANN-merge: `--build_threads 4` (already a flag; we ran it at 1 for the single-thread cell — bump to 4).
  - DiskANN / SPANN+: set their build thread flags to 4.

**Impact:** base build time ↓ substantially (RNND + upper-layer phases scale ~linearly to ~4×; layer-0 LSM
writes don't scale, so realistic end-to-end ~2–3× at 4 threads). Makes 10M/100M builds tractable. **No effect
on query/insert/recall metrics** (those stay single-thread). Fairness preserved (all methods 4-thread build).
**Effort: S** for A1+A3 (assuming Scope B provides the MT build path); the un-pin itself is one line.

## 3.3 Scope B — in-memory bulk build as the build accelerator (follow-up a)

**Wire `BulkBuild` into the harness** (this both accelerates build *and* provides the MT build path for
Scope A):
- Config: add `bool bulk_build` + `int build_threads` to `bench_common.h`; parse `--bulk-build` /
  `--build-threads` in `bench_streaming.cc`.
- `buildBase()` (`bench_common.h`): branch —
  ```cpp
  if (cfg_.bulk_build) {
      db_->BulkBuild(Span<float>(base.data(), base.n * dim_), base.n,
                     BulkBuildOptions{ .num_threads = cfg_.build_threads });
  } else {
      for (...) db_->Insert(...);   // existing loop :460-465
  }
  db_->flushVectorWrites();
  if (cfg_.use_sa) { db_->rebuildAllSaClustersFromScratch(); db_->buildSaL0HopBuffer(cfg_.hops); }
  ```
- **ID guard:** `BulkBuild` assigns ids 0..n-1 sequentially — assert `base_ids[i] == i` (identity) before
  taking this path; fall back to Insert loop otherwise.
- **Empty-DB guard:** already enforced (`lsm_vec_bulk_build.cc:367` throws if non-empty) — fine for base load.
- Re-calibrate `ef_final` on one bulk-built index; verify recall@10 ∈ [0.93, 0.96].

**Impact:** build time ↓ beyond streaming (RNND passes < 1M greedy descents; skips per-insert SA maintenance).
**Bounded by the SA rebuild** afterward, which bulk build does *not* save (a large share of the current 818 s
per `sa_cluster_maint_s` in the insert-profile). Small recall delta possible (approximate graph) → the
mandatory re-calibration. **Effort: S** on top of Scope A.

## 3.4 Scope C — concurrent query/insert serving (future, full design)

Not in the current cells (query/insert stay single-thread), but designed here so we can implement it as a
separate "concurrent" experiment. This is effectively porting AsterVec's concurrency layer.

**C1. Sharded locking.**
- Index layer: add `std::shared_mutex nodes_mu_` + a fixed array of per-node shard mutexes
  `node_shard(nodeId)`; multi-node acquisitions use `std::scoped_lock` in a fixed order to avoid deadlock
  (AsterVec pattern).
- DB layer: per-real-id sharded `std::recursive_mutex` via `real_id_lock(r)` (recursive to allow
  `Insert → UpdateInternal` re-entrancy). Two `Insert` on the same real id serialize; different ids proceed
  in parallel.

**C2. Insert publish protocol** (rework `insertNode`, `src/lsm_vec_index.cc:2103`):
early-publish an empty node under `unique_lock<shared_mutex>`; compute neighbors mutation-free; publish
vector bytes; batch all forward/reverse edges into **one** `db_->Write` (cuts RocksDB WriteThread contention —
AsterVec's `linkNeighborsAsterDB`); layer-0 shrink via `DeleteEdgeBatch`; lock-free entry-point promotion via
`max_layer_.compare_exchange_weak(...)` guarding `entry_point_` (make both `std::atomic`).

**C3. Lock-free search reads.** Layer-0 hot path avoids `nodes_mu_` (only RocksGraph edges + disk vectors);
upper layers take a brief `shared_lock` to **snapshot-copy** neighbor lists, then compute distances lock-free
on the copy (invariant: upper-layer node body immutable post-publish).

**C4. Lock-free `page_of`/`slot_of`.** Replace map/locked id→(page,slot) with two flat POD arrays
(`idToPage_`/`idToSlotInPage_`) + a published-capacity atomic `totalVectors_atomic_` (release on publish);
readers do `if (id < acquire_load) return idToPage_[id];` with no lock. (This is also the single-thread
locality win — see report §4.3; do the flat-array refactor first, add the atomic here.) Add `thread_local`
search scratch + RNG.

**C5. The two project-specific danger spots (must be shard-guarded):**
- **`sa_tree` CF updates** (our Aster patch) are on the insert critical path and are currently unguarded.
  Concurrent inserts would race on SA-tree Put/Delete → must sit inside the per-real-id shard lock.
- **Lazy-ghost delete** read-modify-write (read old vector → compute slot-release set → put) must be inside
  the per-real-id shard lock, or slots leak / double-free. This is the riskiest port point.

**Impact:** insert + query **throughput ↑** with cores (the axis where we currently lag SPFresh/SPANN+ due to
single-thread). Only meaningful as a separate all-systems-multi-threaded comparison. **Effort: L**
(multi-week; touches insert, search, storage, SA maintenance, delete).

---

# Part 4 — Testing & re-baseline plan

**Build (all methods, 4 threads):**
- ours: `--build-threads 4` (via Scope A/B). Baselines: SPFresh `NumberOfThreads=4`/`AppendThreadNum=4`
  (build), DiskANN(-merge) `--build_threads 4`, SPANN+ build threads 4.
- Re-run the 1M cell **build** for every method at 4 threads; record new build-time bars. (DiskANN-merge:
  reuse `--reuse_base_index` only if base params unchanged; otherwise rebuild at 4 threads.)

**Query + Insert (all methods, single thread):** unchanged regime; these metrics should match prior runs
(except any bulk-build recall delta, which is re-calibrated).

**Per-optimization measurement protocol (isolate each, serial runs per the serial-measurement rule):**
1. Baseline: current `ours` 1M numbers (build@4 once MT build lands).
2. +`LSMVEC_DIO_FROM_START`: Δ RSS, Δ latency (expect RSS↓, latency↑ slightly).
3. +`malloc_trim`: Δ RSS (post-build + between-epoch samples).
4. +drop-on-hit: Δ latency, Δ cache hit-rate.
5. +SA-buffer SQ8: Δ RSS (measure `saL0BufferNodeCount`×dim before/after; **run on a float dataset to see the
   win**), verify recall@10 unchanged.
6. +bulk build (Scope B): Δ build time, re-calibrate `ef_final`, verify recall.

Record each in `PROGRESS.md` + a `docs/FINDINGS_astervec_opts.md` with before/after tables. Regenerate the
6-system figures after the build re-baseline.

# Part 5 — Risks & guardrails

- **Fairness:** MT build is safe **only because all methods use 4 threads** — never mix thread counts within
  a metric. Query/insert stay single-thread. Concurrent serving (Scope C) is a *separate* experiment, never
  retrofitted into these cells.
- **Bulk-build recall:** approximate RNND graph → re-calibrate `ef_final`, gate adoption on recall ∈
  [0.93, 0.96].
- **SQ8 buffer:** verify recall unchanged; keep dequant allocation-free (`thread_local`); SIFT shows no DRAM
  win (native uint8) — demonstrate on a float dataset.
- **DIO:** default OFF (env-gated); it's a Pareto knob (RSS↓ / latency↑), not a free win.
- **Scope C danger spots:** `sa_tree` CF + lazy-ghost delete must be shard-guarded before any concurrent
  insert path is enabled.
- **Serial-measurement rule** still applies to every benchmark run (one system at a time).
