#!/bin/bash
# DiskANN flush-regime variant: merge_every=100000 (fires StreamingMerge, bounded in-memory delta).
# Added to every cell that has DiskANN. STRICTLY SERIAL. 1M cells first (fast), then 10M.
set -u
cd /home/dmo/lsm_vec_benchmark
ts(){ date +%H:%M:%S; }
run_one(){
  local cell="$1"
  local out="results/raw/diskann_merge_flush_${cell}.jsonl"
  [ -f "$out" ] && [ "$(wc -l <"$out")" -ge 50 ] && { echo "[$(ts)] SKIP $cell"; return 0; }
  local idx=work/diskann_merge_flush_${cell}_idx
  rm -rf "$idx" && mkdir -p "$idx"
  echo "[$(ts)] START $cell"
  diskann_merge_src/build/tests/bench_stream_merge --trace work/$cell \
    --out "$out" --mem results/raw/diskann_merge_flush_${cell}.mem.jsonl \
    --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000 \
    > logs/diskann_flush/${cell}.log 2>&1
  echo "[$(ts)] done $cell rc=$?"
}
run_one sift_1m_r9010
run_one spacev_1m_r9010
run_one sift_10m_r9010
run_one spacev_10m_r9010
echo "[$(ts)] DISKANN FLUSH ALL DONE"
