#!/bin/bash
# SIFT 100M cell — full serial chain (decision 2026-07-18):
#   0. generate work/sift_100m_r9010 (base 100M + pool 50M from bigann_base_150M.bvecs)
#   1. ours          (sketch-only default, SHARDED build 16 + mmap, ef_final=64) — no ablations
#   2. spfresh       (file-I/O; disk-watchdogged — projected index ~750-810GB, may abort)
#   3. diskann flush (merge_every=100k, disk-watchdogged)
#   4. diskann default (merge_every=30M) — ONLY if stage 3 failed
# STRICTLY SERIAL. Resumable: every stage skips if its output already has 50 epochs.
# Heavy per-system dirs are deleted after each stage to make room for the next.
set -u
cd /home/dmo/lsm_vec_benchmark
TRACE=work/sift_100m_r9010
CELL=sift_100m_r9010
LOGD=logs/sift_100m
mkdir -p "$LOGD" results/raw logs/diskann_flush
ts(){ date +'%m-%d %H:%M:%S'; }
dfree(){ df -h /home/dmo | tail -1 | awk '{print $4}'; }
done50(){ [ -f "$1" ] && [ "$(wc -l <"$1")" -ge 50 ]; }

echo "[$(ts)] CHAIN START free=$(dfree)"

# ---------- stage 0: trace ----------
if [ -f "$TRACE/manifest.json" ]; then
  echo "[$(ts)] SKIP gen (manifest exists)"
else
  echo "[$(ts)] START gen trace (low-mem auto, diskann GT)"
  python3 driver/gen_workload.py --dataset sift --scale 100000000 --ratio r9010 \
    --base-file /home/dmo/vdb_bench/raw_sift_bigann/bigann_base_150M.bvecs \
    --query-file /home/dmo/vdb_bench/raw_sift_bigann/bigann_query.bvecs \
    --n-epochs 50 --gt-interval 10 --seed 1 --gt-method diskann \
    --out "$TRACE" > "$LOGD/gen.log" 2>&1
  rc=$?
  echo "[$(ts)] gen rc=$rc free=$(dfree)"
  [ $rc -ne 0 ] && { echo "[$(ts)] FATAL: trace gen failed"; exit 1; }
fi

# ---------- stage 1: ours (sharded build) ----------
if done50 "results/raw/ours_${CELL}.jsonl"; then
  echo "[$(ts)] SKIP ours"
else
  echo "[$(ts)] START ours (sharded 16, mmap, ef_final=64) free=$(dfree)"
  NAME=ours USE_SA=1 LAYER_MULT=0.125 BULK=1 BUILD_THREADS=4 \
    EXTRA_ARGS="--sharded-build 16 --mmap-vectors" \
    bash driver/run_ours.sh "$TRACE" "$CELL" 64 4 0 > "$LOGD/ours.log" 2>&1
  echo "[$(ts)] ours rc=$? free=$(dfree)"
fi
rm -rf work/ours_db_${CELL}   # ~110GB — make room for spfresh

# ---------- stage 2: spfresh (disk-watchdogged) ----------
if done50 "results/raw/spfresh_${CELL}.jsonl"; then
  echo "[$(ts)] SKIP spfresh"
else
  echo "[$(ts)] START spfresh free=$(dfree)"
  BUILD_THREADS=4 THREADS=1 bash driver/run_spfresh.sh "$TRACE" spfresh 64 \
    > "$LOGD/spfresh.log" 2>&1 &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    free_kb=$(df --output=avail /home/dmo | tail -1)
    if [ "$free_kb" -lt 20971520 ]; then   # < 20GB
      echo "[$(ts)] ABORT spfresh: free disk < 20GB (index replication too large)"
      pkill -9 -P $pid 2>/dev/null; kill -9 $pid 2>/dev/null
      break
    fi
    sleep 60
  done
  wait $pid 2>/dev/null
  echo "[$(ts)] spfresh rc=$? free=$(dfree)"
fi
rm -rf work/spfresh_${CELL}   # SPFresh store (huge)

# ---------- stage 3: diskann flush (merge_every=100k) ----------
FLUSH_OK=0
if done50 "results/raw/diskann_merge_flush_${CELL}.jsonl"; then
  echo "[$(ts)] SKIP diskann flush"
  FLUSH_OK=1
else
  idx=work/diskann_merge_flush_${CELL}_idx
  rm -rf ${idx}* && mkdir -p "$idx"
  echo "[$(ts)] START diskann flush100k free=$(dfree)"
  diskann_merge_src/build/tests/bench_stream_merge --trace "$TRACE" \
    --out results/raw/diskann_merge_flush_${CELL}.jsonl \
    --mem results/raw/diskann_merge_flush_${CELL}.mem.jsonl \
    --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 \
    --merge_every 100000 > logs/diskann_flush/${CELL}.log 2>&1 &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    free_kb=$(df --output=avail /home/dmo | tail -1)
    if [ "$free_kb" -lt 15728640 ]; then   # < 15GB
      echo "[$(ts)] ABORT diskann flush: free disk < 15GB (merge temp)"
      kill -9 $pid 2>/dev/null
      break
    fi
    sleep 60
  done
  wait $pid 2>/dev/null; rc=$?
  echo "[$(ts)] diskann flush rc=$rc free=$(dfree)"
  rm -rf ${idx}temp*
  done50 "results/raw/diskann_merge_flush_${CELL}.jsonl" && FLUSH_OK=1
  [ $FLUSH_OK -eq 1 ] || rm -rf ${idx}*
fi

# ---------- stage 4: diskann default interval — only if flush failed ----------
if [ $FLUSH_OK -eq 0 ] && ! done50 "results/raw/diskann_merge_${CELL}.jsonl"; then
  idx=work/diskann_merge_${CELL}_idx
  rm -rf ${idx}* && mkdir -p "$idx"
  echo "[$(ts)] START diskann default (merge_every=30M) free=$(dfree)"
  diskann_merge_src/build/tests/bench_stream_merge --trace "$TRACE" \
    --out results/raw/diskann_merge_${CELL}.jsonl \
    --mem results/raw/diskann_merge_${CELL}.mem.jsonl \
    --index_prefix $idx/idx --work_dir $idx \
    --L 150 --R 64 --Lbuild 75 --alpha 1.2 --beamwidth 2 --build_threads 4 \
    --merge_every 30000000 > "$LOGD/diskann_default.log" 2>&1 &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    free_kb=$(df --output=avail /home/dmo | tail -1)
    [ "$free_kb" -lt 15728640 ] && { echo "[$(ts)] ABORT diskann default: disk"; kill -9 $pid 2>/dev/null; break; }
    sleep 60
  done
  wait $pid 2>/dev/null
  echo "[$(ts)] diskann default rc=$? free=$(dfree)"
  rm -rf ${idx}temp*
fi

echo "[$(ts)] CHAIN DONE free=$(dfree)"
