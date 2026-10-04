#!/usr/bin/env python3
"""Derive native-byte copies of a V2 trace's float32 vector files (PVLDB revision Step 1).

For each of base/pool/query.fbin writes <name>.u8bin (uint8) or <name>.i8bin (int8) next to it,
same header (int32 n, int32 d). The float traces hold byte-valued data, so the conversion is exact;
this is asserted (integral + in range) and aborts otherwise. Original files are never modified.
Usage: fbin_to_byte.py <trace_dir> <uint8|int8>
"""
import sys, os, struct
import numpy as np

def convert(src, dst, dtype, chunk_rows=4_000_000):
    """Chunked (memory-mapped) so 100M-scale files never load whole; output identical to a one-shot pass."""
    with open(src, 'rb') as f:
        n, d = struct.unpack('ii', f.read(8))
    a = np.memmap(src, dtype=np.float32, mode='r', offset=8, shape=(n, d))
    info = np.iinfo(dtype)
    lo, hi = np.inf, -np.inf
    with open(dst + '.tmp', 'wb') as f:
        f.write(struct.pack('ii', n, d))
        for s0 in range(0, n, chunk_rows):
            c = np.asarray(a[s0:s0 + chunk_rows])
            if not np.all(c == np.round(c)):
                os.remove(dst + '.tmp')
                sys.exit(f'FATAL {src}: non-integral values (rows {s0}..), byte conversion would be lossy')
            lo, hi = min(lo, float(c.min())), max(hi, float(c.max()))
            if lo < info.min or hi > info.max:
                os.remove(dst + '.tmp')
                sys.exit(f'FATAL {src}: range [{lo},{hi}] exceeds {dtype.__name__}')
            c.astype(dtype).tofile(f)
    os.replace(dst + '.tmp', dst)
    print(f'{os.path.basename(dst)}: n={n} d={d} range=[{int(lo)},{int(hi)}] exact')

trace, kind = sys.argv[1], sys.argv[2]
dtype, ext = {'uint8': (np.uint8, 'u8bin'), 'int8': (np.int8, 'i8bin')}[kind]
for name in ('base', 'pool', 'query'):
    convert(f'{trace}/{name}.fbin', f'{trace}/{name}.{ext}', dtype)
