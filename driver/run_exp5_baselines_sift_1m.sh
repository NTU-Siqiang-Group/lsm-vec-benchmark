#!/bin/bash
# Exp 5 (disk breakdown): regenerate the SIFT-1M baseline index directories (cleaned earlier) so we can
# split them into components. Full R-9010 workload (matches the RESULTS end-of-workload disk numbers).
# STRICTLY SERIAL. Dirs are LEFT IN PLACE for inspection.
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/sift_1m_r9010
CELL=sift_1m_r9010
LOGD=logs/exp5_baselines
mkdir -p "$LOGD"
ts(){ date +%H:%M:%S; }

echo "=== [$(ts)] spfresh ==="
BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh "$TRACE" spfresh 64 > "$LOGD/spfresh.log" 2>&1
echo "=== [$(ts)] done spfresh rc=$? ==="

echo "=== [$(ts)] spannplus ==="
BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh "$TRACE" spannplus 64 > "$LOGD/spannplus.log" 2>&1
echo "=== [$(ts)] done spannplus rc=$? ==="

echo "=== [$(ts)] diskann_merge ==="
rm -rf work/diskann_merge_${CELL}_idx && mkdir -p work/diskann_merge_${CELL}_idx
diskann_merge_src/build/tests/bench_stream_merge \
  --trace "$TRACE" \
  --out results/raw/diskann_merge_${CELL}_exp5.jsonl \
  --mem results/raw/diskann_merge_${CELL}_exp5.mem.jsonl \
  --index_prefix work/diskann_merge_${CELL}_idx/idx --work_dir work/diskann_merge_${CELL}_idx \
  --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 30000000 \
  > "$LOGD/diskann_merge.log" 2>&1
echo "=== [$(ts)] done diskann_merge rc=$? ==="

echo "=== [$(ts)] EXP5 BASELINES DONE ==="
