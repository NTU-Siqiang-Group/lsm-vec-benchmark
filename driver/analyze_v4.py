#!/usr/bin/env python3
"""ours_efc20_f32r256 (float32 records, adjacent ratio 256) vs the V2.1 float32 baselines.
Main 50-epoch means per cell, ratios, and iso-recall latency (linear interpolation on each system's
ef sweep) at epoch 0 and epoch 49. Ours: epoch 0 = calib0.txt, epoch 49 = .jsonl.sweep.jsonl;
baselines: v2_tuned/pareto/<sys>_<cell>.jsonl.sweep.jsonl (epochs 0 and 49)."""
import json, os, statistics as st, sys
sys.path.insert(0, os.path.dirname(__file__))
from analyze_byte_step1 import rows, per_epoch_cache, per_epoch_anon
RAW = 'results/raw'; PAR = 'results/v2_tuned/pareto'
CELLS = ['sift_1m_r9010', 'spacev_1m_r9010', 'sift_10m_r9010', 'spacev_10m_r9010']
SYS = [('ours f32r256', 'ours_efc20_f32r256'), ('SPFresh f32', 'spfresh_v2'), ('DiskANN f32', 'diskann_flush_v2')]

def main_stats(name, cell):
    b = f'{RAW}/{name}_{cell}'
    ep = [r for r in rows(b + '.jsonl') if r.get('epoch', -1) >= 0 and 'lat_mean_ms' in r]
    gt = [r for r in ep if r.get('recall10') is not None]
    m = lambda k: st.mean(r[k] for r in ep if r.get(k) is not None)
    a = per_epoch_anon(b, ep); c = per_epoch_cache(b)
    return dict(recall=st.mean(r['recall10'] for r in gt), p99=m('lat_p99_ms'), lat=m('lat_mean_ms'),
                ins=m('ins_ops_s'), anon=st.mean(a.values()), total=st.mean(a.values()) + st.mean(c.values()),
                disk=m('disk_mb'))

def curve(name, cell, epoch):
    pts = []
    if name.startswith('ours'):
        if epoch == 0:
            for line in open(f'{RAW}/{name}_{cell}.calib0.txt'):
                f = line.split()
                if len(f) == 7 and f[0].isdigit():
                    pts.append((float(f[1]), float(f[2]), float(f[4])))
        else:
            for r in rows(f'{RAW}/{name}_{cell}.jsonl.sweep.jsonl'):
                if r['epoch'] == epoch: pts.append((r['recall10'], r['lat_mean_ms'], r['lat_p99_ms']))
    else:
        for r in rows(f'{PAR}/{name}_{cell}.jsonl.sweep.jsonl'):
            if r['epoch'] == epoch: pts.append((r['recall10'], r['lat_mean_ms'], r['lat_p99_ms']))
    return sorted(pts)

def at(pts, target):
    for (r0, l0, p0), (r1, l1, p1) in zip(pts, pts[1:]):
        if r0 <= target <= r1 and r1 > r0:
            t = (target - r0) / (r1 - r0)
            return l0 + t * (l1 - l0), p0 + t * (p1 - p0)
    return None

if __name__ == '__main__':
    for cell in CELLS:
        print(f'\n**{cell}**\n')
        print('| system | recall@10 | lat ms | P99 ms | ins/s | RssAnon MB | total MB | disk MB |')
        print('|---|---|---|---|---|---|---|---|')
        S = {lbl: main_stats(n, cell) for lbl, n in SYS}
        for lbl, d in S.items():
            print(f"| {lbl} | {d['recall']:.3f} | {d['lat']:.2f} | {d['p99']:.2f} | {d['ins']:,.0f} | {d['anon']:,.0f} | {d['total']:,.0f} | {d['disk']:,.0f} |")
        o = S['ours f32r256']
        for lbl in ('SPFresh f32', 'DiskANN f32'):
            b = S[lbl]
            print(f"\n{lbl} ÷ ours: total {b['total']/o['total']:.1f}x, disk {b['disk']/o['disk']:.1f}x, RssAnon {b['anon']/o['anon']:.1f}x, "
                  f"P99 {b['p99']/o['p99']:.2f}x, ins {b['ins']/o['ins']:.2f}x, recall {b['recall']-o['recall']:+.3f}")
        for ep in (0, 49):
            oc = curve('ours_efc20_f32r256', cell, ep)
            for lbl, n in SYS[1:]:
                bc = curve(n, cell, ep)
                if not oc or not bc: continue
                lo = max(oc[0][0], bc[0][0]); hi = min(oc[-1][0], bc[-1][0])
                tg = [t for t in (0.85, 0.88, 0.90, 0.92, 0.94, 0.95, 0.96, 0.97, 0.98) if lo <= t <= hi]
                print(f"iso-recall e{ep} ours vs {lbl} (overlap {lo:.3f}-{hi:.3f}): " + '; '.join(
                    f"R={t:.2f} ours {at(oc,t)[0]:.2f}/{at(oc,t)[1]:.2f} vs {at(bc,t)[0]:.2f}/{at(bc,t)[1]:.2f}" for t in tg) + '  (mean/P99 ms)')
