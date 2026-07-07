#!/usr/bin/env bash
# Orchestrate SPFresh (or SPANN+) over the shared LSM-Vec benchmark trace and emit
# the per-epoch JSONL schema (see docs/baseline_driver_spec.md).
#
# Pipeline:
#   1. ssdserving builds the base SSD index from base.fbin in FILE-I/O mode
#      (UseSPDK=false, UseKV=true, KVPath=<store>/kv).  RocksDB-backed, no SPDK.
#   2. spfresh_driver loads that index and replays OUR exact per-epoch ins/del
#      GLOBAL-id lists through the SPANN dynamic API (AddIndexSPFresh/DeleteIndex),
#      runs the full query set each epoch, and computes recall@10 against OUR
#      gt/epoch_k.gt100 (global-id top-100).  It emits the JSONL + tags the epoch
#      file that mem_sampler.py reads for the continuous RSS stream.
#
# SPFresh vs SPANN+: SPFresh runs the LIRE protocol (reassignment + merge ON);
#   SPANN+ disables reassignment/merge.  Both are the SAME binaries; only the ini
#   reassign/merge knobs differ.
#
# NOTE: latencies are FILE-I/O (RocksDB) numbers, NOT the paper's SPDK numbers.
#
# Usage:
#   driver/run_spfresh.sh <trace_dir> [system] [ef]
#     trace_dir : work/<ds>_<scale>_<ratio>   (has manifest.json, base.fbin, ...)
#     system    : spfresh (default) | spannplus
#     ef        : search internal result num (default 64)
set -euo pipefail

ROOT=/home/dmo/lsm_vec_benchmark
SPF=$ROOT/spfresh/Release
DRV=$ROOT/driver
SRC=$DRV/spfresh_driver.cpp
BIN=$DRV/spfresh_driver

TRACE=${1:?usage: run_spfresh.sh <trace_dir> [spfresh|spannplus] [ef]}
TRACE=$(readlink -f "$TRACE")
SYSTEM=${2:-spfresh}
EF=${3:-64}

# ---- read manifest ----
read DIM NEPOCHS NBASE METRIC DSNAME SCALE RATIO < <(python3 - "$TRACE/manifest.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
print(m["dim"], m["n_epochs"], m["n_base"], m.get("metric","l2"),
      m["dataset"], m["scale"], m["ratio"])
PY
)
# tag: dataset shortname. synthetic->synthetic; sift stays sift. scale like 1m.
case "$SCALE" in
  1000000) STAG=1m ;; 2000) STAG=2k ;; *) STAG=$SCALE ;;
esac
# derive <ds>_<scale>_<ratio> label from the trace dir name (authoritative)
LABEL=$(basename "$TRACE")
OUT=$ROOT/results/raw/${SYSTEM}_${LABEL}.jsonl
MEM=$ROOT/results/raw/${SYSTEM}_${LABEL}.mem.jsonl
WORK=$ROOT/work/${SYSTEM}_${LABEL}
ST=$WORK/store
EPOCHF=$WORK/epoch.ctl

echo "[run] system=$SYSTEM trace=$TRACE dim=$DIM epochs=$NEPOCHS nbase=$NBASE metric=$METRIC ef=$EF"
echo "[run] out=$OUT mem=$MEM store=$ST"

mkdir -p "$ST/kv" "$ST/tmpdir" "$ROOT/results/raw"
rm -rf "$ST/kv" "$ST/tmpdir" "$ST/head_index"
mkdir -p "$ST/kv" "$ST/tmpdir"

# ---- thread count: single-thread by default (matches the SPFresh paper's AppendThreadNum=1 and is
#      apples-to-apples vs our single-threaded method). Override with THREADS=N env for multi-thread. ----
THREADS="${THREADS:-1}"
# Build threads (head-index + SSD-index construction) can differ from the workload append thread
# count. New methodology (2026-07-06): BUILD_THREADS=4 for build, THREADS=1 for the workload.
# Query is always single-thread in spfresh_driver regardless of these.
BUILD_THREADS="${BUILD_THREADS:-$THREADS}"

# ---- reassign/merge knobs: SPFresh = LIRE on (inline reassign, ReassignThreadNum=0 as in the paper's
#      iopslimit ini), SPANN+ = off (DisableReassign=true, as in the paper's spann ini) ----
if [ "$SYSTEM" = "spannplus" ]; then
  DISABLE_REASSIGN=true;  REASSIGN_THREADS=0
else
  DISABLE_REASSIGN=false; REASSIGN_THREADS=0
fi

# ---- compile the driver if stale ----
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  echo "[run] compiling driver..."
  /usr/bin/g++-9 -std=c++17 -O3 -march=native -fopenmp -w \
    -DBOOST_ALL_NO_LIB -DBOOST_ATOMIC_DYN_LINK -DBOOST_FILESYSTEM_DYN_LINK \
    -DBOOST_REGEX_DYN_LINK -DBOOST_SERIALIZATION_DYN_LINK -DBOOST_SYSTEM_DYN_LINK \
    -DBOOST_THREAD_DYN_LINK -DBOOST_WSERIALIZATION_DYN_LINK -DROCKSDB -DSPFRESH_NO_SPDK \
    -I$ROOT/spfresh/AnnService -I$ROOT/spfresh/ThirdParty/zstd/lib \
    -I$ROOT/spfresh/ThirdParty/spdk/include -isystem /home/dmo/SPFresh/rocksdb/_install/include \
    "$SRC" -o "$BIN" \
    "$SPF/libSPTAGLibStatic.a" \
    /usr/lib/x86_64-linux-gnu/libboost_system.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_thread.so.1.74.0 \
    /usr/lib/x86_64-linux-gnu/libboost_wserialization.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_regex.so.1.74.0 \
    /usr/lib/x86_64-linux-gnu/libboost_filesystem.so.1.74.0 \
    /home/dmo/SPFresh/rocksdb/_install/lib/librocksdb.a /usr/lib/x86_64-linux-gnu/libjemalloc.so \
    /usr/lib/x86_64-linux-gnu/libgflags.so.2.2.2 -lpthread /usr/lib/x86_64-linux-gnu/libsnappy.so.1.1.8 \
    "$SPF/libDistanceUtils.a" "$SPF/libzstd.a" /usr/lib/x86_64-linux-gnu/libnuma.a -ltbb \
    /usr/lib/x86_64-linux-gnu/libboost_atomic.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_serialization.so.1.74.0 \
    -lm -lrt
fi

# ---- build ini (DEFAULT vector format == our .fbin for float) ----
cat > "$WORK/build.ini" <<EOF
[Base]
ValueType=Float
DistCalcMethod=L2
IndexAlgoType=BKT
Dim=$DIM
VectorPath=$TRACE/base.fbin
VectorType=DEFAULT
VectorSize=$NBASE
QueryPath=$TRACE/query.fbin
QueryType=DEFAULT
GenerateTruth=false
IndexDirectory=$ST
HeadIndexFolder=head_index

[SelectHead]
isExecute=true
TreeNumber=1
BKTKmeansK=32
BKTLeafSize=8
SamplesNumber=1000
NumberOfThreads=$BUILD_THREADS
SelectDynamically=true
SelectThreshold=12
SplitFactor=9
SplitThreshold=18
Ratio=0.12
RecursiveCheckSmallCluster=true

[BuildHead]
isExecute=true
DistCalcMethod=L2
NeighborhoodSize=32
TPTNumber=32
TPTLeafSize=2000
MaxCheck=8192
MaxCheckForRefineGraph=8192
RefineIterations=3
GraphNeighborhoodScale=2
GraphCEFScale=2
NumberOfThreads=$BUILD_THREADS
BKTNumber=1
BKTKmeansK=32
BKTLeafSize=8
CEF=1000
AddCEF=500

[BuildSSDIndex]
isExecute=true
BuildSsdIndex=true
NumberOfThreads=$BUILD_THREADS
InternalResultNum=64
ReplicaCount=8
PostingPageLimit=12
OutputEmptyReplicaID=1
TmpDir=$ST/tmpdir
UseSPDK=false
UseKV=true
KVPath=$ST/kv
UseDirectIO=false
ResultNum=10
SearchInternalResultNum=64
SearchPostingPageLimit=12
SsdInfoFile=$ST/ssdinfo.bin
DeletedIDs=$ST/DeletedIDs.bin
EOF

# ---- loader ini consumed by spfresh_driver's LoadIndex(<store>) ----
cat > "$ST/indexloader.ini" <<EOF
[Index]
IndexAlgoType=SPANN
ValueType=Float

[Base]
ValueType=Float
DistCalcMethod=L2
IndexAlgoType=BKT
Dim=$DIM
VectorType=DEFAULT
IndexDirectory=$ST
HeadIndexFolder=head_index

[SelectHead]
isExecute=false

[BuildHead]
isExecute=false
DistCalcMethod=L2

[BuildSSDIndex]
isExecute=false
BuildSsdIndex=false
UseSPDK=false
UseKV=true
KVPath=$ST/kv
UseDirectIO=false
ReplicaCount=8
PostingPageLimit=12
SearchPostingPageLimit=12
InternalResultNum=64
SearchInternalResultNum=$EF
ResultNum=10
NumberOfThreads=$THREADS
MaxCheck=8192
HashTableExponent=4
SsdInfoFile=$ST/ssdinfo.bin
DeletedIDs=$ST/DeletedIDs.bin
Update=true
AppendThreadNum=$THREADS
InsertThreadNum=1
ReassignThreadNum=$REASSIGN_THREADS
DisableReassign=$DISABLE_REASSIGN
ReassignK=64
MergeThreshold=10
LatencyLimit=2000.0
EOF

echo "-1" > "$EPOCHF"

# ---- phase 1: build (wrapped by mem_sampler, epoch=-1) ----
echo "[run] building base index..."
python3 "$DRV/mem_sampler.py" --out "$WORK/build.mem.jsonl" --epoch-file "$EPOCHF" --dt 1.0 \
  -- "$SPF/ssdserving" "$WORK/build.ini" > "$WORK/build.log" 2>&1
grep -i "posting num:" "$WORK/build.log" | tail -1 || true

# ---- phase 2: replay our trace (wrapped by mem_sampler, epoch tagged by driver) ----
echo "[run] replaying trace..."
python3 "$DRV/mem_sampler.py" --out "$WORK/run.mem.jsonl" --epoch-file "$EPOCHF" --dt 1.0 \
  -- "$BIN" --store "$ST" --trace "$TRACE" --out "$OUT" \
     --dim "$DIM" --epochs "$NEPOCHS" --k 10 --ef "$EF" --epoch-file "$EPOCHF" \
  > "$WORK/run.log" 2>&1

# ---- merge the two mem streams into the final continuous .mem.jsonl ----
python3 - "$WORK/build.mem.jsonl" "$WORK/run.mem.jsonl" "$MEM" <<'PY'
import json,sys
build,run,out=sys.argv[1:4]
rows=[]; t=0.0
for ln in open(build):
    o=json.loads(ln); rows.append(o); t=o["t_sec"]
off=t
for ln in open(run):
    o=json.loads(ln); o["t_sec"]=round(o["t_sec"]+off,3); rows.append(o)
with open(out,"w") as f:
    for o in rows: f.write(json.dumps(o)+"\n")
print("[run] merged mem stream rows:", len(rows))
PY

echo "[run] DONE. jsonl=$OUT"
tail -n 3 "$WORK/run.log" | sed 's/^/[driver] /' || true
echo "[run] first rows:"; head -n 3 "$OUT"
