#!/usr/bin/env python3
"""SIGMOD handoff ablations on ours_b8r256c (raw/sigmod): one row per variant vs the shared reference run.
Usage: analyze_sigmod.py <cell> <ref-label>=abl_b8r256c_ref <label>=<run-name> ... [--dat out.dat]
Means over the 50 epochs (latency, page misses/accesses, inserts); recall at epoch 0 / mean / epoch 49; memory and
sketch at epoch 49; [sketch_prefix] build stats from the run log."""
import json, re, statistics as st, sys

R, LOG = 'results/raw/sigmod', 'logs/sigmod'
COLS = ['lat_mean_ms', 'lat_p99_ms', 'page_miss_q', 'page_acc_q', 'recall_e0', 'recall_mean', 'recall_e49',
        'ins_ops_s', 'sketch_mb', 'rss_anon_mb', 'total_mem_mb', 'disk_mb',
        'sk_sections', 'sk_nodes', 'sk_frac', 'sk_nodes_p50', 'sk_frac_p50']

def row(cell, run):
    L = [json.loads(l.replace(':nan', ':null')) for l in open(f'{R}/{run}_{cell}.jsonl')]
    m = lambda k: st.mean(r[k] for r in L if r.get(k) is not None)
    rec = [r['recall10'] for r in L if r.get('recall10') is not None]
    last = L[-1]
    tot = float('nan')
    try:  # total memory = RSS + page cache of the run's own files (cache_sampler), last sample
        C = [json.loads(l) for l in open(f'{R}/{run}_{cell}.cache.jsonl')]
        tot = last['rss_mb'] + C[-1].get('cached_mb', C[-1].get('cache_mb', 0))
    except Exception:
        pass
    o = dict(lat_mean_ms=m('lat_mean_ms'), lat_p99_ms=m('lat_p99_ms'), page_miss_q=m('query_page_miss_per_query'),
             page_acc_q=m('query_io_per_query'), recall_e0=rec[0], recall_mean=st.mean(rec), recall_e49=rec[-1],
             ins_ops_s=m('ins_ops_s'), sketch_mb=last.get('mem_sa_sketch_mb', float('nan')),
             rss_anon_mb=last['rss_anon_mb'], total_mem_mb=tot, disk_mb=last['disk_mb'])
    s = open(f'{LOG}/{run}_{cell}.log', errors='replace').read()
    g = re.search(r'\[sketch_prefix\] H=\d+ sections=(\d+) members=\d+ sketch_nodes=(\d+) frac=([\d.]+) '
                  r'members_p10/p50/p90/max=\S+ nodes_p10/p50/p90/max=[\d.]+/([\d.]+)/\S+ frac_p10/p50/p90=[\d.]+/([\d.]+)', s)
    for k, v in zip(['sk_sections', 'sk_nodes', 'sk_frac', 'sk_nodes_p50', 'sk_frac_p50'],
                    g.groups() if g else [float('nan')] * 5):
        o[k] = float(v)
    return o

def main():
    a = sys.argv[1:]
    dat = None
    if '--dat' in a:
        i = a.index('--dat'); dat = a[i + 1]; del a[i:i + 2]
    cell, pairs = a[0], [x.split('=', 1) for x in a[1:]]
    rows = [(lab, row(cell, run)) for lab, run in pairs]
    fmt = lambda k, v: f'{v:.3f}' if k.startswith(('recall', 'sk_frac')) or k.startswith('lat') else f'{v:.1f}'
    print(f'**{cell}**\n| variant | ' + ' | '.join(COLS) + ' |\n|' + '---|' * (len(COLS) + 1))
    for lab, o in rows:
        print(f'| {lab} | ' + ' | '.join(fmt(k, o[k]) for k in COLS) + ' |')
    if dat:
        with open(dat, 'w') as f:
            f.write(f'# {cell}; ours_b8r256c ablation (raw/sigmod); columns as in driver/analyze_sigmod.py\n')
            f.write('variant ' + ' '.join(COLS) + '\n')
            for lab, o in rows:
                f.write(lab + ' ' + ' '.join(f'{o[k]:.4f}' for k in COLS) + '\n')

if __name__ == '__main__':
    main()
