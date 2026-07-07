# Benchmark Progress Ledger

Runbook: `docs/benchmark_implementation_plan.md`. This file tracks phase status, the
per-(system,dataset,scale,ratio) run matrix, resolved decisions, and anomalies.

## Environment (recorded once)

- **Server:** Intel i9-13900K, 32 threads (24 cores), 125 GiB RAM, Ubuntu 22.04.5, kernel 6.8. Bare metal, uid 1002, non-passwordless sudo, Secure Boot ON.
- **Storage:** ONE NVMe (WD SN810 2 TB), system+Windows dual-boot disk, ext4 `/` with ~323 GB free (the disk budget). Two SATA HDDs unusable for SSD bench.
- **Toolchain:** gcc 10.5, g++ 10.5, cmake 3.22.1, python 3.13.9, make. NVMe IOPS (fio) + compiler versions to be recorded into each result file.
- **SPDK decision:** NOT viable (Secure Boot on, no dedicatable NVMe) → SPFresh/SPANN+ run **file-I/O mode**. Footnote on every SPFresh result.

## Decisions (all LOCKED 2026-06-29, per runbook §7)

1. SPDK → file-I/O fallback (B), forced.
2. DiskANN → run BOTH variants (IP + merge) at 1M, carry the winner to 10M/100M.
3. Concurrency → single-thread batched-epoch first; concurrent = later task.
4. Recall → report directly (no band); calibrate ours ≥ baselines (§7.1).
5. Split → base N + disjoint pool 0.5N; 50 epochs; gt every 10; R-9010 delete = uniform over all live ids.
6. Scope (user) → do everything incl. baselines. sudo: user installs apt deps via `!` (option A).

## Phase status

| phase | what | status | notes |
|-------|------|--------|-------|
| 0 | workspace + ledger | ✅ done | driver/ plot/ results/ work/ + siblings diskann/ spfresh/ + this file |
| 1 | server profile / SPDK | ✅ resolved | file-I/O fallback |
| 2.1 | build OURS | ✅ done 2026-06-29 | needed Aster `sa_tree` CF patch (graph.h); sanity: test_sa_l0_buffer 15/15, test_lsm_vec_db 21/21 green |
| 2.2 | build DiskANN (cpp_main, both variants) | ✅ done 2026-06-29 | apt deps installed; `diskann/build/apps` has test_streaming_scenario, search_memory_index, build_memory_index, build_stitched_index, utils/compute_groundtruth. IP variant ready; merge variant = hand-assembled flow (§2.2). |
| 2.3 | build SPFresh + SPANN+ | ✅ done 2026-06-29 | Built file-I/O mode (no SPDK). Binaries in `spfresh/Release/`: `ssdserving` (SPFresh+SPANN+ via ini), `usefultool` (GenTrace/ConvertTruth/CallRecall), `spfresh`. RocksDB PtilopsisL fork built WITH RTTI to local prefix `/home/dmo/SPFresh/rocksdb/_install`. 2 patches (CMakeLists drop SPDK libs; ExtraSPDKController.cpp #ifdef SPFRESH_NO_SPDK). File-I/O backend: ini `[BuildSSDIndex]` UseSPDK=false, UseKV=true, KVPath=<dir>. See `SPFRESH_BUILD_NOTES.md`. |
| 3 | bench_streaming harness (TDD) | ✅ done 2026-06-29 | `test/bench_common.h` + `test/bench_streaming.cc` + gtest `test/unit/test_bench_streaming.cc`; CMake targets `bench_streaming` + `test_bench_streaming`. All 5 ctest suites green. Binary verified end-to-end on a synthetic trace (JSONL + mem stream emitted). Invariants a–d asserted. |
| 4 | gen_workload.py | ✅ done 2026-06-29 | `driver/gen_workload.py` + `trace_format.md`. Synthetic mode verified; real-dataset readers (.fvecs/.bvecs/.fbin); brute-force gt (numpy, ≤1M) + DiskANN compute_groundtruth path with positional→global id remap (10M+). Still NEEDS SIFT/SPACEV downloads for real runs. |
| 5 | baseline orchestrators | 🟡 partial | generic external RSS sampler `driver/mem_sampler.py` done + smoke-tested. run_<system>.sh deferred until baselines build (need their real CLIs per §2.3 feasibility check). |
| 6/7 | run matrix + recall calibration | ⏳ pending | stage-gated 1M→10M→100M; needs baselines + datasets |
| 9/10 | results pipeline (bench.py, plots) | ✅ done 2026-06-29 | `bench.py` (list/run/plot/clean) + `experiments.py` registry + `plot/{style,datfile,plot_timeseries,plot_bar,plot_pareto}.py`. Three-layer raw/dat/fig model. Verified end-to-end: JSONL→.dat(provenance header)→.pdf+.svg for recall_epoch, latency_epoch(dual-panel), mem_time, pareto. |

## Baseline build gating (Phase 2.2/2.3)

Cloned: `diskann` (cpp_main), `spfresh` (recursive). apt deps still
MISSING (user installs via option A): `libaio-dev libmkl-full-dev libisal-dev
libgoogle-perftools-dev gcc-9 g++-9`. Present already: boost, snappy, gflags, tbb.
Datasets (SIFT/SPACEV at 1M/10M/100M) not yet downloaded — needed before any real run or gt.

## Aster patch (build-critical, see also memory aster-sa-tree-cf-patch)

Upstream Aster lacks the custom `sa_tree` column family the branch needs (44 call sites on
`db_->sa_tree_cf()`). Patched `lib/aster/include/rocksdb/graph.h` to add the `sa_tree` CF +
`sa_tree_cf()` accessor + destructor cleanup, per `docs/SA_tree_on_disk_plan.md`. Rebuilt aster
+ all; sanity suites green.

## Run matrix (fill as runs complete)

Systems: ours, spfresh, spannplus, diskann_ip, diskann_merge. Datasets: sift, spacev.
Scales: 1m, 10m, 100m. Ratios: rins, r9010.

| system | dataset | scale | ratio | status | recall@10 (s→e) | RSS / lat_mean | notes |
|--------|---------|-------|-------|--------|-----------------|----------------|-------|
| ours (Phase-1 fixed, ef_final=128) | sift | 1m | r9010 | ✅ | 0.953→0.943 | 0.96–1.15 GB / 2.2 ms | churn-stable after lazy-ghost delete fix |
| diskann_ip (L=150, R64/Lb75/α1.2) | sift | 1m | r9010 | ✅ | 0.999→0.998 | 2.19 GB / 0.40 ms | in-memory, disk=0; consolidate_deletes per epoch |
| spfresh (file-I/O, ef=64) | sift | 1m | r9010 | ✅ | 0.946→0.910 | 4.5–6.0 GB / 1.4 ms | file-I/O not SPDK; biggest RSS; recall drops most under churn |
| ours | sift | 1m | rins | ✅ | 0.953→0.945 | ~1 GB | insert-only ceiling |
| spannplus | sift | 1m | r9010 | ✅ | 0.960→0.884 | 2.4–3.4 GB / 1.4 ms | LIRE off; degrades MOST under churn (−0.076) — the strawman |
| diskann_merge | sift | 1m | r9010 | ✅ | 0.998→0.998 | 3260 MB / 5.5 ms | diskv2 fork; disk index + in-mem delta; **merge_every=10000, single-thread** (25 merges). recall pristine (merges apply deletes). Insert: raw delta-insert 15792/s EXCLUDES merge; AMORTIZED incl. 25 merges (~508s) = **839/s ≈ ours**. build=649s (single-thread; run reused cached base via --reuse_base_index, restore 1s). Slowest latency, high RSS. |

**DECISION 2026-07-02: DiskANN-IP DROPPED from plots/comparison.** Reason: it's a fully in-memory index
(no disk); comparing on-disk methods (ours + its ablations, SPFresh, SPANN+, DiskANN-merge — all
paged/file-I/O) against it is unfair to the on-disk methods. Raw data kept in results/raw, not plotted.
The diskann_ip_vs_merge family was removed; 10m/100m carry DiskANN-**merge** as the on-disk DiskANN.

**Plotted systems (on-disk only): ours, lsm-vec-no-sa, lsm-vec-basic, spfresh, spannplus, diskann_merge.**
Among these at sift_1m_r9010: LSM-Vec family (ours/no-sa/basic) has the LOWEST DRAM (1.1–1.35 GB vs
3.4/3.6/6.0 GB) and is most churn-stable; DiskANN-merge highest recall (0.970) but slowest (5.7ms) + high
RAM (below-threshold artifact); recall order merge 0.970 > ours/no-sa ~0.944 > basic/spfresh ~0.91 > spann+ 0.884.

**CELL sift_1m_r9010 COMPLETE (5/5 run; 6 on-disk systems plotted incl. 2 ablations).** 8 figures in results/fig/*__sift_1m_r9010.pdf (recall_epoch,
latency_epoch, mem_time, recall_latency_pareto, insert_tput_epoch, build_time, insert_tput,
diskann_ip_vs_merge).
- **peak RSS:** ours 1350 < diskann_ip 2194 < spannplus 3423 < diskann_merge 3621 < spfresh 6038 MB → ours LOWEST DRAM (1.6–4.5×).
- **churn-stability (recall drop):** diskann_ip −0.001 < ours −0.010 < diskann_merge −0.028 < spfresh −0.036 < spannplus −0.076 → ours 2nd-best.
- **build time:** ours 818s (slowest, SA rebuild) vs diskann_ip 36 / spannplus 123 / diskann_merge 200 / spfresh 210 s.
- **insert tput:** ours 790/s (1 thread) vs others 1.4k–22k/s (32 threads) — THREAD-COUNT CONFOUND, footnote.
- delete throughput omitted (lazy-delete systems report meaningless ~30M ops/s version-marks).
- SPFresh/SPANN+ latency = file-I/O, not SPDK.

**Cell sift_1m_r9010 = 3/5 systems done** (figures: results/fig/{recall_epoch,latency_epoch,mem_time,recall_latency_pareto}__sift_1m_r9010.pdf).
Headline: ours has the LOWEST DRAM (~5× less than SPFresh, ~2× less than DiskANN) and is MORE churn-stable
than SPFresh (−0.010 vs −0.036); DiskANN leads recall+latency at 2.2× our RAM (pure in-memory).
**Serial-run rule:** all measurements run one at a time (see memory serial-measurement-rule). A concurrent
DiskANN+SPFresh slip was caught and SPFresh re-run solo.

## Anomalies / footnotes

- SPFresh latency is file-I/O, NOT the paper's SPDK number — footnote everywhere.
- Our method untested >200K — 1M stage is also a correctness/scale shakedown (watch recall drift, RSS, disk bloat).
- P2-T3 (drop per-rebuild full-tree writes) NOT implemented on this branch → on-disk SA still has 'C' blobs; report disk honestly. Orphaned-'S'-blob cleanup pending (R-9010 may slowly bloat disk).

**2026-07-07: sketch-only adopted as the default for `ours`.** Dropped the RocksDB SA-overlay for an
incremental resident top-H sketch (docs/sketch-only-design-plan.md; commits aa9d081/1382c9d/73e2e18/5ebedb9).
1M SIFT R-9010 re-baseline (4-thread build, single-thread workload, workload-only RSS):
| system | recall s→e | ins/s | lat | build | RSS(wl) |
|---|---|---|---|---|---|
| ours (sketch-only) | 0.960→0.926 | 890 | 1.7ms | 183s | **769 MB** |
| lsm-vec-no-sa | 0.960→0.927 | 897 | 1.7ms | 180s | 641 MB |
| lsm-vec-basic | 0.925→0.893 | 904 | 1.5ms | 186s | 799 MB |
| diskann_merge | 0.998→0.970 | 5343 | 6.3ms | 221s | 3624 MB |
| spfresh | 0.944→0.908 | 488 | 1.4ms | 574s | 5696 MB |
| spannplus | 0.960→0.884 | 1808 | 1.3ms | 250s | 3472 MB |
ours vs prior overlay: RSS 1025→769 MB (−25%), insert 687→890/s (+30%), recall unchanged. Overlay still
runnable via `--no-sketch-only`. Figures regenerated (results/fig/, 6 systems, workload-only memory).

**2026-07-08: CELL sift_10m_r9010 COMPLETE (4 systems).** Methodology: 4-thread build, single-thread
workload, workload-only RSS, ef_final=64 fixed across scales (user decision — clean scaling study, same
knob at 1M/10M). ours = sketch-only (default).
| system | recall s→e | ins/s | lat | build | RSS(wl) |
|---|---|---|---|---|---|
| ours (sketch-only) | 0.924→0.873 | 516 | 2.7ms | 2833s | **5003 MB** |
| diskann_merge (merge_every=30M) | 0.996→0.970 | 2854 | 7.1ms | 2559s | 17022 MB |
| spfresh | 0.916→0.881 | 377 | 2.4ms | 8419s | 20846 MB |
| spannplus | 0.925→0.834 | 1256 | 2.8ms | 3991s | 19895 MB |
**Headline: ours 5.0 GB vs baselines 17–21 GB = 3.4–4.2× less DRAM** (only ours < 5GB). Recall: ours &
spfresh neck-and-neck (both >> spannplus 0.834, << diskann_merge 0.970 @17GB). DRAM advantage holds vs 1M
(4.5–7×). ours build faster than spann/spfresh; insert > spfresh. 7 figures in results/fig/*__sift_10m_r9010.
diskann_merge below merge threshold (4.5M<30M) → delta 17GB, flag.
