#!/bin/bash
# Phase C part 2 (docs/2026-10-04-byte-main-matrix-plan.md), user-approved order 2026-10-06:
#   1. ours_b8r256c (= ours_b8r256 + compact resident sketch, LSM-Vec 1b31829, bench_v6) on 1M/10M
#   2. ours_b8r256c on sift_100m / spacev_100m (sharded RNND build, 16 shards)
#   3. spfresh_byte on sift_100m / spacev_100m (disk watchdog: stop if free < 50 GB)
#   4. diskann_flush_byte on sift_100m under a 115 GB cgroup cap; spacev_100m only if sift succeeded
# Same settings as Phase C part 1 / §17. STRICTLY SERIAL, resumable, never overwrites existing files.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
LOGD=logs/phase_c2; mkdir -p $LOGD results/raw
ts(){ date +'%m-%d %H:%M:%S'; }
done50(){ [ -f "$1" ] && [ "$(grep -c '"epoch"' "$1")" -ge 50 ]; }
freegb(){ echo $(( $(df --output=avail /home/dmo | tail -1) / 1048576 )); }
SPID=""
sampler_on(){ python3 driver/cache_sampler.py --dir "$2" --out "$1" --interval ${4:-20} ${3:+--epoch-file $3} >/dev/null 2>&1 & SPID=$!; }
sampler_off(){ [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; SPID=""; }

OURS=ours_b8r256c; BIN=work/bin/bench_v6
ours_leg(){ local cell=$1 r8=$2 extra=${3:-} iv=${4:-20} out=results/raw/${OURS}_$1.jsonl db=work/${OURS}_db_$1
  done50 $out && { echo "[$(ts)] SKIP $OURS $cell"; return; }
  echo "[$(ts)] START $OURS $cell $extra (free $(freegb)G)"; rm -rf $db
  sampler_on results/raw/${OURS}_$cell.cache.jsonl $db "" $iv
  $BIN --trace work/$cell --db $db --out $out --mem results/raw/${OURS}_$cell.mem.jsonl \
    --efs 64 --ef-final 64 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.18034 \
    --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 $r8 \
    --checkpoint-epochs 49 --query-sweep 32,48,64,80,100,128 $extra > $LOGD/${OURS}_$cell.log 2>&1
  echo "[$(ts)] $OURS $cell rc=$?"; sampler_off
  du -sb $db > $LOGD/${OURS}_$cell.du.txt 2>&1
  driver/tools/lsm_inspect $db varint > $LOGD/${OURS}_$cell.inspect.txt 2>&1; rm -rf $db; }

spfresh_leg(){ local cell=$1 vt=$2 name=spfresh_byte iv=${3:-20}
  local out=results/raw/${name}_${cell}.jsonl
  done50 "$out" && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START $name $cell ($vt) (free $(freegb)G)"
  rm -rf work/${name}_${cell}; mkdir -p work/${name}_${cell}/store
  sampler_on results/raw/${name}_${cell}.cache.jsonl work/${name}_${cell}/store work/${name}_${cell}/epoch.ctl $iv
  VALUE_TYPE=$vt BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh work/$cell $name 64 > $LOGD/${name}_${cell}.log 2>&1 &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    if [ "$(freegb)" -lt 50 ]; then echo "[$(ts)] DISK WATCHDOG: free $(freegb)G < 50G -> stopping $name $cell"; pkill -P $pid; kill $pid; fi
    sleep 60; done
  wait $pid; echo "[$(ts)] $name $cell rc=$? (free $(freegb)G)"; sampler_off
  du -sb work/${name}_${cell} > $LOGD/${name}_${cell}.du.txt 2>&1
  cp -f work/${name}_${cell}/build.log $LOGD/${name}_${cell}.build.log 2>/dev/null
  rm -rf work/${name}_${cell}; }

diskann_leg(){ local cell=$1 sfx=$2 name=diskann_flush_byte iv=${3:-20}
  local out=results/raw/${name}_${cell}.jsonl idx=work/${name}_${cell}_idx
  done50 "$out" && { echo "[$(ts)] SKIP $name $cell"; return 0; }
  echo "[$(ts)] START $name $cell ($sfx) under MemoryMax=115G (free $(freegb)G)"
  rm -rf ${idx}* && mkdir -p $idx
  sampler_on results/raw/${name}_${cell}.cache.jsonl $idx "" $iv
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemd-run --user --scope -q -p MemoryMax=115G -p MemorySwapMax=0 -- \
    diskann_merge_src/build/tests/bench_stream_merge_$sfx --trace work/$cell \
    --out $out --mem results/raw/${name}_${cell}.mem.jsonl --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000 \
    > $LOGD/${name}_${cell}.log 2>&1
  local rc=$?; echo "[$(ts)] $name $cell rc=$rc"; sampler_off
  du -sb $idx > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf ${idx}*
  done50 "$out"; }

ours_leg sift_1m_r9010 u8
ours_leg spacev_1m_r9010 i8
ours_leg sift_10m_r9010 u8
ours_leg spacev_10m_r9010 i8
ours_leg sift_100m_r9010 u8 "--sharded-build 16" 60
ours_leg spacev_100m_r9010 i8 "--sharded-build 16" 60
spfresh_leg sift_100m_r9010 UInt8 60
spfresh_leg spacev_100m_r9010 Int8 60
if diskann_leg sift_100m_r9010 u8 60; then diskann_leg spacev_100m_r9010 i8 60
else echo "[$(ts)] diskann_flush_byte sift_100m did not complete 50 epochs -> skipping spacev_100m"; fi
echo "[$(ts)] PHASE C2 DONE"
