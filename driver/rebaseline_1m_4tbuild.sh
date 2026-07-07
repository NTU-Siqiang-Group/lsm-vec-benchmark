#!/bin/bash
# Full 1M re-baseline (2026-07-06 methodology): 4-thread BUILD, single-thread WORKLOAD,
# memory measured workload-only (bench.py filters epoch>=0). STRICTLY SERIAL — one system
# at a time (serial-measurement rule). Continue-on-error with clear markers.
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/sift_1m_r9010
CELL=sift_1m_r9010
LOGD=logs/rebaseline_1m
mkdir -p "$LOGD"
ts() { date +%H:%M:%S; }

# 1. ours — bulk build @4t (only 4-thread path), ef_final=64
echo "=== [$(ts)] START ours ==="
NAME=ours USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/ours.log" 2>&1
echo "=== [$(ts)] DONE ours rc=$? ==="

# 2. lsm-vec-no-sa — flat shape, SA off, efs=64
echo "=== [$(ts)] START lsm-vec-no-sa ==="
NAME=lsm-vec-no-sa USE_SA=0 LAYER_MULT=0.125 EFS=64 BULK=1 BUILD_THREADS=4 \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/nosa.log" 2>&1
echo "=== [$(ts)] DONE lsm-vec-no-sa rc=$? ==="

# 3. lsm-vec-basic — standard HNSW shape (layer_mult=0), SA off, efs=64
echo "=== [$(ts)] START lsm-vec-basic ==="
NAME=lsm-vec-basic USE_SA=0 LAYER_MULT=0 EFS=64 BULK=1 BUILD_THREADS=4 \
  bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/basic.log" 2>&1
echo "=== [$(ts)] DONE lsm-vec-basic rc=$? ==="

# 4. spfresh — build 4t, workload 1t (LIRE on)
echo "=== [$(ts)] START spfresh ==="
BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh "$TRACE" spfresh 64 > "$LOGD/spfresh.log" 2>&1
echo "=== [$(ts)] DONE spfresh rc=$? ==="

# 5. spannplus — build 4t, workload 1t (reassign off)
echo "=== [$(ts)] START spannplus ==="
BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh "$TRACE" spannplus 64 > "$LOGD/spannplus.log" 2>&1
echo "=== [$(ts)] DONE spannplus rc=$? ==="

# 6. diskann_merge — build 4t, merge_every=30M (user's choice; merges don't fire at 1M), fresh build
echo "=== [$(ts)] START diskann_merge ==="
rm -rf work/diskann_merge_sift_1m_idx && mkdir -p work/diskann_merge_sift_1m_idx
diskann_merge_src/build/tests/bench_stream_merge \
  --trace "$TRACE" \
  --out results/raw/diskann_merge_${CELL}.jsonl \
  --mem results/raw/diskann_merge_${CELL}.mem.jsonl \
  --index_prefix work/diskann_merge_sift_1m_idx/idx --work_dir work/diskann_merge_sift_1m_idx \
  --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 30000000 \
  > "$LOGD/diskann_merge.log" 2>&1
echo "=== [$(ts)] DONE diskann_merge rc=$? ==="

echo "=== [$(ts)] ALL DONE ==="
