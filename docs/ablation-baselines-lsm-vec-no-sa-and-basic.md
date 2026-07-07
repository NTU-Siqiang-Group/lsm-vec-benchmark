# Ablation baselines derived from our method: `lsm-vec-no-sa` and `lsm-vec-basic`

Reference doc (created 2026-07-01) for two ablation baselines of OUR method (LSM-Vec SA-sketch). Both
are **configs of our own `LSMVecDB`** — same binary (`bench_streaming`), same M / Mmax / ef_construction /
paged disk-backed storage as ours — they differ ONLY in (1) whether the SA-tree is built+used and (2) the
HNSW layer shape. Point future ablation requests at this doc instead of re-describing them.

## The three points of comparison

| variant | SA-tree | HNSW layer shape | search knob | build |
|---|---|---|---|---|
| **ours** (LSM-Vec SA-sketch) | **on** — built + routed | **flat 2-layer** (`sa_layer_mult=0.125`): L0 ≈ N, L1 ≈ 0.00034·N (~353 @1M), no L2+ | `ef_final` (SA L0 budget); `ef_search` is a no-op | expensive (1-shot SA rebuild + resident sketch) |
| **lsm-vec-no-sa** (a) | **off** — not built, not routed | **flat 2-layer** — *same shape as ours* (`layer_mult=0.125`) | `ef_search` (plain HNSW beam) | cheap (no SA build) |
| **lsm-vec-basic** (b) | **off** | **normal HNSW** (`layer_mult=0` → `1/ln(M)≈0.36`): ~5 layers, L1 ≈ N/M (~62k @1M) | `ef_search` | cheap (no SA build) |

## What each baseline is (and isolates)

- **`lsm-vec-no-sa`** — "our flat skeleton, but plain HNSW." Keeps our cheap flat 2-layer shape and drops
  the SA-tree entirely (so build skips the expensive SA rebuild). Search is ordinary HNSW greedy over the
  flat graph. **Isolates the value of the SA-tree routing**: ours vs no-sa = "given the same flat shape,
  what does SA routing buy?" Expectation: without SA, the flat shape gives a poor L0 entry, so plain HNSW
  needs a much larger `ef_search` (more vector reads / latency) to reach the same recall — that gap is the
  SA-tree's contribution.

- **`lsm-vec-basic`** — "vanilla LSM-Vec HNSW." Standard HNSW level decay (M=16 → ~5 layers, ~62k L1 nodes),
  no SA. This is the plain HNSW-on-LSM baseline (the `main`-branch behavior). **ours vs basic** answers
  "does SA-HNSW (flat + SA) beat a normal HNSW?", and **no-sa vs basic** isolates "cost of the flat shape
  when you DON'T have SA to compensate."

## Exact configuration

Common to all (held constant — the controlled part of the ablation):
`M=16, Mmax=32, ef_construction=32, vector_storage_type=1 (paged, disk-backed), batch_read=1, metric=L2,
random_seed=12345`.

Per-variant (what changes):
- **ours**: `use_sahnsw=1`, `sa_layer_mult=0.125`, search at `ef_final=128` (+ sa_beam=8, sa_ef=10,
  sa_max_children=4, sa_min_cluster=16, sa_l0_buffer_hops=4, sa_route_max_steps=4).
- **lsm-vec-no-sa**: `use_sahnsw=0`, `sa_layer_mult=0.125`, search at `ef_search=128`. No SA params apply.
- **lsm-vec-basic**: `use_sahnsw=0`, `sa_layer_mult=0` (→ standard `1/ln(M)`), search at `ef_search=128`.

**Comparison protocol used (1M cell):** FIXED `ef_search=128` for the no-SA variants (parallel to ours'
`ef_final=128` budget), report whatever recall each gets (paper-style, no recall-matching). `ef_construction`
held at 32 across all three so the only changing variables are SA-on/off and layer shape.

## How to run (from the benchmark root, one at a time — serial-measurement rule)

```bash
BIN=LSM-Vec-with-SA-HNSW/build/bin/bench_streaming
# lsm-vec-no-sa (flat shape, no SA):
$BIN --trace work/sift_1m_r9010 --db work/db_nosa_1m \
  --out results/raw/lsm-vec-no-sa_sift_1m_r9010.jsonl --mem results/raw/lsm-vec-no-sa_sift_1m_r9010.mem.jsonl \
  --efs 128 --use-sa 0 --layer-mult 0.125
# lsm-vec-basic (full HNSW):
$BIN --trace work/sift_1m_r9010 --db work/db_basic_1m \
  --out results/raw/lsm-vec-basic_sift_1m_r9010.jsonl --mem results/raw/lsm-vec-basic_sift_1m_r9010.mem.jsonl \
  --efs 128 --use-sa 0 --layer-mult 0
# figures: the two ablations are part of ALL_SYSTEMS, so they appear INSIDE the main comparison
# figures alongside every baseline (no separate ablation figures). Just regenerate the cell:
python3 bench.py run recall_epoch__sift_1m_r9010 latency_epoch__sift_1m_r9010 \
  build_time__sift_1m_r9010 insert_tput__sift_1m_r9010 mem_time__sift_1m_r9010 \
  recall_latency_pareto__sift_1m_r9010 insert_tput_epoch__sift_1m_r9010
```

## What enables them in the code (for future maintenance)

- **`src/lsm_vec_index.cc::randomLevel()`** — patched to honor `sahnsw_layer_mult_` (>0) **even when SA is
  off**, so `lsm-vec-no-sa` gets the flat shape without building SA. Ours (SA on, mult=0.125) is byte-identical.
  With `mult=0` and SA off, it falls back to standard HNSW `-ln(U)/ln(M)` (`lsm-vec-basic`).
- **`test/bench_common.h`** — `Config.use_sa` + `Config.layer_mult`; `bestConfigOptions(..., use_sa, layer_mult)`
  sets `use_sahnsw`/`sa_layer_mult`; `buildBase()` skips `rebuildAllSaClustersFromScratch()` +
  `buildSaL0HopBuffer()` when `use_sa=false` (the cheap build); `runQueries()` uses `ef_search` (the no-SA
  path ignores `ef_final`).
- **`test/bench_streaming.cc`** — CLI `--use-sa {0,1}` (default 1) and `--layer-mult <v>` (default 0.125).
- **Plot/registry** — `plot/style.py` SYSTEM_STYLE has `lsm-vec-no-sa` / `lsm-vec-basic`; `experiments.py`
  `ABLATION_FAMILY` (`ablation_recall` / `ablation_latency` / `ablation_build`, systems = ours + the two).

## HNSW shape recap (why the flat shape matters)

`level = floor(−ln(U) · mult)`. P(level≥1)=e^(−1/mult). At 1M: `mult=0.125` → L1 ≈ 335 (observed 353),
no L2; `mult=1/ln(16)≈0.36` → L1 ≈ 62k over ~5 layers. SA-HNSW deliberately collapses the hierarchy to a
~350-node skeleton and moves routing into the per-cluster SA sketches; the ablations test what happens when
you keep the flat skeleton but remove SA (`no-sa`), or revert to the tall skeleton without SA (`basic`).

Related: [[docs/baseline_driver_spec.md]], `docs/FINDINGS_churn_recall.md`, the SIFT-1M results in PROGRESS.md.
