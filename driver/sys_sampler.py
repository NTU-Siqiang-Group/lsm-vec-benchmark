#!/usr/bin/env python3
"""System-wide sampler for the 2026-10-14 diagnostics (Q1.3 / Q3.2 / Q3.4).

Every --interval seconds writes one JSONL row:
  unix_ms, device counters of --dev from /proc/diskstats (sectors read/written, ms spent writing, in-flight),
  /proc/meminfo (MemFree, Cached, Dirty, Writeback, Slab, SReclaimable, Mapped, AnonPages, Shmem, PageTables),
  and, with --pid-file, the process CPU seconds (utime+stime, all threads) and thread count.
Every --file-every samples it adds the page-cache residency (mincore, via cache_sampler.cached_bytes) of each
--file (e.g. the trace's base/pool files). Runs until killed or until --pid-file's process exits.
Usage: sys_sampler.py --out F [--dev nvme0n1] [--interval 1] [--pid-file P] [--file X ...] [--file-every 10]
"""
import argparse, json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cache_sampler import cached_bytes  # noqa: E402

MEM_KEYS = ["MemFree", "MemAvailable", "Cached", "Dirty", "Writeback", "Slab", "SReclaimable", "Mapped",
            "AnonPages", "Shmem", "PageTables", "Active(file)", "Inactive(file)"]
CLK = os.sysconf("SC_CLK_TCK")


def meminfo():
    out = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            if k in MEM_KEYS:
                out[k] = int(v.split()[0]) / 1024.0  # MB
    return out


def diskstats(dev):
    with open("/proc/diskstats") as f:
        for line in f:
            p = line.split()
            if p[2] == dev:  # fields: reads, merged, sectors_read, ms_read, writes, merged, sectors_written, ms_write, inflight
                return {"rd_sect": int(p[5]), "wr_sect": int(p[9]), "wr_ms": int(p[10]), "inflight": int(p[11]),
                        "io_ms": int(p[12])}
    return {}


def proc_cpu(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            p = f.read().rsplit(")", 1)[1].split()
        threads = int(p[17])
        return (int(p[11]) + int(p[12])) / CLK, threads
    except (OSError, IndexError, ValueError):
        return None, None


def cgroup_mem(pid):
    """memory.current and anon/file/file_dirty/file_writeback (MB) of the process's cgroup v2."""
    try:
        rel = open(f"/proc/{pid}/cgroup").read().strip().split("::", 1)[1]
        base = "/sys/fs/cgroup" + rel
        out = {"cg_current": int(open(base + "/memory.current").read()) / 2**20}
        try:
            out["cg_max"] = open(base + "/memory.max").read().strip()
        except OSError:
            pass
        for line in open(base + "/memory.stat"):
            k, v = line.split()
            if k in ("anon", "file", "file_dirty", "file_writeback", "file_mapped", "shmem"):
                out["cg_" + k] = int(v) / 2**20
        return out
    except (OSError, IndexError, ValueError):
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--dev", default="nvme0n1")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--pid-file")
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--file-every", type=int, default=10)
    a = ap.parse_args()
    pid = None
    i = 0
    with open(a.out, "a") as out:
        while True:
            if a.pid_file and pid is None:
                try:
                    pid = int(open(a.pid_file).read().strip())
                except (OSError, ValueError):
                    pid = None
            row = {"unix_ms": int(time.time() * 1000)}
            row.update(diskstats(a.dev))
            row.update(meminfo())
            if pid:
                cpu, th = proc_cpu(pid)
                if cpu is None:
                    out.write(json.dumps(row) + "\n")
                    break  # process gone
                row["cpu_s"], row["threads"] = cpu, th
                row.update(cgroup_mem(pid))
            if a.file and i % a.file_every == 0:
                row["files_cached_mb"] = {os.path.basename(f): round(cached_bytes(f)[0] / 2**20, 1) for f in a.file}
            out.write(json.dumps(row) + "\n")
            out.flush()
            i += 1
            time.sleep(a.interval)


if __name__ == "__main__":
    main()
