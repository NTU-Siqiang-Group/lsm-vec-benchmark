#!/bin/bash
# Phase 4 (disk breakdown, D6) + Phase 6 (memory breakdown + cache sweep, D7) + Phase 7 (Pareto, D9)
# on SIFT 1M. Ours-only. STRICTLY SERIAL. The default-cache run also carries the ef_final Pareto sweep.
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/sift_1m_r9010
CELL=sift_1m_r9010
LOGD=logs/phase467_sift_1m
mkdir -p "$LOGD"
ts(){ date +%H:%M:%S; }

# Reference: default cache + D6/D7 breakdown (auto) + D9 Pareto sweep at epochs 0/25/49.
echo "=== [$(ts)] ours_section (default cache, breakdown + Pareto sweep) ==="
NAME=ours_section USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 \
  EXTRA_ARGS="--checkpoint-epochs 0,25,49 --query-sweep 16,32,48,64,96,128" \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/ours_section.log" 2>&1
echo "=== [$(ts)] done rc=$? ==="

# Phase 6 cache sensitivity: small (2048=8MB) and large (32768=128MB) vs default (~8192=32MB).
echo "=== [$(ts)] ours_cache_small (2048 pages) ==="
NAME=ours_cache_small USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="--paged-cache-pages 2048" \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/cache_small.log" 2>&1
echo "=== [$(ts)] done rc=$? ==="

echo "=== [$(ts)] ours_cache_large (32768 pages) ==="
NAME=ours_cache_large USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="--paged-cache-pages 32768" \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/cache_large.log" 2>&1
echo "=== [$(ts)] done rc=$? ==="

echo "=== [$(ts)] PHASE 4/6/7 SIFT-1M DONE ==="
