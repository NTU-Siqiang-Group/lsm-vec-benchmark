# LSM-Vec streaming vector-DB benchmark

A reproducible benchmark that compares **LSM-Vec (SA-HNSW, "ours")** against **DiskANN-merge**,
**SPFresh**, and **SPANN+** on a *streaming* workload (continuous insert + delete + query), measuring
**recall, query latency, insert throughput, build time, and — the headline — DRAM footprint** as the
index churns over time.

This repo is the **framework/orchestration**. The four systems under test are included as **git
submodules** (clone with `--recursive` — see §3.1). The experiment outputs (raw data + figures) live in
a **separate results repo**.

- Systems under test: submodules `LSM-Vec-with-SA-HNSW/`, `diskann/`, `diskann_merge_src/`, `spfresh/`
  (+ our patches in `patches/`).
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
  run_ours.sh       drive OUR system (and ablations/variants) over a trace  (§4; knobs in §5, §7)
  run_spfresh.sh    drive SPFresh / SPANN+ over a trace
  spfresh_driver.cpp  the SPFresh replay driver (compiled by run_spfresh.sh on first use)
  mem_sampler.py    external RSS sampler (wraps baseline processes; ours samples in-process)
  trace_format.md   on-disk trace format spec
  run_*.sh          per-experiment orchestrators (rebaselines, ablations, diagnostics,
                    SPACEV mirror, DiskANN merge-regime variant) — catalogued in §7
plot/               paper-style plotters: core families + additional/diagnostic plotters
                    (ablation, breakdown, pareto_curve, param, exp1_routing, exp5_disk, exp2_memory) — §7
patches/            local patches + new driver sources to apply to the submodules (see §3.1)
LSM-Vec-with-SA-HNSW/  diskann/  diskann_merge_src/  spfresh/   ← submodules (systems under test)
work/               generated traces + scratch DBs/indices  (gitignored — large)
results/            raw/ dat/ fig/  (gitignored here — versioned in the separate results repo)
CLAUDE.md           agent guidance + key build facts
```
`PROGRESS.md` and `chat_history.md` are **local-only** working files (gitignored).

---

## 3. Prerequisites

### 3.1 Systems under test — **git submodules**

The four systems are **submodules** of this repo, pinned to the exact commits used for the published
results. Clone recursively, then apply the small local patches we carry in `patches/` (each system needs
minor modifications — the file-I/O build for SPFresh, the merge driver for DiskANN, the `sa_tree` column
family for ours), and drop in the two new driver sources.

```bash
git clone --recursive git@github.com:NTU-Siqiang-Group/lsm-vec-benchmark.git
cd lsm-vec-benchmark
# (already cloned without --recursive? run:  git submodule update --init --recursive)

# apply our local patches (tracked-file diffs) + add the new driver sources:
(cd diskann           && git apply ../patches/diskann.patch)
(cd diskann_merge_src && git apply ../patches/diskann_merge_src.patch)
(cd spfresh           && git apply ../patches/spfresh.patch)
(cd LSM-Vec-with-SA-HNSW/lib/aster && git apply ../../../patches/aster-graph-sa_tree_cf.patch)  # sa_tree CF
cp patches/newfiles/diskann_merge_src/tests/bench_stream_merge.cpp diskann_merge_src/tests/
cp patches/newfiles/diskann/apps/bench_stream_diskann.cpp          diskann/apps/                 # optional
```

| submodule | what | pinned to | build → binary |
|---|---|---|---|
| `LSM-Vec-with-SA-HNSW/` | **ours** (SA-HNSW) | `qyz-thu/LSM-Vec-with-SA-HNSW` @ `sa-resident-sketch` | `make aster && make all`, then `cmake --build build --target bench_streaming` → `build/bin/bench_streaming` |
| `diskann/` | DiskANN (used for ground truth) | `microsoft/DiskANN` @ `cpp_main` | standard CMake → `build/apps/utils/compute_groundtruth` |
| `diskann_merge_src/` | FreshDiskANN merge (DiskANN-merge) | `Yuming-Xu/DiskANN_Baseline` @ `diskv2` | CMake → `build/tests/bench_stream_merge` |
| `spfresh/` | SPFresh + SPANN+ (file-I/O, **no SPDK**) | `SPFresh/SPFresh` @ `main` | its build → `Release/ssdserving` (+ `driver/spfresh_driver`, auto-compiled by `run_spfresh.sh`) |

**Two dependencies the submodules do *not* capture (manual, once):**
- **SPFresh needs a RocksDB fork built with RTTI** at a separate prefix (its posting store is static-linked
  against it). Without it the file-I/O backend won't link. See the SPFresh build notes.
- `run_spfresh.sh` hardcodes `ROOT=/home/dmo/lsm_vec_benchmark` — edit it for your checkout path.

*(Why patches instead of committing to the submodules? Three of the four upstreams aren't ours to write
to, and the changes are small build/driver tweaks — carrying them as `patches/*.patch` keeps the
submodules pointing at clean upstream commits.)*

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


---

## 7. Experiment runners, CLI knobs & plotters (additional + diagnostic experiments)

Beyond the core cells (§4–§6), the study includes ablations, diagnostics, a full **SPACEV mirror**, and
a **DiskANN merge-regime variant**. Each is driven by a `driver/run_*.sh` orchestrator (strictly serial;
most are **resumable** — a variant whose raw JSONL already has 50 epochs is skipped). Findings for all of
these live in the results repo's `RESULTS.md` (§10 ablations, §11 diagnostics, §12 SPACEV, §13 DiskANN
flush).

### 7.1 Runner scripts

| script | what it runs | RESULTS |
|---|---|---|
| `rebaseline_1m_4tbuild.sh`, `rebaseline_10m.sh` | main cells, all systems, 4-thread build / 1-thread workload | §2–§3 |
| `run_spacev_1m.sh`, `run_spacev_10m.sh` | main cells on SPACEV (all systems) | §4–§5 |
| `run_ablation_sift_1m.sh` | SA-routing (D4) + layout (D5) ablation arms | §10.1–10.2 |
| `run_phase467_sift_1m.sh` | disk/mem breakdown (D6/D7) + cache sweep + ef Pareto (D9) | §10.3–10.5 |
| `run_phase8_param_200k.sh` | param sensitivity: top-H×beam, layer_mult, alpha, min-cluster | §10.6 |
| `run_additional_sift_10m.sh` | 10M ablation + breakdown + Pareto (section-cap fix path) | §10.7 |
| `run_exp5_baselines_sift_1m.sh` | regenerate baseline index dirs for the disk breakdown | §11.2 |
| `run_spacev_200k_params.sh`, `run_spacev_1m_additional.sh`, `run_spacev_1m_baselines.sh`, `run_spacev_10m_additional.sh`, `run_spacev_mirror_chain.sh` | **SPACEV mirror** of every SIFT experiment (chain = 1M→baselines→10M) | §12 |
| `run_diskann_flush.sh`, `run_diskann_flush_10m.sh` | **DiskANN `merge_every=100k`** variant (merges actually fire); the 10M runner is **disk-watchdog-guarded** (aborts <12 GB free) | §13 |

Most runners drive `run_ours.sh` with `NAME=<variant>` and `EXTRA_ARGS="<flags>"`; look inside any
script for the exact invocation.

### 7.2 `run_ours.sh` passthrough & `bench_streaming` CLI knobs

`run_ours.sh` forwards `EXTRA_ARGS` verbatim to `bench_streaming`, which exposes:

- **Ablation / variant:** `--sa-route-off` (D4: build SA, skip routing at query = controlled `ours_no_sa`);
  `--layout {section,append,random}` (D5: on-disk vector placement); `--no-sketch-only` (overlay A/B).
- **Parameter sweeps:** `--m` / `--m-max` (graph out-degree); `--sa-max-children`, `--sa-beam`,
  `--sa-rebuild-alpha`, `--sa-min-cluster` (D8); `--paged-cache-pages` (vector page cache);
  `--hops` (= sketch depth top-H); `--layer-mult` (already a positional/env knob).
- **Diagnostics:** `--checkpoint-epochs a,b,c --query-sweep e1,e2,...` (D9: query-only ef Pareto on the
  live index → `<out>.sweep.jsonl`); `--trace-exp1 <epoch> --trace-queries N` (Exp 1: per-query visit
  trace for the SA-routing case study); `--profile-insert` (insert-phase breakdown).
- **Metrics added to the per-epoch JSONL:** `lat_p95_ms`; `query_page_miss_per_query` (physical vector
  reads); `query_vec_read_ms` (vector-read wall time); `disk_{graph,vector,wal,meta}_mb` (D6);
  `mem_{upper_hnsw,sa_sketch,graph_cache,vec_cache,update_buf}_mb` (D7).

`bench_stream_merge` (DiskANN) adds `--merge_every` — **30M** = the paper default (never fires ≤14M live,
the "below-threshold" regime); **100k** = the merge-regime variant in §13.

### 7.3 Diagnostic plotters (`plot/`)

Read raw JSONL directly (not via `bench.py`), one figure family each:

- `plot_ablation.py {phase2|phase3} <cell>` — SA-routing / layout ablation bars.
- `plot_breakdown.py {disk|mem|cache} <cell>` — disk & memory component stacks, cache sensitivity.
- `plot_pareto_curve.py <name> <cell>` — recall-latency / recall-IO Pareto from a `.sweep.jsonl`.
- `plot_param.py {heatmap|msweep|lines} <cell>` — top-H×beam heatmap, M sweep, layer/alpha/min-cluster.
- `plot_exp1_routing.py <trace.jsonl> <trace_dir> <epoch> <tag>` — routing trajectory + target-hit
  (computes dist-to-target offline from the trace vectors + gt).
- `plot_exp5_disk.py <cell>` — per-system disk breakdown from the final index directories.
- `plot_exp2_memory.py <cell>` — LSM-Vec memory composition over epochs + ours-vs-SPFresh RSS.
