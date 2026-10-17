# LSM-Vec streaming vector-DB benchmark

A reproducible benchmark that compares **LSM-Vec (SA-HNSW, "ours")** with **SPFresh** and
**FreshDiskANN** on a *streaming* workload (continuous inserts, deletes and queries), measuring
**recall, query latency, insert throughput, build time, DRAM footprint and disk** as the index churns.

This repo is the framework (trace generation, drivers, orchestration, results pipeline). The systems
under test are git submodules plus small patches. Raw data, tables and figures live in a separate
results repo: `github.com/volatill/lsm_vec_results` (`RESULTS.md` there).

**Current version (2026-10):** all systems store the datasets' native byte types (SIFT uint8, SPACEV
int8); cells SIFT/SPACEV × 1M/10M/100M; 4-thread build, single-thread workload; 50-epoch R-9010 traces.

---

## 1. What a run is

A **trace** (`work/<ds>_<scale>_<ratio>/`) is generated once per cell and shared by every system: a base
set of N vectors, a disjoint insert pool of 0.5·N, 10k queries, and 50 **epochs** of operations. Ratio
`r9010` = per epoch 0.9%·N inserts + 0.1%·N deletes (the live set grows to 1.4·N); `rins` = inserts only.
Ground truth is recomputed every 10 epochs on the live set.

A **run** builds a system's index on the base set (timed), then replays the epochs: apply the epoch's
deletes and inserts (timed → insert throughput), then run the 10k queries single-threaded (recall@10,
latency). Every epoch appends one JSON line to `results/raw/<system>_<cell>.jsonl`; a sampler records
RSS over time (`.mem.jsonl`) and the page-cache footprint of the system's store (`.cache.jsonl`).
Memory is reported as RssAnon + page-cache footprint of the store.

## 2. Repository layout

```
driver/        gen_workload.py (traces + GT), fbin_to_byte.py (native-byte copies), run_main.sh (one cell, all systems),
               run_spfresh.sh + spfresh_driver.cpp (SPFresh driver), prep_100m.sh (100M data prep), samplers,
               analyze_phase_c.py (main table), further run_*.sh for the supplementary experiments
patches/       our changes to the submodules (see §3.1)
plot/          plotters;  bench.py + experiments.py = figure registry over results/raw
LSM-Vec-with-SA-HNSW/  diskann_merge_src/  spfresh/  diskann/   submodules (ours, FreshDiskANN, SPFresh, DiskANN tools)
work/  logs/   generated traces, scratch stores, run logs (not tracked)
results/       separate repo (volatill/lsm_vec_results)
```

## 3. Prerequisites

### 3.1 Systems under test (submodules + patches)

```bash
git clone --recursive git@github.com:NTU-Siqiang-Group/lsm-vec-benchmark.git && cd lsm-vec-benchmark
(cd LSM-Vec-with-SA-HNSW           && git apply ../patches/lsm-vec-sa-resident-sketch.patch)   # ours: the SA-HNSW branch used here
(cd LSM-Vec-with-SA-HNSW/lib/aster && git apply ../../../patches/aster.patch)                   # Aster: sa_tree CF, minimal mode, varint edges
(cd diskann_merge_src && git apply ../patches/diskann_merge_src.patch && cp ../patches/newfiles/diskann_merge_src/tests/bench_stream_merge.cpp tests/)
(cd spfresh           && git apply ../patches/spfresh.patch)                                    # file-I/O (RocksDB) backend, no SPDK
(cd diskann           && git apply ../patches/diskann.patch)
```

| submodule | role | build → binary |
|---|---|---|
| `LSM-Vec-with-SA-HNSW/` (`sa-resident-sketch`) | **ours** | `make aster && make all`, then `cmake --build build --target bench_streaming` → `build/bin/bench_streaming` |
| `diskann_merge_src/` (`diskv2`) | FreshDiskANN (StreamingMerge) | CMake → `build/tests/bench_stream_merge_{u8,i8}` |
| `spfresh/` (`main`) | SPFresh (file-I/O build) | its build → `Release/ssdserving` (+ `driver/spfresh_driver_{u8,i8}`, compiled by `run_spfresh.sh`) |
| `diskann/` (`cpp_main`) | ground truth (`compute_groundtruth`) | CMake → `build/apps/utils/compute_groundtruth` |

SPFresh's file-I/O backend links a **RocksDB build with RTTI**; point `ROCKSDB_PREFIX` at it before running
`run_spfresh.sh`. Everything else is standard CMake; C++17, zstd/snappy/lz4, Boost headers, Python 3.9+
with `numpy` and `matplotlib`.

### 3.2 Datasets

- **SIFT / BIGANN** (128-d uint8): `bigann_base_{10M,100M,1000M}.bvecs` + `bigann_query.bvecs`.
- **SPACEV / MSSPACEV** (100-d int8): `spacev1b_base.i8bin` + `query.i8bin` (big-ann-benchmarks); a
  prefix of the base file is enough (`driver/prep_100m.sh` shows a range download of the first 150M rows).

For scale N the base file must hold ≥ 1.5·N vectors (base N + insert pool 0.5·N).

## 4. Quickstart — one cell end-to-end

```bash
SIFT=/path/to/bigann ; CELL=sift_1m_r9010

# (1) trace + ground truth (brute force ≤ 1M; use --gt-method diskann above that), then native-byte copies
python3 driver/gen_workload.py --dataset sift --scale 1000000 --ratio r9010 \
  --base-file $SIFT/bigann_base_10M.bvecs --query-file $SIFT/bigann_query.bvecs \
  --n-epochs 50 --gt-interval 10 --seed 1 --gt-method bruteforce --out work/$CELL
python3 driver/fbin_to_byte.py work/$CELL uint8          # int8 for SPACEV

# (2) the three systems, one after another (ours, SPFresh, FreshDiskANN)
driver/run_main.sh $CELL

# (3) main table + figures
python3 driver/analyze_phase_c.py --md
python3 bench.py run recall_epoch__$CELL latency_epoch__$CELL mem_time__$CELL insert_tput_epoch__$CELL
```

`run_main.sh` runs ours as `bench_streaming --efs 64 --ef-final 64 --hops 4 --use-sa 1 --layer-mult 0.18034
--bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 u8|i8` (SA-HNSW with the
resident sketch, adjacent-layer ratio 256, M = 16, 32 MB caches), SPFresh through `run_spfresh.sh`
(`VALUE_TYPE=UInt8|Int8`, 4 build threads, 1 append thread, ef 64) and FreshDiskANN as
`bench_stream_merge_{u8,i8} --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4
--merge_every 100000`. Pass a subset to run fewer systems: `driver/run_main.sh $CELL ours spfresh`.

## 5. Other scales and datasets

Everything is keyed by the cell tag `<ds>_<scale>_<ratio>`.

```bash
# SIFT 10M: base from the 100M file, GT with DiskANN
python3 driver/gen_workload.py --dataset sift --scale 10000000 --ratio r9010 \
  --base-file $SIFT/bigann_base_100M.bvecs --query-file $SIFT/bigann_query.bvecs \
  --n-epochs 50 --gt-interval 10 --seed 1 --gt-method diskann \
  --diskann-gt-bin diskann/build/apps/utils/compute_groundtruth --out work/sift_10m_r9010
python3 driver/fbin_to_byte.py work/sift_10m_r9010 uint8

# SPACEV 1M (same for 10M/100M with --scale)
python3 driver/gen_workload.py --dataset spacev --scale 1000000 --ratio r9010 \
  --base-file $SPACEV/spacev1b_base.i8bin --query-file $SPACEV/query.i8bin --max-queries 10000 \
  --n-epochs 50 --gt-interval 10 --seed 1 --gt-method diskann \
  --diskann-gt-bin diskann/build/apps/utils/compute_groundtruth --out work/spacev_1m_r9010
python3 driver/fbin_to_byte.py work/spacev_1m_r9010 int8
```

At 100M, `run_main.sh` switches ours to the out-of-core sharded build (`--sharded-build 16`) and FreshDiskANN to
`--M_gb 100`; `driver/prep_100m.sh` prepares the 100M traces, and `driver/run_phase_c2.sh` is the exact
orchestration used for the published 1M/10M/100M matrix. Run one system at a time: the measurements assume
an otherwise idle machine. Register a new scale in `SCALES` in `experiments.py` before plotting it.

## 6. Results pipeline

`results/raw/` (per-epoch JSONL) → `results/dat/` (one canonical table per figure, with provenance headers)
→ `results/fig/` (PDF + SVG). `experiments.py` is the registry (figure families × cells); `python3 bench.py list`
enumerates them and `python3 bench.py run <name> [...]` aggregates and renders. `driver/analyze_phase_c.py`
prints the main comparison table (stream means and ratios) from the raw files.

## 7. Supplementary experiments

The remaining `driver/run_*.sh` scripts (ablations, parameter sweeps, cache-protocol and layout studies,
the 100M ef_final study) and the `plot/plot_*.py` diagnostic plotters back the supplementary sections of
the results repo's `RESULTS.md`; each script documents its invocation in its header. `bench_streaming`
flags for them: `--sa-route-off`, `--layout {section,append,random}`, `--hops H`, `--layer-mult`, `--m`,
`--efc`, `--ef-final`, `--paged-cache-pages`, `--checkpoint-epochs a,b --query-sweep e1,e2,...`,
`--cold-queries --warmup-queries N`, `--trace-exp1 <epoch> --trace-queries N`.
