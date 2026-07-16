#!/bin/bash
# SPACEV mirror of the SIFT-200k experiments: Phase 8 param sweeps + Exp 3 (M) + Exp 4 (latency).
# STRICTLY SERIAL. Same settings as the SIFT 200k runs (bounded cache 256 for the reads-signal sweeps).
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/spacev_200k_r9010
CELL=spacev_200k_r9010
LOGD=logs/spacev_200k
mkdir -p "$LOGD"
ts(){ date +%H:%M:%S; }
# runv <name> <hops> <layer_mult> <extra_args...>
runv(){
  local name="$1" hops="$2" lm="$3"; shift 3
  local out="results/raw/${name}_${CELL}.jsonl"
  [ -f "$out" ] && [ "$(wc -l <"$out")" -ge 50 ] && { echo "[$(ts)] SKIP $name"; return 0; }
  NAME="$name" USE_SA=1 LAYER_MULT="$lm" BULK=1 BUILD_THREADS=4 EXTRA_ARGS="$*" \
    bash driver/run_ours.sh "$TRACE" "$CELL" 64 "$hops" "${QSUB:-0}" > "$LOGD/${name}.log" 2>&1
  echo "[$(ts)] done $name rc=$?"
}

echo "=== [$(ts)] GROUP 1: sketch depth (top_H) x beam (bounded cache 256, qsub 200) ==="
QSUB=200
for H in 2 3 4 5; do for B in 1 2 4 8; do runv "ours_h${H}_b${B}" "$H" 0.125 "--sa-beam $B --paged-cache-pages 256"; done; done
QSUB=0

echo "=== [$(ts)] GROUP 2: layer ratio ==="
for LM in 0.125 0.25; do runv "ours_lm${LM}" 4 "$LM"; done

echo "=== [$(ts)] GROUP 3: rebuild alpha ==="
for A in 0.1 0.2 0.3 0.5; do runv "ours_alpha${A}" 4 0.125 "--sa-rebuild-alpha $A"; done

echo "=== [$(ts)] GROUP 4: min cluster size ==="
for MC in 8 16 32 64; do runv "ours_mc${MC}" 4 0.125 "--sa-min-cluster $MC"; done

echo "=== [$(ts)] GROUP 5: graph out-degree M (Exp 3) ==="
for M in 8 16 32 48; do runv "ours_M${M}" 4 0.125 "--m $M --m-max $((M*2))"; done

echo "=== [$(ts)] GROUP 6: Exp 4 latency (bounded cache 256, query-subsample 200 to bound time) ==="
NAME=ours_q USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="--paged-cache-pages 256" \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 200 > "$LOGD/ours_q.log" 2>&1; echo "[$(ts)] done ours_q rc=$?"
NAME=ours_q_nosa USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="--sa-route-off --paged-cache-pages 256" \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 200 > "$LOGD/ours_q_nosa.log" 2>&1; echo "[$(ts)] done ours_q_nosa rc=$?"

echo "=== [$(ts)] SPACEV 200k PARAMS DONE ==="
