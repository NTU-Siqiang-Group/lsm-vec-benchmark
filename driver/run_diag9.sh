#!/bin/bash
# Diagnostics handoff 2026-10-14 (docs/2026-10-14-sigmod-diagnostics-handoff.md): runs for Q1.3, Q1.4, Q2.1-2.7, Q3.2-3.4.
# STRICTLY SERIAL, resumable (.done markers), new names only. Main-matrix config unchanged (ours_b8r256c).
# Outputs: results/raw/diag/<family>_<variant>_<cell>.*  Logs: logs/diag/.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
BIN=work/bin/bench_v12; OUTD=results/raw/diag; LOGD=logs/diag; mkdir -p $OUTD $LOGD
ts(){ date +'%m-%d %H:%M:%S'; }
freegb(){ df -BG --output=avail / | tail -1 | tr -dc 0-9; }
DIAGF=1
OURS_F="--efs 64 --ef-final 64 --hops 4 --query-subsample 0 --use-sa 1 --bulk-build --build-threads 4 --mmap-vectors --cache-stats"
B8="--layer-mult 0.18034 --efc 12 --graph-lean"   # + --vec-raw8 u8|i8 = ours_b8r256c

# truncated trace view (symlinks): first n epochs, manifest n_epochs=n
mk_trunc(){ local src=$1 n=$2 dst=$3
  [ -f $dst/manifest.json ] && return
  mkdir -p $dst
  for f in $src/*; do b=$(basename $f); case $b in epoch_*|manifest.json) ;; *) ln -sfn $(readlink -f $f) $dst/$b ;; esac; done
  for ((e=0; e<n; e++)); do for x in ins del; do f=$(printf "%s/epoch_%03d.%s.u32" $src $e $x); [ -f $f ] && ln -sfn $(readlink -f $f) $dst/; done; done
  python3 -c "import json,sys; m=json.load(open('$src/manifest.json')); m['n_epochs']=$n; m['truncated_from']='$src'; json.dump(m,open('$dst/manifest.json','w'),indent=1)"; }

# sys sampler bound to the first process matching a pattern
sys_on(){ local out=$1 pat=$2; shift 2; local pf=$out.pid; rm -f $pf
  ( for i in $(seq 1 28800); do p=$(pgrep -f -n -- "$pat"); [ -n "$p" ] && { echo $p > $pf; break; }; sleep 0.5; done ) &
  python3 driver/sys_sampler.py --out $out --pid-file $pf "$@" >/dev/null 2>&1 & SYSP=$!; }
sys_off(){ [ -n "${SYSP:-}" ] && kill $SYSP 2>/dev/null; SYSP=""; }

# ours <name> <trace> <bin> <flags...>   (env: SYNC=1, SYS=1, CAP=<MB>, SYSFILES="f1 f2")
ours(){ local name=$1 cell=$2 bin=$3; shift 3
  local out=$OUTD/${name}_${cell}.jsonl db=work/diag_db
  [ -f $out.done ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START ours $name $cell ($*) sync=${SYNC:-0} cap=${CAP:-0}"; rm -rf $db
  python3 driver/cache_sampler.py --dir $db --out $OUTD/${name}_${cell}.cache.jsonl --interval 20 >/dev/null 2>&1 & local cs=$!
  local ff=""; for f in ${SYSFILES:-}; do ff="$ff --file $f"; done
  [ "${SYS:-0}" = 1 ] && sys_on $OUTD/${name}_${cell}.sys.jsonl "$bin --trace work/$cell --db $db" --interval 1 $ff
  local capf=""; [ -n "${CAP:-}" ] && capf="--mem-cap-after-build-mb $CAP"
  BENCH_PHASE_LOG=$OUTD/${name}_${cell}.phases BENCH_SYNC_INSERT=${SYNC:-0} \
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemd-run --user --scope -q -p MemoryMax=infinity -p MemorySwapMax=0 -- \
    $bin --trace work/$cell --db $db --out $out --mem $OUTD/${name}_${cell}.mem.jsonl $OURS_F $capf "$@" \
    > $LOGD/${name}_${cell}.log 2>&1
  local rc=$?; echo "[$(ts)] $name $cell rc=$rc"; kill $cs 2>/dev/null; sys_off
  du -sb $db > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf $db
  [ $rc = 0 ] && touch $out.done; }

# spf <name> <trace> <UInt8|Int8>   (output results/raw/<name>_<trace>.jsonl, moved to diag/)
spf(){ local name=$1 cell=$2 vt=$3; local d=$OUTD/${name}_${cell}.jsonl
  [ -f $d.done ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START spfresh $name $cell sync=${SYNC:-0} (free $(freegb)G)"
  local drv=spfresh_driver_u8; [ $vt = Int8 ] && drv=spfresh_driver_i8
  local ff=""; for f in ${SYSFILES:-}; do ff="$ff --file $f"; done
  sys_on $OUTD/${name}_${cell}.sys.jsonl "$drv --store" --interval ${SYSIV:-1} $ff
  python3 driver/cache_sampler.py --dir work/${name}_${cell}/store --out $OUTD/${name}_${cell}.cache.jsonl --interval ${CSIV:-20} \
    --epoch-file work/${name}_${cell}/epoch.ctl >/dev/null 2>&1 & local cs=$!
  BENCH_PHASE_LOG=$(pwd)/$OUTD/${name}_${cell}.phases BENCH_SYNC_INSERT=${SYNC:-0} \
    VALUE_TYPE=$vt BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh work/$cell $name 64 > $LOGD/${name}_${cell}.log 2>&1
  local rc=$?; echo "[$(ts)] $name $cell rc=$rc (free $(freegb)G)"; kill $cs 2>/dev/null; sys_off
  for x in jsonl mem.jsonl; do [ -f results/raw/${name}_${cell}.$x ] && mv results/raw/${name}_${cell}.$x $OUTD/; done
  cp -f work/${name}_${cell}/build.log $LOGD/${name}_${cell}.build.log 2>/dev/null
  cp -f work/${name}_${cell}/run.log $LOGD/${name}_${cell}.run.log 2>/dev/null
  du -sb work/${name}_${cell} > $LOGD/${name}_${cell}.du.txt 2>&1; rm -rf work/${name}_${cell}
  [ $rc = 0 ] && touch $d.done; }

# dsk <name> <trace> <u8|i8>
dsk(){ local name=$1 cell=$2 sfx=$3 idx=work/diag_dsk_idx; local out=$OUTD/${name}_${cell}.jsonl
  [ -f $out.done ] && { echo "[$(ts)] SKIP $name $cell"; return; }
  echo "[$(ts)] START diskann $name $cell sync=${SYNC:-0}"; rm -rf ${idx}* && mkdir -p $idx
  sys_on $OUTD/${name}_${cell}.sys.jsonl "bench_stream_merge_$sfx --trace work/$cell" --interval 1
  BENCH_PHASE_LOG=$OUTD/${name}_${cell}.phases BENCH_SYNC_INSERT=${SYNC:-0} \
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemd-run --user --scope -q -p MemoryMax=115G -p MemorySwapMax=0 -- \
    diskann_merge_src/build/tests/bench_stream_merge_$sfx --trace work/$cell \
    --out $out --mem $OUTD/${name}_${cell}.mem.jsonl --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000 \
    > $LOGD/${name}_${cell}.log 2>&1
  local rc=$?; echo "[$(ts)] $name $cell rc=$rc"; sys_off; rm -rf ${idx}*
  [ $rc = 0 ] && touch $out.done; }

S1=sift_1m_r9010; V1=spacev_1m_r9010; S10=sift_10m_r9010
SWEEP49="--checkpoint-epochs 49 --query-sweep 64,128,256,512,1024,64n,R,64"

# ===== 1. Q2.3/2.4/2.5 diagnostic streaming runs (1M) =====
ours q2diag_b8r256c $S1 $BIN $B8 --vec-raw8 u8 --diag-graph $SWEEP49
ours q2diag_b8r256c $V1 $BIN $B8 --vec-raw8 i8 --diag-graph $SWEEP49

# ===== 2. Q2.1 static control, SPACEV 1M (SIFT 1M: RESULTS §29) =====
for k in 0 49; do
  [ -f work/spacev_1m_fresh$k/manifest.json ] || python3 driver/make_fresh_trace.py work/$V1 $k work/spacev_1m_fresh$k > $LOGD/mkfresh_spacev_$k.log 2>&1
  ours q2static_b8r256c_fresh$k spacev_1m_fresh$k $BIN $B8 --vec-raw8 i8 --checkpoint-epochs 0 --query-sweep 64,128,256
done

# ===== 2b. Q2.8 candidate fix at 1M (SIFT first): insert-pool K=32/64; then per-origin degree (v14) incl. efc 20 =====
BIN13=work/bin/bench_v13; BIN14=work/bin/bench_v14
for K in 32 64; do ours q28fix_pool${K}_b8r256c $S1 $BIN13 $B8 --vec-raw8 u8 --insert-pool $K --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256; done
ours q2deg_b8r256c $S1 $BIN14 $B8 --vec-raw8 u8 --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256
ours q2deg_efc20_b8r256c $S1 $BIN14 --layer-mult 0.18034 --efc 20 --graph-lean --vec-raw8 u8 --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256

# ===== 2e. Q2.8 fix v2: streamed inserts keep up to m_max (32) layer-0 neighbours, from a larger candidate pool =====
BIN15=work/bin/bench_v15
ours q28fix_pool64_m032_b8r256c $S1 $BIN15 $B8 --vec-raw8 u8 --insert-pool 64 --insert-m0 32 --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256
# fix v3: + keep pruned connections (fill up to the limit) — bench_v16
BIN16=work/bin/bench_v16
for M0 in 32 24; do ours q28fix_pool64_m0${M0}fill_b8r256c $S1 $BIN16 $B8 --vec-raw8 u8 --insert-pool 64 --insert-m0 $M0 --insert-fill --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256; done

# ===== 4. Q1.3 SPFresh-byte SIFT100M re-check: rebuild, 3 epochs, meminfo + trace-file residency every 10 s =====
mk_trunc work/sift_100m_r9010 3 work/sift_100m_r9010_e3
if [ "$(freegb)" -gt 300 ]; then
  SYSIV=10 CSIV=60 SYSFILES="work/sift_100m_r9010/base.u8bin work/sift_100m_r9010/pool.u8bin" spf q13_spfresh_byte sift_100m_r9010_e3 UInt8
else echo "[$(ts)] SKIP q13 (free $(freegb)G < 300G)"; fi

# ===== 2f. insert-path profile + insert buffer (bench_v17), SIFT 1M =====
BIN17=work/bin/bench_v17
for B in 2000 10000; do ours q29buf${B}_m024fill_b8r256c $S1 $BIN17 $B8 --vec-raw8 u8 --insert-pool 64 --insert-m0 24 --insert-fill --insert-buffer $B --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256; done

# ===== 2g. streaming insert-path profile (bench_v18: per-epoch prof_*_us), SIFT 1M, 10 epochs =====
BIN18=work/bin/bench_v18
ours q29prof2_b8r256c $S1 $BIN18 $B8 --vec-raw8 u8 --max-epochs 10
ours q29prof2_m024fill_b8r256c $S1 $BIN18 $B8 --vec-raw8 u8 --insert-pool 64 --insert-m0 24 --insert-fill --max-epochs 10
ours q29prof2_buf2000_b8r256c $S1 $BIN18 $B8 --vec-raw8 u8 --insert-buffer 2000 --max-epochs 10

# ===== 4b. Q1.3 SYNC variant =====
if [ "$(freegb)" -gt 300 ]; then
  # same, with sync() inside the insert window (durable insert cost under the RAM cap; Q3.3 at 100M)
  [ "$(freegb)" -gt 300 ] && SYNC=1 SYSIV=10 CSIV=60 SYSFILES="work/sift_100m_r9010/base.u8bin work/sift_100m_r9010/pool.u8bin" spf q13sync_spfresh_byte sift_100m_r9010_e3 UInt8
fi

# ===== 2h. piggyback prototype (bench_v19), SIFT 1M, buffer 10000 (> one epoch of inserts), no fill =====
BIN19=work/bin/bench_v19
ours q30buf10000_nosort_b8r256c $S1 $BIN19 $B8 --vec-raw8 u8 --insert-buffer 10000 --insert-buffer-nosort --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256
ours q30piggy_b8r256c $S1 $BIN19 $B8 --vec-raw8 u8 --insert-buffer 10000 --insert-buffer-nosort --insert-piggyback --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256
ours q30piggy_ref4_b8r256c $S1 $BIN19 $B8 --vec-raw8 u8 --insert-buffer 10000 --insert-buffer-nosort --insert-piggyback --piggy-refine-ef 4 --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256

# ===== 2d. Q2.8 on SPACEV 1M (after the Q1.3 re-check) =====
for K in 32 64; do ours q28fix_pool${K}_b8r256c $V1 $BIN13 $B8 --vec-raw8 i8 --insert-pool $K --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256; done
ours q2deg_efc20_b8r256c $V1 $BIN14 --layer-mult 0.18034 --efc 20 --graph-lean --vec-raw8 i8 --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256

# ===== 3. Q3.2/3.3/3.4 insert-window timing (SIFT 1M x10 epochs, SIFT 10M x5 epochs), all systems =====
mk_trunc work/$S1 10 work/sift_1m_r9010_e10; mk_trunc work/$S10 5 work/sift_10m_r9010_e5
for cell in sift_1m_r9010_e10 sift_10m_r9010_e5; do
  for sy in 0 1; do tag=nosync; [ $sy = 1 ] && tag=sync
    SYNC=$sy SYS=1 ours q3ins_b8r256c_$tag $cell $BIN $B8 --vec-raw8 u8
    SYNC=$sy spf q3ins_spfresh_byte_$tag $cell UInt8
    SYNC=$sy dsk q3ins_diskann_flush_byte_$tag $cell u8
  done
done

# ===== 2i. section-scan insert (bench_v20): candidates from co-located section pages, no efc search; one merge per epoch =====
BIN20=work/bin/bench_v20
if [ ! -f $OUTD/smoke_v20.done ]; then
  rm -rf work/diag_smoke20
  $BIN20 --trace work/sift_200k_r9010 --db work/diag_smoke20 --out $OUTD/smoke_v20.jsonl --efs 64 --ef-final 64 --hops 4 \
    --use-sa 1 --layer-mult 0.18034 --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 u8 \
    --insert-buffer 1000000 --insert-buffer-flush-epoch --insert-section-scan --section-beam 3 --insert-batch-inline-rev \
    > $LOGD/smoke_v20.log 2>&1; rc=$?; rm -rf work/diag_smoke20
  [ $rc = 0 ] && touch $OUTD/smoke_v20.done || echo "[$(ts)] SMOKE v20 FAILED rc=$rc"
fi
SCAN="--insert-buffer 1000000 --insert-buffer-flush-epoch --insert-section-scan --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256"
ours q31scan_b1_b8r256c     $S1 $BIN20 $B8 --vec-raw8 u8 $SCAN --section-beam 1 --insert-batch-inline-rev
ours q31scan_b3_b8r256c     $S1 $BIN20 $B8 --vec-raw8 u8 $SCAN --section-beam 3 --insert-batch-inline-rev
ours q31scan_b3_c64_b8r256c $S1 $BIN20 $B8 --vec-raw8 u8 $SCAN --section-beam 3 --section-cand 64 --insert-batch-inline-rev
ours q31scan_b3_pig_b8r256c $S1 $BIN20 $B8 --vec-raw8 u8 $SCAN --section-beam 3 --insert-batch-inline-rev --insert-piggyback
ours q31scan_b3_agg_b8r256c $S1 $BIN20 $B8 --vec-raw8 u8 $SCAN --section-beam 3

# ===== 4c. SPFresh-byte SPACEV 100M full 50-epoch rerun with the system sampler (meminfo/diskstats every 10 s) =====
if [ "$(freegb)" -gt 300 ]; then
  SYSIV=10 CSIV=60 SYSFILES="work/spacev_100m_r9010/base.i8bin work/spacev_100m_r9010/pool.i8bin" spf q13full_spfresh_byte spacev_100m_r9010 Int8
else echo "[$(ts)] SKIP q13full spacev (free $(freegb)G < 300G)"; fi

# ===== 5. Q2.7 epoch-0 recall vs ef_final, efc 12 vs 20; Q2.2 insert-only / delete-only; Q2.6 one change at a time =====
for c in "$S1 u8" "$V1 i8"; do set -- $c
  ours q27cal_b8r256c_efc12 $1 $BIN $B8 --vec-raw8 $2 --max-epochs 1 --checkpoint-epochs 0 --query-sweep 32,48,64,96,128,192,256
  ours q27cal_b8r256c_efc20 $1 $BIN --layer-mult 0.18034 --efc 20 --graph-lean --vec-raw8 $2 --max-epochs 1 --checkpoint-epochs 0 --query-sweep 32,48,64,96,128,192,256
done
gen(){ local ds=$1 out=$2; shift 2
  [ -f work/$out/manifest.json ] && return
  echo "[$(ts)] gen $out"
  if [ $ds = sift ]; then src="--base-file /home/dmo/vdb_bench/raw_sift_bigann/bigann_base_10M.bvecs --query-file /home/dmo/vdb_bench/raw_sift_bigann/bigann_query.bvecs"
  else src="--base-file work/spacev_10m_r9010/base.fbin --query-file work/spacev_10m_r9010/query.fbin"; fi
  python3 driver/gen_workload.py --dataset $ds --scale 1000000 --ratio custom "$@" $src \
    --n-epochs 50 --gt-interval 10 --seed 1 --gt-method diskann --out work/$out > $LOGD/gen_$out.log 2>&1
  echo "[$(ts)] gen $out rc=$?"; }
for ds in sift spacev; do
  gen $ds ${ds}_1m_cins9 --ins-frac 0.9 --del-frac 0
  gen $ds ${ds}_1m_cdel1 --ins-frac 0 --del-frac 0.1
  gen $ds ${ds}_1m_cdel5 --ins-frac 0 --del-frac 0.5
  r8=u8; [ $ds = spacev ] && r8=i8
  for t in cins9 cdel1 cdel5; do ours q22_b8r256c ${ds}_1m_$t $BIN $B8 --vec-raw8 $r8 --diag-graph; done
done
# Q2.6: v3-like start (SQ8, rho 3000, efc 20, full graph), then one change at a time; all at ef_final 64.
ours q26_s0_sq8_rho3000_efc20_full $S1 $BIN --layer-mult 0.125 --efc 20
ours q26_s1_efc12                  $S1 $BIN --layer-mult 0.125 --efc 12
ours q26_s2_rho256                 $S1 $BIN --layer-mult 0.18034 --efc 12
ours q26_s3_raw8                   $S1 $BIN --layer-mult 0.18034 --efc 12 --vec-raw8 u8
#      s4 = + graph-lean = ours_b8r256c (q2diag_b8r256c above, same binary)
ours q26_s5_precompact_v5          $S1 work/bin/bench_v5 $B8 --vec-raw8 u8

# ===== 6. Q1.4 ours SIFT10M under total caps (page cache charged, swap off), 10 epochs each =====
for cap in 4000 2500; do
  CAP=$cap SYS=1 SYSFILES="work/$S10/base.fbin work/$S10/pool.fbin" ours q14cap${cap}_b8r256c $S10 $BIN $B8 --vec-raw8 u8 --max-epochs 10
done

# ===== 7. Q2 main finding at SIFT10M: static control (fresh e49) + diagnostic streaming run =====
[ -f work/sift_10m_fresh49/manifest.json ] || python3 driver/make_fresh_trace.py work/$S10 49 work/sift_10m_fresh49 > $LOGD/mkfresh_sift10m_49.log 2>&1
ours q2static_b8r256c_fresh49 sift_10m_fresh49 $BIN $B8 --vec-raw8 u8 --checkpoint-epochs 0 --query-sweep 64,128,256
ours q2diag_b8r256c $S10 $BIN $B8 --vec-raw8 u8 --diag-graph --checkpoint-epochs 49 --query-sweep 64,128,256,512,64n

echo "[$(ts)] DIAG DONE"
