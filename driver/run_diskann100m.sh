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
diskann_leg(){ local cell=$1 sfx=$2 name=diskann_flush_byte${NAME_SUFFIX:-}
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
  # StreamingMerge writes each merge's temp files as <idx>temp<k>_temp_* (outside the index dir; k = lowest unused
  # number) and never deletes them (~55 GB per merge at 100M -> filled the disk on 2026-10-09). After a merge has
  # finished ("Merge time" in the log), every temp generation except the one the index was just RELOADed from is
  # dead and is removed. (An earlier rule — "keep the two highest k" — deleted a generation that was being written,
  # because k restarts at the lowest free number; that corrupted the run of 2026-10-09 22:12.)
  local merges_seen=0 log=$LOGD/${name}_${cell}.log
  while kill -0 $pid 2>/dev/null; do
    local m; m=$(grep -c 'Merge time :' $log 2>/dev/null)
    if [ "${m:-0}" -gt "$merges_seen" ]; then
      merges_seen=$m
      local keep; keep=$(grep -o 'RELOAD: Loading graph from .*temp[0-9]*_temp_disk_index' $log | tail -1 | sed -E 's/.*temp([0-9]+)_temp_disk_index/\1/')
      for f in ${idx}temp*_temp_*; do
        [ -e "$f" ] || continue
        k=$(echo "$f" | sed -E 's/.*temp([0-9]+)_temp_.*/\1/')
        [ "$k" = "$keep" ] && continue
        echo "[$(ts)] after merge $m: remove dead temp gen $k file $(basename $f) ($(du -sh $f | cut -f1)); keep gen $keep"
        rm -f "$f"
      done
      if [ -n "${STOP_AFTER_MERGES:-}" ] && [ "$m" -ge "$STOP_AFTER_MERGES" ]; then
        echo "[$(ts)] VALIDATION: reached $m merges with cleanup, stopping"; sleep 120; kill $pid; fi
    fi
    if [ "$(freegb)" -lt 50 ]; then echo "[$(ts)] DISK WATCHDOG: free $(freegb)G < 50G -> stopping $name $cell"; kill $pid; fi
    sleep 30
  done
  wait $pid; echo "[$(ts)] $name $cell rc=$? (free $(freegb)G)"; kill $sp 2>/dev/null
  du -sb $idx > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf ${idx}*
  done50 "$out"; }
if [ -n "${VALIDATE_CELL:-}" ]; then  # cleanup-logic validation on a small cell (output name suffixed)
  NAME_SUFFIX=_cleanupcheck diskann_leg $VALIDATE_CELL ${VALIDATE_SFX:-u8}; echo "[$(ts)] VALIDATION DONE"; exit 0
fi
if diskann_leg sift_100m_r9010 u8; then diskann_leg spacev_100m_r9010 i8
else echo "[$(ts)] diskann_flush_byte sift_100m did not complete 50 epochs -> skipping spacev_100m"; fi
echo "[$(ts)] DISKANN 100M DONE -> starting ef_final study"
bash driver/run_ef100m.sh > logs/ef100m_chain.log 2>&1
echo "[$(ts)] ALL DONE"
