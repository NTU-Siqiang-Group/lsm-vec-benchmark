# LSM-Vec streaming vector-DB benchmark

A reproducible benchmark that compares **LSM-Vec (SA-HNSW, "ours")** against **DiskANN-merge**,
**SPFresh**, and **SPANN+** on a *streaming* workload (continuous insert + delete + query), measuring
**recall, query latency, insert throughput, build time, and — the headline — DRAM footprint** as the
index churns over time.

This repo is the **framework/orchestration** only. The experiment outputs (raw data + figures) live in
a **separate results repo**; the systems under test live in **sibling code repos** (see Prerequisites).

- Method + baseline code: sibling repos (built separately).
- Results (raw/dat/fig + a detailed writeup): `github.com/volatill/lsm_vec_results` (`RESULTS.md` there).

---

## 1. What a "run" is

A **cell** is one `(dataset, scale, ratio)` triple, e.g. `sift_1m_r9010`. One cell =

1. a **shared trace** (a byte-identical stream of ops, so every system sees the same inserts/deletes),
2. each system **replayed** over that trace → a per-epoch metrics JSONL + an RSS-vs-time stream,
3. **aggregation + plots** from those JSONLs.

**Workload `r9010`** (the churn workload): base index of *N* vectors, then **50 epochs**; each epoch
inserts 0.9%·N and deletes 0.1%·N (uniform over live ids). Ground-truth top-100 is recomputed on the
**active set** every `gt-interval` epochs. (`rins` = insert-only variant.)

**Methodology (as run for the published cells):**
- **Build = 4 threads** for every system; **workload (insert/delete/query) = single thread** for every
  system. Query latency is measured serially.
- **Memory metric = peak RSS during the *workload* only** (build-phase RSS excluded).
- **ours** runs in **sketch-only** SA mode (the default) with search budget **`ef_final = 64`**, held
  fixed across scales.
- **Runs are strictly serial** — never run two systems at once (resource contention invalidates the
  memory/latency numbers).

---

## 2. Repository layout

```
bench.py            results orchestrator: aggregate raw JSONL -> canonical .dat -> figures
experiments.py      experiment registry: which (family, cell, systems) exist
driver/
  gen_workload.py   generate a shared trace for one cell (base/pool/queries + per-epoch ops + gt)
  run_ours.sh       drive OUR system (and the two ablations) over a trace
  run_spfresh.sh    drive SPFresh / SPANN+ over a trace
  spfresh_driver.cpp  the SPFresh replay driver (compiled by run_spfresh.sh on first use)
  mem_sampler.py    external RSS sampler (wraps baseline processes; ours samples in-process)
  trace_format.md   on-disk trace format spec
plot/               paper-style Matplotlib plotters (style, dat reader, timeseries/bar/pareto)
work/               generated traces + scratch DBs/indices  (gitignored — large)
results/            raw/ dat/ fig/  (gitignored here — versioned in the separate results repo)
CLAUDE.md           agent guidance + key build facts
```
`PROGRESS.md` and `chat_history.md` are **local-only** working files (gitignored).

---

## 3. Prerequisites

### 3.1 Sibling code repos (built separately, placed next to this repo)

The scripts assume this layout (the benchmark root and the systems are siblings). Paths are currently
absolute (`/home/dmo/lsm_vec_benchmark`) in `run_spfresh.sh` — adjust `ROOT`/paths for your machine.

| dir | what | build | binary used |
|---|---|---|---|
| `LSM-Vec-with-SA-HNSW/` | **ours** (branch `sa-resident-sketch`) | patch `lib/aster/include/rocksdb/graph.h` to add the `sa_tree` column family (see that repo's docs / the `aster-sa-tree-cf-patch` note), then `make aster && make all`, then `cmake --build build --target bench_streaming` | `LSM-Vec-with-SA-HNSW/build/bin/bench_streaming` |
| `diskann/` | DiskANN (microsoft/DiskANN, cpp_main) | its standard CMake build → `diskann/build/apps` | `diskann/build/apps/utils/compute_groundtruth` (used for large-scale ground truth) |
| `diskann_merge_src/` | FreshDiskANN merge driver (diskv2 fork) | CMake → `diskann_merge_src/build/tests` | `diskann_merge_src/build/tests/bench_stream_merge` |
| `spfresh/` | SPFresh + SPANN+ (file-I/O mode, **no SPDK**) | its build → `spfresh/Release/`; needs a RocksDB fork built with RTTI at a separate prefix | `spfresh/Release/ssdserving` (+ `driver/spfresh_driver` auto-compiled) |

> **Aster patch:** upstream Aster lacks the `sa_tree` CF that the `sa-resident-sketch` branch needs. The
> patch to `graph.h` is a working-tree change in the `lib/aster` submodule (not committed). Re-apply it
> before building ours.

### 3.2 Datasets

SIFT/BIGANN `.bvecs` (128-d uint8): a base file and the query file. Trace generation reads them via
`--base-file` / `--query-file`. **For scale N you need a base file with ≥ 1.5·N vectors** (base N +
disjoint insert pool 0.5·N). E.g. a 1M cell reads from the 10M base file; a 10M cell reads from the
100M base file.

### 3.3 Python

`numpy` (trace gen + brute-force gt) and `matplotlib` (plots). Python 3.9+.

---

## 4. Quickstart — reproduce the 1M cell end-to-end

Run everything from the benchmark root, **one command at a time** (serial). Substitute your dataset paths.

```bash
SIFT=/path/to/bigann          # dir with bigann_base_10M.bvecs, bigann_query.bvecs
CELL=sift_1m_r9010 ; TRACE=work/$CELL

# (1) generate the shared trace (base=1M, pool=0.5M from the 10M file; gt brute-force at 1M)
python3 driver/gen_workload.py --dataset sift --scale 1000000 --ratio r9010 \
  --base-file $SIFT/bigann_base_10M.bvecs --query-file $SIFT/bigann_query.bvecs \
  --n-epochs 50 --gt-interval 10 --seed 1 --gt-method bruteforce --out $TRACE

# (2) run each system over the trace (SERIAL — one at a time). 4-thread build, single-thread workload.
#   ours (sketch-only, ef_final=64):
NAME=ours          USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4        bash driver/run_ours.sh $TRACE $CELL 64 4 0
#   ablations (SA off; efs is their recall knob):
NAME=lsm-vec-no-sa USE_SA=0 LAYER_MULT=0.125 EFS=64 BULK=1 BUILD_THREADS=4 bash driver/run_ours.sh $TRACE $CELL 64 4 0
NAME=lsm-vec-basic USE_SA=0 LAYER_MULT=0     EFS=64 BULK=1 BUILD_THREADS=4 bash driver/run_ours.sh $TRACE $CELL 64 4 0
#   SPFresh / SPANN+ (build 4 threads, workload 1 thread):
BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh $TRACE spfresh   64
BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh $TRACE spannplus 64
#   DiskANN-merge (build 4 threads; merge_every=30M per the SPFresh paper):
mkdir -p work/diskann_merge_${CELL}_idx
diskann_merge_src/build/tests/bench_stream_merge \
  --trace $TRACE --out results/raw/diskann_merge_${CELL}.jsonl --mem results/raw/diskann_merge_${CELL}.mem.jsonl \
  --index_prefix work/diskann_merge_${CELL}_idx/idx --work_dir work/diskann_merge_${CELL}_idx \
  --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 30000000

# (3) aggregate + plot (writes results/dat/*.dat and results/fig/*.pdf|svg)
python3 bench.py run \
  recall_epoch__$CELL latency_epoch__$CELL mem_time__$CELL recall_latency_pareto__$CELL \
  insert_tput_epoch__$CELL build_time__$CELL insert_tput__$CELL
```

Each run writes `results/raw/<system>_<cell>.jsonl` (per-epoch) and `.mem.jsonl` (RSS-vs-time). Step 3
turns those into `results/dat/*.dat` and `results/fig/*.{pdf,svg}`.

---

## 5. Running **any** scale / ratio / dataset

Everything is parameterized by the **cell tag** `<ds>_<scale>_<ratio>` and the trace's `--scale`.

```bash
N=10000000 ; CELL=sift_10m_r9010 ; TRACE=work/$CELL      # example: 10M

# trace: for scale N read a base file with >= 1.5*N vectors; use DiskANN gt above ~1M (brute force is too slow)
python3 driver/gen_workload.py --dataset sift --scale $N --ratio r9010 \
  --base-file $SIFT/bigann_base_100M.bvecs --query-file $SIFT/bigann_query.bvecs \
  --n-epochs 50 --gt-interval 10 --seed 1 --gt-method diskann \
  --diskann-gt-bin diskann/build/apps/utils/compute_groundtruth --out $TRACE

# then the same per-system commands as §4, with $CELL/$TRACE = your scale, and register the scale first:
```

**Register a new scale** so `bench.py`/`experiments.py` know about it: add it to `SCALES` in
`experiments.py`, and set `systems_for_scale()` to the systems you actually ran at that scale (e.g.
larger cells run only `ours` + `diskann_merge` — see the hardware limits below). Figure names are
`<family>__<cell>`; the seven families are `recall_epoch, latency_epoch, mem_time,
recall_latency_pareto, insert_tput_epoch, build_time, insert_tput`.

**Knobs you'll actually change:**
- `--scale N`, `--ratio {r9010,rins}`, `--n-epochs`, `--gt-interval`, `--seed`.
- `--gt-method {bruteforce,diskann}` — brute force ≤1M; DiskANN `compute_groundtruth` for 10M+.
- `run_ours.sh` env: `NAME` (output prefix), `USE_SA` (1=ours, 0=ablation), `LAYER_MULT`
  (0.125=flat, 0=standard HNSW), `BULK=1`+`BUILD_THREADS=N` (multi-thread bulk build), `EFS`
  (ablation recall knob); positional args `<trace> <cell> <ef_final> <hops> <query_subsample>`
  (`query_subsample=0` = full queries every epoch, for publication).
- `run_spfresh.sh`: `driver/run_spfresh.sh <trace> {spfresh|spannplus} <ef>`, env `BUILD_THREADS`
  (build) and `THREADS` (workload append).
- `bench_stream_merge`: `--merge_every` (StreamingMerge cadence; 30M matches the SPFresh paper),
  `--build_threads`, `--L` (search).

**`--sa-sketch-only` / `--no-sketch-only`** on `bench_streaming` toggle ours' SA mode (sketch-only is
the default in the harness); overlay is kept only for A/B.

---

## 6. Results pipeline (`bench.py` + `experiments.py`)

- `experiments.py` is the registry: `FAMILIES` (figure types + which raw source + which plotter) ×
  `all_experiments()` (families × datasets × scales × ratios) with `systems_for_scale()` deciding who's
  plotted at each scale.
- `python3 bench.py list` — list every known experiment. `python3 bench.py run <name> [<name>...]` —
  aggregate the matching raw JSONLs into `results/dat/<name>.dat` and render `results/fig/<name>.{pdf,svg}`.
- The three-layer model: `results/raw/` (source JSONL) → `results/dat/` (canonical tables w/ provenance
  headers) → `results/fig/` (figures). Memory metrics use **workload-only** RSS (samples with
  `epoch ≥ 0`; the build phase is tagged `epoch = -1`).

