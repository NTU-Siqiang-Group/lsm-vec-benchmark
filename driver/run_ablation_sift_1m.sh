#!/bin/bash
# Phase 2 (SA-routing, D4) + Phase 3 (layout, D5) ablations on SIFT 1M. Ours-variants only (no
# baselines). STRICTLY SERIAL. All share the same deterministic bulk build (only the ablated knob
# differs). Reference arm = ours_section (section layout, SA routing on); canonical `ours` untouched.
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/sift_1m_r9010
CELL=sift_1m_r9010
LOGD=logs/ablation_sift_1m
mkdir -p "$LOGD"
ts(){ date +%H:%M:%S; }

echo "=== [$(ts)] ours_section (section, route-on) — reference for Phase 2 & 3 ==="
NAME=ours_section USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/ours_section.log" 2>&1
echo "=== [$(ts)] done rc=$? ==="

echo "=== [$(ts)] ours_no_sa (section, route-OFF) — D4 Phase 2 controlled arm ==="
NAME=ours_no_sa USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="--sa-route-off" \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/ours_no_sa.log" 2>&1
echo "=== [$(ts)] done rc=$? ==="

echo "=== [$(ts)] ours_append (append layout) — D5 Phase 3 ==="
NAME=ours_append USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="--layout append" \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/ours_append.log" 2>&1
echo "=== [$(ts)] done rc=$? ==="

echo "=== [$(ts)] ours_random (random layout) — D5 Phase 3 ==="
NAME=ours_random USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="--layout random" \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/ours_random.log" 2>&1
echo "=== [$(ts)] done rc=$? ==="

echo "=== [$(ts)] ABLATION SIFT-1M DONE ==="
