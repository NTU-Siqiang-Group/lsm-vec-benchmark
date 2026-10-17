#!/bin/bash
# Main streaming comparison on one cell: LSM-Vec (ours), SPFresh and FreshDiskANN, each in the dataset's native byte
# type (SIFT uint8, SPACEV int8), 4-thread build, single-thread workload, 50-epoch R-9010 trace. Strictly serial.
#
#   driver/run_main.sh <cell> [ours|spfresh|diskann ...]      e.g. driver/run_main.sh sift_1m_r9010
#
# Requires work/<cell>/ (driver/gen_workload.py + driver/fbin_to_byte.py) and the built binaries (README §3).
# Outputs results/raw/<system>_<cell>.jsonl (per-epoch metrics), .mem.jsonl (RSS vs time) and .cache.jsonl
# (page-cache footprint of the store vs time); logs in logs/main/.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
CELL=${1:?usage: run_main.sh <cell> [systems...]}; shift
SYSTEMS=${*:-ours spfresh diskann}
case "$CELL" in sift_*) BT=u8; VT=UInt8 ;; spacev_*) BT=i8; VT=Int8 ;; *) echo "cell must start with sift_ or spacev_"; exit 2 ;; esac
SCALE=$(python3 -c "import json;print(json.load(open('work/$CELL/manifest.json'))['scale'])")
BIN=${OURS_BIN:-LSM-Vec-with-SA-HNSW/build/bin/bench_streaming}
LOGD=logs/main; mkdir -p $LOGD results/raw
ts(){ date +'%m-%d %H:%M:%S'; }
sampler(){ python3 driver/cache_sampler.py --dir "$1" --out "$2" --interval ${3:-20} ${4:+--epoch-file $4} >/dev/null 2>&1 & echo $!; }

for sys in $SYSTEMS; do case $sys in
ours)
  name=ours_b8r256c; db=work/${name}_db_$CELL; out=results/raw/${name}_$CELL.jsonl
  extra=""; [ "$SCALE" -ge 50000000 ] && extra="--sharded-build 16"     # out-of-core build at 100M
  echo "[$(ts)] START $name $CELL"; rm -rf $db
  sp=$(sampler $db results/raw/${name}_$CELL.cache.jsonl)
  $BIN --trace work/$CELL --db $db --out $out --mem results/raw/${name}_$CELL.mem.jsonl \
    --efs 64 --ef-final 64 --hops 4 --query-subsample 0 --use-sa 1 --layer-mult 0.18034 \
    --bulk-build --build-threads 4 --efc 12 --mmap-vectors --graph-lean --vec-raw8 $BT \
    --checkpoint-epochs 49 --query-sweep 32,48,64,80,100,128 $extra > $LOGD/${name}_$CELL.log 2>&1
  echo "[$(ts)] $name $CELL rc=$?"; kill $sp 2>/dev/null; rm -rf $db ;;
spfresh)
  name=spfresh_byte; echo "[$(ts)] START $name $CELL"; rm -rf work/${name}_$CELL; mkdir -p work/${name}_$CELL/store
  sp=$(sampler work/${name}_$CELL/store results/raw/${name}_$CELL.cache.jsonl 20 work/${name}_$CELL/epoch.ctl)
  VALUE_TYPE=$VT BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh work/$CELL $name 64 > $LOGD/${name}_$CELL.log 2>&1
  echo "[$(ts)] $name $CELL rc=$?"; kill $sp 2>/dev/null; rm -rf work/${name}_$CELL ;;
diskann)
  name=diskann_flush_byte; idx=work/${name}_${CELL}_idx; out=results/raw/${name}_$CELL.jsonl
  echo "[$(ts)] START $name $CELL"; rm -rf ${idx}* && mkdir -p $idx
  sp=$(sampler $idx results/raw/${name}_$CELL.cache.jsonl)
  mgb=""; [ "$SCALE" -ge 50000000 ] && mgb="--M_gb 100"                 # keep the single-shot (tag-aware) build at 100M
  diskann_merge_src/build/tests/bench_stream_merge_$BT --trace work/$CELL --out $out \
    --mem results/raw/${name}_$CELL.mem.jsonl --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 --merge_every 100000 $mgb \
    > $LOGD/${name}_$CELL.log 2>&1
  echo "[$(ts)] $name $CELL rc=$?"; kill $sp 2>/dev/null; rm -rf ${idx}* ;;
*) echo "unknown system $sys" ;;
esac; done
echo "[$(ts)] DONE $CELL"
