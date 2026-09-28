#!/usr/bin/env python3
"""E4 coupled vs decoupled layout (PVLDB revision). Means over rows per arm x workload x cell.
Query side from readonly/mixed rows; update side from mixed/updateonly rows. --md for markdown."""
import json, os, sys, statistics as st
D = 'results/raw/e4'
CELLS = ['sift_1m_r9010', 'spacev_1m_r9010']

def load(arm, wl, cell):
    p = f'{D}/e4_{arm}_{wl}_{cell}.jsonl'
    return [json.loads(l.replace(':nan', ':null')) for l in open(p)] if os.path.exists(p) else []

def mean(rows, k, pred=lambda r: True):
    v = [r[k] for r in rows if pred(r) and r.get(k) is not None]
    return st.mean(v) if v else float('nan')

def main():
    md = '--md' in sys.argv
    qcols = ['recall10', 'lat_mean_ms', 'lat_p99_ms', 'q_rocks_gets', 'q_rocks_bytes_read_kb', 'q_block_miss',
             'q_block_read_kb', 'q_vec_pages_kb', 'q_total_read_kb', 'q_cpl_unused_edge_kb', 'q_unused_frac']
    ucols = ['ins_ops_s', 'upd_rocks_logical_kb', 'upd_cpl_put_vec_kb', 'upd_wal_kb', 'upd_flush_kb',
             'upd_compact_w_kb', 'upd_proc_w_kb', 'wa', 'disk_mb', 'disk_nowal_mb', 'rss_anon_mb']
    for cell in CELLS:
        print(f'\n**{cell}** — query side'); hdr = ['arm/workload'] + qcols
        print('| ' + ' | '.join(hdr) + ' |'); print('|' + '---|' * len(hdr))
        for wl in ['readonly', 'mixed']:
            for arm in ['decoupled', 'coupled']:
                rs = [r for r in load(arm, wl, cell) if r.get('lat_mean_ms', 0) > 0]
                if not rs: continue
                for r in rs:  # decoupled vector reads: physical 4 KB page misses of the SQ8 vector file
                    r['q_vec_pages_kb'] = 4.0 * r.get('query_page_miss_per_query', 0)
                    r['q_total_read_kb'] = r.get('q_block_read_kb', 0) + r['q_vec_pages_kb']
                    g = r.get('q_rocks_bytes_read_kb') or 0
                    r['q_unused_frac'] = (r.get('q_cpl_unused_edge_kb', 0) / g) if (arm == 'coupled' and g) else 0
                vals = [f'{mean(rs, k):.3f}' if k in ('recall10', 'q_unused_frac') else f'{mean(rs, k):.1f}' for k in qcols]
                print(f'| {arm}/{wl} | ' + ' | '.join(vals) + ' |')
        print(f'\n**{cell}** — update side (per insert, KB)'); hdr = ['arm/workload'] + ucols
        print('| ' + ' | '.join(hdr) + ' |'); print('|' + '---|' * len(hdr))
        for wl in ['updateonly', 'mixed']:
            for arm in ['decoupled', 'coupled']:
                rs = [r for r in load(arm, wl, cell) if r.get('ins_ops_s', 0) > 0]
                if not rs: continue
                vrec = (128 if cell.startswith('sift') else 100) + 8  # SQ8 record bytes (decoupled vector file)
                for r in rs:  # physical WA = device writes / logical bytes (RocksDB Puts + vector-file records)
                    r['disk_nowal_mb'] = r['disk_mb'] - r.get('disk_wal_mb', 0)
                    lg = r['upd_rocks_logical_kb'] + r.get('upd_vec_writes', 0) * vrec / 1024.0
                    r['wa'] = r['upd_proc_w_kb'] / lg if lg else float('nan')
                vals = [f'{mean(rs, k):.2f}' if k == 'wa' else f'{mean(rs, k):.1f}' for k in ucols]
                print(f'| {arm}/{wl} | ' + ' | '.join(vals) + ' |')

if __name__ == '__main__':
    main()
