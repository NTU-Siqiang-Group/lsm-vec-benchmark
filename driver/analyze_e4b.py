#!/usr/bin/env python3
"""E4 coupled vs decoupled on the current config ours_b8r256c (raw byte records), RESULTS §33.
Sources: results/raw/e4p (SIFT readonly/mixed, memory caps) and results/raw/sigmod (SIFT updateonly, SPACEV all).
Means over rows per arm x workload x cap x cell; same columns as analyze_e4.py (§19) + device read KB/q and cap.
Query side from readonly/mixed rows; update side from mixed/updateonly rows. Usage: analyze_e4b.py [--md]"""
import json, os, statistics as st

R = 'results/raw'
ARM = {'dec': 'decoupled', 'cpl': 'coupled'}
WL = {'ro': 'readonly', 'mix': 'mixed', 'readonly': 'readonly', 'updateonly': 'updateonly', 'mixed': 'mixed'}

def runs():  # (cell, cap, arm, wl, path)
    out = []
    for f in sorted(os.listdir(f'{R}/e4p')):
        if not (f.startswith('e4p_') and f.endswith('_r9010.jsonl')): continue
        _, arm, wl, cap, *rest = f[:-6].split('_')
        out.append(('_'.join(rest), 0 if cap == 'free' else int(cap), arm, WL[wl], f'{R}/e4p/{f}'))
    for f in sorted(os.listdir(f'{R}/sigmod')):
        if not (f.startswith('e4_b8r256c_') and f.endswith('_r9010.jsonl')): continue
        _, _, arm, wl, *rest = f[:-6].split('_')
        out.append(('_'.join(rest), 0, arm, WL[wl], f'{R}/sigmod/{f}'))
    return out

def load(p):
    return [json.loads(l.replace(':nan', ':null')) for l in open(p)]

def mean(rows, k):
    v = [r[k] for r in rows if r.get(k) is not None]
    return st.mean(v) if v else float('nan')

QC = ['recall10', 'lat_mean_ms', 'lat_p99_ms', 'q_rocks_gets', 'q_rocks_bytes_read_kb', 'q_block_miss',
      'q_block_read_kb', 'q_vec_pages_kb', 'q_unused_frac', 'q_dev_read_kb']
UC = ['ins_ops_s', 'upd_rocks_logical_kb', 'upd_cpl_put_vec_kb', 'upd_proc_w_kb', 'wa', 'disk_nowal_mb', 'rss_anon_mb']

def main():
    rs = runs()
    for cell in sorted({r[0] for r in rs}, key=lambda c: (c.split('_')[1], c)):
        vrec = 128 if cell.startswith('sift') else 100  # raw byte record (decoupled vector file)
        print(f'\n**{cell}** — query side'); h = ['cap MB', 'arm/workload', 'epochs'] + QC
        print('| ' + ' | '.join(h) + ' |'); print('|' + '---|' * len(h))
        for cell_, cap, arm, wl, p in sorted(rs, key=lambda x: (x[1], x[3], x[2] != 'dec')):
            if cell_ != cell or wl == 'updateonly': continue
            rows = [r for r in load(p) if r.get('lat_mean_ms', 0) > 0]
            for r in rows:
                r['q_vec_pages_kb'] = 4.0 * r.get('query_page_miss_per_query', 0)
                g = r.get('q_rocks_bytes_read_kb') or 0
                r['q_unused_frac'] = r.get('q_cpl_unused_edge_kb', 0) / g if (arm == 'cpl' and g) else 0
            v = [f'{mean(rows, k):.3f}' if k in ('recall10', 'q_unused_frac') else f'{mean(rows, k):.1f}' for k in QC]
            print(f'| {cap or "—"} | {ARM[arm]}/{wl} | {len(rows)} | ' + ' | '.join(v) + ' |')
        print(f'\n**{cell}** — update side (per insert, KB)'); h = ['cap MB', 'arm/workload', 'epochs'] + UC
        print('| ' + ' | '.join(h) + ' |'); print('|' + '---|' * len(h))
        for cell_, cap, arm, wl, p in sorted(rs, key=lambda x: (x[1], x[3], x[2] != 'dec')):
            if cell_ != cell or wl == 'readonly': continue
            rows = [r for r in load(p) if r.get('ins_ops_s', 0) > 0]
            for r in rows:  # physical WA = process write bytes / logical bytes (RocksDB Puts + vector-file records)
                r['disk_nowal_mb'] = r['disk_mb'] - r.get('disk_wal_mb', 0)
                lg = r.get('upd_rocks_logical_kb', 0) + r.get('upd_vec_writes', 0) * vrec / 1024.0
                r['wa'] = r.get('upd_proc_w_kb', 0) / lg if lg else float('nan')
            last = rows[-1] if rows else {}
            v = [f'{mean(rows, k):.2f}' if k == 'wa' else f'{mean(rows, k):.1f}' for k in UC[:-2]]
            v += [f'{last.get("disk_mb", 0) - last.get("disk_wal_mb", 0):.0f}', f'{last.get("rss_anon_mb", 0):.0f}']
            print(f'| {cap or "—"} | {ARM[arm]}/{wl} | {len(rows)} | ' + ' | '.join(v) + ' |')

if __name__ == '__main__':
    main()
