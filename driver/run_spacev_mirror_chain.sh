#!/bin/bash
# Master chain: SPACEV 1M (ours) -> 1M baselines -> 10M (ours). STRICTLY SERIAL, resumable.
set -u
cd /home/dmo/lsm_vec_benchmark
echo "=== CHAIN START $(date +%H:%M:%S) ==="
bash driver/run_spacev_1m_additional.sh
bash driver/run_spacev_1m_baselines.sh
bash driver/run_spacev_10m_additional.sh
echo "=== CHAIN DONE $(date +%H:%M:%S) ==="
