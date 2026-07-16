#!/bin/bash
# DiskANN flush 10M cells, disk-guarded. Aborts the run if free disk < 12GB (DiskANN 10M merges
# need ~48GB transient temp; a watchdog prevents a disk-full crash mid-workload).
set -u
cd /home/dmo/lsm_vec_benchmark
ts(){ date +%H:%M:%S; }
run_one(){
  local cell="$1"
  local out="results/raw/diskann_merge_flush_${cell}.jsonl"
  [ -f "$out" ] && [ "$(wc -l <"$out")" -ge 50 ] && { echo "[$(ts)] SKIP $cell"; return 0; }
  local idx=work/diskann_merge_flush_${cell}_idx
  rm -rf ${idx}* && mkdir -p "$idx"
  echo "[$(ts)] START $cell"
  diskann_merge_src/build/tests/bench_stream_merge --trace work/$cell \
    --out "$out" --mem results/raw/diskann_merge_flush_${cell}.mem.jsonl \
    --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000 \
    > logs/diskann_flush/${cell}.log 2>&1 &
  local pid=$!
  # watchdog: kill if free disk drops below 12GB
  while kill -0 $pid 2>/dev/null; do
    local free_kb=$(df --output=avail /home/dmo | tail -1)
    if [ "$free_kb" -lt 12582912 ]; then
      echo "[$(ts)] ABORT $cell: free disk < 12GB, killing to avoid crash"
      kill -9 $pid 2>/dev/null; rm -rf ${idx}*
      return 1
    fi
    sleep 30
  done
  wait $pid; echo "[$(ts)] done $cell rc=$?"
  rm -rf ${idx}temp*  # clean merge temp files after each cell
}
run_one sift_10m_r9010
run_one spacev_10m_r9010
echo "[$(ts)] DISKANN FLUSH 10M DONE"
