#!/bin/bash
# Phase 1 — SPACEV 10M cell (parallel to SIFT rebaseline_10m.sh).
# 4-thread BUILD, single-thread WORKLOAD, workload-only memory. STRICTLY SERIAL.
# Systems = experiments.systems_for_scale('10m') = {ours, spfresh, spannplus, diskann_merge}.
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/spacev_10m_r9010
CELL=spacev_10m_r9010
LOGD=logs/spacev_10m
mkdir -p "$LOGD"
ts() { date +%H:%M:%S; }

echo "=== [$(ts)] START ours (sketch-only, bulk @4t, ef_final=64) ==="
NAME=ours USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/ours.log" 2>&1
echo "=== [$(ts)] DONE ours rc=$? ==="

echo "=== [$(ts)] START spfresh (build 4t / workload 1t) ==="
BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh "$TRACE" spfresh 64 > "$LOGD/spfresh.log" 2>&1
echo "=== [$(ts)] DONE spfresh rc=$? ==="
# reclaim the ~80GB SPFresh index (raw JSONL already written) before SPANN+ builds its own
rm -rf work/spfresh_${CELL}

echo "=== [$(ts)] START spannplus ==="
BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh "$TRACE" spannplus 64 > "$LOGD/spannplus.log" 2>&1
echo "=== [$(ts)] DONE spannplus rc=$? ==="
rm -rf work/spannplus_${CELL}

echo "=== [$(ts)] START diskann_merge (build 4t, merge_every=30M) ==="
rm -rf work/diskann_merge_${CELL}_idx && mkdir -p work/diskann_merge_${CELL}_idx
diskann_merge_src/build/tests/bench_stream_merge \
  --trace "$TRACE" \
  --out results/raw/diskann_merge_${CELL}.jsonl \
  --mem results/raw/diskann_merge_${CELL}.mem.jsonl \
  --index_prefix work/diskann_merge_${CELL}_idx/idx --work_dir work/diskann_merge_${CELL}_idx \
  --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 30000000 \
  > "$LOGD/diskann_merge.log" 2>&1
echo "=== [$(ts)] DONE diskann_merge rc=$? ==="

echo "=== [$(ts)] ALL SPACEV-10M DONE ==="
