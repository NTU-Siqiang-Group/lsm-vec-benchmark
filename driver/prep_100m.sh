#!/bin/bash
# 100M data prep for the byte main matrix (docs/2026-10-04-byte-main-matrix-plan.md, Phase D).
# Run only when NO measurement is running (heavy I/O + CPU). Resumable; each step checks its output.
#   1. SIFT 100M: native uint8 copies of the existing trace (chunked fbin_to_byte).
#   2. SPACEV: range-download the first 150M base vectors (15 GB) + query file from big-ann-benchmarks,
#      patch the header n, verify the prefix against the existing SPACEV 10M trace (base+pool = rows 0..15M)
#      and the 10k queries, then generate spacev_100m_r9010 exactly like spacev_10m (seed 1, gt diskann).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"
LOGD=logs/prep_100m; mkdir -p $LOGD; RAWD=work/raw_spacev; mkdir -p $RAWD
ts(){ date +'%m-%d %H:%M:%S'; }
URL=https://comp21storage.z5.web.core.windows.net/comp21/spacev1b
N=150000000; D=100

# 1. SIFT 100M byte copies
if [ ! -f work/sift_100m_r9010/query.u8bin ]; then
  echo "[$(ts)] fbin_to_byte sift_100m"; python3 driver/fbin_to_byte.py work/sift_100m_r9010 uint8 > $LOGD/sift_byte.log 2>&1 || { echo FAIL; exit 1; }
fi

# 2a. SPACEV download (range) + header patch
BASE=$RAWD/spacev_base_150M.i8bin
if [ ! -f $BASE.ok ]; then
  echo "[$(ts)] download spacev base rows 0..$N"
  curl -sS --retry 10 -C - -r 0-$((8 + N * D - 1)) -o $BASE.part $URL/spacev1b_base.i8bin || { echo FAIL; exit 1; }
  [ "$(stat -c %s $BASE.part)" -eq $((8 + N * D)) ] || { echo "FAIL size"; exit 1; }
  python3 -c "import struct;f=open('$BASE.part','r+b');f.write(struct.pack('ii',$N,$D))"
  mv $BASE.part $BASE; touch $BASE.ok
fi
QRY=$RAWD/spacev_query.i8bin
[ -f $QRY ] || curl -sS --retry 10 -o $QRY $URL/query.i8bin || { echo FAIL; exit 1; }

# 2b. verify prefix + queries against the existing spacev_10m trace
if [ ! -f $RAWD/verify.ok ]; then
  python3 - <<PY > $LOGD/verify.log 2>&1 || { echo "FAIL verify (see $LOGD/verify.log)"; exit 1; }
import numpy as np
def fb(p):
    n,d=np.fromfile(p,dtype=np.int32,count=2); return np.memmap(p,dtype=np.float32,mode='r',offset=8,shape=(n,d))
def ib(p):
    n,d=np.fromfile(p,dtype=np.int32,count=2); return np.memmap(p,dtype=np.int8,mode='r',offset=8,shape=(n,d))
raw=ib('$BASE'); q=ib('$QRY')
b10=fb('work/spacev_10m_r9010/base.fbin'); p10=fb('work/spacev_10m_r9010/pool.fbin'); q10=fb('work/spacev_10m_r9010/query.fbin')
import random
for i in random.Random(1).sample(range(10_000_000), 20000)+list(range(1000)):
    assert (raw[i]==b10[i]).all(), ('base', i)
for i in random.Random(2).sample(range(5_000_000), 20000):
    assert (raw[10_000_000+i]==p10[i]).all(), ('pool', i)
qs={q[i].tobytes() for i in range(len(q))}
assert all(q10[j].astype(np.int8).tobytes() in qs for j in range(len(q10))), 'query subset'  # gen picks a seeded subset
print('prefix + query verified')
PY
  touch $RAWD/verify.ok
fi

# 2c. trace (same generator settings as spacev_10m; low-mem path auto-engages > 30M)
if [ ! -f work/spacev_100m_r9010/manifest.json ]; then
  echo "[$(ts)] gen spacev_100m"
  python3 driver/gen_workload.py --dataset spacev --scale 100000000 --ratio r9010 \
    --base-file $BASE --query-file $QRY --max-queries 10000 \
    --n-epochs 50 --gt-interval 10 --seed 1 --gt-method diskann \
    --out work/spacev_100m_r9010 > $LOGD/gen_spacev_100m.log 2>&1 || { echo FAIL gen; exit 1; }
fi
cmp work/spacev_100m_r9010/query.fbin work/spacev_10m_r9010/query.fbin || { echo "FAIL query mismatch vs spacev_10m"; exit 1; }
[ -f work/spacev_100m_r9010/query.i8bin ] || python3 driver/fbin_to_byte.py work/spacev_100m_r9010 int8 > $LOGD/spacev_byte.log 2>&1
echo "[$(ts)] PREP 100M DONE"
