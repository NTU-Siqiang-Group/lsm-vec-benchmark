#!/usr/bin/env python3
"""Page-cache footprint sampler (mincore-based).

Periodically walks a data directory and reports how many bytes of its files are
resident in the OS page cache — the 'invisible memory' a file-I/O system relies
on, which neither VmRSS nor RssAnon captures. One JSONL row per sample:
  {"t_sec": ..., "cached_mb": ..., "store_mb": ..., "epoch": ...}

epoch is read from an optional epoch-file (spfresh's epoch.ctl convention);
-2 means no tag. Files that vanish mid-walk (compaction) are skipped.
Usage: cache_sampler.py --dir D [--dir D2 ...] --out F [--interval 15] [--epoch-file F]
"""
import argparse, ctypes, ctypes.util, json, os, sys, time

try:
    import numpy as _np  # vectorized bit-count: ~10ms for a 100GB file's mincore vec
except ImportError:
    _np = None

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                      ctypes.c_int, ctypes.c_int, ctypes.c_long]
libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
PAGE = os.sysconf("SC_PAGE_SIZE")
PROT_READ, MAP_SHARED = 0x1, 0x01
MAP_FAILED = ctypes.c_void_p(-1).value


def cached_bytes(path):
    try:
        size = os.path.getsize(path)
        if size == 0:
            return 0, 0
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return 0, 0
    try:
        addr = libc.mmap(None, size, PROT_READ, MAP_SHARED, fd, 0)
        if addr == MAP_FAILED or addr is None:
            return size, 0
        try:
            npages = (size + PAGE - 1) // PAGE
            vec = (ctypes.c_ubyte * npages)()
            if libc.mincore(ctypes.c_void_p(addr), ctypes.c_size_t(size), vec) != 0:
                return size, 0
            if _np is not None:
                resident = int((_np.frombuffer(vec, dtype=_np.uint8) & 1).sum())
            else:
                resident = sum(1 for b in vec if b & 1)
            return size, resident * PAGE
        finally:
            libc.munmap(ctypes.c_void_p(addr), ctypes.c_size_t(size))
    finally:
        os.close(fd)


def sample(dirs):
    tot_size = tot_cached = 0
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for root, _, files in os.walk(d):
            for f in files:
                s, c = cached_bytes(os.path.join(root, f))
                tot_size += s
                tot_cached += c
    return tot_size, tot_cached


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", action="append", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=15.0)
    ap.add_argument("--epoch-file", default="")
    args = ap.parse_args()
    t0 = time.time()
    with open(args.out, "w") as out:
        while True:
            size, cached = sample(args.dir)
            epoch = -2
            if args.epoch_file and os.path.exists(args.epoch_file):
                try:
                    epoch = int(open(args.epoch_file).read().strip())
                except (ValueError, OSError):
                    pass
            out.write(json.dumps({
                "t_sec": round(time.time() - t0, 1),
                "cached_mb": round(cached / 1e6, 1),
                "store_mb": round(size / 1e6, 1),
                "epoch": epoch,
            }) + "\n")
            out.flush()
            time.sleep(args.interval)


if __name__ == "__main__":
    main()
