#!/bin/bash
# FreshDiskANN-byte at 100M (user decision 2026-10-09), then the 100M ef_final study.
# The Phase C2 attempt failed because the default indexing RAM budget (--M_gb 16) made DiskANN switch to its
# sharded "merged index" build, which refuses tags (needed by StreamingMerge). --M_gb 100 keeps the normal
# single in-memory Vamana build; it only sets DiskANN's build RAM budget (all other settings as §17/Phase C).
# Runs under a 115 GB cgroup cap. spacev_100m only if sift_100m completes 50 epochs. STRICTLY SERIAL.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
LOGD=logs/phase_c2; mkdir -p $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
done50(){ [ -f "$1" ] && [ "$(grep -c '"epoch"' "$1")" -ge 50 ]; }
freegb(){ echo $(( $(df --output=avail /home/dmo | tail -1) / 1048576 )); }
diskann_leg(){ local cell=$1 sfx=$2 name=diskann_flush_byte
  local out=results/raw/${name}_${cell}.jsonl idx=work/${name}_${cell}_idx
  done50 "$out" && { echo "[$(ts)] SKIP $name $cell"; return 0; }
  echo "[$(ts)] START $name $cell ($sfx) --M_gb 100 under MemoryMax=115G (free $(freegb)G)"
  rm -rf ${idx}* && mkdir -p $idx
  python3 driver/cache_sampler.py --dir $idx --out results/raw/${name}_${cell}.cache.jsonl --interval 60 >/dev/null 2>&1 & local sp=$!
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemd-run --user --scope -q -p MemoryMax=115G -p MemorySwapMax=0 -- \
    diskann_merge_src/build/tests/bench_stream_merge_$sfx --trace work/$cell \
    --out $out --mem results/raw/${name}_${cell}.mem.jsonl --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000 --M_gb 100 \
    > $LOGD/${name}_${cell}.log 2>&1
  echo "[$(ts)] $name $cell rc=$? (free $(freegb)G)"; kill $sp 2>/dev/null
  du -sb $idx > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf ${idx}*
  done50 "$out"; }
if diskann_leg sift_100m_r9010 u8; then diskann_leg spacev_100m_r9010 i8
else echo "[$(ts)] diskann_flush_byte sift_100m did not complete 50 epochs -> skipping spacev_100m"; fi
echo "[$(ts)] DISKANN 100M DONE -> starting ef_final study"
bash driver/run_ef100m.sh > logs/ef100m_chain.log 2>&1
echo "[$(ts)] ALL DONE"
