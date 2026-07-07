# CLAUDE.md — LSM-Vec benchmark project

Guidance for Claude Code when working in this benchmark project (the root that compares OUR method,
LSM-Vec SA-sketch, against SPFresh / SPANN+ / DiskANN). For the method's own codebase docs, see
`LSM-Vec-with-SA-HNSW/CLAUDE.md`.

## Conversation logging (workflow rule)

Append a record of **every** exchange in our conversations to `chat_history.md` at this project root:
each time you (Claude) answer, add the user's question and a concise summary of your answer/actions
(and any key results/decisions) to that file. Append-only, newest at the bottom, with a date/short
heading per exchange. Do this as part of producing each response.

## Documents location (workflow rule)

All documents — plans, design notes, findings/reports, build notes, the runbook — live in **`docs/`**
at this project root. Create new docs there. The only files that stay at the root are the operational
ones: `CLAUDE.md` (must be root to auto-load), `chat_history.md` (the running log), and `PROGRESS.md`
(the live ledger).

## Layout

```
lsm_vec_benchmark/                  ← benchmark project root (run scripts from here)
├── PROGRESS.md                        the ledger (phase status, run matrix, decisions)
├── chat_history.md                    our conversation log (append per the rule above)
├── bench.py  experiments.py           results orchestrator + experiment registry (§10)
├── docs/                              all docs: benchmark_implementation_plan.md (runbook), FINDINGS_*, plans, build notes
├── driver/                            gen_workload.py, mem_sampler.py, trace_format.md, run_*.sh
├── plot/                              style.py, datfile.py, plot_timeseries/bar/pareto.py
├── results/   { raw/  dat/  fig/ }    JSONL → canonical .dat → paper-ready .pdf/.svg
├── work/                              generated traces + scratch DBs (large, gitignore)
├── LSM-Vec-with-SA-HNSW/             OUR METHOD (git repo); C++ harness in its test/, binary in build/bin
├── diskann/                          baseline (microsoft/DiskANN cpp_main), built in build/apps
└── spfresh/                          baseline (SPFresh), built in Release/ (file-I/O mode, no SPDK)
```

## Key build facts (don't rediscover)

- **Our system needs an Aster patch:** `LSM-Vec-with-SA-HNSW/lib/aster/include/rocksdb/graph.h` was
  patched to add the `sa_tree` column family the `sa-resident-sketch` branch requires (the pinned
  upstream commit is gone). Build: `make aster && make all` in the repo; then the bench targets via
  `cmake --build build --target bench_streaming test_bench_streaming`.
- **SPFresh** is built file-I/O mode (no SPDK runtime). Binaries in `spfresh/Release/`
  (`ssdserving`, `usefultool`, `spfresh`). RocksDB fork (with RTTI) at `/home/dmo/SPFresh/rocksdb`
  (left outside the tree; binaries are static-linked). Select file-I/O backend in the `.ini`:
  `[BuildSSDIndex] UseSPDK=false, UseKV=true, KVPath=<dir>`. See `SPFRESH_BUILD_NOTES.md`.
- **DiskANN** binaries in `diskann/build/apps` (test_streaming_scenario, search_memory_index,
  build_memory_index, utils/compute_groundtruth).

## Datasets

- SIFT (BIGANN) is local: `/home/dmo/vdb_bench/raw_sift_bigann/` — `bigann_base_{1M,10M,100M}.bvecs`
  (128-d uint8) + `bigann_query.bvecs` (10k). For a 1M run, read base from the 10M file (base=first
  1M, pool=next 0.5M). SPACEV is NOT local yet (needs download from microsoft/SPTAG).

## Common commands (run from this root)

```bash
# generate a trace (real SIFT 1M, R-9010):
python3 driver/gen_workload.py --dataset sift --scale 1000000 --ratio r9010 \
  --base-file /home/dmo/vdb_bench/raw_sift_bigann/bigann_base_10M.bvecs \
  --query-file /home/dmo/vdb_bench/raw_sift_bigann/bigann_query.bvecs \
  --n-epochs 50 --gt-interval 10 --seed 1 --out work/sift_1m_r9010

# run OUR system over a trace (ef_final is the recall knob, NOT efs):
driver/run_ours.sh work/sift_1m_r9010 sift_1m_r9010 128 4

# calibrate ef_final on one build:
LSM-Vec-with-SA-HNSW/build/bin/bench_streaming --trace work/sift_1m_r9010 \
  --db work/calib_db --calibrate "16,32,64,128,256,512" --hops 4

# aggregate + plot results:
python3 bench.py run recall_epoch__sift_1m_r9010
python3 bench.py list
```

## Gotchas

- **`efs` (ef_search) is a no-op recall knob in our SA path** — sweep **`ef_final`** instead (it was
  hardcoded; `--calibrate` and `--ef-final` drive it). At 1M SIFT, ef_final≈128–256 → recall@10
  0.93–0.96.
- Base build at 1M takes ~15 min (one-shot SA rebuild) — calibrate by sweeping query params on ONE
  build, never rebuild per config.
