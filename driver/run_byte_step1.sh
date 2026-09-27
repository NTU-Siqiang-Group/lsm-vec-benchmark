#!/bin/bash
# PVLDB revision Step 1 (docs/2026-09-27-pvldb-revision-server-handoff.md §5): native-byte baselines.
# SPFresh and FreshDiskANN-style merge store vectors in the dataset's native byte type
# (SIFT uint8, SPACEV int8) instead of V2's float32. Same traces, GT, and parameters as V2.1.
# Ours is NOT rerun (compared against the existing ours_efc20 / ours_v2 V2.1 results).
# STRICTLY SERIAL, resumable (a leg with 50 epochs is skipped). Never writes a V2 file name.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
LOGD=logs/byte_step1; MB=results/v2_tuned/membudget
mkdir -p "$LOGD" "$MB" results/raw
ts(){ date +'%m-%d %H:%M:%S'; }
done50(){ [ -f "$1" ] && [ "$(grep -c '"epoch"' "$1")" -ge 50 ]; }
SPID=""
sampler_on(){ python3 driver/cache_sampler.py --dir "$2" --out "$1" --interval 20 ${3:+--epoch-file $3} >/dev/null 2>&1 & SPID=$!; }
sampler_off(){ [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; SPID=""; }

# $1 cell  $2 VALUE_TYPE(UInt8|Int8)
spfresh_leg(){
  local cell=$1 vt=$2 name=spfresh_byte
  local out=results/raw/${name}_${cell}.jsonl
  done50 "$out" && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START $name $cell ($vt)"
  rm -rf work/${name}_${cell}
  mkdir -p work/${name}_${cell}/store
  sampler_on results/raw/${name}_${cell}.cache.jsonl work/${name}_${cell}/store work/${name}_${cell}/epoch.ctl
  VALUE_TYPE=$vt BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh work/$cell $name 64 \
    > $LOGD/${name}_${cell}.log 2>&1
  echo "[$(ts)] $name $cell rc=$?"; sampler_off
  cp -f work/${name}_${cell}/build.log $LOGD/${name}_${cell}.build.log 2>/dev/null
  rm -rf work/${name}_${cell}
}

# $1 cell  $2 bin suffix (u8|i8)
diskann_leg(){
  local cell=$1 sfx=$2 name=diskann_flush_byte
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
  rm -rf ${idx}*
}

# memory-cap legs (§14.5 protocol: cgroup-v2 MemoryMax + MemorySwapMax=0, 3h timeout; OOM = data point)
cap_run(){  # $1 tag $2 bytes $3 name ; rest = command
  local tag=$1 bytes=$2 name=$3; shift 3
  local out=$MB/${name}_mb${tag}_sift_1m_r9010.jsonl
  done50 "$out" && { echo "[$(ts)] SKIP $name mb$tag"; return; }
  echo "[$(ts)] START $name mb$tag (MemoryMax=$bytes)"
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} timeout 10800 \
    systemd-run --user --scope -q -p MemoryMax=$bytes -p MemorySwapMax=0 -- "$@" \
    > $LOGD/${name}_mb${tag}.log 2>&1
  echo "[$(ts)] $name mb$tag rc=$?"
}
cap_legs(){
  local cell=sift_1m_r9010
  for pair in 4g:4G 2g:2G; do
    local tag=${pair%%:*} bytes=${pair##*:}
    rm -rf work/spfresh_bytecap_${cell}
    cap_run $tag $bytes spfresh_byte env VALUE_TYPE=UInt8 BUILD_THREADS=4 THREADS=1 \
      bash driver/run_spfresh.sh work/$cell spfresh_bytecap 64
    [ -f results/raw/spfresh_bytecap_${cell}.jsonl ] && \
      mv -f results/raw/spfresh_bytecap_${cell}.jsonl $MB/spfresh_byte_mb${tag}_${cell}.jsonl
    [ -f results/raw/spfresh_bytecap_${cell}.mem.jsonl ] && \
      mv -f results/raw/spfresh_bytecap_${cell}.mem.jsonl $MB/spfresh_byte_mb${tag}_${cell}.mem.jsonl
    cp -f work/spfresh_bytecap_${cell}/build.log $LOGD/spfresh_byte_mb${tag}.build.log 2>/dev/null
    cp -f work/spfresh_bytecap_${cell}/run.log $LOGD/spfresh_byte_mb${tag}.run.log 2>/dev/null
    rm -rf work/spfresh_bytecap_${cell}

    local idx=work/diskann_bytecap_idx; rm -rf ${idx}* && mkdir -p $idx
    cap_run $tag $bytes diskann_flush_byte diskann_merge_src/build/tests/bench_stream_merge_u8 \
      --trace work/$cell --out $MB/diskann_flush_byte_mb${tag}_${cell}.jsonl \
      --mem $MB/diskann_flush_byte_mb${tag}_${cell}.mem.jsonl --index_prefix $idx/idx --work_dir $idx \
      --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000
    rm -rf ${idx}*
  done
}

echo "[$(ts)] BYTE STEP1 START"
spfresh_leg spacev_1m_r9010 Int8
diskann_leg spacev_1m_r9010 i8
spfresh_leg sift_1m_r9010   UInt8
diskann_leg sift_1m_r9010   u8
cap_legs
if [ "${WITH_10M:-0}" = "1" ]; then
  [ -f work/sift_10m_r9010/base.u8bin ] || python3 driver/fbin_to_byte.py work/sift_10m_r9010 uint8
  spfresh_leg sift_10m_r9010 UInt8
fi
echo "[$(ts)] BYTE STEP1 DONE"
