#!/bin/bash
# dev200k_test.sh <label> — build + run the 200K SIFT trace through OUR system and
# print a one-line perf summary (build time / RSS / recall / latency / SA-buffer bytes).
# Used to measure the per-optimization performance delta in the AsterVec-adoption series.
set -e
cd /home/dmo/lsm_vec_benchmark
LABEL="${1:-run}"
EF_FINAL="${2:-128}"
BUILD_THREADS="${3:-}"    # optional --build-threads N
BULK="${4:-}"             # optional --bulk-build
TRACE=work/sift_200k_r9010
DB=work/dev200k_db
OUT=/tmp/dev200k_${LABEL}.jsonl
MEM=/tmp/dev200k_${LABEL}.mem.jsonl
LOG=/tmp/dev200k_${LABEL}.log
rm -rf "$DB"
EXTRA=""
[ -n "$BUILD_THREADS" ] && EXTRA="$EXTRA --build-threads $BUILD_THREADS"
[ -n "$BULK" ] && EXTRA="$EXTRA --bulk-build"
LSM-Vec-with-SA-HNSW/build/bin/bench_streaming \
  --trace "$TRACE" --db "$DB" --out "$OUT" --mem "$MEM" \
  --ef-final "$EF_FINAL" --hops 4 $EXTRA > "$LOG" 2>&1
python3 - "$OUT" "$MEM" "$LOG" "$LABEL" <<'PY'
import json,sys,re
out,mem,log,label=sys.argv[1:5]
r=[json.loads(l) for l in open(out)]
m=[json.loads(l) for l in open(mem)]
build=max([x['t_sec'] for x in m if x['epoch']==-1],default=0)
peak=max(x['rss_mb'] for x in m)
pb=[x['rss_mb'] for x in m if x['epoch']==0]
pb=pb[0] if pb else float('nan')
endrss=m[-1]['rss_mb']
ck=[x['recall10'] for x in r if x['recall10'] is not None]
lat=sum(x['lat_mean_ms'] for x in r)/len(r)
sab=re.findall(r'est_embedding_bytes=(\d+)',open(log).read())
sab=int(sab[-1]) if sab else 0
print(f"[{label}] build={build:.1f}s peak_rss={peak:.0f}MB postbuild_rss={pb:.0f}MB "
      f"end_rss={endrss:.0f}MB recall={ck[-1] if ck else 0:.4f} lat={lat:.2f}ms "
      f"sa_buf={sab/1e6:.1f}MB")
PY
