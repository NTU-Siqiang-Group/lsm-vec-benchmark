# Benchmark Plan — LSM-Vec (SA-sketch) vs. SPFresh / SPANN+ / DiskANN

> **For the server agent:** this is a runbook *and* a plan. Phases 0–2 are setup, 3 is the
> harness you build in our repo (TDD), 4 is workload generation, 5 is the run matrix, 6 is
> collection/plotting. Execute top-to-bottom. **Decision gates** are marked **⟶ ALIGN** — stop
> and confirm with the human at those, don't guess. Record progress in a ledger file.

**Goal:** On a public workload, compare our method (branch `sa-resident-sketch`) against the three
SPFresh-paper baselines — **SPFresh**, **SPANN+**, **DiskANN (streaming)** — on **recall@10,
query latency (mean + P99.9), insert/delete throughput, and memory/disk footprint**, under two
realistic update ratios, staged 1M → 10M → 100M, on SIFT and SPACEV.

**Our method's pitch to validate:** in-RAM routing (resident top-H SA sketch) + LSM-backed
vectors gives **low query I/O, fast in-RAM queries, and cheap build/insert** while keeping
**recall stable under churn** — at a smaller DRAM footprint than graph baselines.

---

## 0. Design summary (read once)

**Systems under test (SUT):**
| # | system | repo | nature | role |
|---|---|---|---|---|
| 1 | **Ours** — LSM-Vec SA-sketch | this repo, branch `sa-resident-sketch` | HNSW upper layers in RAM + resident SA sketch; L0 edges in RocksDB; vectors paged on disk | the method |
| 2 | **SPFresh** | `github.com/SPFresh/SPFresh` | SPANN + LIRE in-place update, SPDK NVMe | paper's system |
| 3 | **SPANN+** | same repo, LIRE disabled in `.ini` | append-only SPANN, no reassignment | paper's strawman |
| 4a | **DiskANN-IP** (in-place) | `github.com/microsoft/DiskANN` `cpp_main` (`test_streaming_scenario`) | graph index, in-place insert/delete | paper's graph baseline (modern) |
| 4b | **DiskANN-merge** (FreshDiskANN) | **same repo**, hand-assembled merge flow — ⚠️ no turnkey binary (§2.2) | graph index, streamingMerge | paper's exact graph baseline |

*Repo links all verified live 2026-06-29: `github.com/SPFresh/SPFresh` (SPFresh + SPANN+, one repo)
and `github.com/microsoft/DiskANN` `cpp_main` (both DiskANN variants, one repo). The only gap is
DiskANN-merge having no turnkey binary — see §2.2.*

**Datasets:** SIFT (128-d, uint8, 10k queries) and SPACEV (100-d, int8, 29,316 queries), L2.
**Scales (staged):** 1M → 10M → 100M. Each scale uses a disjoint **base** + **update pool** split.
**Workload ratios (ours, NOT the paper's 50/50):**
- **R-INS** — pure insert (index grows from base to full).
- **R-9010** — 90% insert / 10% delete by operation count (net-growing, realistic churn).
Deletes target random live ids. (Per the user: "update" = delete+insert, so testing delete *is*
testing update; no separate update op.)
**Primary metrics (all as a time-series over the update stream):** recall@10, query latency
(mean, **P50, P99** — not P99.9), query QPS, insert throughput (ops/s), delete throughput (ops/s),
**real-time process RSS (DRAM) sampled at a fixed cadence over the WHOLE run → a continuous
memory-vs-time curve** (SPFresh Fig-5 style, not just a peak), on-disk index size. Peak RSS is kept
as a derived scalar for the summary table. Plus a final summary table per (system, dataset, scale,
ratio).

**Methodology — report recall (paper-style), with our recall calibrated to be competitive.**
Following the paper, we do NOT force all systems onto one recall band. Each system runs at a
sensible fixed config and we **report recall@10 directly**, alongside latency/throughput/memory.
The constraint we hold ourselves to: **our recall@10 must be ≈ or better than every baseline in
most (dataset, scale, ratio) cells.** A pre-run **calibration** step (§7.1) tunes OUR `efs`/
`ef-final` up until our start-of-stream recall ≥ the baselines', then locks it for the run. If we
cannot reach baseline recall within reasonable latency, that is a finding to surface, not hide. We
also report a recall-vs-latency Pareto at 2 checkpoints for context. Baselines use their
documented/default search budgets (DiskANN search `L`; SPANN/SPFresh `SearchPostingPageLimit`/
`MaxCheck`); record each system's exact config in its result file.

---

## 1. Server profile & the SPDK decision  **[RESOLVED — file-I/O fallback (B)]**

**Confirmed server (2026-06-28):** Intel i9-13900K, 32 threads (24 cores), **125 GiB RAM**,
Ubuntu 22.04.5 / kernel 6.8. Storage: ONE NVMe `nvme0n1` (WD SN810 2 TB) that is the **system +
Windows dual-boot disk** (EFI + NTFS partitions + ext4 `/`, **323 GB free**); plus two **SATA HDDs**
(WD 1 TB, spinning — unusable for an SSD benchmark). Not root (uid 1002), no passwordless sudo,
**Secure Boot ENABLED**, IOMMU off in cmdline, bare metal.

**Decision: SPDK is NOT viable here → SPFresh/SPANN+ run in non-SPDK file-I/O mode.** Reasons, all
blocking: (1) the only NVMe holds the live root + Windows partitions and cannot be dedicated/bound
away from the kernel; (2) Secure Boot is enabled (SPFresh requires it OFF for SPDK); (3) IOMMU off
+ no passwordless root → cannot bind NVMe to VFIO/uio. **Consequence:** SPFresh's latency is its
file-I/O number, **NOT** the paper's SPDK number — **footnote this on every SPFresh result.** All
four systems share the one ext4 NVMe at `/`; the 323 GB free is the disk budget (fine for 1M/10M;
see §8 — watch it at 100M, where 4 systems × 2 datasets of indices may approach it).

**Scale feasibility on this box:** 125 GiB RAM ≈ the paper's 128 GB. 100M fits in RAM for the
in-memory parts (DiskANN dynamic index ≈ 38 GB for SIFT100M; our resident sketch multi-GB; SPFresh
is low-DRAM by design). **Disk free (323 GB) is the tighter constraint at 100M**, not RAM.

**Install needs (require sudo; you have non-passwordless sudo on your own box):**
```bash
sudo apt update
sudo apt install -y libaio-dev libmkl-full-dev            # DiskANN
sudo apt install -y libisal-dev                           # SPFresh (file-I/O; SPDK/gcc-9 not needed)
sudo apt install -y nvme-cli fio                           # optional: device info + IOPS number
# present already: boost1.74, tbb, jemalloc, snappy, gflags, cmake 3.22, make, gcc/g++ 10.5, python3.13
```
**Build note:** SPFresh's *SPDK* build wants gcc-9; in **file-I/O mode we skip SPDK** and attempt the
build with the system **gcc-10.5**. ⟶ verify SPFresh's non-SPDK CMake path compiles on gcc-10; if it
hard-requires gcc-9, `sudo apt install gcc-9 g++-9` and point CMake at it (`-DCMAKE_C_COMPILER=gcc-9`).

Baseline hardware to record into every result file: the profile above + measured NVMe random-read
IOPS (`fio`, once installed) + compiler versions.

---

## 2. Build all four systems

Create a top-level `bench/` workspace on the server: `bench/{systems,data,work,results,logs}`.

### 2.1 Ours (this repo)
```bash
git clone <our-repo> bench/systems/lsmvec && cd bench/systems/lsmvec
git checkout sa-resident-sketch
git submodule update --init --recursive && make aster && make all
build/bin/test_sa_l0_buffer && build/bin/test_lsm_vec_db   # sanity: suites green
```

### 2.2 DiskANN (`cpp_main`)
```bash
git clone -b cpp_main https://github.com/microsoft/DiskANN bench/systems/diskann
cd bench/systems/diskann
sudo apt install -y make cmake g++ libaio-dev libgoogle-perftools-dev libboost-all-dev libmkl-full-dev
mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j
# binaries in build/apps: test_streaming_scenario, test_insert_deletes_consolidate,
#   search_memory_index, build_memory_index; build/apps/utils: fvecs_to_bin, compute_groundtruth
```
**Two DiskANN variants come from this ONE repo** (decision #2 = run both at 1M). Repo verified live
2026-06-29; `cpp_main` is the older C++ code, "not actively maintained" → **pin a known-good commit**.
- **DiskANN-IP (in-place):** `test_streaming_scenario` — ready binary, in-place insert/delete, no
  merge. Label "DiskANN (in-place)". Low effort.
- **DiskANN-merge (FreshDiskANN / streamingMerge):** ⚠️ **no single turnkey binary / entrypoint**
  exists (confirmed: DiskANN issues [#355](https://github.com/microsoft/DiskANN/issues/355),
  [#495](https://github.com/microsoft/DiskANN/issues/495); FreshDiskANN paper arXiv:2105.09613). To
  stand it up, hand-assemble the merge flow from the `cpp_main` components: `test_streaming_scenario`
  (accumulate inserts/deletes into the in-memory TempIndex) + `build_stitched_index` (the
  StreamingMerge into the SSD-resident index, triggered every ~30M ops per the paper) +
  `search_disk_index`. **Build-sub-task with real risk**; if it can't be stood up cleanly, run
  IP-only and footnote that DiskANN-merge was omitted. Params (paper): `R=64, L_build=75, alpha=1.2,
  search L tuned, beamwidth=2, merge every 30M`.

### 2.3 SPFresh + SPANN+ (SPTAG fork)
```bash
git clone --recurse-submodules https://github.com/SPFresh/SPFresh bench/systems/spfresh
cd bench/systems/spfresh
sudo apt install -y cmake gcc-9 g++-9 libjemalloc-dev libsnappy-dev libgflags-dev \
                    pkg-config swig libboost-all-dev libtbb-dev libisal-dev
# Build bundled ThirdParty: SPDK (CC=gcc-9 make -j) [only if SPDK path], isal-l_crypto, modified RocksDB
mkdir Release && cd Release && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j
# binaries: SSDServing (build+stream), IndexBuilder, usefultool (GenTrace/ConvertTruth/CallRecall)
```
**SPANN+** is the same `SSDServing` binary with the LIRE/rebuilder sections disabled in the `.ini`
(use the paper's `Script_AE/iniFile/*spann*.ini` as the template; SPFresh uses the `*spfresh*.ini`).

**Phase-0 feasibility check (do this early):** clone `SPFresh/Script_AE`, read
`overall_spacev_spfresh.sh` + `usefultool --GenTrace`/`--ConvertTruth`/`--CallRecall` help.
Confirm `usefultool --GenTrace` can emit per-epoch insert/delete id lists for OUR chosen split,
and `compute_groundtruth` (DiskANN) can produce per-checkpoint groundtruth. **If `Script_AE` is
turnkey on this server, prefer it; the research says it is not (hardcoded paths, SPDK, 44 h Azure
runs) → default to the neutral driver in §3–§4, reusing only `usefultool --GenTrace` for the trace
and `compute_groundtruth` for truth.** Record the verdict in the ledger.

---

## 3. The neutral benchmark harness (build in OUR repo) — TDD

We need a driver that replays a **shared workload trace** against our system and emits the metric
time-series. (Each baseline is driven by its own native streaming tool fed the *same* trace ids;
see §5.) Build this as a new app, TDD, on `sa-resident-sketch`.

**Files:**
- Create `bench/driver/trace_format.md` — the shared trace spec (below).
- Create `test/bench_streaming.cc` — our SUT driver (new binary `build/bin/bench_streaming`).
- Create `test/unit/test_bench_streaming.cc` — gtest for the replay/metrics logic.
- Modify `CMakeLists.txt` to add both targets.

**Shared trace format (the contract all systems consume):**
```
work/<dataset>_<scale>_<ratio>/
  base.fbin              # initial index vectors (DiskANN .fbin: int32 n, int32 d, raw rows)
  base.ids.u32           # ids assigned to base rows (0..n_base-1)
  query.fbin             # held-out queries (fixed across the whole run)
  epoch_000.ins.u32      # ids inserted this epoch (rows pulled from pool.fbin by id)
  epoch_000.del.u32      # ids deleted this epoch (subset of currently-live ids)
  ...
  pool.fbin + pool.ids.u32   # the insertion source (vectors + their global ids)
  gt/epoch_000.gt100     # groundtruth top-100 for query.fbin vs the ACTIVE set after epoch 000
  manifest.json          # dataset, dim, metric, scale, ratio, n_base, n_epochs, ops_per_epoch
```
`.fbin` is the universal vector format (DiskANN-native; SPFresh reads it via XVEC/DEFAULT after a
trivial header copy; ours reads it via a small loader). Ids are stable global ids so delete lists
are unambiguous across systems.

**Driver behavior (`bench_streaming`):**
- [ ] **Step 1 — failing test:** `test_bench_streaming` builds a tiny trace (n_base=200, 3 epochs,
  R-9010) in a temp dir, runs the replay, asserts: (a) live-set size after each epoch matches
  base + Σins − Σdel; (b) a deleted id is absent from results; (c) recall@10 computed by the driver
  against a provided gt file matches an independent brute-force on the active set (delta < 1e-6);
  (d) the emitted metrics JSON has one row per epoch with the required fields. RED first.
- [ ] **Step 2–4 — implement:** open our DB with the **best config** (§6), load `base.fbin` (Insert
  per id), **then trigger ONE SA rebuild to materialize the initial sketches** (RAM-pending defers
  tree building — without this the base index has no sketch; see §6 opt #5), persist. Then per
  epoch: apply `epoch_k.del` (Delete) then `epoch_k.ins` (Insert from
  pool), letting our **lazy SA rebuild** + **lazy-ghost delete** run naturally (do NOT force a full
  rebuild each epoch). After the update batch, run the query set Q times, recording per-query
  latency; compute recall@10 vs `gt/epoch_k.gt100`; read current RSS and DB on-disk size. Emit
  `results/raw/ours_<ds>_<scale>_<ratio>.jsonl` (one JSON row/epoch:
  `{epoch, live_n, recall10, qps, lat_mean_ms, lat_p50, lat_p99, ins_ops_s, del_ops_s, rss_mb, disk_mb}`).
  Latency percentiles are **P50 and P99** (NOT P99.9). Insert/delete throughput = ops / wall-time of
  that epoch's apply phase.
- [ ] **Step 5 — real-time memory curve:** start a **background sampler thread** at construction that
  polls the process RSS (Linux: read `VmRSS` from `/proc/self/status`) every **Δt = 1 s** for the
  ENTIRE run (base build + every epoch's apply + query phases) and appends
  `{t_sec, epoch, rss_mb}` to `results/raw/ours_<ds>_<scale>_<ratio>.mem.jsonl`. This is the
  continuous DRAM-vs-time stream (SPFresh Fig-5 style); peak RSS = max over the stream. The
  sampler must keep running across phase boundaries (do NOT only sample at epoch ends).
- [ ] **Step 6 — measurement hygiene:** compute query I/O from post-reset page-cache counters
  `(page_cache_hits_total + misses_total)/nq` (the known `total − after_build` trap — see
  `docs/exp_200k_best_vs_baselines.md` notes). Report it as an extra column for our system.
- [ ] **Step 7 — commit.**

**Concurrency model — [RESOLVED: single-thread batched-epoch first].** Start single-threaded with
the **batched-epoch model** — apply the epoch's deletes then inserts, then run a clean query phase
and measure. A **concurrent** insert/delete/search version is a planned **later task (lower
priority)**: it requires verifying thread-safety of our Insert/Delete/SearchKnn and matching the
paper's per-role thread budget. Out of scope for the first pass.

---

## 4. Workload sampling (how the trace is generated)

One generator script `bench/driver/gen_workload.py` produces the §3 trace for a (dataset, scale,
ratio). Use SPFresh's `usefultool --GenTrace` where convenient, but a small Python generator is
clearer and gives us full control — **prefer the Python generator; it is the source of truth for
all systems.**

**Split (per dataset, per scale N = the base index size: 1M, 10M, 100M):**
1. **base** = first `N` vectors of the dataset (the initial index, built before the stream).
   **pool** = a DISJOINT `0.5N` vectors from the dataset's tail (the source of all inserts; never in
   base). A "1M run" therefore uses **1.5M distinct dataset vectors** (1M base + 0.5M pool). Queries
   = the dataset's standard held-out query file (10k SIFT / 29,316 SPACEV), fixed for the whole run.
2. `n_epochs = 50`; `ops_per_epoch = 1%·N` (the paper's 1%/epoch cadence). [N=1M → 10,000 ops/epoch]
   - **R-INS (pure insert):** each epoch inserts `1%·N` pool vectors; no deletes. Index grows
     `N → 1.5N` over 50 epochs (consumes all `0.5N` of the pool).
   - **R-9010 (90/10):** each epoch = `0.9%·N` inserts (from pool) + `0.1%·N` deletes (random live
     ids). Net `+0.8%·N`/epoch → index grows `N → 1.4N`; consumes `0.45N` of the pool. Deletes never
     touch un-inserted ids. **Delete policy = UNIFORM** over all currently-live ids (incl. the
     original base vectors — true random churn, matches the paper).
3. **Groundtruth:** recomputing top-100 against the active set every epoch is O(|active|·|Q|·d)
   brute force — expensive at 10M+. **Checkpoint** instead: compute gt every `G` epochs
   (default `G = 10` → 6 checkpoints incl. epoch 0 and last) using DiskANN
   `compute_groundtruth --data_type {uint8|int8} --dist_fn l2 --base_file active.fbin
   --query_file query.fbin -K 100`. The driver only measures recall at gt checkpoints (latency /
   throughput are measured every epoch). Materialize `active.fbin` at each checkpoint from base +
   applied ins − applied del.
4. **Determinism:** seed the RNG; write the seed into `manifest.json`. The SAME trace files drive
   every system, so insert/delete sequences are identical across SUTs.

**[RESOLVED]** split = base `N` + disjoint pool `0.5N`; `n_epochs=50`; gt every `G=10`; R-9010
**delete policy = UNIFORM** over all currently-live ids (incl. original base — true random churn,
matches the paper).

**Data prep commands (SIFT example, 1M):**
```bash
# SIFT/SPACEV downloaders: DiskANN apps/utils + SPTAG datasets; convert to .fbin
./diskann/build/apps/utils/fvecs_to_bin float sift_base.fvecs sift_base.fbin   # SIFT is uint8 in paper; use matching dtype
python bench/driver/gen_workload.py --dataset sift --scale 1000000 --ratio r9010 \
       --n-epochs 50 --gt-interval 10 --seed 1 --out work/sift_1m_r9010
```
(SPACEV: download SPACEV1B head from `microsoft/SPTAG/datasets/SPACEV1B`, take N-vector prefix +
disjoint pool; dtype int8, dim 100.)

---

## 5. Driving the baselines on the shared trace

Each baseline replays the SAME `epoch_k.ins/.del` id lists; we write one thin orchestrator per
system under `bench/driver/run_<system>.sh` that loops epochs and logs the same JSONL schema.

- **DiskANN:** build an initial in-memory dynamic index from `base.fbin` with tags = base ids
  (`build_memory_index` or start empty + insert). Per epoch: feed `epoch_k.ins` ids (insert those
  rows with their tags) and `epoch_k.del` ids (lazy delete + `consolidate_deletes`), then run
  `search_memory_index --dynamic true --tags 1 -K 10 -L <tuned>` against `query.fbin` +
  `gt/epoch_*.gt100`. `test_streaming_scenario` can drive the whole sliding window if its window
  semantics match our trace; otherwise script the insert/delete/search loop with the dynamic-index
  apps. Record QPS, per-query latency → **P50 and P99** (NOT P99.9), recall@K. Params: `R=64,
  L_build=75, alpha=1.2, search L` tuned to the recall band.
- **SPFresh / SPANN+:** convert `base.fbin` → SPTAG bin; build via `SSDServing <build.ini>`. Use
  `usefultool --GenTrace` OR feed our `epoch_k.*` lists (map our id lists into the format
  `SSDServing` expects via its update-batch config). SPFresh ini: LIRE on; SPANN+ ini: LIRE off.
  Recall via `usefultool --CallRecall` against the per-epoch gt; latency (P50/P99) + QPS from
  `SSDServing` logs. **(SPDK vs file-I/O per §1.)**
- **Ours:** `build/bin/bench_streaming` (§3) consumes the trace directly.

**External real-time memory sampler (all baselines).** Each baseline is a separate process, so the
orchestrator wraps it with a poller (a tiny background loop — Python or bash — reading `VmRSS` from
`/proc/<pid>/status` every **Δt = 1 s** from launch to exit), writing `{t_sec, epoch, rss_mb}` to
`results/raw/<system>_<ds>_<scale>_<ratio>.mem.jsonl`. The orchestrator advances the `epoch` tag as
it drives the stream. This gives the same continuous DRAM-vs-time curve as our in-process sampler
(§3 Step 5); peak RSS = max of the curve.

Each `run_<system>.sh` writes `results/raw/<system>_<ds>_<scale>_<ratio>.jsonl` (per-epoch metrics)
+ `.mem.jsonl` (the memory curve), identical schema across systems so §10 can join them.

**⟶ ALIGN** at first 1M run: confirm each baseline actually ingests our trace ids faithfully
(spot-check that a deleted id is gone, that live-set sizes match) before scaling up — a silent
trace-mapping bug invalidates everything.

---

## 6. Our method — configuration & optimizations to use

**(a) Best config (from `docs/KNOWLEDGE_SHARE_sa_sketch_redesign.md` §3, the validated 200K best):**
```
--sahnsw 1 --M 16 --Mmax 32 --efc 32 --ef-final 16
--sa-max-children 4 --sa-min-cluster 16 --sa-ef 10 --sa-beam 8 --sa-layer-mult 0.125
--sa-l0-buffer-hops 4 --sa-max-steps 4
--vec-storage 1 --batch-read 1
--efs <calibrated per §7.1>   # ONLY deviation from the experiment's efs=16: tuned up so our recall ≥ baselines
```
**Alignment note:** every parameter above is **identical to the validated 200K best config**, with
exactly two deliberate streaming adaptations: (i) `efs` is **calibrated** (§7.1), not the
experiment's fixed 16; (ii) `--rebuild-sa-after-insert` is replaced by **one rebuild after the base
load + lazy rebuild during the stream** (opt #5). There are **no update operations** in this
benchmark (deletes = lazy-ghost `Delete`; "update" = delete+insert per the workload), so the
update-route choice does not apply here.
**(b) Optimizations that MUST be on (and why):**
1. **Resident top-H SA sketch routing** (Phase 1) — in-RAM routing, no per-query tree read. The
   query-latency win.
2. **RAM `pending` accumulator** (Phase 2 T2) — cheap inserts (no per-insert blob rewrite). The
   insert-throughput win; critical for a streaming insert workload.
3. **Sketch persist/reopen** (Phase 2 T1) — so a build→reopen restores routing (used if we
   checkpoint/restart).
4. **H=4 hop-buffer + `sa-beam=8`** — the I/O-optimal operating point (beam>1 is Pareto-better
   *because* the buffer makes routing visits free; do NOT use beam=1).
5. **Rebuild policy: ONE rebuild after the base load, then LAZY during the stream.** After loading
   the initial `N` base vectors, trigger **one** SA rebuild to materialize the initial sketches —
   with RAM-pending (P2-T2) the base inserts are deferred, so without this rebuild the base index
   has **no sketch** and routing falls back to disk. During the streaming epochs, do NOT force a
   full rebuild per epoch — rely on `maybeRebuildSaCluster`'s threshold-triggered lazy rebuild +
   lazy-ghost deletes. **⟶ verify** the lazy cadence over a long stream keeps recall stable (this
   is exactly the paper's "recall stability" axis — our headline test).
6. **`--sa-l0-buffer-hops` set identically on build and on any reopen** (else the sketch isn't
   restored — known gotcha).

**Scale caveats to watch (staged 1M→10M→100M):**
- At larger N the number of L1 clusters grows (~N·p); the **resident sketch RAM grows roughly
  linearly** (≈8 MB / 65 clusters at 200K → multi-GB at 100M). Track RSS at each scale; if it
  blows the RAM budget, raise `--sa-min-cluster` / lower hop depth, or revisit `--sa-layer-mult`.
- **P2-T3 (drop per-rebuild full-tree writes) is NOT implemented** on this branch — so on-disk SA
  state still includes `'C'` blobs. Report disk honestly; note T3 would shrink it. Also the
  orphaned-`'S'`-blob cleanup is pending (delete-heavy R-9010 will slowly bloat disk — watch it,
  and cite the follow-up).

---

## 7. Experiment matrix & open decisions

**Matrix:** {SIFT, SPACEV} × {R-INS, R-9010} × systems. **At 1M, 5 systems** — Ours, SPFresh,
SPANN+, **DiskANN-IP** (in-place) AND **DiskANN-merge** (streamingMerge/FreshDiskANN) — = 20 runs,
to compare the two DiskANN variants directly. **At 10M/100M, 4 systems** (carry forward the chosen
DiskANN variant) = 16 runs/scale. Stage gate: complete + sanity-check 1M before 10M; 10M before 100M.

**Metrics table (the deliverable), one row per run:**
| system | dataset | scale | ratio | recall@10 (start/mid/end) | lat_mean | lat_p50 | lat_p99 | search QPS | insert ops/s | delete ops/s | peak RSS (max of mem curve) | disk |
plus the per-epoch JSONL time-series → recall-vs-epoch, p999-vs-epoch, RSS-vs-epoch plots
(reproducing the paper's Figure-5 style, which is the core recall-stability story).

**Decision status:**
1. **§1 SPDK:** ✅ RESOLVED — file-I/O fallback (B), forced (no dedicatable NVMe, Secure Boot on).
2. **§2.2 DiskANN variant:** ✅ RESOLVED — run **BOTH** at 1M (DiskANN-IP + DiskANN-merge),
   compare, then carry the chosen one forward to 10M/100M. (DiskANN-merge has no turnkey binary →
   build sub-task with risk; if it can't be stood up, fall back to IP-only and note it.)
3. **§3 concurrency:** ✅ RESOLVED — single-thread batched-epoch first; concurrent = later task.
4. **§4/§6 recall:** ✅ RESOLVED — report recall directly (no band); calibrate ours ≥ baselines (§7.1).
5. **§4 split & cadence:** ✅ RESOLVED — split `N` + pool `0.5N`, 50 epochs, gt/10; R-9010 delete =
   **uniform** over all live ids (incl. base).

**ALL DECISIONS LOCKED (2026-06-29).** No open ⟶ALIGN decisions remain; the remaining `⟶ verify`
notes in §3/§5/§6 are execution-time sanity checks, not decisions.

### 7.1 Recall calibration (pre-run, per dataset × scale)
Before each scale's production matrix: build base-only indices for all four systems at their chosen
configs; run the query set once; record start-of-stream recall@10. Tune OUR `efs`/`ef-final` upward
until our recall ≥ max(baseline recalls) — or until latency stops being competitive, then stop and
flag. Lock our config; record every system's config + start recall in
`results/calibration_<ds>_<scale>.json`. The production run then reports recall as-measured.

## 8. Risks / honesty notes to carry into the writeup
- All baselines are **disk-based, built for billion-scale on limited DRAM**; at 1M–10M everything
  fits in RAM, which flatters in-memory routing. The meaningful axes at small scale are
  **recall-stability under churn, update throughput, and DRAM** — report memory prominently. The
  **disk-I/O** advantage of our method only becomes latency-relevant at larger-than-RAM scale (the
  reason for the 100M stage).
- File-I/O SPFresh ≠ paper-SPFresh latency — footnote everywhere if we use fallback (B).
- Our method untested >200K — the 1M stage is also a **correctness/scale shakedown** (watch
  recall drift, RSS, disk bloat), not just a perf run.

## 9. Ledger / execution
Track in `bench/PROGRESS.md`: phase, per-(system,dataset,scale,ratio) run status, the ALIGN
decisions as they're resolved, and anomalies. Commit the harness (§3), generators (§4), the
results pipeline (§10), and the canonical `.dat` files; gitignore raw logs, `work/` traces, `data/`.

---

## 10. Results pipeline — data → `.dat` → paper-ready figure (reproducible, one-command)

Academic-standard pattern: **separate run / data / presentation** so a heavy benchmark runs once,
the canonical result is a small diffable file, and figures regenerate from it in seconds without
re-running anything.

### 10.1 Three-layer data model
```
bench/results/
  raw/   <system>_<ds>_<scale>_<ratio>.jsonl        # §3/§5 per-epoch metrics. Big. GITIGNORED.
  raw/   <system>_<ds>_<scale>_<ratio>.mem.jsonl    # the real-time RSS-vs-time stream {t_sec,epoch,rss_mb}. GITIGNORED.
  dat/   <experiment>.dat                            # ONE canonical table per figure, aggregated from the raw it needs. Small. COMMITTED. Overwritten on rerun.
  fig/   <experiment>.pdf  (+ <experiment>.svg)      # paper-ready vector figure, SAME basename, regenerable from the .dat alone.
```
**Invariant (your requirement):** one experiment ⇒ exactly one `dat/<name>.dat` ⇒ one
`fig/<name>.pdf`. A rerun **overwrites** all three deterministically — a result always maps to its
fixed name. The `.dat` is the version-controlled source of truth; figures are derived artifacts.

### 10.2 `.dat` format — tidy table + provenance header
Whitespace-delimited (gnuplot/numpy-loadable), self-describing:
```
# experiment: recall_epoch__sift_1m_r9010
# generated : 2026-07-01T12:00:00Z   git:<sha>   cmd: bench.py run recall_epoch__sift_1m_r9010
# source    : raw/{ours,spfresh,spannplus,diskann_ip,diskann_merge}_sift_1m_r9010.jsonl
# columns   : epoch system recall10 lat_mean_ms lat_p50_ms lat_p99_ms qps ins_ops_s del_ops_s rss_mb disk_mb
#   (time-series memory figures use a separate <experiment>.dat with columns: t_sec system epoch rss_mb)
0   ours          0.912  0.18  0.26   ...
0   spfresh       0.880  3.10  4.20   ...
...
```
Plain text → diffable, archivable, **re-plottable without re-running**. One `.dat` holds all series
a figure needs (the plotter slices by the `system` column).

### 10.3 Plotting — paper-ready Matplotlib
- **Shared style module `bench/plot/style.py`:** vector output (**PDF + SVG**); embed **Type-42/TrueType
  fonts** (never Type-3 — venues reject them: `pdf.fonttype=42, ps.fonttype=42`); serif/Times-like
  family; base font ≈ 9–10 pt legible at ~3.3" single-column width; **colorblind-safe palette**
  (Wong/Tol) with a **distinct linestyle + marker per system** so it survives B/W printing; light
  grid; legend in the least-busy corner; **no figure title** (captions live in LaTeX);
  `savefig(..., bbox_inches='tight')`. One helper `save_fig(fig, name)` writes both `.pdf` and `.svg`.
- **One pure plotter per figure family** in `bench/plot/`: `plot_timeseries.py`, `plot_bar.py`,
  `plot_pareto.py`, each exposing `plot(dat_path, out_path)` — reads the `.dat`, renders, saves.
  Pure function of the `.dat`; no benchmark dependency.

### 10.4 Orchestrator — `bench.py` (the single `main` controller)
A Python controller with an **experiment registry** (`bench/experiments.py`): each entry =
`{name, dataset, scale, ratio, family, needs:[raw runs], aggregate(), plotter}`. Subcommands:
| command | does |
|---|---|
| `bench.py list` | list all registered experiments + their status (raw? dat? fig?) |
| `bench.py run <name>` | ensure needed raw runs exist (execute via §5 runners if missing or `--force`) → aggregate → `dat/<name>.dat` → plot → `fig/<name>.pdf`+`.svg` |
| `bench.py run all` | the whole suite, honoring the §7 scale stage-gates (1M before 10M…) |
| `bench.py plot <name>` \| `plot all` | re-aggregate + re-plot from EXISTING raw/.dat **without** re-running the benchmark (cheap; for restyling / fixing a figure) |
| `bench.py clean <name>` | remove that experiment's dat/fig (raw kept) |
Properties: **idempotent + resumable** (default skips a run whose raw output exists; `--force`
re-executes); logs to `bench/logs/<name>.log`; every `.dat` stamped with git sha + UTC time +
source for provenance. So **`bench.py run all` reproduces the entire paper end-to-end**, and
`bench.py run <name>` reproduces exactly one — each emitting its `.dat` and its paper-ready figure.

### 10.5 The figure set (deliverables) — **⟶ ALIGN on this list**
Proposed families (each instance = one experiment = one `.dat`+`.pdf`), named
`<family>__<ds>_<scale>_<ratio>`:
| family | what it shows | grouping | source |
|---|---|---|---|
| `recall_epoch` | recall@10 vs epoch, systems overlaid — **the recall-stability headline** | per (ds,scale,ratio) | timeseries |
| `latency_epoch` | query latency vs epoch — **P50 and P99** (two stacked panels, P99 top / P50 bottom, shared x), systems overlaid | per (ds,scale,ratio) | timeseries |
| `insert_tput_epoch` | insert (and delete, R-9010) throughput vs epoch | per (ds,scale,ratio) | timeseries |
| `mem_time` | **real-time DRAM (RSS) vs time** — continuous curve from run start to end, systems overlaid (SPFresh Fig-5 style, NOT a peak bar) | per (ds,scale,ratio) | mem-timeseries |
| `recall_latency_pareto` | recall@10 vs mean latency at end-of-stream | per (ds,scale,ratio) | pareto |
| `diskann_ip_vs_merge` | the two DiskANN variants head-to-head (decision #2) | **1M only**, per (ds,ratio) | timeseries |
Rendering all cells = many figures (e.g. `recall_epoch` alone = 2 ds × 3 scale × 2 ratio = 12).
`mem_time` x-axis = **epoch progress** by default (aligns systems with different wall-clock, like
SPFresh); the fine-grained `t_sec` samples are retained so it can also be drawn vs wall-clock.
**⟶ ALIGN:** confirm the families, and whether to render **every cell** or a **curated subset** (e.g.
the headline `recall_epoch` + `latency_epoch` + `mem_time` for all cells, the rest only at a
representative scale). Also: commit `fig/*.pdf` to git, or only the `.dat` (figures regenerable)?
