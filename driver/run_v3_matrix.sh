#!/bin/bash
# Step 4 of docs/2026-09-30-astervec-port-and-remeasure-plan.md: freeze ours_efc20_v3 and re-measure.
# ours_efc20 settings + --graph-lean (+ $V3_EXTRA, e.g. the WAL cap decision). Baselines NOT re-run
# (compared against RESULTS §17). Binary: work/bin/bench_v3 (frozen copy). STRICTLY SERIAL, resumable.
#   main legs: sift_1m, spacev_1m, sift_10m (50 epochs; ef_final sweep at epoch 49 -> .sweep.jsonl)
#   epoch-0 ef_final sweep: --calibrate on the 1M cells
#   memory caps: sift_1m at 4 GB and 2 GB (cgroup-v2, §14.5 protocol)
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
BIN=work/bin/bench_v3; NAME=ours_efc20_v3; V3_EXTRA=${V3_EXTRA:-}
LOGD=logs/v3; MB=results/v2_tuned/membudget; mkdir -p $LOGD $MB
SWEEP=48,64,80,100,128,160
ts(){ date +'%m-%d %H:%M:%S'; }
done50(){ [ -f "$1" ] && [ "$(grep -c '"epoch"' "$1")" -ge 50 ]; }
args(){ echo --efs 64 --ef-final 100 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.125 \
  --bulk-build --build-threads 4 --efc 20 --mmap-vectors --graph-lean $V3_EXTRA; }
main_leg(){ local cell=$1 out=results/raw/${NAME}_$1.jsonl db=work/${NAME}_db_$1
  done50 $out && { echo "[$(ts)] SKIP main $cell"; return; }
  echo "[$(ts)] START main $cell"; rm -rf $db
  python3 driver/cache_sampler.py --dir $db --out results/raw/${NAME}_$cell.cache.jsonl --interval 20 >/dev/null 2>&1 & local sp=$!
  $BIN --trace work/$cell --db $db --out $out --mem results/raw/${NAME}_$cell.mem.jsonl $(args) \
    --checkpoint-epochs 49 --query-sweep $SWEEP > $LOGD/main_$cell.log 2>&1
  echo "[$(ts)] main $cell rc=$?"; kill $sp 2>/dev/null
  driver/tools/lsm_inspect $db varint > $LOGD/main_$cell.inspect.txt 2>&1; rm -rf $db; }
calib_leg(){ local cell=$1 out=results/raw/${NAME}_$1.calib0.txt db=work/${NAME}_cal_$1
  [ -s $out ] && { echo "[$(ts)] SKIP calib $cell"; return; }
  echo "[$(ts)] START calib $cell"; rm -rf $db
  $BIN --trace work/$cell --db $db $(args) --calibrate $SWEEP > $out 2> $LOGD/calib_$cell.log
  echo "[$(ts)] calib $cell rc=$?"; rm -rf $db; }
cap_leg(){ local tag=$1 bytes=$2 cell=sift_1m_r9010
  local out=$MB/${NAME}_mb${tag}_$cell.jsonl db=work/${NAME}_mb${tag}_db
  done50 $out && { echo "[$(ts)] SKIP cap $tag"; return; }
  echo "[$(ts)] START cap $tag (MemoryMax=$bytes)"; rm -rf $db
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} timeout 10800 \
    systemd-run --user --scope -q -p MemoryMax=$bytes -p MemorySwapMax=0 -- \
    $BIN --trace work/$cell --db $db --out $out --mem $MB/${NAME}_mb${tag}_$cell.mem.jsonl $(args) \
    > $LOGD/cap_$tag.log 2>&1
  echo "[$(ts)] cap $tag rc=$?"; rm -rf $db; }
main_leg sift_1m_r9010
main_leg spacev_1m_r9010
calib_leg sift_1m_r9010
calib_leg spacev_1m_r9010
cap_leg 4g 4G
cap_leg 2g 2G
main_leg sift_10m_r9010
echo "[$(ts)] V3 MATRIX DONE"
