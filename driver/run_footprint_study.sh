#!/bin/bash
# Footprint study (PVLDB revision): where do ours' bytes go, and what do two storage fixes save?
# ours_efc20 config (efc=20, ef_final=100, --mmap-vectors), SIFT 1M, 50 epochs, serial, resumable.
#   fp_base      control (same binary)
#   fp_wal64     max_total_wal_size = 64 MB (forces flush of lagging column families)
#   fp_outonly   graph stores out-edges only (in-lists are never read by LSM-Vec)
#   fp_both      both
# After each run the final DB is inspected (driver/tools/lsm_inspect) and then deleted.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
CELL=sift_1m_r9010; LOGD=logs/footprint; mkdir -p $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
leg(){ local name=$1; shift
  local out=results/raw/${name}_${CELL}.jsonl db=work/${name}_db_${CELL}
  [ -f $out ] && [ "$(grep -c '"epoch"' $out)" -ge 50 ] && { echo "[$(ts)] SKIP $name"; return; }
  echo "[$(ts)] START $name ($*)"
  python3 driver/cache_sampler.py --dir $db --out results/raw/${name}_${CELL}.cache.jsonl --interval 20 >/dev/null 2>&1 & local sp=$!
  NAME=$name USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 EXTRA_ARGS="--efc 20 --mmap-vectors $*" \
    bash driver/run_ours.sh work/$CELL $CELL 100 4 0 > $LOGD/$name.log 2>&1
  echo "[$(ts)] $name rc=$?"; kill $sp 2>/dev/null
  driver/tools/lsm_inspect $db > $LOGD/$name.inspect.txt 2>&1; echo "[$(ts)] inspected $name"
  rm -rf $db
}
leg fp_base
leg fp_wal64   --max-total-wal-mb 64
leg fp_outonly --graph-out-only
leg fp_both    --max-total-wal-mb 64 --graph-out-only
echo "[$(ts)] FOOTPRINT STUDY DONE"
