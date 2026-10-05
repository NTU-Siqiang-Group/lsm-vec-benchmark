#!/usr/bin/env python3
"""Phase C byte main matrix: ours_b8r256 vs SPFresh-byte vs FreshDiskANN-byte (+ ours v3 reference).
Means over the 50-epoch stream; ratios baseline ÷ ours. --md prints markdown."""
import os, statistics as st, sys
sys.path.insert(0, os.path.dirname(__file__))
from analyze_byte_step1 import rows, per_epoch_cache, per_epoch_anon
RAW = 'results/raw'
CELLS = ['sift_1m_r9010', 'spacev_1m_r9010', 'sift_10m_r9010', 'spacev_10m_r9010', 'sift_100m_r9010', 'spacev_100m_r9010']
SYS = [('ours_b8r256', 'ours_b8r256'), ('ours v3 (SQ8, ratio 3000, efc20, ef100)', 'ours_efc20_v3'),
       ('SPFresh-byte', 'spfresh_byte'), ('DiskANN-byte', 'diskann_flush_byte')]

def stats(name, cell):
    b = f'{RAW}/{name}_{cell}'
    ep = [r for r in rows(b + '.jsonl') if r.get('epoch', -1) >= 0 and 'lat_mean_ms' in r]
    if not ep: return None
    gt = [r for r in ep if r.get('recall10') is not None]
    m = lambda k: st.mean(r[k] for r in ep if r.get(k) is not None)
    a = per_epoch_anon(b, ep); c = per_epoch_cache(b)
    return dict(n=len(ep), rec=st.mean(r['recall10'] for r in gt), r0=gt[0]['recall10'], r49=gt[-1]['recall10'],
                lat=m('lat_mean_ms'), p99=m('lat_p99_ms'), ins=m('ins_ops_s'), anon=st.mean(a.values()),
                cache=st.mean(c.values()) if c else float('nan'),
                total=st.mean(a.values()) + (st.mean(c.values()) if c else float('nan')), disk=m('disk_mb'),
                wkb=m('ins_write_kb_per_op') if any(r.get('ins_write_kb_per_op') for r in ep) else float('nan'))

for cell in CELLS:
    S = {lbl: stats(n, cell) for lbl, n in SYS}
    if not S['ours_b8r256']: continue
    print(f'\n**{cell}**\n')
    print('| system | recall mean (e0→e49) | lat ms | P99 ms | ins/s | RssAnon MB | page cache MB | total MB | disk MB | write KB/ins |')
    print('|---|---|---|---|---|---|---|---|---|---|')
    for lbl, d in S.items():
        if not d: continue
        print(f"| {lbl} | {d['rec']:.3f} ({d['r0']:.3f}→{d['r49']:.3f}) | {d['lat']:.2f} | {d['p99']:.2f} | {d['ins']:,.0f} | "
              f"{d['anon']:,.0f} | {d['cache']:,.0f} | {d['total']:,.0f} | {d['disk']:,.0f} | {d['wkb']:.1f} |")
    o = S['ours_b8r256']
    for lbl in ('SPFresh-byte', 'DiskANN-byte'):
        b = S[lbl]
        if not b: continue
        print(f"\n{lbl} ÷ ours: total {b['total']/o['total']:.1f}x · disk {b['disk']/o['disk']:.1f}x · RssAnon {b['anon']/o['anon']:.2f}x · "
              f"write/ins {b['wkb']/o['wkb']:.1f}x · ours P99 {o['p99']/b['p99']:.2f}x of theirs · ours ins {o['ins']/b['ins']:.2f}x · recall {o['rec']-b['rec']:+.3f}")
