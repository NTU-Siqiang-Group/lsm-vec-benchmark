#!/bin/bash
# ef_final study at 100M (user request 2026-10-08), queued after driver/run_phase_c2.sh (incl. DiskANN 100M test).
# ef_final changes queries only (index state is identical), so ONE 50-epoch run per dataset replays the query set
# at ef_final 64 (stream), 128 and 256 at EVERY epoch (--checkpoint-epochs 0..49 --query-sweep 64,128,256).
# Same ours_b8r256c settings as Phase C2. Output name ours_b8r256c_efsw (never overwrites).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
WAITPID=${1:-}; LOGD=logs/ef100m; mkdir -p $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
[ -n "$WAITPID" ] && { echo "[$(ts)] waiting for pid $WAITPID"; while kill -0 $WAITPID 2>/dev/null; do sleep 120; done; }
NAME=ours_b8r256c_efsw; BIN=work/bin/bench_v6; ALL=$(seq -s, 0 49)
leg(){ local cell=$1 r8=$2 out=results/raw/${NAME}_$1.jsonl db=work/${NAME}_db_$1
  [ -f $out ] && [ "$(grep -c '"epoch"' $out)" -ge 50 ] && { echo "[$(ts)] SKIP $cell"; return; }
  echo "[$(ts)] START $NAME $cell"; rm -rf $db
  python3 driver/cache_sampler.py --dir $db --out results/raw/${NAME}_$cell.cache.jsonl --interval 60 >/dev/null 2>&1 & local sp=$!
  $BIN --trace work/$cell --db $db --out $out --mem results/raw/${NAME}_$cell.mem.jsonl \
    --efs 64 --ef-final 64 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.18034 \
    --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 $r8 --sharded-build 16 \
    --checkpoint-epochs $ALL --query-sweep 64,128,256 > $LOGD/${NAME}_$cell.log 2>&1
  echo "[$(ts)] $NAME $cell rc=$?"; kill $sp 2>/dev/null; rm -rf $db; }
leg sift_100m_r9010 u8
leg spacev_100m_r9010 i8
echo "[$(ts)] EF100M DONE"
