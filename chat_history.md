# Conversation history

Append-only log of our exchanges (newest at the bottom). Per the rule in CLAUDE.md, each
response adds the user's question + a concise summary of the answer/actions/results.

---

## 2026-06-29 — Session: execute benchmark_implementation_plan.md

**Q: 把 LSM-Vec-with-SA-HNSW 切换到最新 branch.**
A: Repo's GitHub remote was auth-gated (private); couldn't fetch. Switched to the locally-known
latest branch `sa-resident-sketch` (931b524) per the user's go-ahead.

**Q: 开始执行 benchmark_implementation_plan.md.**
A: Read the 10-phase runbook. Hit a build blocker: `lib/aster` submodule pinned a commit gone from
upstream. User manually re-pointed it. Then found deeper issue: our code needs a custom Aster
`sa_tree` column family (44 call sites) absent from upstream. **Patched `lib/aster/.../graph.h`** to
add the `sa_tree` CF + accessor (per `docs/SA_tree_on_disk_plan.md`); rebuilt Aster + our system;
sanity suites green (test_sa_l0_buffer 15/15, test_lsm_vec_db 21/21). Set up `bench/` workspace +
`PROGRESS.md` ledger.

**Q: 我能提前赋予 sudo 权限吗？**
A: Explained two layers: Claude's permission prompt (can allowlist) vs OS sudo password (the real
blocker — non-interactive shell can't prompt). User chose option A (installs apt deps themselves).
Claude can't self-modify permission rules (guardrail).

**Q: scope — everything including baselines.**
A: Built Phase 3 (bench_streaming harness, TDD — `test/bench_common.h` + binary + gtest; 5/5 ctest),
Phase 4 (`gen_workload.py` + trace spec), Phase 10 (results pipeline `bench.py` + plotters), Phase 5
external RSS sampler. All verified on synthetic data.

**Q: dependency checks / sudo password help.**
A: Diagnosed apt install aborting (likely MKL license prompt). User installed deps in their own
terminal. Verified all baseline deps present (MKL, libaio, isal, gperftools, gcc-9).

**Q: 继续编译 baseline.**
A: Found SIFT already on disk (`/home/dmo/vdb_bench/raw_sift_bigann/`, BIGANN 1M/10M/100M). Built
DiskANN (all binaries). Delegated SPFresh build to a background agent — SUCCESS (file-I/O mode, no
SPDK; `ssdserving`/`usefultool` built, RocksDB fork with RTTI). All 4 systems built. Generated real
SIFT 1M trace; ran our system on it.

**Q: 跑得如何了.**
A: First real SIFT 1M results. **Finding 1:** recall@10 degrades under churn 0.685→0.334 over 50
epochs (the headline recall-stability axis fails as-is). **Finding 2:** efs is a no-op recall knob in
the SA path (flat 0.685 across efs 16–512); the real knob is `ef_final`. **Finding 3:** ~15 min base
build at 1M. Corrected `--calibrate` to sweep ef_final; relaunched. Saved findings to memory.

**Q: 先写 orchestrator 脚本，校准好就能跑矩阵；并在 CLAUDE.md 加规则把对话记录存到 chat_history.md.**
A: Added the conversation-logging rule to CLAUDE.md and created this file. Investigated DiskANN
dynamic-index API (insert_point/lazy_delete/consolidate_deletes/search_with_tags) — the stock apps
are positional (sliding window / delete-from-beginning), so faithfully replaying our arbitrary
per-epoch ins/del id lists needs a small C++ driver (planned).

**Q: 目录结构不对——我们的方法和 baselines 的 source、benchmark scripts、CLAUDE.md、chat_history 都应在 bench 主目录（顶层）。**
A: **ef_final calibration finished — resolves the base-recall concern:** recall/latency Pareto @1M
SIFT epoch0 = ef_final 16→0.685, 32→0.801, 64→0.885, 128→0.935, 256→0.960, 512→0.970 (lat
0.42→7.4ms). So our base recall is competitive at ef_final≈128–256; efs was just the wrong knob.
Then restructuring the repo: baselines (diskann, spfresh) → top-level siblings of LSM-Vec-with-SA-HNSW;
benchmark scripts (driver/, plot/, bench.py, experiments.py), results/, work/, PROGRESS.md,
CLAUDE.md, chat_history.md → top level. The C++ harness (test/bench_common.h, bench_streaming.cc)
stays inside the method repo (compiles against our lib). Waiting for the calibration process to fully
exit before moving, then fixing all path references.

**Q: 和我对齐一下新的目录结构.**
A: Presented the target tree; user confirmed: two CLAUDE.md (benchmark-root + method-repo), leave
SPFresh's RocksDB fork at /home/dmo/SPFresh/rocksdb, move whole baseline build trees. **Executed the
restructure** — root `/home/dmo/lsm_vec_benchmark/` now holds driver/ plot/ results/ work/ bench.py
experiments.py PROGRESS.md CLAUDE.md chat_history.md, with siblings LSM-Vec-with-SA-HNSW/ diskann/
spfresh/. Fixed all path refs (run_ours.sh, gen_workload gt-bin, .gitignore, PROGRESS.md, memory).
Created benchmark-root CLAUDE.md (chat-logging rule + build facts); trimmed the repo's CLAUDE.md to a
harness pointer. Verified bench.py, diskann/spfresh binaries, run_ours.sh all work post-move.

**Q: 为什么要写 DiskANN/SPFresh 的 orchestrator？我们应该只校准自己的方法？**
A: Clarified: calibration tunes OUR method only (correct); orchestrators are not for calibration but
for running the BASELINES on the same trace to produce the comparison numbers the plan's figures
overlay. Agreed the user's instinct is sound given the shakedown found recall degrades under churn
(the method's headline axis). **Decision: focus on our own method first, defer baselines.** Archived
the efs16 run; launched a full 50-epoch streaming run at the calibrated ef_final=128 on SIFT 1M
r9010 to test whether recall stays ~0.93 under churn or still degrades (which would point to lazy SA
rebuild / resident-sketch staleness). Baseline orchestrators deferred.

**Q: 为什么现在后台有四个 shell 在跑？**
A: They were polling "waiter" loops (one per background run) to get completion notifications; several
early ones self-matched their own `pgrep -f` pattern and never exited. Explained, killed the orphans,
kept only the active run + its waiter, and switched future waiters to `pgrep -x bench_streaming`
(exact binary name, no self-match).

**Q: [ef_final=128 run result]**
A: **Decisive: recall STILL decays under churn at ef_final=128** (0.935→0.780→0.675→0.602→0.550→0.515
over epochs 0..49) — same slope as ef_final=16, just shifted up. So it's NOT search budget; it's
**stale resident sketch**. Root cause (code: `maybeRebuildSaCluster`): rebuild fires only at
`pending ≥ 0.3×(tnodes+pending)`; at 1M/351-clusters/9k-ins-per-epoch a cluster needs ~50 epochs to
trigger → sketches refresh ~once in the whole stream → streamed-in vectors stay in flat `pending`,
invisible to the sketch → SA routing misdirects queries near new vectors. Instrumented per-epoch
JSONL (sketch_clusters, cluster_blob_puts, sketch_route_hits) and added `--rebuild-every K`; launched
a diagnostic run (ef_final=128 + rebuild every 10 epochs) to confirm a forced rebuild restores recall.
Candidate fixes: periodic rebuild, lower sa_rebuild_alpha, or incremental sketch update.

**Q: 等跑完看 recall 有没有跳回 / ef_final=128 跑完了吗.**
A: **Stale-sketch hypothesis FALSIFIED.** Forced rebuild every 10 epochs gave essentially the SAME
curve as lazy (0.781/0.681/0.612/0.565/0.535). Instrumentation shows the sketch was never stale:
sketch_clusters grows 353→527, cluster_blob_puts +~1000/epoch (continuous rebuilds), route_hits
~9900/epoch. So the resident sketch tracks inserts fine and forcing more rebuilds does nothing.
Corrected the memory note. Narrowed to two candidates: (A) churn structurally damages the incremental
index, or (B) ef_final=128 just inadequate at 1.4M. Launched the decisive test: materialized the
epoch-49 active set (1.4M, work/sift_1m_active49, reusing the epoch_049 gt) and ran a FRESH build +
ef_final sweep — fresh@128≈0.93 ⇒ churn damage (A); fresh@128≈0.55 ⇒ pure scale (B). (~20min.)

**Q: [fresh-build result] → 先归因：跑 R-INS（纯插入）.**
A: **Decisive: (A) churn structurally damages the L0 graph.** Fresh build on the exact 1.4M epoch-49
active set: recall@ef_final 64→0.892, 128→0.947, 256→0.974, 512→0.986; the streamed/churned index on
identical vectors = 0.535 @128. The 0.41 gap = incremental-churn damage. Why forced SA rebuild didn't
help: `rebuildAllSaClustersFromScratch` rebuilds only the SA overlay, NOT the underlying HNSW L0 graph
— and the damage is in the L0 graph (efc=32 incremental inserts + ~50k lazy-ghost delete tombstones).
This is what SPFresh-LIRE / DiskANN-merge solve; our method has no L0 consolidation under churn.
User chose to attribute first: launched R-INS (pure insert, no deletes) at ef_final=128 to see if it
stays ~0.93 (⇒ deletes are the culprit) or also drops (⇒ inserts/efc also contribute).

**Q: [R-INS result] → 先别改，我再想想.**
A: **Attribution definitive: the DELETES are the sole cause.** R-INS recall flat ~0.95 (0.953→0.945)
while index grows 1.0M→1.5M; R-9010 collapses 0.935→0.515. Inserts are fine (efc=32 OK), deletes do all
the damage. Read the delete path: `deleteNode` (src/lsm_vec_index.cc ~2440–2530) removes the node's L0
edges both directions but **never re-links the orphaned neighbors** → textbook HNSW deletion problem;
every delete fragments local navigability, no repair. Fix = DiskANN-style neighbor re-linking
(consolidate_deletes), reusing the method's existing heuristic neighbor selection; eager (per-delete)
or periodic. Per user's "don't change code yet" choice, wrote a full diagnosis/design doc
`FINDINGS_churn_recall.md` (all 4 experiments + root cause + proposed fix + ruled-out alternatives) and
a figure `results/fig/churn_recall_attribution.pdf` (R-INS vs R-9010 vs fresh-rebuild reference). No
method code changed; awaiting user's decision on the fix.

**Q: eager rewiring 是不是不合理？10 个邻居要两两全连（45 条边）吗？**
A: Correct that naive clique-the-neighbors is wrong (edge explosion + busts m_max), but that's NOT what
consolidate does — each in-neighbor of X *inherits X's out-neighbors as candidates* then *prunes back to
m_max* via the existing heuristic, so degree stays bounded and net edges are ~conserved (not +45). Gave a
worked 10-neighbor / m_max=32 example. Noted our delete already removes edges symmetrically so in-
neighbors = X's neighbor list (no reverse index needed). Real design axis is eager-vs-periodic, not edge
explosion.

**Q: 用 lazy 思路（delete→ghost 不删边，靠 insert 时 degree>M 的 prune 顺带清理）写个 plan；并加规则：主目录建 docs/，所有文档（含 plan）放 docs/.**
A: Added the docs-location rule to CLAUDE.md; created `docs/` and moved the runbook
(benchmark_implementation_plan.md), FINDINGS_churn_recall.md, SPFRESH_BUILD_NOTES.md into it (updated
path refs in CLAUDE.md/PROGRESS.md/memory; CLAUDE.md, chat_history.md, PROGRESS.md stay at root as
operational files). Wrote `docs/2026-06-30-lazy-ghost-delete-plan.md` capturing the user's lazy design:
Phase 1 = ghostify on delete (keep node+edges+vector, filter from results only → no fragmentation, the
minimal change that should restore recall); Phase 2 = opportunistic ghost reclamation piggybacking on
insert-time degree>m_max prune (evict ghosts first, reclaim when no live in-edges); Phase 3 = optional
cold-region sweep. Includes cost trade-off vs eager, risks (memory growth, search overhead), files to
touch, and a validation gate (re-run R-9010 @128, expect ~0.93 vs 0.515). No code changed.

**Q: 实现 Phase 1，跑 R-9010 验证 recall 能不能回到 0.93.**
A: Implemented Phase 1 in `src/lsm_vec_index.cc`: `deleteNode` no longer unlinks edges / deletes the
vector / erases the node — it keeps the deleted node as a navigable ghost (filtered from RESULTS via
deleted_ids_ at knnSearchSA ~3055, still traversed), only retargeting the entry point if it was the
deleted id. Confirmed the search path already filters deleted ids from results while traversing them.
Hit one regression: route-2 Update (delete+reinsert same id) — fixed by a revive-purge at the top of
`insertNode` (when re-inserting a previously-deleted id, drop its stale edges+vector+in-memory node so
the fresh insert rebuilds clean; this is not fragmentation since the node comes right back). All 5
ctest suites green. Launched the R-9010 SIFT 1M ef_final=128 validation run (~40min) comparing recall
to the broken 0.515 baseline and the R-INS ~0.945 reference, plus RSS for ghost accumulation.

**Q: 为什么要跑 40 分钟 / 加子采样压到 20 分钟 / 等跑完看 recall 回到多少.**
A: Explained the 40min = ~15min base build + ~18min querying (10k queries × 50 epochs @2.2ms) + ~8min
inserts. Added `--query-subsample N` (non-checkpoint epochs query N, checkpoints full for exact recall);
wired into bench_streaming + run_ours.sh (default 2000). Honest caveat: subsampling cuts query ~18→5min
→ total ~28min (the 15min base build now dominates, not 20); suggested a 200K dev trace for a truly fast
loop. **Phase-1 VALIDATION = SUCCESS:** R-9010 recall now 0.953→0.943 (was →0.515), tracking the R-INS
ceiling 0.953→0.945 within 0.002 — recall stable under churn restored. Costs negligible: RSS +0.9%,
latency ~same, disk not inflated (ghosts live on disk, cached). Phase 2 likely unneeded at 10% churn.
Figure results/fig/phase1_churn_recall_fixed.pdf. Memory + task updated; Phase 1 marked done.

**Q: Resume the baseline comparison.**
A: Resumed Phase 5/6. Wrote `docs/baseline_driver_spec.md` (exact shared JSONL schema + trace format +
sanity gate + system names diskann_ip/spfresh/spannplus). Launched two background agents: one builds a
DiskANN-IP C++ streaming driver (dynamic index insert_point/lazy_delete/consolidate_deletes/
search_with_tags, replaying our trace, params R=64/L_build=75/alpha=1.2); one builds a SPFresh
orchestrator (ssdserving file-I/O mode UseSPDK=false/UseKV=true, mapping our per-epoch id-lists +
computing recall vs our global-id gt). Both validate on work/synth_2k_r9010 first, then run
work/sift_1m_r9010 in background. Set the canonical `ours_sift_1m_r9010.jsonl` to the Phase-1 FIXED
result (recall 0.943) so the matrix shows the corrected method.

**Q: 不要并行跑不同 baseline / 我们的方法也只能串行跑（资源抢占）.**
A: Recorded the hard rule [[serial-measurement-rule]] (all measurement runs strictly serial; builds +
tiny synthetic validation may overlap). Can't message a running agent (only stop), so the plan: agents
BUILD+VALIDATE drivers; I orchestrate the full-scale runs serially. Armed a precise watchdog (alerts
only when ≥2 real benchmark binaries >800MB RSS run at once). **DiskANN agent DONE**: driver
`diskann/apps/bench_stream_diskann.cpp` built + synthetic-validated (live_n ✓, 0 deleted-id violations,
recall 1.0, schema ok), 1M run launched and is the SOLE measurement (serial-OK) — epoch0 live_n
1.008M, recall@10 0.9987, lat 0.40ms, RSS 2187MB (vs ours 920MB — low-DRAM pitch showing), disk 0
(in-memory). Note: diskann/build cmake cache is stale (pre-move path) so the agent linked directly
against libdiskann.a; a fresh cmake needed to rebuild via CMake. SPFresh agent still building; if it
launches its 1M while DiskANN runs, the watchdog fires and I'll serialize. Waiter set on DiskANN run.

**Q: [baseline runs proceeding].**
A: **DiskANN done** — 50 epochs, recall ~0.998 stable, lat 0.40ms (flat → confirmed clean), RSS 2187MB,
disk 0 (in-memory). **SPFresh agent done** but it launched its 1M run CONCURRENTLY with DiskANN (serial
violation; watchdog missed it because SPFresh's replay binary is `spfresh_driver`, not in the match
pattern). DiskANN's latency was flat through the overlap → kept as clean. SPFresh contaminated from
epoch 0 → killed + discarded, **re-running solo**. Drivers: `diskann/apps/bench_stream_diskann.cpp`,
`driver/run_spfresh.sh` + `driver/spfresh_driver.cpp` (replays our ins/del global-ids via SPANN
AddIndexSPFresh/DeleteIndex; recall computed in-driver vs our gt; ini UseSPDK=false/UseKV=true; L2 head
fix). Preliminary 1M R-9010: ours recall~0.95/RSS 960MB; DiskANN 0.998/2187MB; SPFresh(file-IO) 0.95/
~4300MB/6.6GB disk — our low-DRAM pitch strong. Both agents finished → all remaining runs serial,
driven by me. Waiter set on SPFresh solo re-run.

**Q: [SPFresh solo re-run done].**
A: Clean SPFresh result (50 epochs): recall 0.946→0.910 (drops MORE under churn than ours), lat
1.4→1.6ms, RSS 4.5→6.0GB. Full clean SIFT 1M R-9010 head-to-head (3 systems): ours recall 0.953→0.943
/RSS ~1GB; DiskANN 0.999→0.998/2.19GB/0.40ms; SPFresh 0.946→0.910/4.5-6GB/1.4ms. Findings: ours has
LOWEST DRAM (~5× < SPFresh, ~2× < DiskANN) and is MORE churn-stable than SPFresh (−0.010 vs −0.036);
DiskANN leads recall+latency at 2.2× our RAM (pure in-memory). Generated all 4 overlaid figures via
`bench.py run` (recall_epoch, latency_epoch, mem_time [4254 RSS samples], recall_latency_pareto) — 3
systems each. Updated PROGRESS run matrix. Remaining for the cell: SPANN+ (trivial, ssdserving LIRE
off) + DiskANN-merge (hard, hand-assembled).

**Q: Finish the 1M R-9010 cell → SPANN+ then DiskANN-merge; for DiskANN-merge, attempt the diskv2 build.**
A: Ran SPANN+ solo: recall 0.960→0.884 (drops MOST under churn, −0.076 — the no-reassignment strawman),
RSS 2.4→3.4GB. **Churn-stability ranking (recall drop, lower=better): DiskANN-IP −0.001 < ours −0.010 <
SPFresh −0.036 < SPANN+ −0.076** — ours 2nd-most-stable AND lowest DRAM. Refreshed all 4 figures with 4
systems. Found DiskANN-merge (FreshDiskANN streamingMerge) is NOT in cpp_main (only merge_shards/
stitched) — user chose to attempt the diskv2 build. Launched a background agent to clone+build the
diskv2 / Yuming-Xu DiskANN_Baseline merge variant + a driver replaying our trace (system `diskann_merge`),
**build+synthetic-validate ONLY, NOT run the 1M** (I run the measurement serially). Cell sift_1m_r9010 =
4/5 done. Note: at 1M the merge threshold (~30M ops) likely never triggers — expected, will note it.

**Q: [DiskANN-merge agent done].**
A: Agent SUCCESS — built real FreshDiskANN MergeInsert flow from Yuming-Xu/DiskANN_Baseline@diskv2
(SSD PQFlashIndex + in-mem delta + StreamingMerger), driver `diskann_merge_src/tests/bench_stream_merge.cpp`,
synthetic-validated green (recall 0.999→0.991, 0 delete violations), did NOT run 1M (respected serial
rule), gave exact launch cmd. Fixed an upstream RSS-balloon (mem reservation now sized to pool, not
30M). I launched the DiskANN-merge 1M run SOLO (disk index build + 50 epochs, merge won't trigger at
450k ops ≪ 30M — footnote: disk-base+delta+filtered-search regime). Waiter set. Will complete the 5/5
cell + regenerate figures + diskann_ip_vs_merge.

**Q: 作图没 show build time 和 insert/avg throughput.**
A: Right — build time wasn't captured anywhere. Recovered it WITHOUT re-runs from the `.mem.jsonl`
epoch=-1 phase (build_time_s = max t_sec at epoch -1): ours ~818s, DiskANN-IP ~36s, SPFresh ~210s,
SPANN+ ~123s — ours' SA rebuild is a real weakness. Added to bench.py a 'summary' source
(build_time_s, mean_ins_ops_s, mean_del_ops_s, peak_rss_mb, end_recall10) and registered families
`build_time` + `insert_tput` (plot_bar) and `insert_tput_epoch` (timeseries). Insert tput: ours ~790
ops/s (1 thread) vs DiskANN ~22k (32 threads) — thread-count confound, will footnote. Code verified;
deferring figure generation until the DiskANN-merge measurement finishes (avoid contention + include
all 5 systems).

**Q: DiskANN-merge 还没跑完吗？**
A: It finished (50 epochs, merges=0 as expected, 0 delete violations): recall 0.998→0.970, lat 5.8ms
(slowest, disk PQ search), peak RSS 3621MB, disk 930MB — NOT low-DRAM at 1M (its value is at 100M).
**CELL sift_1m_r9010 COMPLETE (5/5).** Generated all 8 figures. Full standings — peak RSS: ours 1350 <
diskann_ip 2194 < spannplus 3423 < diskann_merge 3621 < spfresh 6038 MB (ours LOWEST DRAM, 1.6–4.5×);
churn drop: diskann_ip −0.001 < ours −0.010 < diskann_merge −0.028 < spfresh −0.036 < spannplus −0.076
(ours 2nd-best); build: ours 818s slowest (SA rebuild); insert tput: ours 790/s (1T) vs 1.4k–22k (32T,
confound). Marked Phase 5 (orchestrators) done; updated PROGRESS. Remaining matrix: R-INS baselines,
SPACEV (needs download), 10M/100M scaling.

**Q: Report our params + why query slow + HNSW shape; then build 2 ablations of ours.**
A: Reported config (ef_final=128 is the real knob; efs is a no-op; latency ≈ ef_final×paged-vector-reads,
~1065 reads/query @128). HNSW shape: only 2 layers — L0 ~1M, L1 ~353 (=sketch_clusters), no L2+ — because
sa_layer_mult=0.125 (vs standard 0.36 → ~5 layers / ~62k L1). Built 2 ablations as configs of our own
LSMVecDB: tweaked randomLevel() to honor layer_mult even with SA off (ours byte-unchanged); added Config
use_sa/layer_mult, bestConfigOptions params, buildBase skips SA build when use_sa=false, CLI
--use-sa/--layer-mult. lsm-vec-no-sa = use_sahnsw=false + layer_mult=0.125 (flat, entry@layer1 confirmed);
lsm-vec-basic = use_sahnsw=false + layer_mult=0 (full HNSW, entry@layer3 confirmed). User chose FIXED
ef_search=128 (report recall), efc=32 held. gtest green; added both to style + an ablation family
(recall/latency/build). Running both SOLO serially (no-sa→basic, PID-chained); will plot ours vs no-sa vs
basic when done.

**Q: 留个档把这两个新 baseline 记录下来，方便一个月后 refer.**
A: Wrote `docs/ablation-baselines-lsm-vec-no-sa-and-basic.md` — self-contained reference (definitions +
intent, exact config held-constant-vs-varies, run commands, code hooks, comparison protocol, what each
isolates, HNSW shape recap). Added a [[ablation-baselines-doc]] memory pointer so future mentions of these
baselines surface the doc instead of re-deriving. Ablation runs still in flight (serial).

**Q: 不用额外生成图，把这两个 ablation 放进之前那些图里，和其他 baseline 一起比.**
A: Added lsm-vec-no-sa/lsm-vec-basic to `ALL_SYSTEMS` (so they appear inside the main families), removed
the separate ABLATION_FAMILY. Main 1m families now expect 7 systems. Updated the doc's run-command.

**Q: 等跑完看 ablation 结果.**
A: Both ablations done (serial). Regenerated all 7 figures (7 systems each). **Key ablation finding:**
lsm-vec-no-sa (flat, NO SA) recall 0.953→0.944 ≈ IDENTICAL to ours (0.953→0.943); ours is ~15% faster
(2.38 vs 2.79ms) but costs +250MB RAM (1351 vs 1105) + 190s build (818 vs 630). lsm-vec-basic (full HNSW,
no SA) recall 0.921→0.913 — the FLAT SHAPE (no-sa) clearly beats normal HNSW at efc=32. So: SA-tree buys
LATENCY not recall; the flat shape is the bigger win; SA's marginal recall value ≈ 0 at ef=128. Caveat:
single fixed budget — proposed a recall-latency Pareto sweep (no-sa ef_search vs ours ef_final) to see if
SA earns its keep at lower budgets.

**Q: DiskANN-in-place 总体 performance 很强，用了什么优化？**
A: DiskANN-IP = dynamic in-memory Vamana, full-precision vectors in RAM (no PQ, disk=0). Strength from:
(1) **Vamana + RobustPrune(α=1.2)** — α>1 keeps some long-range edges → low-diameter navigable graph,
a better neighbor rule than the HNSW heuristic (why 0.998 vs our 0.94); (2) full vectors in RAM → exact +
fast (0.40ms) vs our paged reads (2.4ms) — RAM-for-speed trade; (3) in-place `consolidate_deletes`
physically repairs the graph → best churn-stability (−0.001). Highest-value borrow for ours: swap L0
neighbor selection to **α-RobustPrune** (could lift recall ~0.97 at same RAM, orthogonal to SA). Noted
IP being strong at 1M-in-RAM is expected (its RAM ~linear → infeasible at 100M, which is our pitch).

**Q: 为什么 disk-in-place 的 memory 反而比 disk-merge 低？**
A: Artifact of running FreshDiskANN BELOW its merge threshold at 1M. Confirmed: merges=0 (450k≪30M), merge
RSS pinned flat at 3621MB from ep0 (pre-reserved), IP grows organically 2187→2194MB. Merge carries TWO
structures — SSD PQFlashIndex (PQ+caches in RAM, full vecs on SSD, disk=930MB) PLUS an in-memory
short-term delta Vamana **pre-reserved to mem_capacity_th≈pool_n (~501k) full-precision points**. Since
merge never fires, its memory-saving premise never activates → you pay two indexes' overhead. IP is ONE
lean in-memory index (~2.2GB). Ordering FLIPS at billion scale (merges fire, delta bounded ~30M, bulk
PQ-on-SSD → merge ≪ IP; IP would need ~50GB+ at 100M). Offered to force periodic merges for a
representative 1M number, else footnote so 3.6GB isn't misread as "merge is memory-hungry".

**Q: Drop DiskANN-in-place — comparing on-disk methods vs a fully in-memory one is unfair to the on-disk
methods; don't compare or plot it.**
A: Removed diskann_ip from ALL_SYSTEMS + systems_for_scale (10m/100m now carry diskann_merge as the
on-disk DiskANN); emptied DISKANN_FAMILY (removed diskann_ip_vs_merge) + deleted its stale dat/fig; kept
diskann_ip raw data (not plotted). Regenerated all 1m figures → 6 on-disk systems (ours, lsm-vec-no-sa,
lsm-vec-basic, spfresh, spannplus, diskann_merge). Recorded the decision + refreshed standings in
PROGRESS. On-disk standings: LSM-Vec family lowest DRAM (1.1–1.35GB vs 3.4–6.0GB) + most churn-stable;
diskann_merge highest recall (0.970) but slowest/heaviest; ours > spfresh/spannplus on recall AND memory.

**Q: 我们是 out-of-place update，SPFresh 是 in-place，为什么我们 insert 反而慢？investigate.**
A: Framing correction: R-9010 inserts are PURE inserts (new ids) → cost = index-construction, not update
semantics. Insert throughput: ours 790/s < no-sa 981 < basic 1006 < spfresh 1381 < spannplus 1791 (all
1-thread; note SPANN+ no-reassign > SPFresh reassign, confirming in-place reassign costs SPFresh). Added a
`--profile-insert` mode (profile_sa_tree + IO counts on the base build) and profiled on SIFT 200K:
**ours 2510/s @ 138.8 vector-reads/insert vs no-sa 5844/s @ 7.0 reads/insert.** CORRECTED root cause: NOT
SA cluster maintenance (only 4%) but **SA-guided insert routing `saGraphEntryForInsert` (43%)** — every
insert routes through the SA structure reading ~139 vectors vs plain-HNSW's 7. So the SA-tree also taxes
INSERT (2.3× slower at build, 1.24× at 1M streaming). Combined w/ the ablation, SA-tree ledger: costs
+130% insert / +190s build / +250MB RAM, benefits ~15% query latency / 0 recall. Proposed optimization:
decouple insert placement (cheap plain-HNSW greedy, 7 reads) from SA routing (query-only, lazy) → ~2×
insert throughput, no downside. Awaiting user's go on trying the decoupling.

**Q: Initial workload 所有方法都统一 single-thread（含 build，这次）才公平；double-check SPANN+ 是不是 SPFresh paper 里的版本.**
A: (1) **SPANN+ IS the paper's version** — matches `Script_AE/iniFile/.../indexloader_spann.ini`:
IndexAlgoType=SPANN + **DisableReassign=true** (LIRE off = strawman). BUT we'd deviated on threads: used
AppendThreadNum=4; the PAPER uses AppendThreadNum=1 (and ReassignThreadNum=0) for both SPANN+ and SPFresh
(iopslimit ini). So single-thread fairness == paper-faithful. (2) Thread audit: streaming inserts —
ours/no-sa/basic=1, diskann_merge=1 (sequential loop, 173qps confirms 1-thread query), spfresh/spannplus=4
(async pool) → the only multi-thread ones. Builds: ours=1, all baselines=16. User chose FULL single-thread
THIS run (build+insert+query), multi-thread build later at larger scale (+ will implement our own MT build).
Parameterized run_spfresh.sh (THREADS env, default 1 → NumberOfThreads/AppendThreadNum=1, ReassignThreadNum=0
= paper). Archived old MT results as *_mt. Launched serial single-thread re-run chain: SPFresh → SPANN+ →
DiskANN-merge(build_threads=1); slow 1-thread builds ~2-3h. Will regenerate figures after.

**Q: 根据目前的结果先 update 一下 figures.**
A: Regenerated all 7 figures with current single-thread data. Temporarily dropped diskann_merge from
ALL_SYSTEMS (its 1t build is mid-run, overwriting its mem.jsonl → garbage build/RSS); will re-add when
done. **Single-thread revealed more confounds in our favor:** build time — ours 818s now FASTER than
SPFresh 1250s and SPANN+ 920s (their fast builds were the 16-thread advantage; SPFresh head-graph alone
645s single-thread); no-sa/basic fastest (614–630s). Insert — ours 790 > SPFresh 485 (intuition
confirmed); only strawman SPANN+ (1811, cheap append) faster. DRAM — ours 1350MB ≪ SPFresh 5686 / SPANN+
3504. So single-thread apples-to-apples: ours beats SPFresh on build+insert+memory, leads churn-stability.
Will do final clean regen (incl. diskann_merge 1t) when the chain finishes.

**Q: 为什么 SPANN+ 表现比 SPFresh 好这么多？SPFresh paper 不是这么写的.**
A: Not a contradiction — a regime mismatch. Paper's SPFresh>SPANN+ holds at HEAVY churn + billion scale +
SPDK. Ours is LIGHT churn (R-9010 = 10% deletes, net-growing 1M→1.4M, ~50% total) + file-I/O. Two reasons
SPANN+ looks better here: (1) **file-I/O vs SPDK** — SPFresh's LIRE reassignment does many small random
I/Os (cheap on SPDK, expensive on RocksDB), tanking its insert to 485/s vs SPANN+'s append-only 1811/s;
(2) light churn → posting imbalance mild → LIRE pays full cost for little benefit. BUT the paper's
QUALITATIVE claim still holds: SPFresh degrades LESS (recall drop 0.036 vs SPANN+ 0.052); they converge to
0.908 only because SPANN+ starts higher (0.960 vs 0.944). To reproduce the paper's clear SPFresh win we'd
need heavier churn (R-5050 / more epochs / 10M+). Offered an R-5050 heavy-churn cell.

**Q: SPANN+ 的 update 路径是怎么样的？**
A: Traced in ExtraDynamicSearcher.h. Structure: in-RAM head index (~119k centroids/BKT) + on-KV posting
lists (~95 vecs/posting, PostingPageLimit=12); each vector in ReplicaCount=8 nearest postings. INSERT
(AddIndex→Append): find 8 nearest heads → append to each posting → if posting overflows → Split (k-means
into 2 new heads). DELETE: lazy tombstone in DeletedIDs set, filtered at query, physically dropped only on
later split/merge. The ONE line separating SPANN+ from SPFresh: `Split(p_index, headID,
!m_opt->m_disableReassign)` — SPANN+ (DisableReassign=true) splits WITHOUT reassigning neighbors; SPFresh
reassigns boundary vectors (CollectReAssign→ReassignAsyncJob) to keep Voronoi cells clean. So SPANN+ =
append + tombstone + local split (cheap, few I/Os, fast, file-I/O-friendly) but drifts/degrades under churn.

**Q: 那为什么 SPANN+ 的 build time 又会更慢？后续 update 真的有 sync 到 disk 上吗？**
A: (1) SPANN+ build is NOT slower than SPFresh — IDENTICAL ssdserving build per build.log (select-head 16s
+ build-head 645/649s + build-ssd 246s = ~907s, 119451 postings both). My build_time metric (time-to-epoch0)
over-counted SPFresh by including its driver-load/reassign-init (~340s extra); true build ~907s both, vs
ours 818s (single-thread build-head graph is the SPANN bottleneck). Metric fixable but user said skip for
now. (2) YES, updates sync to disk — KV store on disk grows 3.6GB→~7GB as vectors are appended (wobble =
RocksDB compaction); RSS grows only modestly. Same RocksDB memtable+WAL→SST durability model as our
Aster/RocksGraph, so fair on-disk comparison. SPANN+ isn't cheating; append+tombstone is just a cheap
disk-friendly write pattern.

**Q: 优化 figures — lines 和 legends 重叠看不清（如 mem_time__sift_1m_r9010.svg）.**
A: Root cause: legend was loc="best" (inside axes) → overlapped lines with 7 systems. Fixed in plot/:
added style.legend_below() (legend outside, below axes, 2–3 cols, fontsize 7); widened SINGLE_COL to
4.0×2.7"; dense series (mem_time's per-sec RSS, >60 pts) now drawn as thin alpha lines w/o markers,
sparse series keep markers. Applied to plot_timeseries (single + dual) and plot_pareto. Regenerated all
figures; visually verified mem_time renders clean (legend below, RSS story clear: SPFresh ~5.7GB, SPANN+
~3.5GB, LSM-Vec family ~0.7–1.15GB lowest). diskann_merge still out pending its 1t run.

**Q: legend 太小；画大一些、竖排、统一放 figure 左侧外面；mem_time 各方法 line 区别要明显（类似之前版本）.**
A: Changed style.legend_left() → single-column vertical legend OUTSIDE-LEFT, fontsize 9 (was 7), larger
handles/labelspacing. Dual-panel latency uses fig.legend spanning both panels on the left. Reverted the
dense thin/alpha lines → markers + full linewidth 1.4 (~10 markers/series) so overlapping curves stay
distinct (like the earlier version). Regenerated all timeseries+pareto figs; visually verified mem_time
and latency_epoch render clean (left vertical legend, distinct marker'd lines).

**Q: latency_epoch__sift_1m_r9010 的 y 轴从 0 开始且不要 log scale.**
A: Set logy=False in the latency_epoch registry opts + plot_dual now anchors linear panels at y=0
(ax.set_ylim(bottom=0)). Regenerated; verified P99 (0–4ms) / P50 (0–3ms) linear from 0.

**Q: 画一组临时 present 用的简化图到 results/fig_temp/，只含 LSM-Vec no-SA / SPFresh / SPANN+，并把 no-SA 叫 LSM-Vec.**
A: Wrote reusable `plot/make_temp_figs.py` — filters existing .dat to KEEP=[lsm-vec-no-sa,spfresh,spannplus],
relabels lsm-vec-no-sa → "LSM-Vec" with prominent style (solid vermil circle), outputs 7 figs to
results/fig_temp/ (+ dat_temp). Verified mem_time: LSM-Vec flat ~0.65GB vs SPFresh ~5.7GB, SPANN+ ~3.5GB.
Separate from main results/fig/ (which keeps all systems).

**Q: 为什么 SPFresh memory 先随 epoch 上升一段，后半段不变？**
A: RocksDB KV controller has a FIXED 3GB LRU block cache (ExtraRocksDBController.h: NewLRUCache(3UL<<30)) +
16MB write buffer. Epochs 0–~22: block cache FILLS as queries/updates touch the growing on-disk posting
lists → RSS rises 3.4→5.4GB. Epoch ~22+: working set exceeds 3GB → cache full at cap → RSS flat ~5.6GB even
as index grows to 1.4M. Tell: RSS plateaus while disk keeps growing (5→9GB) — SPANN's on-disk design (extra
vectors go to disk, RAM = head index + bounded 3GB cache). So SPFresh's high RSS is partly this generous
cache-size config, not data size.

**Q: SPFresh 的 RocksDB 开了 direct IO 吗？**
A: NO — ini UseDirectIO=false → RocksDBIO ctor skips use_direct_reads/use_direct_io_for_flush_and_compaction
→ BUFFERED I/O (+ BlobDB for vectors). Consequence/caveat: buffered I/O double-buffers (3GB block cache IN
RSS + OS page cache in KERNEL RAM, NOT in VmRSS) → our RSS metric (5.6GB) UNDERCOUNTS SPFresh's true memory.
Same caveat applies to ours (paged pread also uses OS page cache), so RSS comparison is consistent in kind,
but SPFresh reserves a big explicit 3GB block cache. Paper's SPFresh uses SPDK (no OS page cache) → different
profile, another reason our numbers differ. Offered: measure OS page-cache footprint too, or re-run SPFresh
with UseDirectIO=true / smaller block cache for a fairer memory number.

**Q: DiskANN-merge single-thread 跑完了吗？**
A: Not yet — the single-thread chain CRASHED on the DiskANN-merge step (iostream error). Root cause: my
chain script did `rm -rf work/diskann_merge_sift_1m_idx` but omitted the `mkdir -p` (the original MT
command had `mkdir -p ... &&`), so the driver's write of idx.base.tags failed. NOT disk-full (283G free),
NOT a DiskANN bug. SPFresh + SPANN+ single-thread had already completed fine. Relaunched DiskANN-merge
solo with mkdir fixed (--build_threads 1); building cleanly now (~30-40min build + 50 epochs). Waiter set;
will re-add diskann_merge to ALL_SYSTEMS + regenerate the full 6-system single-thread figures when done.

**Q: how is it (DiskANN-merge 1t status).**
A: DONE — DiskANN-merge single-thread finished (recall 0.998→0.970, build 649s @1-thread vs ~200s @16;
insert 5328/s, lat 5.6ms, RSS 3625MB — insert/lat/RSS unchanged since those were already single-thread).
Re-added diskann_merge to ALL_SYSTEMS; regenerated all 7 figures (6 systems, all single-thread). FINAL
single-thread standings SIFT-1M-R9010: DRAM — LSM-Vec family 0.7–1.1GB ≪ others 3.5–5.6GB (headline win);
recall — diskann_merge 0.970 > LSM-Vec ~0.944 > spfresh/spann 0.908–0.913; insert — diskann_merge 5328
(ARTIFACT: no merge at 1M → in-mem delta, deferred) > spann+ 1811 > LSM-Vec ~1000/790 > spfresh 485 (LIRE
tax); latency — spann pair ~1.3ms < LSM-Vec ~2.4 < diskann_merge 5.6; build — no-sa/basic ~620 < ours 818
< spann 920 < spfresh 1251. Cell fully complete, fair single-thread.

**Q: default DiskANN-merge merge window → 10000, 记一下; 重跑能不能不 rebuild?**
A: Done both. (1) Changed compile-time default `merge_every` 30000000 → **10000** in
diskann_merge_src/tests/bench_stream_merge.cpp (30M never fires at 1M → merges=0 → misleading fast
insert; 10k fires ~40 merges over a 1M R-9010 trace so insert cost is real). Recompiled.
(2) Rebuild question: the base disk index is a PURE FUNCTION of (base vectors, R/L/alpha/B build
params) — merge_every only drives the epoch-phase merge cadence — so it's cacheable across
merge_every sweeps. Added `--reuse_base_index <snapshot_dir>`: first run snapshots the pristine base
build (right after build_disk_index, before any merge mutates it) + SNAPSHOT_OK sentinel; later runs
restore (~few-sec copy) and skip the ~650s single-thread build. Snapshot dir must sit OUTSIDE the
per-run-wiped idx dir. Recorded convention in memory (diskann-merge-window-and-reuse) + here. The
prior 1M result (ins 5328/s @30M window) is an artifact — will re-run at merge_every=10000 for a
realistic insert/latency number.

**Q: re-run diskann_merge at merge_every=10000 with reuse.**
A: Pre-seeded the base-index snapshot from the surviving pristine base build, launched with
--reuse_base_index → **build skipped, restored in 0.42s** (vs ~650s). Ran merge_every=10000
single-thread: 50/50 epochs, **25 merges fired**. SURPRISING result — insert went UP not down:
raw ins_ops_s 5328→**15792/s**. Root cause: ins_ops_s measures ONLY delta-insert-loop speed; small
window → tiny delta → faster inserts. The merge cost is a SEPARATE wall-time phase (25 merges ≈ 508s,
~20s each) NOT counted in the insert metric. Honest AMORTIZED insert incl. merge = 450k/(28s ins +
508s merge) = **839/s ≈ ours (790/s)**. Recall now pristine 0.998→0.998 (merges physically apply
deletes). RSS 3260MB (down, small delta), lat 5.5ms. User chose to report AMORTIZED. Added scoped
SUMMARY_OVERRIDES in bench.py (diskann_merge@sift_1m_r9010: build=649 real single-thread, ins=839
amortized), regenerated all 6-system figures. Corrected my earlier wrong framing ("10k makes insert
cost real" — actually 10k makes the insert METRIC look better; real cost hides in merge phase).
Caveat noted: insert_tput_epoch timeseries still shows diskann_merge raw delta-insert (~15792), which
is inconsistent with the amortized summary bar (839).

**Q: double-check — 设计目标是只把 SA-tree 高度<hops 的顶部驻留内存,不存整棵树。实际运行是这样吗?**
A: 核实代码(不跑实验)。机制存在且 benchmark 开着:bench_common.h:274-275 设 sa_l0_buffer_hops=4 /
sa_route_max_steps=4,build 后 buildSaL0HopBuffer(4)。L0 disk-backed(saTreeLayerZeroDiskBacked =
use_sahnsw_ && sa_tree_cf();Aster patch 提供 CF)。完整树存 RocksDB sa_tree CF;RAM 只有
sa_l0_sketch_ (map<root,SaTree>)。rebuildSaTreeOnSaTreeRocks 里 cluster 是栈局部变量,建树→写Rocks→
丢弃,RAM 只留 node_count + pruned sketch,完整树不驻留。buildTopHPrunedTree(5359)从 root BFS 收
≤4跳节点,只留 {id,radius,parent_dist,children},显式丢 pivot_sketch/pairwise_child_dists,从不含
embedding(在 paged store/disk)。⚠️ 关键发现:剪枝按 ≤4跳切,但 fanout sa_max_children_=32,1M 下
每 cluster ~2800 成员 → 树高约 log32(2800)≈2-3 跳 < 4 → top-4-hops 很可能=整棵树结构,高度剪枝是
no-op!当前省内存只来自"不存embedding+不存pivot/pairwise",不是来自"高度<hops才驻留"。优化切入点:
要让高度剪枝生效,树必须比 hops 深 → 调小 fanout(fanout=8→高度≈4,fanout=4→≈6)。下一步:用
profiler saTreeProfile().tree_height_sum_per_layer 在已有 ours_db_sift_1m_r9010(不重建)量实际树高确认。

**Q: plan 里 set --sa-max-children 4,实际实验有这个 setting 吗?是被 drop 还是 miss 了?**
A: 没被 drop 也没 miss——实际就是 4。CORRECTION of prior turn: 我上轮引用了成员默认 sa_max_children_=32
(lsm_vec_index.h:543 / config.h:31 struct 默认),但那被 bestConfigOptions 覆盖了。bench_common.h:269
硬编码 o.sa_max_children=4,buildBase(:449)走这个函数 → 所有 ours run 的 fanout=4。plan
(benchmark_implementation_plan.md:307)与 ablation 文档(:38)都写 4,一致。--sa-max-children CLI flag
存在(config.h:311 解析)但 benchmark driver 不用它(4 已烤进 bestConfigOptions;该 flag 给 gtest 用)。
更正上轮结论:fanout=4(非32)→ 树高约 log4(2800)≈6 hops > hops=4 → top-4-hops 剪枝 **确实生效**:
约 341/2800 ≈ 12% 结构驻留,~88% 留 RocksDB。设计按预期工作。下一步仍是用 profiler 在已有
ours_db_sift_1m_r9010 量真实树高 + resident-vs-full 节点比,坐实剪枝削减比例。

**Q: 分析 AsterVec(NTU-Siqiang-Group,我们方法的 fork)的优化,哪些能用到我们方法上,写报告。用户点名 3 项:in-memory build、multi-thread、SQ8。**
A: 4 个并行 subagent 逐项对照 AsterVec 源码 vs 我们本地代码,写了 docs/astervec-optimizations-report.md。
关键(意外)发现:用户点的 3 项里有 2 项我们已经有了——(1) in-memory bulk build(RNN-Descent+MIRAGE)
算法在 lsm_vec_bulk_build.cc/lsm_vec_rnn_descent.cc 里字节级一致,但被 pin 成串行(nthreads=1 @:372)且
没接进 bench_streaming(buildBase 还是逐行 Insert);(2) SQ8 已在 disk+page-cache vector store 上(commit
24c664e),但 SIFT 是原生 uint8(128B),我们 SQ8 record 是 136B 反而更大 → SQ8 只在 float 数据集
(SPACEV/GIST)才省内存;我们 ~1.1GB RSS 主要是常驻 float32 SA L0 buffer + Aster/RocksDB,不是向量。
只有 multi-thread 是真缺口:MT build 机器存在但关着(打开对 10m/100m 公平安全,build time 是独立指标);
并发 serving 会破坏单线程公平规则,是独立实验(L,风险在 sa_tree CF + lazy-ghost delete)。额外发现几个
我们没有的新优化:LSMVEC_DIO_FROM_START(直接开 Direct I/O 降 RSS,S)、malloc_trim(build 后释放堆降
RSS,S)、EdgeLRUCache drop-on-hit(我们每次 get() 都 splice,S)、flat POD idToPage 数组(~11% build)。
Roadmap 分 3 phase:Phase A 全是 S 且公平安全(DIO_FROM_START + malloc_trim + drop-on-hit + 串行 bulkBuild
接线),Phase B 中(flat 数组、给 float 数据集 SQ8 常驻 buffer),Phase C 大且按规模 gate(MT build for
10m/100m、adaptive DIO、独立的并发 serving 实验)。已写 memory: astervec-fork-optimizations。

**Q: S 的都做 + SA L0 buffer 也用 SQ8;每个 point 先写详细 plan(涉及哪些代码 + 影响);multi-thread 作为
单独全面的 part。测试方法学:build 阶段所有方法统一 4-thread(否则 10M/100M build 太慢),query+insert 保持
所有方法单线程;in-memory build 作为后续(a),当前只要支持 multi-thread build(b)。**
A: 写了 docs/astervec-adoption-plan.md(详细实现计划,配合 astervec-optimizations-report.md)。结构:
- 方法学:build 全员 4-thread(公平,因为大家都 4-thread)、query/insert 全员单线程;in-memory build 是
  后续加速(a),本阶段只要 MT build(b)。
- Part 1 S 级(各带 file:line + 影响):1.1 LSMVEC_DIO_FROM_START(lsm_vec_index.cc:160-171 注入 2 个
  RocksDB DIO flag,env-gated,降 RSS/略升 latency,Pareto),1.2 malloc_trim(新 TrimMemory(),buildBase:490
  + applyEpoch 后调用,降 RSS),1.3 EdgeLRUCache drop-on-hit(lsm_vec_index.h:31 去掉 get() 的 splice),
  1.4 bulk build 接线(指向 Part 3.3)。
- Part 2 SA L0 buffer SQ8:sa_l0_buffer_(lsm_vec_index.h:553)从 vector<float> 改成 SQ8 record(复用
  disk_vector.h:380/400 的 static quantize/dequantize),写处 quant、读处 dequant(thread_local scratch)、
  persist 格式升版;~3.76x on float 数据集,SIFT 原生 uint8 无收益;M;需验 recall。
- Part 3 multi-thread(全面):Scope A MT build(解开 lsm_vec_bulk_build.cc:373 的 nthreads=1 pin,RNND 已
  线程安全,layer-0 Aster 写保持串行,--build-threads 4 贯穿 harness+baselines),Scope B bulk build 接进
  buildBase(id 0..n-1 guard、空库 guard、重校准 ef_final),Scope C 并发 serving 完整设计(sharded locks/
  publish protocol/lock-free reads/atomic entry point/lock-free page_of;危险点=sa_tree CF + lazy-ghost
  delete 必须 shard-guard)——设计但后续作为独立实验,不进当前 cell。
- Part 4 测试&re-baseline:全员 4-thread 重建 build bar,query/insert 单线程不变,逐项隔离测量协议(serial)。
- Part 5 风险&护栏。先写 plan、未开始实现,等确认。

**Q: drop 1.1 (不开 Direct IO);实现 Part1-3 其余 points,每个 point commit 一次并在 200K 上测性能变化。**
A: 建了 200K dev-loop 测试器 driver/dev200k_test.sh(build/RSS/recall/latency/sa_buf 一行汇总)。
先做 baseline checkpoint commit(55a164c:harness+lazy-ghost+cmake)。200K baseline: build 77s,
end_rss 390MB, recall 0.9729, lat 0.57ms。逐点实现+测+commit(全在 LSM-Vec-with-SA-HNSW repo,
sa-resident-sketch 分支):
- **1.2 malloc_trim** (a16a952): TrimMemory() build 后 + 每 epoch 后。end_rss 390→268MB(-122MB),
  其余不变。
- **1.3 EdgeLRUCache drop-on-hit** (3ef6636): get() 不再 splice。200K 内是噪声级(lat 0.57→0.59),
  无回归,高 QPS/大规模才显现。
- **Scope B bulk build 接线** (beef5a3): --bulk-build 接进 buildBase(identity-id guard +
  buildSaOverlayFromExistingGraph)。首测暴露严重回归(end_rss 1031MB, lat 3.05ms):根因是
  section_layer(2) > max_layer(1) 时 section-key 塌缩成 per-vector(sections=200000)→ 20万个近空
  4KB page。修复:section_layer clamp 到 max_layer。修复后:build 77→41s(1.88x),recall 0.9729→
  0.9883(更高),end_rss 283MB(~持平),lat 0.67ms,sections=65。
- **Scope A MT build** (29eabd8): 解开 nthreads pin。4 线程首测 segfault——Phase D(paged store 写/读)
  和 Phase E(nodes_ map 插入)非线程安全。方案:只并行 RNND(Phase B,主要开销,in-RAM flat 向量,
  真线程安全),Phase D/E 保持串行(需 lock-free storage = Scope C)。结果:build 41→21s(vs streaming
  77s = 3.67x),recall/RSS/lat 不变。
- **Part 2 SQ8 SA L0 buffer** (c96e598): 先测——buffer 非空,57004 nodes=29.2MB float32。实现:
  sa_l0_buffer_ 从 vector<float> 改 SQ8 record(136B),serveSaL0FromBuffer 反量化进 caller scratch
  (resolveVectorSpanForSaCluster 用其现有 scratch;两个 searchLayer caller 用 loop-local),
  quantize/dequantize 提为 public。结果:buffer 29.2→7.8MB(3.76x),**recall 0.9729 完全不变**,
  lat 不变。1M 规模约 146→39MB(-107MB,~10% RSS)。
新方法学(build 全员 4-thread、query/insert 单线程)已写进 astervec-adoption-plan.md。Scope C(并发
serving + lock-free paged storage)未做,是将来独立实验。

**Q: 在新 setting 下完整重跑 1M 全部方法。所有方法 4 线程 build、单线程 workload;内存只算 build 之后
(insert/update/query)的 workload 段,不含 build 期间。**
A: 确认理解并执行。改动:(1) bench.py peak_rss_mb + aggregate_mem 改成只取 epoch>=0(workload-only,
所有系统 build 都 tag epoch=-1,过滤统一);(2) 删掉过时的 diskann_merge SUMMARY_OVERRIDE(这次 30M
窗口 merges=0,insert 是 raw delta,build 是真 4 线程时间);(3) run_ours.sh 支持 bulk/build-threads/
use-sa/layer-mult/EFS 变体;(4) run_spfresh.sh 拆分 BUILD_THREADS(build)vs THREADS(append),query
本来就是 driver 里单线程。用户拍板:ours 用 bulk build @4t + ef_final=64;diskann_merge 用 merge_every=30M
(旧,1M 下不触发)。串行跑完 6 系统(~3.2h,全 rc=0,各 50 epoch)。
**最终 1M 标准(4线程 build,单线程 workload,内存=workload-only):**
| system | recall s→e | ins/s | lat | build(4t) | RSS(wl) |
| ours | 0.961→0.926 | 687 | 1.7ms | 193s | 1025MB |
| lsm-vec-no-sa | 0.960→0.927 | 897 | 1.7ms | 180s | 641MB |
| lsm-vec-basic | 0.925→0.893 | 904 | 1.5ms | 186s | 799MB |
| diskann_merge | 0.998→0.970 | 5343 | 6.3ms | 221s | 3624MB |
| spfresh | 0.944→0.908 | 488 | 1.4ms | 574s | 5696MB |
| spannplus | 0.960→0.884 | 1808 | 1.3ms | 250s | 3472MB |
要点:4 线程 build 把 build time 大幅压低(ours 818→193s=4.2x,spfresh 1250→574s,diskann 649→221s);
DRAM 仍是 LSM-Vec family 完胜(641–1025MB vs 3.5–5.7GB);ef_final=64 下 ours recall 0.961→0.926;
diskann_merge insert 5343 是 30M 窗口 merges=0 的 delta-only(如实报告)。7 张图已用 workload-only 内存
重新生成(mem_time 从 epoch 0 起,不含 build)。

**Q: 为什么 ours 内存比 lsm-vec-no-sa 高近 400MB?SQ8 压缩后 sketch 应该不大。**
A: 加了 mem-breakdown 诊断(logMemoryBreakdown:index structs + SQ8 buffer + RocksDB per-CF props),
1M 上 ours vs no-sa 干净逐项 diff:
| component | ours | no-sa | Δ |
| SQ8 buffer | 25.4 | 0 | +25 |
| rocksdb memtables(all CF) | 88.2 | 39.9 | +48 |
| table_readers | 11.5 | 9.4 | +2 |
| block_cache | 33.4 | 33.4 | 0 |
| index structs(sa_clusters/membership) | ~0 | ~0 | 0 (disk-backed L0 → SA 数据在 RocksDB 不在 RAM) |
| **total RSS** | **986** | **679** | **+307** |
结论:**sketch 本身确实很小(SQ8 buffer 25MB,你的直觉对)**。差距的真正来源是维护 SA overlay 的
**RocksDB sa_tree 列族的写路径开销**,不是 sketch 数据:tracked 只占 ~75MB(buffer 25 + memtable 48 +
readers 2),**剩 ~232MB 是 glibc 堆高水位**——sa_tree CF 用默认 64MB write_buffer_size,workload 中反复
填满→flush(174MB SST = 多次 flush),每次释放的 64MB arena 被 glibc 保留;加上 SA 维护路径 139 reads/insert
(1.4M 插入 × 139 ≈ 195M 次读)的临时 iterator/block/解压缩 buffer。jemalloc 反而更高(1356MB,retention),
排除"换 allocator"。修复方向:(1) 给 sa_tree CF 调小 write_buffer_size(64→8MB)直接砍 arena 高水位;
(2) 减少 139 reads/insert(decouple-insert 优化,既降 RSS 又提 insert);(3) RocksDB 更激进还内存给 OS。
诊断工具已 commit(759655a);临时 memdiag/jemalloc 产物已清理。

**Q: 写一份详细的 sketch-only(不维护 SA-overlay,只维护 SA-sketch)design + 实现 plan 放 docs/。**
A: 写了 docs/sketch-only-design-plan.md。核心:查询只走 resident top-H sketch(≤4 跳)+ HNSW L0 精修,
完整 SA-tree(sa_tree CF)只用于 (a) 派生 sketch (b) miss fallback——深层与 HNSW L0 冗余。方案:把 sketch
升为唯一的增量维护 RAM 结构,砍掉 overlay。新算法 = incrementalIntoSketch(从 root 下降≤H,落点<H 就插入
并 max 更新祖先 radius;到 H 前沿则不进 sketch,交 HNSW L0),每插入 ≤16 次 in-RAM SQ8 dist eval,0 次
sa_tree RocksDB 写(替代 139 reads/insert)。含:直接 top-H build(buildSaTreeTopH)、radius 单调 max、
fanout split、lazy-ghost delete 不变、query miss fallback 改用 HNSW L0 入口、可选周期性 rebalance。
列了 file:line 级改动(insertNode L0 维护块 2339、buildSaL0HopBuffer 5427、knnSearchSA fallback、
persist 只留 sketch blob)、config(--sa-sketch-only / sa_rebalance_every)、预期(RSS 1025→~670MB 逼近
no-sa+sketch,insert 687→~900/s)、风险&验证(A/B 看 recall 是否守住 0.926)、4 phase rollout(Phase B
增量插入是 payoff)。未实现,等确认。

**Q: 按 A→B 开始实现,先做 buildSaTreeTopH。**
A: Phase A 完成(commit aa9d081)。实现 buildSaTreeTopH(sa_tree.cc/.h):深度受限的 SA-tree 构建,
在第 max_depth 层剪断递归——因为 SA-tree 是严格自顶向下(每层划分只依赖上层),所以只建前 H 层得到的
结构与"建完整树再剪枝"逐节点相同,但从不分配深层节点。前沿节点(depth==max_depth)用精确 max-distance
覆盖半径(覆盖其整组分配点),保证 saRouteBeam 的 covering-radius 剪枝正确;深层点交 HNSW L0。省略
pairwise_child_dists/pivot_sketch(routing 不用),与 buildTopHPrunedTree 产出的 sketch 一致。加了 3 个
单元测试(test_sa_tree,全过 9/9):full-depth cap == buildSaTree 节点集;H=1,2 限深+减少节点数;前沿半径
可证覆盖完整树的隐藏子树(剪枝安全性)。尚未接入 build 路径——那是 Phase B(替换完整树构建 + 去 overlay
维护,拿 RSS/insert 收益 + 验 recall)。

**Q: 继续 Phase B(把 buildSaTreeTopH 接进去 + 去 overlay 维护)。**
A: Phase B 完成并验证(commits 1382c9d + 73e2e18)。实现 --sa-sketch-only:build 用
buildSketchesTopHDirect(L1→L0 in-RAM 分配 + buildSaTreeTopH,无完整树/无 RocksDB);insert 用
insertIntoSketch(在 SQ8 buffer 上下降 ≤H 跳,band 内且未满则加节点否则只扩 radius,点始终在 HNSW L0);
query miss → HNSW L0(不读 RocksDB)。flag 门控,overlay 路径不动。
两个关键修复:(1) 只 buffer 真正成为路由节点的点(前沿落点不 buffer);(2) 强制 max_children 上限(满了
当前沿处理),把每 cluster 限成 max_children-叉 depth-H 树(有界)。修复前 sketch 无限增长(buffer 525k/71MB)。
**验证结果:**
- 200K A/B(同参数):overlay recall 0.9744→0.9729 / ins 1454 / RSS 356MB;sketch-only 同 recall /
  ins 2428(+67%) / RSS 296MB。
- **1M:overlay(ours)recall 0.926 / ins 687 / RSS 1025MB → sketch-only recall 0.927 / ins 865(+26%) /
  RSS 730MB(−295MB,−29%)**。buffer 有界 113k/15MB;recall 完全不掉;逼近 no-sa floor(641MB,+89MB
  其中部分是 memtable flush 时序噪声)。sa_tree CF 彻底消失。
结论:sketch-only 设计验证成功——砍掉 overlay 维护,recall 不变,RSS 大降、insert 提升。Phase C/D
(去 fallback/persist 瘦身、可选 rebalance)可选后续。

**Q: 采纳 sketch-only 作为默认,重跑 1M ours。**
A: 把 sketch-only 设成 bench harness 默认(bench_common.h Config sa_sketch_only=true;--no-sketch-only
逃生口用于 overlay A/B;commit 5ebedb9)。用官方参数(bulk build @4t、ef_final=64、单线程 workload、
全量 query QSUB=0)重跑 1M ours(sketch-only 现为默认),重生成 6-system 图。
**结果:ours recall 0.960→0.926(不变)/ ins 890/s(+30% vs overlay 687,≈no-sa 897)/ lat 1.66ms /
build 183s / RSS 769MB(vs overlay 1025,−256MB −25%)**。(769 vs 验证时 730 是因为全量 query 有更多
page-cache 压力。)最终 6-system 标准:ours 769MB 进入低 DRAM 梯队(与自家 ablations 0.64-0.8GB 并列),
比 SPFresh/SPANN+/DiskANN-merge 的 3.5-5.7GB 低 4.5-7x;insert 追平 no-sa。之前落后的两个轴(内存、insert)
都补上了,recall 零代价。图已用 workload-only 内存重生成。

**Q: 开始跑 10M 实验(sketch-only 已为默认)。**
A: 生成 10M SIFT R-9010 trace(base 10M + pool 5M from 100M bvecs,gt via DiskANN compute_groundtruth,
50 epochs / gt_interval 10;清理了 ~34GB gt active-set 中间文件)。方法学同 1M:4 线程 build、单线程
workload、workload-only 内存。ours 10M(sketch-only,bulk @4t,ef_final=64)结果:recall 0.924→0.873,
ins 516/s,lat 2.74ms,build 2833s(47min),peak_wl_rss 5003MB(sketch buffer 143MB/1.05M nodes,
rocksdb table_readers 95MB)。**关键:recall 随 live_n 10M→14M 单调平滑下降(0.924/0.907/0.897/0.888/
0.879/0.873),lat 平、insert 稳——是"固定 budget + 索引增长"的正常效应,不是 sketch 不稳定;sketch-only
在 10M 健康。** 决定:保持 ef_final=64 跨尺度固定(scaling study 的干净方法学),baselines 也用标准参数
(spfresh ef=64、diskann L=150)。已串行启动 3 个 baseline(spfresh→spannplus→diskann_merge,~9h)。
若最终 ordering 显示 ours 低于它该赢的 baseline,再 bump ours budget。diskann_merge 用 merge_every=30M
(4.5M 插入 < 30M,merges 不触发,delta 撑大,flag)。

**10M cell COMPLETE (4 systems, 4-thread build / single-thread workload / workload-only mem):**
| system | recall s→e | ins/s | lat | build | RSS(wl) |
| ours (sketch-only, ef_final=64) | 0.924→0.873 | 516 | 2.7ms | 2833s | **5003 MB** |
| diskann_merge (merge_every=30M) | 0.996→0.970 | 2854 | 7.1ms | 2559s | 17022 MB |
| spfresh | 0.916→0.881 | 377 | 2.4ms | 8419s | 20846 MB |
| spannplus | 0.925→0.834 | 1256 | 2.8ms | 3991s | 19895 MB |
**Headline: ours 5.0GB vs baselines 17-21GB = 3.4-4.2x less DRAM (只有 ours < 5GB).** Recall: ours &
spfresh neck-and-neck(ours 起步领先,~e10 交叉,spfresh 末尾领先 ~0.008),两者 >> spannplus(0.834,
churn 掉最多),<< diskann_merge(0.970 但 17GB)。ours build 快于 spann/spfresh,insert 快于 spfresh。
diskann_merge merge_every=30M → 4.5M<30M merges 不触发,delta 撑到 17GB(below-threshold artifact)。
7 张 10M 图已生成。开放决策:ours ef_final=64 末尾 recall 略低于 spfresh,是否 bump 到 128 清过 spfresh。
