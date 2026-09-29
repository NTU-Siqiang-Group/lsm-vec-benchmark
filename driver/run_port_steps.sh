#!/bin/bash
# AsterVec port dev-loop legs (docs/2026-09-30-astervec-port-and-remeasure-plan.md).
# Usage: driver/run_port_steps.sh <leg>...   leg = name:bin:cell:epochs[:extra args, comma-separated]
#   bin = work/bin/bench_<tag> (frozen copy per step, so later rebuilds never change a finished leg)
# ours_efc20 settings. Output results/raw/port/<name>_<cell>.*, logs/port/. Serial, resumable.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
OUTD=results/raw/port; LOGD=logs/port; mkdir -p $OUTD $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
for spec in "$@"; do
  IFS=: read -r name bin cell ep extra <<<"$spec"; extra=${extra//,/ }
  out=$OUTD/${name}_${cell}.jsonl; db=work/port_${name}_db_${cell}
  if [ -f $out ] && [ "$(grep -c '"epoch"' $out)" -ge $ep ]; then echo "[$(ts)] SKIP $name $cell"; continue; fi
  echo "[$(ts)] START $name $cell ($bin $extra)"
  rm -rf $db
  python3 driver/cache_sampler.py --dir $db --out $OUTD/${name}_${cell}.cache.jsonl --interval 20 >/dev/null 2>&1 & sp=$!
  work/bin/bench_$bin --trace work/$cell --db $db --out $out --mem $OUTD/${name}_${cell}.mem.jsonl \
    --efs 64 --ef-final 100 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.125 \
    --bulk-build --build-threads 4 --efc 20 --mmap-vectors --max-epochs $ep $extra > $LOGD/${name}_${cell}.log 2>&1
  echo "[$(ts)] $name $cell rc=$?"; kill $sp 2>/dev/null
  enc=""; [[ " $extra " =~ --graph-(varint|lean) ]] && enc=varint
  driver/tools/lsm_inspect $db $enc > $LOGD/${name}_${cell}.inspect.txt 2>&1
  rm -rf $db
done
echo "[$(ts)] PORT LEGS DONE"
