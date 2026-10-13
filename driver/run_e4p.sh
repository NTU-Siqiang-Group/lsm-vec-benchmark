#!/bin/bash
# E4 with the current config + under memory pressure (2026-10-13; reviewers R2-2 / R3-D1).
# Arms: decoupled (ours: graph in Aster, out-edges only, + raw-byte paged vector file) vs coupled (one LSM record per
# node = out-list + raw-byte vector). Config = ours_b8r256c (raw byte, ratio 256, efc 12, ef_final 64, --graph-lean).
# Memory pressure: the base build runs uncapped; then the process caps its own cgroup (--mem-cap-after-build-mb), so
# the workload phase runs with the store mostly outside the page cache. Coupled under pressure is very slow, so the
# capped mixed legs run 10 (1M) / 5 (10M) epochs. STRICTLY SERIAL, resumable, new names only.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
BIN=work/bin/bench_v10; OUTD=results/raw/e4p; LOGD=logs/e4p; mkdir -p $OUTD $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
leg(){ local name=$1 cell=$2 r8=$3 arm=$4 wl=$5 need=$6 cap=$7; shift 7
  local out=$OUTD/${name}_${cell}.jsonl db=work/e4p_db
  [ -f $out ] && [ "$(grep -c '"epoch"' $out)" -ge $need ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  local armf="--graph-out-only"; [ $arm = cpl ] && armf="--coupled --graph-out-only"
  local capf=""; [ "$cap" != 0 ] && capf="--mem-cap-after-build-mb $cap"
  echo "[$(ts)] START $name $cell ($arm $wl cap=$cap $*)"; rm -rf $db
  python3 driver/cache_sampler.py --dir $db --out $OUTD/${name}_${cell}.cache.jsonl --interval 20 >/dev/null 2>&1 & local sp=$!
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemd-run --user --scope -q -p MemoryMax=infinity -- \
    $BIN --trace work/$cell --db $db --out $out --mem $OUTD/${name}_${cell}.mem.jsonl \
    --efs 64 --ef-final 64 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.18034 \
    --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 $r8 \
    --e4-metrics --cache-stats --workload $wl $armf $capf "$@" > $LOGD/${name}_${cell}.log 2>&1
  echo "[$(ts)] $name $cell rc=$?"; kill $sp 2>/dev/null; rm -rf $db; }
C=sift_1m_r9010
leg e4p_dec_ro_free  $C u8 dec readonly 3 0
leg e4p_cpl_ro_free  $C u8 cpl readonly 3 0
leg e4p_dec_mix_free $C u8 dec mixed 50 0
leg e4p_cpl_mix_free $C u8 cpl mixed 50 0
leg e4p_dec_mix_650  $C u8 dec mixed 10 650 --max-epochs 10
leg e4p_cpl_mix_650  $C u8 cpl mixed 10 650 --max-epochs 10
leg e4p_dec_ro_650   $C u8 dec readonly 3 650
leg e4p_cpl_ro_650   $C u8 cpl readonly 3 650
leg e4p_dec_ro_500   $C u8 dec readonly 3 500
leg e4p_cpl_ro_500   $C u8 cpl readonly 3 500
C=sift_10m_r9010
leg e4p_dec_ro_3500  $C u8 dec readonly 3 3500
leg e4p_cpl_ro_3500  $C u8 cpl readonly 3 3500
leg e4p_dec_mix_3500 $C u8 dec mixed 5 3500 --max-epochs 5
leg e4p_cpl_mix_3500 $C u8 cpl mixed 5 3500 --max-epochs 5
echo "[$(ts)] E4P DONE"
