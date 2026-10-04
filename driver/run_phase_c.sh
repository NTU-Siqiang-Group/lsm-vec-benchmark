#!/bin/bash
# Phase C (docs/2026-10-04-byte-main-matrix-plan.md), part 1: 1M + 10M, native byte types.
#   ours_b8r256 = v3 + idToPage int32 + raw byte records (--vec-raw8 u8|i8) + adjacent ratio 256,
#                 efc 12, ef_final 64 (user-chosen operating point, 2026-10-05); epoch-49 ef sweep.
#   missing byte baselines: spfresh_byte spacev_10m; diskann_flush_byte sift_10m, spacev_10m
#   (settings identical to §17 / run_byte_step1.sh). Existing byte baseline runs are reused.
# STRICTLY SERIAL, resumable (a leg with 50 epochs is skipped). Never overwrites existing files.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
LOGD=logs/phase_c; mkdir -p $LOGD results/raw
ts(){ date +'%m-%d %H:%M:%S'; }
done50(){ [ -f "$1" ] && [ "$(grep -c '"epoch"' "$1")" -ge 50 ]; }
SPID=""
sampler_on(){ python3 driver/cache_sampler.py --dir "$2" --out "$1" --interval 20 ${3:+--epoch-file $3} >/dev/null 2>&1 & SPID=$!; }
sampler_off(){ [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; SPID=""; }

OURS=ours_b8r256; BIN=work/bin/bench_v5
ours_leg(){ local cell=$1 r8=$2 out=results/raw/${OURS}_$1.jsonl db=work/${OURS}_db_$1
  done50 $out && { echo "[$(ts)] SKIP $OURS $cell"; return; }
  echo "[$(ts)] START $OURS $cell"; rm -rf $db
  sampler_on results/raw/${OURS}_$cell.cache.jsonl $db
  $BIN --trace work/$cell --db $db --out $out --mem results/raw/${OURS}_$cell.mem.jsonl \
    --efs 64 --ef-final 64 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.18034 \
    --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 $r8 \
    --checkpoint-epochs 49 --query-sweep 32,48,64,80,100,128 > $LOGD/${OURS}_$cell.log 2>&1
  echo "[$(ts)] $OURS $cell rc=$?"; sampler_off
  driver/tools/lsm_inspect $db varint > $LOGD/${OURS}_$cell.inspect.txt 2>&1; rm -rf $db; }

spfresh_leg(){ local cell=$1 vt=$2 name=spfresh_byte
  local out=results/raw/${name}_${cell}.jsonl
  done50 "$out" && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START $name $cell ($vt)"
  rm -rf work/${name}_${cell}; mkdir -p work/${name}_${cell}/store
  sampler_on results/raw/${name}_${cell}.cache.jsonl work/${name}_${cell}/store work/${name}_${cell}/epoch.ctl
  VALUE_TYPE=$vt BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh work/$cell $name 64 > $LOGD/${name}_${cell}.log 2>&1
  echo "[$(ts)] $name $cell rc=$?"; sampler_off
  cp -f work/${name}_${cell}/build.log $LOGD/${name}_${cell}.build.log 2>/dev/null
  rm -rf work/${name}_${cell}; }

diskann_leg(){ local cell=$1 sfx=$2 name=diskann_flush_byte
  local out=results/raw/${name}_${cell}.jsonl idx=work/${name}_${cell}_idx
  done50 "$out" && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START $name $cell ($sfx)"
  rm -rf ${idx}* && mkdir -p $idx
  sampler_on results/raw/${name}_${cell}.cache.jsonl $idx
  diskann_merge_src/build/tests/bench_stream_merge_$sfx --trace work/$cell \
    --out $out --mem results/raw/${name}_${cell}.mem.jsonl --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000 \
    > $LOGD/${name}_${cell}.log 2>&1
  echo "[$(ts)] $name $cell rc=$?"; sampler_off
  rm -rf ${idx}*; }

ours_leg sift_1m_r9010 u8
ours_leg spacev_1m_r9010 i8
ours_leg sift_10m_r9010 u8
ours_leg spacev_10m_r9010 i8
spfresh_leg spacev_10m_r9010 Int8
diskann_leg sift_10m_r9010 u8
diskann_leg spacev_10m_r9010 i8
echo "[$(ts)] PHASE C (1M/10M) DONE"
