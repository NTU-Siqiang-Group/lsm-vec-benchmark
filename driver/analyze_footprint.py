#!/usr/bin/env python3
"""Footprint study (PVLDB revision): ours_efc20 SIFT1M legs fp_base / fp_wal64 / fp_outonly / fp_both.
Per leg: disk (total/graph/vector/WAL, mean + final + peak), RssAnon, page-cache, total memory,
recall, P99, insert throughput, physical write KB/insert. Mean over epochs 0..49. --md for markdown."""
import os, sys, statistics as st
sys.path.insert(0, os.path.dirname(__file__))
from analyze_byte_step1 import rows, per_epoch_cache, per_epoch_anon

RAW = 'results/raw'; CELL = 'sift_1m_r9010'
LEGS = ['fp_base', 'fp_wal64', 'fp_outonly', 'fp_both']

def leg(name):
    base = f'{RAW}/{name}_{CELL}'
    ep = [r for r in rows(base + '.jsonl') if r.get('epoch', -1) >= 0]
    if not ep: return None
    fin = ep[-1]; gt = [r for r in ep if r.get('recall10') is not None]
    anon = per_epoch_anon(base, ep); cache = per_epoch_cache(base)
    m = lambda k: st.mean(r[k] for r in ep)
    d = dict(n=len(ep), disk=m('disk_mb'), disk_pk=max(r['disk_mb'] for r in ep), disk_fin=fin['disk_mb'],
             graph=m('disk_graph_mb'), graph_fin=fin['disk_graph_mb'], vec=m('disk_vector_mb'),
             wal=m('disk_wal_mb'), wal_pk=max(r['disk_wal_mb'] for r in ep), wal_fin=fin['disk_wal_mb'],
             anon=st.mean(anon.values()) if anon else float('nan'),
             cache=st.mean(cache.values()) if cache else float('nan'),
             recall=st.mean(r['recall10'] for r in gt), p99=m('lat_p99_ms'), lat=m('lat_mean_ms'),
             ins=m('ins_ops_s'), wkb=m('ins_write_kb_per_op'))
    d['total'] = d['anon'] + d['cache']
    return d

def main():
    md = '--md' in sys.argv
    res = {l: leg(l) for l in LEGS}
    cols = [('n','ep'),('disk','disk MB'),('disk_pk','peak'),('disk_fin','final'),('graph','graph'),
            ('graph_fin','graph fin'),('vec','vector'),('wal','WAL'),('wal_pk','WAL pk'),('anon','RssAnon'),
            ('cache','cache'),('total','total mem'),('recall','R@10'),('p99','P99 ms'),('ins','ins/s'),
            ('wkb','wr KB/ins')]
    hdr = ['leg'] + [c[1] for c in cols]
    print(('| ' + ' | '.join(hdr) + ' |') if md else '  '.join(hdr))
    if md: print('|' + '---|' * len(hdr))
    for l, d in res.items():
        if not d: continue
        cells = [l] + [f'{d[k]:.3f}' if k == 'recall' else f'{d[k]:.2f}' if k == 'p99' else f'{d[k]:.0f}' for k, _ in cols]
        print(('| ' + ' | '.join(cells) + ' |') if md else '  '.join(cells))
    b = res.get('fp_base')
    if b:
        print()
        for l, d in res.items():
            if d and l != 'fp_base':
                print(f'{l}: disk mean {100*(d["disk"]/b["disk"]-1):+.0f}%  graph {100*(d["graph"]/b["graph"]-1):+.0f}%  '
                      f'WAL {100*(d["wal"]/b["wal"]-1):+.0f}%  total mem {100*(d["total"]/b["total"]-1):+.0f}%  '
                      f'recall {d["recall"]-b["recall"]:+.3f}  ins/s {100*(d["ins"]/b["ins"]-1):+.0f}%  '
                      f'wrKB/ins {100*(d["wkb"]/b["wkb"]-1):+.0f}%')

if __name__ == '__main__':
    main()
