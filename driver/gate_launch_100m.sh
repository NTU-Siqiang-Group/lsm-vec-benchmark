#!/bin/bash
# Gate: wait for the 10M light validation to finish; PASS = epoch-0 recall@ef64 within
# 0.005 of the monolithic 10M baseline (0.9241 -> floor 0.9191). On PASS, launch the
# 100M chain fully detached (survives the interactive session).
cd /home/dmo/lsm_vec_benchmark
LOG=logs/sharded_ab/sharded4_10m_light.log
# [b]racket defeats pgrep self-matching (this script's own cmdline contains the pattern)
while pgrep -f '[b]ench_streaming --trace work/sift_10m_r9010 --db work/sharded10m_valid_db' >/dev/null; do
  sleep 60
done
sleep 5
R=$(grep -E '^64 ' "$LOG" | awk '{print $2}' | head -1)
echo "[gate] ef64 epoch-0 recall = '${R:-none}' (floor 0.9191)"
ok=$(python3 -c "
try: print(1 if float('${R:-0}') >= 0.9191 else 0)
except Exception: print(0)")
if [ "$ok" = "1" ]; then
  echo "[gate] PASS -> launching 100M chain (detached)"
  nohup setsid bash driver/run_sift_100m_chain.sh > logs/sift_100m/chain.log 2>&1 &
  echo "[gate] chain pid $!"
else
  echo "[gate] FAIL/missing -> chain NOT launched; needs manual review"
fi
