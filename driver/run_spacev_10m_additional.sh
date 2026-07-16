#!/bin/bash
# SPACEV mirror of SIFT-10M additional (ablation; current binary has section-cap fix as default). SERIAL.
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/spacev_10m_r9010; CELL=spacev_10m_r9010
LOGD=logs/spacev_10m_add; mkdir -p "$LOGD"
ts(){ date +%H:%M:%S; }
runv(){ local name="$1"; shift
  local out="results/raw/${name}_${CELL}.jsonl"
  [ -f "$out" ] && [ "$(wc -l <"$out")" -ge 50 ] && { echo "[$(ts)] SKIP $name"; return 0; }
  NAME="$name" USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="$*" \
    bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/${name}.log" 2>&1
  echo "[$(ts)] done $name rc=$?"
}
runv ours_section "--checkpoint-epochs 0,20,40 --query-sweep 16,32,48,64,96,128"
runv ours_no_sa   "--sa-route-off"
runv ours_append  "--layout append"
runv ours_random  "--layout random"
echo "[$(ts)] SPACEV 10M ADDITIONAL DONE"
