#!/bin/bash
# Phase 8 — SA / section parameter sensitivity on SIFT 200k (fast; relative trends). Ours-only.
# STRICTLY SERIAL. One knob group at a time (no full Cartesian). Continue-on-error.
#   1. sketch depth (top_H = --hops) x beam (--sa-beam)  -> heatmap
#   2. layer ratio (LAYER_MULT)                          -> line
#   3. rebuild threshold (--sa-rebuild-alpha)            -> line
#   4. min cluster size (--sa-min-cluster)               -> line
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/sift_200k_r9010
CELL=sift_200k_r9010
LOGD=logs/phase8_param
mkdir -p "$LOGD"
ts(){ date +%H:%M:%S; }

# run <name> <hops> <layer_mult> <extra_args...>
run(){
  local name="$1" hops="$2" lm="$3"; shift 3
  NAME="$name" USE_SA=1 LAYER_MULT="$lm" BULK=1 BUILD_THREADS=4 EXTRA_ARGS="$*" \
    bash driver/run_ours.sh "$TRACE" "$CELL" 64 "$hops" 0 > "$LOGD/${name}.log" 2>&1
  echo "=== [$(ts)] done $name rc=$? ==="
}

echo "=== [$(ts)] GROUP 1: sketch depth (top_H) x beam ==="
for H in 2 3 4 5; do for B in 1 2 4 8; do
  run "ours_h${H}_b${B}" "$H" 0.125 "--sa-beam $B"
done; done

echo "=== [$(ts)] GROUP 2: layer ratio ==="
for LM in 0.0625 0.125 0.25; do
  run "ours_lm${LM}" 4 "$LM"
done

echo "=== [$(ts)] GROUP 3: rebuild threshold alpha ==="
for A in 0.1 0.2 0.3 0.5; do
  run "ours_alpha${A}" 4 0.125 "--sa-rebuild-alpha $A"
done

echo "=== [$(ts)] GROUP 4: min cluster size ==="
for MC in 8 16 32 64; do
  run "ours_mc${MC}" 4 0.125 "--sa-min-cluster $MC"
done

echo "=== [$(ts)] PHASE 8 PARAM SWEEP DONE ==="
