#!/usr/bin/env python3
"""Derive native-byte copies of a V2 trace's float32 vector files (PVLDB revision Step 1).

For each of base/pool/query.fbin writes <name>.u8bin (uint8) or <name>.i8bin (int8) next to it,
same header (int32 n, int32 d). The float traces hold byte-valued data, so the conversion is exact;
this is asserted (integral + in range) and aborts otherwise. Original files are never modified.
Usage: fbin_to_byte.py <trace_dir> <uint8|int8>
"""
import sys, os, struct
import numpy as np

def convert(src, dst, dtype):
    with open(src, 'rb') as f:
        n, d = struct.unpack('ii', f.read(8))
        a = np.fromfile(f, dtype=np.float32, count=n * d)
    info = np.iinfo(dtype)
    if not np.all(a == np.round(a)):
        sys.exit(f'FATAL {src}: non-integral values, byte conversion would be lossy')
    if a.min() < info.min or a.max() > info.max:
        sys.exit(f'FATAL {src}: range [{a.min()},{a.max()}] exceeds {dtype.__name__}')
    b = a.astype(dtype)
    with open(dst, 'wb') as f:
        f.write(struct.pack('ii', n, d))
        b.tofile(f)
    print(f'{os.path.basename(dst)}: n={n} d={d} range=[{int(a.min())},{int(a.max())}] exact')

trace, kind = sys.argv[1], sys.argv[2]
dtype, ext = {'uint8': (np.uint8, 'u8bin'), 'int8': (np.int8, 'i8bin')}[kind]
for name in ('base', 'pool', 'query'):
    convert(f'{trace}/{name}.fbin', f'{trace}/{name}.{ext}', dtype)
