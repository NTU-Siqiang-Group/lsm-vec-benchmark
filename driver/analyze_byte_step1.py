#!/usr/bin/env python3
"""PVLDB revision Step 1: float32 (V2.1) vs native-byte baselines, plus ours_efc20.

Per system and cell: recall@10, P99, insert throughput/latency, RssAnon, page-cache footprint,
total footprint (= RssAnon + footprint, per epoch), disk, per-insert physical write — each as the
mean over the 50-epoch stream and the final epoch. Cache samples are epoch-tagged (SPFresh) or mapped
onto epochs through the .mem.jsonl timeline (ours, DiskANN: sampler and run start together).
Usage: analyze_byte_step1.py [--md]   (reads results/raw, prints tables)
"""
import json, os, sys, bisect, statistics as st

RAW = os.path.join(os.path.dirname(__file__), '..', 'results', 'raw')
MD = '--md' in sys.argv


def rows(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        line = line.strip().replace(':nan', ':null')
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def per_epoch_cache(base):
    """epoch -> mean cached_mb (page-cache footprint) over that epoch's samples."""
    cache = rows(f'{base}.cache.jsonl')
    if not cache:
        return {}
    tagged = [c for c in cache if c.get('epoch', -2) >= 0]
    by = {}
    if tagged:
        for c in tagged:
            by.setdefault(c['epoch'], []).append(c['cached_mb'])
    else:
        mem = [m for m in rows(f'{base}.mem.jsonl') if 'epoch' in m and 't_sec' in m]
        if not mem:
            return {}
        ts = [m['t_sec'] for m in mem]
        for c in cache:
            i = min(bisect.bisect_left(ts, c['t_sec']), len(mem) - 1)
            e = mem[i]['epoch']
            if e >= 0:
                by.setdefault(e, []).append(c['cached_mb'])
    return {e: st.mean(v) for e, v in by.items()}


def per_epoch_anon(base, ep):
    """epoch -> RssAnon MB. Per-epoch JSONL field if present, else mean from .mem.jsonl."""
    if any(r.get('rss_anon_mb') for r in ep):
        return {r['epoch']: r['rss_anon_mb'] for r in ep if r.get('rss_anon_mb') is not None}
    by = {}
    for m in rows(f'{base}.mem.jsonl'):
        if m.get('epoch', -1) >= 0 and m.get('rss_anon_mb') is not None:
            by.setdefault(m['epoch'], []).append(m['rss_anon_mb'])
    return {e: st.mean(v) for e, v in by.items()}


def summarize(name, cell, directory=RAW):
    base = os.path.join(directory, f'{name}_{cell}')
    ep = [r for r in rows(f'{base}.jsonl') if r.get('epoch', -1) >= 0 and 'lat_mean_ms' in r]
    if not ep:
        return None
    last = max(r['epoch'] for r in ep)
    fin = [r for r in ep if r['epoch'] == last][0]
    gt = [r for r in ep if r.get('recall10') is not None]
    anon = per_epoch_anon(base, ep)
    cache = per_epoch_cache(base)
    tot = {e: anon[e] + cache[e] for e in anon if e in cache}

    def mean(k):
        v = [r[k] for r in ep if r.get(k) is not None]
        return st.mean(v) if v else None

    def mf(d):
        return (st.mean(d.values()) if d else None, d.get(last) if d else None)

    return {
        'epochs': len(ep),
        'recall': (st.mean(r['recall10'] for r in gt) if gt else None, gt[-1]['recall10'] if gt else None),
        'p99': (mean('lat_p99_ms'), fin.get('lat_p99_ms')),
        'lat': (mean('lat_mean_ms'), fin.get('lat_mean_ms')),
        'ins': (mean('ins_ops_s'), fin.get('ins_ops_s')),
        'anon': mf(anon), 'cache': mf(cache), 'total': mf(tot),
        'disk': (mean('disk_mb'), fin.get('disk_mb')),
        'wkb': (mean('ins_write_kb_per_op'), fin.get('ins_write_kb_per_op')),
    }


def f(x, p=0):
    if x is None:
        return '—'
    return f'{x:,.{p}f}'


COLS = [('recall', 3, 'recall@10'), ('p99', 2, 'P99 ms'), ('ins', 0, 'ins/s'),
        ('anon', 0, 'RssAnon MB'), ('cache', 0, 'cache MB'), ('total', 0, 'total MB'),
        ('disk', 0, 'disk MB'), ('wkb', 1, 'write KB/ins')]


def table(cell, systems):
    hdr = ['system'] + [f'{c[2]} mean / final' for c in COLS]
    lines = []
    if MD:
        lines.append('| ' + ' | '.join(hdr) + ' |')
        lines.append('|' + '---|' * len(hdr))
    else:
        lines.append(f'=== {cell} ===')
    res = {}
    for label, name, directory in systems:
        s = summarize(name, cell, directory)
        res[label] = s
        if s is None:
            cells = ['(missing)'] + [''] * (len(COLS) - 1)
        else:
            cells = [f'{f(s[k][0], p)} / {f(s[k][1], p)}' for k, p, _ in COLS]
        if MD:
            lines.append(f'| {label} | ' + ' | '.join(cells) + ' |')
        else:
            lines.append(f'{label:26} ' + ' | '.join(cells))
    print('\n'.join(lines))
    return res


def ratio(a, b, k, i):
    if not a or not b or a[k][i] in (None, 0) or b[k][i] is None:
        return None
    return b[k][i] / a[k][i]


if __name__ == '__main__':
    MBD = os.path.join(RAW, '..', 'v2_tuned', 'membudget')
    all_res = {}
    for cell in ('sift_1m_r9010', 'spacev_1m_r9010', 'sift_10m_r9010'):
        systems = [('ours_efc20 (V2.1)', 'ours_efc20', RAW), ('ours_v2 (V2.1)', 'ours_v2', RAW),
                   ('spfresh float32 (V2.1)', 'spfresh_v2', RAW), ('spfresh byte', 'spfresh_byte', RAW),
                   ('diskann float32 (V2.1)', 'diskann_flush_v2', RAW),
                   ('diskann byte', 'diskann_flush_byte', RAW)]
        if MD:
            print(f'\n#### {cell}\n')
        all_res[cell] = table(cell, systems)
        print()
    print('=== ratios baseline / ours_efc20 (mean over stream; final in parentheses) ===')
    for cell, r in all_res.items():
        o = r.get('ours_efc20 (V2.1)')
        for lbl in ('spfresh float32 (V2.1)', 'spfresh byte', 'diskann float32 (V2.1)', 'diskann byte'):
            b = r.get(lbl)
            if not o or not b:
                continue
            t = [ratio(o, b, 'total', 0), ratio(o, b, 'total', 1)]
            d = [ratio(o, b, 'disk', 0), ratio(o, b, 'disk', 1)]
            a = [ratio(o, b, 'anon', 0), ratio(o, b, 'anon', 1)]
            print(f'{cell:16} {lbl:24} total {f(t[0],1)}x ({f(t[1],1)}x) | disk {f(d[0],1)}x ({f(d[1],1)}x)'
                  f' | RssAnon {f(a[0],1)}x ({f(a[1],1)}x)')
    print('\n=== memory-cap legs (sift_1m) ===')
    for name in ('ours_efc20', 'ours_v2', 'spfresh_v2', 'spfresh_byte', 'diskann_flush_v2', 'diskann_flush_byte'):
        for tag in ('4g', '2g'):
            ep = [r for r in rows(os.path.join(MBD, f'{name}_mb{tag}_sift_1m_r9010.jsonl'))
                  if r.get('epoch', -1) >= 0 and 'lat_mean_ms' in r]
            if not ep and not os.path.exists(os.path.join(MBD, f'{name}_mb{tag}_sift_1m_r9010.jsonl')):
                continue
            gt = [r['recall10'] for r in ep if r.get('recall10') is not None]
            lat = [r['lat_mean_ms'] for r in ep]
            p99 = [r['lat_p99_ms'] for r in ep if r.get('lat_p99_ms') is not None]
            print(f'{name:20} {tag}: epochs={len(ep):2d}  lat mean {f(st.mean(lat) if lat else None,2)} ms'
                  f'  P99 mean {f(st.mean(p99) if p99 else None,2)} ms  recall mean {f(st.mean(gt) if gt else None,3)}')
