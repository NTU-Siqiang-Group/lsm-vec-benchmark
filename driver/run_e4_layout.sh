#!/bin/bash
# E4 (PVLDB revision): coupled vs decoupled node layout, 1M. ours_efc20 config otherwise
# (bulk build x4, efc=20, ef_final=100, hops=4, SA sketch defaults, --mmap-vectors).
#   decoupled: layer-0 adjacency in Aster (out-edges only) + separate SQ8 paged vector file
#   coupled:   one LSM record per node = [out-list][SQ8 vector]; edge RMW rewrites the vector
# Workloads: mixed (R-9010, 50 epochs), updateonly (50 epochs, query only the last),
#            readonly (epoch 0 applied, then 3 query passes). Serial, resumable.
# Waits for any running footprint chain first (strictly serial measurements).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
BIN=LSM-Vec-with-SA-HNSW/build_e4/bin/bench_streaming
LOGD=logs/e4; OUTD=results/raw/e4; mkdir -p $LOGD $OUTD
ts(){ date +'%m-%d %H:%M:%S'; }
while pgrep -f run_footprint_study.sh >/dev/null; do sleep 60; done
leg(){ local cell=$1 arm=$2 wl=$3 need=$4; shift 4
  local name=e4_${arm}_${wl}; local out=$OUTD/${name}_${cell}.jsonl db=work/${name}_db_${cell}
  [ -f $out ] && [ "$(grep -c '"epoch"' $out)" -ge $need ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  local armf="--graph-out-only"; [ $arm = coupled ] && armf="--coupled --graph-out-only"
  echo "[$(ts)] START $name $cell"
  rm -rf $db
  python3 driver/cache_sampler.py --dir $db --out $OUTD/${name}_${cell}.cache.jsonl --interval 20 >/dev/null 2>&1 & local sp=$!
  $BIN --trace work/$cell --db $db --out $out --mem $OUTD/${name}_${cell}.mem.jsonl \
    --efs 64 --ef-final 100 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.125 \
    --bulk-build --build-threads 4 --efc 20 --mmap-vectors --e4-metrics \
    --workload $wl $armf "$@" > $LOGD/${name}_${cell}.log 2>&1
  echo "[$(ts)] $name $cell rc=$?"; kill $sp 2>/dev/null
  du -sb $db > $LOGD/${name}_${cell}.du.txt 2>&1
  rm -rf $db
}
# Smoke (200k, 3 epochs) — abort the chain if the coupled arm is broken.
for arm in decoupled coupled; do leg sift_200k_r9010 $arm mixed 3 --max-epochs 3; done
r=$(python3 -c "
import json;rows=[json.loads(l) for l in open('$OUTD/e4_coupled_mixed_sift_200k_r9010.jsonl')]
print(rows[0]['recall10'] or 0)" 2>/dev/null || echo 0)
echo "[$(ts)] smoke coupled recall@epoch0=$r"
python3 -c "import sys; sys.exit(0 if float('$r')>0.8 else 1)" || { echo "[$(ts)] SMOKE FAILED, stop"; exit 1; }
for cell in sift_1m_r9010 spacev_1m_r9010; do
  for arm in decoupled coupled; do
    leg $cell $arm readonly 3
    leg $cell $arm mixed 50
    leg $cell $arm updateonly 50
  done
done
echo "[$(ts)] E4 DONE"
