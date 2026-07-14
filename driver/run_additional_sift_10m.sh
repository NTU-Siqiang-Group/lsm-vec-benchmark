#!/bin/bash
# Additional experiments at SIFT 10M (Phases 2/3/4/6/7). Ours-only, STRICTLY SERIAL. Same
# deterministic bulk build; only the ablated knob differs. Reference = ours_section (also carries the
# D6/D7 breakdown + D9 Pareto sweep at GT-aligned epochs 0/20/40). NB: 128-d -> section_layer=2, so the
# section layout may hit the section-collapse at 10M (few level-2 nodes) — the run measures that too.
# RESUMABLE: a variant whose raw jsonl already has all 50 epochs is skipped (survives power loss).
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/sift_10m_r9010
CELL=sift_10m_r9010
LOGD=logs/additional_sift_10m
mkdir -p "$LOGD"
ts(){ date +%H:%M:%S; }

# runv <name> <extra_args...>
runv(){
  local name="$1"; shift
  local out="results/raw/${name}_${CELL}.jsonl"
  if [ -f "$out" ] && [ "$(wc -l < "$out")" -ge 50 ]; then
    echo "=== [$(ts)] SKIP $name (already 50 epochs) ==="
    return 0
  fi
  echo "=== [$(ts)] START $name  extra='$*' ==="
  NAME="$name" USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="$*" \
    bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/${name}.log" 2>&1
  echo "=== [$(ts)] done $name rc=$? ==="
}

runv ours_section "--checkpoint-epochs 0,20,40 --query-sweep 16,32,48,64,96,128"   # Phase 4/6/7
runv ours_no_sa   "--sa-route-off"                                                 # Phase 2
runv ours_append  "--layout append"                                               # Phase 3
runv ours_random  "--layout random"                                               # Phase 3

echo "=== [$(ts)] ADDITIONAL SIFT-10M DONE ==="
