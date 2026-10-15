#!/bin/bash
# SIGMOD SPACEV supplements (docs/2026-10-15-sigmod-spacev-supplements.md), then the full 50-epoch SPFresh-byte
# 100M reruns (SPACEV, SIFT) with the system sampler. STRICTLY SERIAL, resumable (.done), new names only.
# Config = ours_b8r256c (raw byte, ratio 256, efc 12, ef_final 64, H4, --graph-lean). Binary bench_v22 (= v11 +
# diagnostics + rebuild counters; all new switches default off).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
BIN=work/bin/bench_v22; OUTD=results/raw/sigmod2; LOGD=logs/sigmod2; mkdir -p $OUTD $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
freegb(){ df -BG --output=avail / | tail -1 | tr -dc 0-9; }
OURS_F="--efs 64 --ef-final 64 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.18034 --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --cache-stats"
P2="--cold-queries --warmup-queries 2000"

ours(){ local name=$1 cell=$2 r8=$3; shift 3
  local out=$OUTD/${name}_${cell}.jsonl db=work/sigmod2_db
  [ -f $out.done ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START ours $name $cell ($*)"; rm -rf $db
  python3 driver/cache_sampler.py --dir $db --out $OUTD/${name}_${cell}.cache.jsonl --interval 20 >/dev/null 2>&1 & local cs=$!
  $BIN --trace work/$cell --db $db --out $out --mem $OUTD/${name}_${cell}.mem.jsonl $OURS_F --vec-raw8 $r8 "$@" > $LOGD/${name}_${cell}.log 2>&1
  local rc=$?; echo "[$(ts)] $name $cell rc=$rc"; kill $cs 2>/dev/null
  du -sb $db > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf $db
  [ $rc = 0 ] && touch $out.done; }

# spf <name> <cell> <UInt8|Int8> [SWEEP_ARGS]  (env SYSIV/CSIV/SYSFILES for the system sampler)
spf(){ local name=$1 cell=$2 vt=$3 extra=${4:-}; local d=$OUTD/${name}_${cell}.jsonl
  [ -f $d.done ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START spfresh $name $cell ($extra) (free $(freegb)G)"
  local drv=spfresh_driver_u8; [ $vt = Int8 ] && drv=spfresh_driver_i8
  local ff=""; for f in ${SYSFILES:-}; do ff="$ff --file $f"; done
  local pf=$OUTD/${name}_${cell}.sys.pid; rm -f $pf
  if [ -n "${SYSIV:-}" ]; then
    ( for i in $(seq 1 28800); do p=$(pgrep -f -n -- "$drv --store"); [ -n "$p" ] && { echo $p > $pf; break; }; sleep 0.5; done ) &
    python3 driver/sys_sampler.py --out $OUTD/${name}_${cell}.sys.jsonl --pid-file $pf --interval $SYSIV $ff >/dev/null 2>&1 & SYSP=$!
  fi
  python3 driver/cache_sampler.py --dir work/${name}_${cell}/store --out $OUTD/${name}_${cell}.cache.jsonl --interval ${CSIV:-20} \
    --epoch-file work/${name}_${cell}/epoch.ctl >/dev/null 2>&1 & local cs=$!
  BENCH_PHASE_LOG=$(pwd)/$OUTD/${name}_${cell}.phases \
    VALUE_TYPE=$vt BUILD_THREADS=4 THREADS=1 SWEEP_ARGS="$extra" bash driver/run_spfresh.sh work/$cell $name 64 > $LOGD/${name}_${cell}.log 2>&1
  local rc=$?; echo "[$(ts)] $name $cell rc=$rc (free $(freegb)G)"; kill $cs 2>/dev/null; [ -n "${SYSP:-}" ] && kill $SYSP 2>/dev/null; SYSP=""
  for x in jsonl mem.jsonl; do [ -f results/raw/${name}_${cell}.$x ] && mv results/raw/${name}_${cell}.$x $OUTD/; done
  cp -f work/${name}_${cell}/build.log $LOGD/${name}_${cell}.build.log 2>/dev/null
  cp -f work/${name}_${cell}/run.log $LOGD/${name}_${cell}.run.log 2>/dev/null
  du -sb work/${name}_${cell} > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf work/${name}_${cell}
  [ $rc = 0 ] && touch $d.done; }

dsk(){ local name=$1 cell=$2 sfx=$3; shift 3; local idx=work/sigmod2_dsk_idx out=$OUTD/${name}_${cell}.jsonl
  [ -f $out.done ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START diskann $name $cell ($*)"; rm -rf ${idx}* && mkdir -p $idx
  python3 driver/cache_sampler.py --dir $idx --out $OUTD/${name}_${cell}.cache.jsonl --interval 20 >/dev/null 2>&1 & local cs=$!
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemd-run --user --scope -q -p MemoryMax=115G -p MemorySwapMax=0 -- \
    diskann_merge_src/build/tests/bench_stream_merge_$sfx --trace work/$cell --out $out --mem $OUTD/${name}_${cell}.mem.jsonl \
    --index_prefix $idx/idx --work_dir $idx --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000 "$@" \
    > $LOGD/${name}_${cell}.log 2>&1
  local rc=$?; echo "[$(ts)] $name $cell rc=$rc"; kill $cs 2>/dev/null; rm -rf ${idx}*
  [ $rc = 0 ] && touch $out.done; }

S1=sift_1m_r9010; V1=spacev_1m_r9010; S10=sift_10m_r9010

# ===== 1. routing case study, SPACEV 1M (§35 protocol) =====
if [ ! -f $OUTD/routing_spacev.done ]; then
  echo "[$(ts)] START routing trace $V1"; rm -rf work/sigmod2_db
  $BIN --trace work/$V1 --db work/sigmod2_db --out work/routing_b8r256c_trace_spacev_1m.jsonl \
    --efs 64 --hops 4 --use-sa 1 --layer-mult 0.18034 --bulk-build --build-threads 4 --efc 12 --mmap-vectors \
    --graph-lean --vec-raw8 i8 --trace-exp1 49 --trace-queries 1000 --query-sweep 16,32,64 > $LOGD/routing_spacev_1m.log 2>&1
  rc=$?; echo "[$(ts)] routing spacev rc=$rc"; rm -rf work/sigmod2_db
  [ $rc = 0 ] && python3 plot/plot_exp1_routing.py work/routing_b8r256c_trace_spacev_1m.jsonl work/$V1 49 b8r256c_spacev_1m > $LOGD/routing_spacev_plot.log 2>&1 && touch $OUTD/routing_spacev.done
fi

# ===== 2. cold-cache protocol P2, SPACEV 1M, all three systems (§31 protocol) =====
ours p2_b8r256c $V1 i8 $P2
spf spfresh_byte_coldwu $V1 Int8 "$P2"
dsk diskann_flush_byte_coldwu $V1 i8 $P2

# ===== 3. rebuild-threshold sweep alpha, SIFT 1M (alpha 0.3 = reference, rerun here for the rebuild counters) =====
for A in 0.3 0.1 0.5 1.0; do ours alpha${A}_b8r256c $S1 u8 --sa-rebuild-alpha $A --diag-graph; done

# ===== 4. reordering ablation, SIFT 10M: append (reference = main-matrix section run) =====
ours layout_append_b8r256c $S10 u8 --layout append

# ===== 5. SPFresh-byte full 50-epoch 100M reruns with the system sampler (meminfo/diskstats every 10 s) =====
for c in "spacev_100m_r9010 Int8 i8bin" "sift_100m_r9010 UInt8 u8bin"; do set -- $c
  if [ "$(freegb)" -gt 300 ]; then
    SYSIV=10 CSIV=60 SYSFILES="work/$1/base.$3 work/$1/pool.$3" spf spfresh_byte_full $1 $2
  else echo "[$(ts)] SKIP spfresh full $1 (free $(freegb)G < 300G)"; fi
done
echo "[$(ts)] SIGMOD2 DONE"
