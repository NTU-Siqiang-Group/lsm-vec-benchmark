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
    > $LOGD/${name}_${cell}.log 2>&1 &
  local pid=$!
  # StreamingMerge leaves each merge's temp files as <idx>temp<k>_temp_* (outside the index dir, never deleted;
  # ~55 GB per merge at 100M -> filled the disk after 12 merges on 2026-10-09). The merged result is copied into
  # the index dir, so only the two newest temp generations are kept; older ones are removed (logged).
  while kill -0 $pid 2>/dev/null; do
    ks=$(ls -d ${idx}temp*_temp_* 2>/dev/null | sed -E 's/.*temp([0-9]+)_temp_.*/\1/' | sort -n -u)
    nk=$(echo "$ks" | grep -c .)
    if [ "$nk" -gt 2 ]; then
      for k in $(echo "$ks" | head -n $((nk - 2))); do
        echo "[$(ts)] cleanup stale merge temp generation $k ($(du -sch ${idx}temp${k}_temp_* 2>/dev/null | tail -1 | cut -f1))"
        rm -f ${idx}temp${k}_temp_*; done
    fi
    if [ "$(freegb)" -lt 50 ]; then echo "[$(ts)] DISK WATCHDOG: free $(freegb)G < 50G -> stopping $name $cell"; kill $pid; fi
    sleep 60
  done
  wait $pid; echo "[$(ts)] $name $cell rc=$? (free $(freegb)G)"; kill $sp 2>/dev/null
  du -sb $idx > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf ${idx}*
  done50 "$out"; }
if diskann_leg sift_100m_r9010 u8; then diskann_leg spacev_100m_r9010 i8
else echo "[$(ts)] diskann_flush_byte sift_100m did not complete 50 epochs -> skipping spacev_100m"; fi
echo "[$(ts)] DISKANN 100M DONE -> starting ef_final study"
bash driver/run_ef100m.sh > logs/ef100m_chain.log 2>&1
echo "[$(ts)] ALL DONE"
