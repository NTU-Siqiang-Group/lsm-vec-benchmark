#!/usr/bin/env python3
"""Build a "fresh index on the epoch-k live set" trace (R2-4 recall-decay attribution).

Replays epochs 0..k of <src> (deletes then inserts, as the harness does), takes the live vectors, renumbers
them 0..n'-1 (bulk build needs identity ids), and writes <out> with:
  base.fbin / base.ids.u32 = live set (renumbered), a 1-row dummy pool, query.fbin copied,
  a single epoch_000 with no ops, gt/epoch_000.gt100 = <src>/gt/epoch_<k>.gt100 with ids remapped.
Querying <out> at epoch 0 = recall of an index built from scratch on exactly the data the churned index holds
at epoch k, against the same ground truth. Usage: make_fresh_trace.py <src_trace> <k> <out_trace>
"""
import json, os, shutil, struct, sys
import numpy as np

src, k, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
man = json.load(open(f'{src}/manifest.json'))
dim = man['dim']

def u32(p):
    return np.fromfile(p, dtype=np.uint32) if os.path.exists(p) else np.zeros(0, np.uint32)

def fbin(p):
    n, d = np.fromfile(p, dtype=np.int32, count=2)
    return np.memmap(p, dtype=np.float32, mode='r', offset=8, shape=(int(n), int(d)))

base, pool = fbin(f'{src}/base.fbin'), fbin(f'{src}/pool.fbin')
base_ids, pool_ids = u32(f'{src}/base.ids.u32'), u32(f'{src}/pool.ids.u32')
if len(base_ids) == 0: base_ids = np.arange(base.shape[0], dtype=np.uint32)
loc = {int(g): ('b', i) for i, g in enumerate(base_ids)}
loc.update({int(g): ('p', i) for i, g in enumerate(pool_ids)})
live = set(int(g) for g in base_ids)
for e in range(k + 1):
    for g in u32(f'{src}/epoch_{e:03d}.del.u32'): live.discard(int(g))
    for g in u32(f'{src}/epoch_{e:03d}.ins.u32'): live.add(int(g))
order = sorted(live)
new_of = {g: i for i, g in enumerate(order)}
os.makedirs(f'{out}/gt', exist_ok=True)

with open(f'{out}/base.fbin', 'wb') as f:
    f.write(struct.pack('ii', len(order), dim))
    for s in range(0, len(order), 200_000):
        rows = [base[i] if t == 'b' else pool[i] for t, i in (loc[g] for g in order[s:s + 200_000])]
        np.asarray(rows, dtype=np.float32).tofile(f)
np.arange(len(order), dtype=np.uint32).tofile(f'{out}/base.ids.u32')
with open(f'{out}/pool.fbin', 'wb') as f:  # 1-row dummy pool (never inserted)
    f.write(struct.pack('ii', 1, dim)); np.zeros(dim, np.float32).tofile(f)
np.array([len(order)], dtype=np.uint32).tofile(f'{out}/pool.ids.u32')
shutil.copy(f'{src}/query.fbin', f'{out}/query.fbin')
open(f'{out}/epoch_000.ins.u32', 'wb').close(); open(f'{out}/epoch_000.del.u32', 'wb').close()

g = open(f'{src}/gt/epoch_{k:03d}.gt100', 'rb').read()
nq, K = struct.unpack('II', g[:8])
ids = np.frombuffer(g[8:8 + 4 * nq * K], dtype=np.uint32)
missing = sum(1 for x in ids if int(x) not in new_of)
if missing: sys.exit(f'FATAL: {missing} GT ids are not live at epoch {k} (replay mismatch)')
new_ids = np.array([new_of[int(x)] for x in ids], dtype=np.uint32)
with open(f'{out}/gt/epoch_000.gt100', 'wb') as f:
    f.write(g[:8]); new_ids.tofile(f); f.write(g[8 + 4 * nq * K:])

m = dict(man, scale=len(order), n_base=len(order), n_pool=1, n_epochs=1, ops_per_epoch=0, ins_per_epoch=0,
         del_per_epoch=0, gt_interval=1, fresh_from=f'{src}@epoch{k}')
json.dump(m, open(f'{out}/manifest.json', 'w'), indent=1)
print(f'fresh trace {out}: n={len(order)} (live at epoch {k}), GT remapped ({nq}x{K}), all GT ids live')
