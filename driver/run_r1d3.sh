#!/bin/bash
# R1-D3 cache protocol study (2026-10-12/13). SIFT 1M and 10M, native byte types.
#   ours P0 (current protocol: each query phase follows the previous epoch's evaluation queries) + --cache-stats
#   all systems P2 = --cold-queries --warmup-queries 2000: drop every cache (process caches + OS page cache of the
#   store) before each query phase, then warm with 2,000 pool vectors (never the evaluation queries).
# Baselines' P0 = existing §17/§26 byte runs. New names only (never overwrites). STRICTLY SERIAL.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
LOGD=logs/r1d3; mkdir -p $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
done50(){ [ -f "$1" ] && [ "$(grep -c '"epoch"' "$1")" -ge 50 ]; }
P2="--cold-queries --warmup-queries 2000"
B="--graph-lean+--vec-raw8+u8+--layer-mult+0.18034+--efc+12+--ef-final+64+--cache-stats"
driver/run_port_steps.sh r1d3_p0:v9:sift_1m_r9010:50:$B r1d3_p2:v9:sift_1m_r9010:50:$B+--cold-queries+--warmup-queries+2000
spf(){ local cell=$1 name=spfresh_byte_coldwu out=results/raw/spfresh_byte_coldwu_$1.jsonl
  done50 $out && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START $name $cell"; rm -rf work/${name}_$cell; mkdir -p work/${name}_$cell/store
  python3 driver/cache_sampler.py --dir work/${name}_$cell/store --out results/raw/${name}_$cell.cache.jsonl --interval 20 --epoch-file work/${name}_$cell/epoch.ctl >/dev/null 2>&1 & local sp=$!
  VALUE_TYPE=UInt8 BUILD_THREADS=4 THREADS=1 SWEEP_ARGS="$P2" bash driver/run_spfresh.sh work/$cell $name 64 > $LOGD/${name}_$cell.log 2>&1
  echo "[$(ts)] $name $cell rc=$?"; kill $sp 2>/dev/null; rm -rf work/${name}_$cell; }
dsk(){ local cell=$1 name=diskann_flush_byte_coldwu out=results/raw/diskann_flush_byte_coldwu_$1.jsonl idx=work/diskann_flush_byte_coldwu_$1_idx
  done50 $out && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START $name $cell"; rm -rf ${idx}* && mkdir -p $idx
  python3 driver/cache_sampler.py --dir $idx --out results/raw/${name}_$cell.cache.jsonl --interval 20 >/dev/null 2>&1 & local sp=$!
  diskann_merge_src/build/tests/bench_stream_merge_u8 --trace work/$cell --out $out --mem results/raw/${name}_$cell.mem.jsonl \
    --index_prefix $idx/idx --work_dir $idx --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 \
    --merge_every 100000 $P2 > $LOGD/${name}_$cell.log 2>&1
  echo "[$(ts)] $name $cell rc=$?"; kill $sp 2>/dev/null; rm -rf ${idx}*; }
spf sift_1m_r9010
dsk sift_1m_r9010
driver/run_port_steps.sh r1d3_p0:v9:sift_10m_r9010:50:$B r1d3_p2:v9:sift_10m_r9010:50:$B+--cold-queries+--warmup-queries+2000
spf sift_10m_r9010
dsk sift_10m_r9010
echo "[$(ts)] R1D3 DONE"
