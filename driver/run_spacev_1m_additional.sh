#!/bin/bash
# SPACEV mirror of SIFT-1M additional experiments (ablation + cache + Pareto + Exp 1 trace). SERIAL.
# ours_section carries D6/D7 breakdown (Phase 4/6, Exp 2/2.1) + D9 Pareto sweep (Phase 7).
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/spacev_1m_r9010; CELL=spacev_1m_r9010
LOGD=logs/spacev_1m_add; mkdir -p "$LOGD"
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
runv ours_cache_small "--paged-cache-pages 2048"
runv ours_cache_large "--paged-cache-pages 32768"
echo "[$(ts)] Exp1 routing trace"
if [ ! -s work/exp1_trace_spacev_1m.jsonl ]; then
  rm -rf work/exp1_sv1m_db
  LSM-Vec-with-SA-HNSW/build/bin/bench_streaming --trace "$TRACE" --db work/exp1_sv1m_db \
    --out work/exp1_trace_spacev_1m.jsonl --efs 64 --hops 4 --bulk-build --build-threads 4 \
    --use-sa 1 --layer-mult 0.125 --trace-exp1 49 --trace-queries 1000 --query-sweep 16,32,64 \
    > "$LOGD/exp1_trace.log" 2>&1
  rm -rf work/exp1_sv1m_db
fi
echo "[$(ts)] SPACEV 1M ADDITIONAL DONE"
