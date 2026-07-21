#!/bin/bash
# Addendum: refined adjacent-ratio sweep. sa_layer_mult = 1/ln(adj_ratio), centered on the paper
# default (ratio~3000, mult=0.125). SIFT 1M. STRICTLY SERIAL, resumable. Section-cap fix on (SA default).
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/sift_1m_r9010; CELL=sift_1m_r9010
LOGD=logs/adjratio; mkdir -p "$LOGD"
ts(){ date +%H:%M:%S; }
# adj_ratio -> sa_layer_mult (from the addendum table)
declare -A LM=( [750]=0.1511 [1500]=0.1367 [3000]=0.1249 [6000]=0.1150 [12000]=0.1065 )
for AR in 750 1500 3000 6000 12000; do
  name="ours_ar${AR}"
  out="results/raw/${name}_${CELL}.jsonl"
  [ -f "$out" ] && [ "$(wc -l <"$out")" -ge 50 ] && { echo "[$(ts)] SKIP $name"; continue; }
  echo "[$(ts)] START $name (adj_ratio=$AR sa_layer_mult=${LM[$AR]})"
  NAME="$name" USE_SA=1 LAYER_MULT="${LM[$AR]}" BULK=1 BUILD_THREADS=4 \
    bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/${name}.log" 2>&1
  echo "[$(ts)] done $name rc=$?"
done
echo "[$(ts)] ADJRATIO SWEEP DONE"
