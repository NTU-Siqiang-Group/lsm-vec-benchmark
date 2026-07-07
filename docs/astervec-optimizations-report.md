# AsterVec optimizations applicable to our method — analysis & adoption plan

**Date:** 2026-07-05
**Subject:** [NTU-Siqiang-Group/AsterVec](https://github.com/NTU-Siqiang-Group/AsterVec) is a fork/extension of
our method (`LSM-Vec-with-SA-HNSW`). Same architecture; classes renamed (`LSMVec`→`AsterVec`,
`LSMVecDB`→`AsterVecDB`). This report inventories AsterVec's optimizations, checks which we **already have**,
and recommends what to adopt to improve our benchmark metrics (DRAM footprint, build time, query latency,
insert throughput, recall).

Method: four parallel source-level investigations, each fetching AsterVec source (raw.githubusercontent.com)
and diffing against our local tree at `LSM-Vec-with-SA-HNSW/`.

---

## TL;DR — the surprising part

Two of the three features flagged as "new in AsterVec" are **already in our code**:

| Suggested item | Status in OUR code | What's actually missing |
|---|---|---|
| **In-memory build** | ✅ Algorithm present & byte-identical (`lsm_vec_bulk_build.cc`, `lsm_vec_rnn_descent.cc`) | It's **pinned serial** (`nthreads=1`) and **not wired into `bench_streaming`** — the harness still builds via per-row `Insert()` |
| **SQ8 quantization** | ✅ Already active on the disk + page-cache vector store (`disk_vector.h`, commit `24c664e`) | Nothing on disk store. Only the *resident float32 SA buffer* is un-quantized (and SQ8 doesn't help SIFT — see §3) |
| **Multi-thread** | ⚠️ MT **build** machinery exists but clamped off; **no** concurrent serving at all | Genuine gap (see §2) |

So the real work is: **(a) wire up + benchmark the bulk build**, **(b) decide the multi-thread story carefully
(fairness!)**, and **(c) pick up several genuinely-new small wins** the original list didn't mention — chiefly
two S-effort DRAM reducers (`LSMVEC_DIO_FROM_START`, `malloc_trim`).

### Adoption priority (by benefit / effort)

| Rank | Optimization | Metric moved | Effort | Fairness-safe for the 1M single-thread cell? |
|---|---|---|---|---|
| 1 | Wire **serial bulk build** into `buildBase()` | build time ↓ | **S** | ✅ yes (still single-thread) |
| 2 | **`LSMVEC_DIO_FROM_START`** (open in Direct I/O) | DRAM ↓ | **S** | ✅ yes |
| 3 | **`malloc_trim`** after build/rebuild | RSS ↓ | **S** | ✅ yes |
| 4 | **EdgeLRUCache drop-on-hit** | query+build ↑ | **S** | ✅ yes |
| 5 | **Flat POD `idToPage/idToSlot`** array layout | build+query ↑ | M | ✅ yes |
| 6 | **Multi-thread build** (un-pin `nthreads`) | build time ↓↓ | **S** | ⚠️ only for 10M/100M or a separately-labeled MT cell |
| 7 | **SQ8 the resident SA L0 buffer** | DRAM ↓ (float datasets only) | M | ✅ yes (but no effect on SIFT) |
| 8 | **Adaptive Direct-I/O escalation** (cgroup monitor) | DRAM ↓ (dynamic) | L | ✅ yes |
| — | Concurrent insert+search serving | throughput ↑ | **L** (multi-week) | ❌ breaks fairness; separate experiment only |

Skip: Bloom filter (low ROI), `delete_stats` (observability only), metadata filtering (irrelevant to our
benchmark). Already at parity: graph-aware section-key page layout.

---

## 1. In-memory bulk build — *we already have it; wire it up*

**AsterVec** (`src/astervec_bulk_build.cc`, `src/astervec_rnn_descent.cc`): a 4-phase one-shot builder
replacing per-row streaming `Insert()`:
- **Phase B — RNN-Descent L0 KNN graph:** params `S=16` random init neighbours, `T1=4`×`T2=15` iterations,
  pool cap `R=64`; RNG-pruning with cross-pollination; **squared-L2, ordering-only** (skips sqrt). Output CSR.
- **Phase C — level draw** (serial), pre-publish level≥1 nodes.
- **Phase E — MIRAGE-style upper-layer stitch** (`addPointUpperLayersOnly`): greedy-descend + `searchLayer` +
  `selectNeighbors` per upper layer (parallel, chunk 32).
- **Phase D — bulk L0 load** (`bulkLoadLayer0`): section-key placement, symmetrize, degree-cap to `m_max_`,
  batched `AddEdgeBatch` (64K-edge chunks).

**OURS:** the **entire algorithm is present and byte-identical** — `src/lsm_vec_bulk_build.cc`
(`bulkBuild`:360, `bulkLoadLayer0`:65, `addPointUpperLayersOnly`:283), `src/lsm_vec_rnn_descent.cc`
(RNG-prune core :174-194), `BulkBuildOptions` (`lsm_vec_db.h:47`, same S16/T1=4/T2=15/R64). It was inherited
from the common origin.

**The gap:**
1. **Pinned serial** — `lsm_vec_bulk_build.cc:372`: `const int nthreads = 1; // serial port` (ignores
   `opts.num_threads`); `lsm_vec_db.h:48`: `num_threads = 1`.
2. **Not wired into the harness** — `bench_common.h::buildBase()` (:424) builds via a per-row `db_->Insert()`
   loop (:460-465). It **never** calls `BulkBuild`. Bulk build is only reachable from `test/test.cc` behind
   `--bulk-build`, which `bench_streaming` doesn't set.

**Applicability:** Even single-threaded, `bulkBuild` should beat the current ~818 s streaming build — RNND's
~60 ordering-only squared-L2 passes are cheaper than 1M greedy descents, and it skips per-insert SA
maintenance. **Rough estimate: build drops toward ~300–500 s** (must be measured). ⚠️ **Important bound:**
bulk build produces the HNSW graph **only, no SA overlay** — we still pay one
`rebuildAllSaClustersFromScratch()` + resident-sketch pass afterward, which is a *large* share of the 818 s and
is **not** saved. Net win is bounded by the HNSW-construction fraction (`sa_graph_entry_s` in the
insert-profile), not the whole build.

**Effort: S** (serial). Steps: (1) add `cfg_.bulk_build` to `bench_common.h`; (2) in `buildBase()`, branch to
`db_->BulkBuild(...)` instead of the Insert loop, then run the existing SA-rebuild + resident-sketch block
(mandatory — bulk build emits no SA overlay); (3) guard the id-assignment (bulk build assigns ids 0..n-1
sequentially — fine for base load with default ids, breaks on non-identity `base.ids.u32`); (4) re-calibrate
`ef_final` on one bulk-built index and verify recall@10 stays in 0.93–0.96.

**Risks:** approximate RNND+symmetrize graph → possible small recall delta, needs re-calibration; `bulkBuild`
requires an empty DB and ids 0..n-1 (base load only, not the epoch-insert path); multi-threaded RNND is
non-deterministic across thread counts.

---

## 2. Multi-threading — *split into two very different axes*

**AsterVec** has a full concurrency layer (`src/astervec_index.cc`, `src/astervec_db.cc`):
- **Parallel build:** `--build-threads` in `test/concurrent_search_bench.cc` — either per-thread concurrent
  `Insert()` over dataset chunks, or `BulkBuild()` with `num_threads=bt` (the RNND + phase D/E pipeline runs MT).
- **Thread-safe insert:** per-real-id sharded `std::recursive_mutex` (`real_id_lock`), index-layer
  `std::shared_mutex nodes_mu_` + per-node shards (`node_shard`), a 7-step publish protocol, batched
  `linkNeighborsAsterDB` single `db_->Write` (cuts RocksDB WriteThread contention), atomic
  `entry_point_`/`max_layer_` CAS.
- **Thread-safe search:** layer-0 hot path avoids `nodes_mu_` entirely; upper layers take a brief
  `shared_lock` to snapshot-copy neighbour lists, then compute lock-free.
- **Lock-free `page_of`/`slot_of`:** adaptive `section_layer_` layout computes page/slot arithmetically from
  the id with no lock; `thread_local` scratch + RNG.

**OURS:** the streaming/query path has **zero concurrency primitives** (grep for
`shared_mutex|scoped_lock|node_shard|recursive_mutex` = 0 in `lsm_vec_index.cc`/`lsm_vec_db.cc`). We **do**
have MT **build** machinery (`lsm_vec_rnn_descent.cc` `parallel_for` + per-`Nhood` mutex) but it's clamped by
the same `nthreads=1` pin as §1.

**Applicability — two independent decisions:**
- **(a) Multi-thread BUILD** (un-pin `nthreads` for RNND / phase E): helps the parallelizable phases; the
  layer-0 Aster writes stay WriteThread-bound and won't scale. **Does NOT break fairness** — build time is
  reported separately and every baseline builds however it likes (SPFresh/DiskANN already build multi-thread
  at scale). **Recommended for 10M/100M** where the plan already anticipates MT build. **Effort: S.**
- **(b) Concurrent QUERY/INSERT serving** (port AsterVec's sharded-lock model): **breaks the current
  single-thread fairness comparison** — our headline 1M numbers are apples-to-apples *because* everything is
  1 thread (see `PROGRESS.md`, `serial-measurement-rule` memory). This is only valid as a **separate, later
  "concurrent" experiment** with all systems re-run multi-threaded. **Effort: L (multi-week).**

**Risks for a concurrency port:** the **`sa_tree` CF** update (our Aster patch) is on the insert critical path
and is *not* shard-guarded — concurrent inserts would race on SA-tree Put/Delete; AsterVec's `real_id_lock`
shard is what makes this safe. The **lazy-ghost delete** read-modify-write (read old vector → compute
slot-release set → put) must sit inside the per-real-id shard lock or slots leak/double-free — the single
riskiest spot.

---

## 3. SQ8 scalar quantization — *already on the disk store; SIFT doesn't benefit*

**AsterVec** (`include/disk_vector.h`, `PagedVectorStorage`): per-vector asymmetric min–max SQ8. Record =
`[min:f32][max:f32][uint8[dim]]`, `recordSize = dim + 2*sizeof(float)`. It is the **sole disk format AND the
page-cache format**; all reads `dequantize()` to float, distances computed in float, **no rerank** (relies on
SQ8 being near-lossless). ~3.76× vs float32 (512 B → 136 B for 128-d).

**OURS:** **already implements the identical SQ8** — our `sa-resident-sketch` branch carries commit `24c664e`
"Implement SQ8 quantization for page-based vector storage". `PagedVectorStorage` in `disk_vector.h`
(`recordSize_ = dim + 2*sizeof(float)`:778; dequantize on read :400/:594/:662/:935), and the benchmark uses it
(`bench_common.h:276` `vector_storage_type=1`). Disk + page cache are both SQ8 already, and it's already in our
measured RSS.

**The catch — SQ8 does not help our SIFT cell:**
- **SIFT is uint8 natively (128 B). Our SQ8 record is 136 B — 8 bytes *larger* per vector.** SQ8 wins only
  against float32. To *demonstrate* the memory win we need a **float32 dataset** (SPACEV/GIST/deep) where
  512 B → 136 B ≈ 3.76×.
- Our ~1.1 GB RSS @1M is **not** the vector file (1M×136 B ≈ 136 MB on disk, ~32 MB cached). It's dominated
  by (a) the **float32 resident SA L0 buffer** (`sa_l0_buffer_`, `unordered_map<id, vector<float>>`,
  `lsm_vec_index.h:553`, active at `--hops 4`) + SA `pivot_sketch`/ghost floats, and (b) Aster/RocksDB (block
  cache + memtables + LSM).

**The one remaining SQ8 opportunity for us:** quantize the **resident SA L0 buffer** (and pivot_sketch). Costs
`N×dim×4B` today; SQ8 → `N×136B` (~3.7× smaller) — **but only on float datasets**, and the buffer exists to
avoid disk reads so per-access dequant must stay cheap. **Effort: M.** First instrument
`saL0BufferNodeCount()` to size the actual saving before acting.

**Recall:** our path already runs SQ8-lossy with no rerank and holds recall@10 0.93–0.96 @1M SIFT, so SQ8 is
recall-safe here. On harder high-dim float sets a full-precision rerank tail may become necessary.

---

## 4. Other optimizations (genuinely new unless noted)

**4.1 `LSMVEC_DIO_FROM_START` — open directly in Direct I/O** *(commit f462474)* — **ADOPT FIRST (S).**
~8 lines: if env set, force `use_direct_reads=true` + `use_direct_io_for_flush_and_compaction=true` at open.
Skips buffered double-buffering of RocksDB SSTs in the OS page cache → **lowers RSS**, our headline metric.
For a benchmark this is *better* than the adaptive version (§4.5): runs are configured up front, so we open in
Direct I/O for a memory-constrained cell and get a clean DRAM-vs-recall Pareto point. Not in our code.

**4.2 `malloc_trim` / `trim_memory()` — release idle heap** *(commit e2cd77c)* — **ADOPT (S).**
`malloc_trim(0)` returns idle heap arenas to the OS. Called after the one-shot SA bulk rebuild (large scratch
alloc/free) and between epochs, it drops RSS that `mem_sampler.py` would otherwise attribute to us. Directly
improves the accuracy/fairness of our DRAM numbers. One call site + `#ifdef __GLIBC__`. Not in our code.

**4.3 Flat POD `idToPage_`/`idToSlotInPage_` arrays (storage-layout half of the lock-free path)**
*(commit a4515f4)* — **ADOPT (M).** Two parallel POD arrays indexed by id replace map/locked lookups; even
single-threaded, AsterVec reports **~11% faster build** from better cache locality on every batch read. The
atomic/lock-free publish half is only needed once multi-thread lands (coordinate with §2). Not lock-free in ours.

**4.4 EdgeLRUCache drop-on-hit** *(commit 03e6fba)* — **ADOPT the single-thread slice (S).**
AsterVec's `EdgeLRUCache` stops splicing on every `get()` (reads don't reorder the LRU list). Ours
(`lsm_vec_index.h:27-76`) **splices on every `get()`** (:35) — the exact cache-line-bouncing pattern they
removed. Dropping the splice cuts list-pointer writes on the hot `getEdgesCached` path → minor query+build
speedup even single-threaded (coarser LRU quality is the tradeoff). Full sharding (64 shards) is threading-domain → defer to §2.

**4.5 Adaptive Direct-I/O escalation under memory pressure** *(commit c6499f8)* — **ADOPT LATER (L).**
`CgroupMemoryMonitor` (new `include/cgroup_monitor.h`) watches cgroup-v2 `memory.current`/`memory.max` +
`workingset_refault_file`; at >90% + refault ≥1000 pg/s for 4 s it reopens the RocksGraph flipping Direct-I/O
and sheds SST OS-cache via `posix_fadvise(DONTNEED)`. Env: `LSMVEC_ADAPTIVE_DIO`, `LSMVEC_DIO_HIGH_FRACTION`,
`LSMVEC_DIO_REFAULT_MIN`, `LSMVEC_DIO_DEBOUNCE_S`. Lowers DRAM dynamically — the "adapts under pressure" story.
But §4.1 gets most of the benefit for S effort; do this only if we want the dynamic narrative. Not in our code.

**4.6 Bloom filter for the updated-ID map** (`src/bloom_filter.cc`) — **SKIP (low ROI).** Probabilistic
negative pre-filter over the sparse `updated_real_to_internal_` map. Helps only with heavy in-place-update
workloads (not our churn ratio); adds a bit array (doesn't lower DRAM). Reconsider if we add update-heavy cells.

**4.7 `delete_stats()`** *(commit e2cd77c)* — **SKIP for perf** (observability only). Could lift
`tombstone_ratio` into our stats for the churn-recall writeup.

**4.8 Graph-aware section-key page layout** — **NO ACTION (already at parity).** `src/lsm_vec_bulk_build.cc:82-141`,
`disk_vector.h:715-879`, `lsm_vec_index.cc:2199-2459`. AsterVec's only delta is a threading-safety detail.

**4.9 Metadata filtering** (`src/metadata*.cc`) — **IRRELEVANT** to our SIFT recall/latency/DRAM benchmark.

---

## 5. Recommended roadmap

**Phase A — free DRAM + build wins, fairness-safe, all S (do now):**
1. `LSMVEC_DIO_FROM_START` gate (§4.1) → DRAM ↓
2. `malloc_trim` after build/rebuild + between epochs (§4.2) → RSS ↓
3. EdgeLRUCache drop-on-hit (§4.4) → latency ↓
4. Wire serial `bulkBuild` into `buildBase()` behind a flag (§1), re-calibrate `ef_final`, verify recall →
   build time ↓

Each is independently measurable on the existing 1M single-thread cell without breaking fairness. Re-run the
`ours` cell after each and diff build time / RSS / recall.

**Phase B — medium (next):**
5. Flat POD id→(page,slot) arrays (§4.3) → build+query locality
6. SQ8 the resident SA L0 buffer (§3) — **only worth it once we add a float dataset** (SPACEV/GIST); no effect
   on SIFT

**Phase C — larger, scale-gated:**
7. Multi-thread **build** (§2a) — enable for the 10M/100M cells (the plan already assumes MT build there);
   keep the 1M headline cell single-thread
8. Adaptive Direct-I/O escalation (§4.5) if we want the dynamic-pressure story

**Deferred / separate experiment:**
9. Concurrent insert+search serving (§2b) — a distinct multi-week port; only as its own multi-threaded
   comparison with all baselines re-run MT. **Never** retrofit into the single-thread cells.

## 6. Methodology guardrails

- **Single-thread rule stays for the 1M headline cell.** Anything in Phase A/B keeps ours single-thread, so
  the apples-to-apples comparison holds. Multi-thread build (Phase C) is fine because build time is a separate,
  per-system-configured metric; concurrent serving is NOT and must be its own cell.
- **Re-calibrate `ef_final` after the bulk-build switch** — the RNND graph differs from streaming HNSW; verify
  recall@10 before trusting the faster build.
- **SQ8 needs a float dataset to *show* a memory win** — on SIFT (native uint8) it's neutral-to-slightly-worse;
  it's already in our numbers on the disk store.
