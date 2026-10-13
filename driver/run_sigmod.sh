#!/bin/bash
# SIGMOD resubmission handoff (docs/2026-10-12-sigmod-resubmission-server-handoff.md), items 1-6, on the current
# config ours_b8r256c (raw byte, ratio 256, efc 12, ef_final 64, M=16, H=4, --graph-lean, 32 MB caches).
# Waits for the running E4-pressure chain (run_e4p.sh). STRICTLY SERIAL, resumable (.done markers), new names only.
# One shared reference run per dataset (section layout, H=4, rho=256, M=16) serves items 2/4/5/6.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
BIN=work/bin/bench_v11; OUTD=results/raw/sigmod; LOGD=logs/sigmod; mkdir -p $OUTD $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
while pgrep -f 'driver/run_e4p.sh' >/dev/null; do sleep 60; done
echo "[$(ts)] e4p chain finished; starting SIGMOD runs"

# leg <name> <cell> <u8|i8> <workload> <extra...>   (mixed = 50-epoch R-9010). argval takes the FIRST match, so
# hops / layer_mult are overridden via H_= / LM_= (not by appending flags).
leg(){ local name=$1 cell=$2 r8=$3 wl=$4; shift 4
  local out=$OUTD/${name}_${cell}.jsonl db=work/sigmod_db
  [ -f $out.done ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START $name $cell ($wl $*)"; rm -rf $db
  python3 driver/cache_sampler.py --dir $db --out $OUTD/${name}_${cell}.cache.jsonl --interval 20 >/dev/null 2>&1 & local sp=$!
  $BIN --trace work/$cell --db $db --out $out --mem $OUTD/${name}_${cell}.mem.jsonl \
    --efs 64 --ef-final 64 --hops ${H_:-4} --query-subsample 0 --use-sa 1 --layer-mult ${LM_:-0.18034} \
    --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 $r8 \
    --cache-stats --workload $wl "$@" > $LOGD/${name}_${cell}.log 2>&1
  local rc=$?; echo "[$(ts)] $name $cell rc=$rc"; kill $sp 2>/dev/null
  du -sb $db > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf $db
  [ $rc = 0 ] && touch $out.done; }

S=sift_1m_r9010; V=spacev_1m_r9010

# 0. smoke: new log line present, run completes
if [ ! -f $OUTD/smoke.done ]; then
  $BIN --trace work/sift_200k_r9010 --db work/sigmod_smoke --out $OUTD/smoke.jsonl --efs 64 --ef-final 64 --hops 4 \
    --use-sa 1 --layer-mult 0.18034 --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 u8 \
    --workload readonly > $LOGD/smoke.log 2>&1; rc=$?; rm -rf work/sigmod_smoke
  grep -q '\[sketch_prefix\]' $LOGD/smoke.log && [ $rc = 0 ] || { echo "[$(ts)] SMOKE FAILED rc=$rc"; exit 1; }
  touch $OUTD/smoke.done; echo "[$(ts)] smoke ok"
fi

# 1. E4 (SIFT readonly/mixed already in raw/e4p): SIFT updateonly; SPACEV readonly/updateonly/mixed. Both arms.
for wl in updateonly; do for arm in dec cpl; do
  a="--graph-out-only"; [ $arm = cpl ] && a="--coupled --graph-out-only"
  leg e4_b8r256c_${arm}_$wl $S u8 $wl --e4-metrics $a; done; done
for wl in readonly updateonly mixed; do for arm in dec cpl; do
  a="--graph-out-only"; [ $arm = cpl ] && a="--coupled --graph-out-only"
  leg e4_b8r256c_${arm}_$wl $V i8 $wl --e4-metrics $a; done; done

# reference runs (section, H=4, rho=256, M=16)
leg abl_b8r256c_ref $S u8 mixed
leg abl_b8r256c_ref $V i8 mixed

# 2. reordering ablation
for L in append random; do leg layout_b8r256c_$L $S u8 mixed --layout $L; done
for L in append random; do leg layout_b8r256c_$L $V i8 mixed --layout $L; done

# 3. routing case study (§11.1 protocol: one build, replay to epoch 49, 1000 traced queries, SA vs --sa-route-off)
if [ ! -f $OUTD/routing.done ]; then
  echo "[$(ts)] START routing trace $S"; rm -rf work/sigmod_db
  $BIN --trace work/$S --db work/sigmod_db --out work/routing_b8r256c_trace_sift_1m.jsonl \
    --efs 64 --hops 4 --use-sa 1 --layer-mult 0.18034 --bulk-build --build-threads 4 --efc 12 --mmap-vectors \
    --graph-lean --vec-raw8 u8 --trace-exp1 49 --trace-queries 1000 --query-sweep 16,32,64 > $LOGD/routing_sift_1m.log 2>&1
  rc=$?; echo "[$(ts)] routing rc=$rc"; rm -rf work/sigmod_db; [ $rc = 0 ] && touch $OUTD/routing.done
fi

# 4. sketch depth sweep (H=4 = ref)
for H in 2 3 5; do H_=$H leg depth_b8r256c_h$H $S u8 mixed; done
for H in 2 3 5; do H_=$H leg depth_b8r256c_h$H $V i8 mixed; done

# 5. layer-ratio sweep (rho=256 = ref); layer_mult = 1/ln(rho)
for R in 3000:0.124902 1000:0.144765 500:0.160911; do
  LM_=${R##*:} leg ratio_b8r256c_rho${R%%:*} $S u8 mixed; done

# 6. degree sweep (M=16 = ref): --m M --m-max 2M as in the old param_M panel
for M in 8 24 32; do leg degree_b8r256c_m$M $S u8 mixed --m $M --m-max $((2*M)); done

echo "[$(ts)] SIGMOD DONE"
