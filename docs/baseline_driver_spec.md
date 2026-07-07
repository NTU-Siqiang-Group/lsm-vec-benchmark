# Baseline driver spec — what each baseline driver must produce

Each baseline (DiskANN, SPFresh, SPANN+) is driven over the **same shared trace** as our system and
must emit the **same per-epoch JSONL schema** so `bench.py` can overlay all systems on one figure.

## Input: the shared trace (see `driver/trace_format.md` for byte layout)
```
work/<dataset>_<scale>_<ratio>/
  manifest.json            # dataset, dim, metric(l2), n_base, n_pool, n_epochs, ops_per_epoch, gt_interval, seed
  base.fbin  base.ids.u32  # initial index vectors + their GLOBAL ids
  pool.fbin  pool.ids.u32  # insertion source vectors + their GLOBAL ids
  query.fbin               # fixed query set
  epoch_000.ins.u32        # global ids inserted this epoch (rows pulled from pool by id)
  epoch_000.del.u32        # global ids deleted this epoch (may be absent/empty for R-INS)
  ...
  gt/epoch_000.gt100       # groundtruth (DiskANN format) for query.fbin vs the ACTIVE set after epoch 0
  gt/epoch_010.gt100       # only at gt checkpoints (every manifest.gt_interval epochs)
```
- `.fbin`: int32 n, int32 d, then n*d float32 (row-major).
- `.u32`: raw uint32 array (no header). Missing del file ⇒ no deletes that epoch.
- `.gt100`: uint32 nq, uint32 K, then nq*K uint32 neighbor **global ids**, then nq*K float32 dists.
  Recall@10 = mean over queries of |result_top10 ∩ gt_top10| / 10.
- **Ids are stable GLOBAL ids.** Insert each vector under its global id as the system's tag/label, so
  delete lists and groundtruth match unambiguously. (DiskANN: use the id as the `tag`. SPFresh: map the
  id to its native key.)

## Driver behavior (per epoch k = 0..n_epochs-1)
1. Apply `epoch_k.del.u32` (delete by global id) then `epoch_k.ins.u32` (insert that global id's vector
   from pool). Record delete wall-time and insert wall-time + counts.
2. Run the **full query set** (`query.fbin`) — record per-query latency.
3. If `gt/epoch_k.gt100` exists, compute recall@10 against it; else recall is null.
4. Emit one JSONL row (below). Maintain a live-set so `live_n` = base + Σins − Σdel.

## Output: `results/raw/<system>_<dataset>_<scale>_<ratio>.jsonl` — one JSON object per epoch
```json
{"epoch":0,"live_n":1008000,"recall10":0.93,"qps":1234.5,"lat_mean_ms":0.81,"lat_p50_ms":0.79,
 "lat_p99_ms":1.20,"ins_ops_s":5000.0,"del_ops_s":4000.0,"rss_mb":920.5,"disk_mb":2554.0,
 "query_io_per_query":0}
```
- `recall10`: number at gt checkpoints, JSON `null` otherwise.
- latency percentiles are **P50 and P99** (not P99.9), in ms; `qps` = queries / query-phase wall-time.
- `ins_ops_s`/`del_ops_s` = count / that epoch's apply-phase wall-time (0 if none).
- `rss_mb`: process RSS sampled at emit time (also produce the continuous stream below).
- `disk_mb`: on-disk index size in MB (0 / best-effort for a purely in-memory index — note it).
- `query_io_per_query`: ours-only (page-cache accesses); baselines emit 0.
- **System names** (the `<system>` in the filename, must match `experiments.py`): `diskann_ip`,
  `diskann_merge`, `spfresh`, `spannplus`.

## Output: `results/raw/<system>_<dataset>_<scale>_<ratio>.mem.jsonl` — continuous RSS stream
One object per ~1s for the WHOLE run (build + every epoch): `{"t_sec":12.3,"epoch":4,"rss_mb":940.1}`.
Either sample in-process (read `/proc/self/status` VmRSS in a background thread) or wrap the process with
`driver/mem_sampler.py` (it polls `/proc/<pid>/status` and tags epochs from a control file).

## Sanity gate (the §5 ALIGN check — do this on the small synthetic trace first)
Validate on `work/synth_2k_r9010` (dim=32, n_base=2000, 5 epochs, gt every epoch — fast) BEFORE the 1M
run: (a) `live_n` after each epoch matches base+Σins−Σdel; (b) a deleted id never appears in results;
(c) recall@10 is sane (>0 and computed against the gt file); (d) JSONL has all required fields. Only then
run the real `work/sift_1m_r9010`.
