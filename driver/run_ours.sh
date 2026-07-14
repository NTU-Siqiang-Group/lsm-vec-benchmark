#!/usr/bin/env bash
# Drive OUR system (or a lsm-vec ablation) over a shared trace and emit the per-epoch
# JSONL + real-time RSS stream. bench_streaming has its own in-process RSS sampler.
#
# Run from the benchmark root. Usage: driver/run_ours.sh <trace_dir> <cell_tag> [ef_final] [hops] [query_subsample]
#   e.g. driver/run_ours.sh work/sift_1m_r9010 sift_1m_r9010 64 4 0
# Env overrides (ablations / MT build):
#   NAME=ours|lsm-vec-no-sa|lsm-vec-basic   output prefix (default ours)
#   USE_SA=1|0        SA overlay on/off (default 1)
#   LAYER_MULT=0.125  level multiplier (0.125=flat ours/no-sa, 0=standard HNSW basic)
#   BULK=1            base load via multi-thread bulk build (default off = streaming Insert)
#   BUILD_THREADS=4   bulk-build parallelism (default 1)
# query_subsample N: non-checkpoint epochs query only N (0 = full every epoch — publication).
set -euo pipefail
cd "$(dirname "$0")/.."   # benchmark project root

TRACE="${1:?trace_dir}"
CELL="${2:?cell_tag (e.g. sift_1m_r9010)}"
EF_FINAL="${3:-128}"
HOPS="${4:-4}"
QSUB="${5:-0}"

NAME="${NAME:-ours}"
EFS="${EFS:-64}"          # ef_search — the recall knob for the no-SA ablations (no-op in ours' SA path)
USE_SA="${USE_SA:-1}"
LAYER_MULT="${LAYER_MULT:-0.125}"
BULK="${BULK:-}"
BUILD_THREADS="${BUILD_THREADS:-1}"

BIN=LSM-Vec-with-SA-HNSW/build/bin/bench_streaming
RAW=results/raw
DB=work/${NAME}_db_${CELL}
mkdir -p "$RAW"
rm -rf "$DB"

EXTRA=""
[ -n "$BULK" ] && EXTRA="--bulk-build --build-threads $BUILD_THREADS"
# EXTRA_ARGS: free-form passthrough for ablation/sweep flags (--sa-route-off, --layout, --sa-max-children,
# --checkpoint-epochs/--query-sweep, ...). Appended verbatim.
EXTRA_ARGS="${EXTRA_ARGS:-}"

echo "[run_ours] name=$NAME cell=$CELL ef_final=$EF_FINAL hops=$HOPS qsub=$QSUB use_sa=$USE_SA layer_mult=$LAYER_MULT bulk=${BULK:-0} build_threads=$BUILD_THREADS extra_args='$EXTRA_ARGS'"
"$BIN" --trace "$TRACE" --db "$DB" \
  --out  "$RAW/${NAME}_${CELL}.jsonl" \
  --mem  "$RAW/${NAME}_${CELL}.mem.jsonl" \
  --efs "$EFS" --ef-final "$EF_FINAL" --hops "$HOPS" --query-subsample "$QSUB" \
  --use-sa "$USE_SA" --layer-mult "$LAYER_MULT" $EXTRA $EXTRA_ARGS

echo "[run_ours] done -> $RAW/${NAME}_${CELL}.jsonl (+ .mem.jsonl)"
