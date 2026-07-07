#!/usr/bin/env python3
"""External real-time RSS sampler for the baseline orchestrators (runbook §5).

Each baseline is a separate process, so we poll its RSS from outside. This script
either launches a command and samples it, or attaches to an existing PID, writing
{t_sec, epoch, rss_mb} to a .mem.jsonl every Δt seconds from launch to exit — the
same continuous DRAM-vs-time curve as our in-process sampler (§3 Step 5).

The `epoch` tag is read from an optional control file (one integer) that the
orchestrator overwrites as it advances the stream; -1 means "pre-stream / build".

Usage:
  # launch + sample:
  mem_sampler.py --out results/raw/diskann_ip_sift_1m_r9010.mem.jsonl \
                 --epoch-file /tmp/diskann.epoch --dt 1.0 -- ./SSDServing build.ini
  # attach to a known pid:
  mem_sampler.py --out f.mem.jsonl --pid 12345
"""
import argparse
import os
import subprocess
import sys
import time


def read_rss_mb(pid):
    """RSS in MB from /proc/<pid>/status (VmRSS). Returns None if the pid is gone."""
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024.0
    except (FileNotFoundError, ProcessLookupError):
        return None
    return 0.0


def read_epoch(epoch_file):
    if not epoch_file:
        return -1
    try:
        with open(epoch_file) as f:
            return int(f.read().strip() or "-1")
    except (FileNotFoundError, ValueError):
        return -1


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return os.path.exists(f"/proc/{pid}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="output .mem.jsonl path")
    ap.add_argument("--epoch-file", default="", help="file holding the current epoch int")
    ap.add_argument("--dt", type=float, default=1.0, help="sample interval seconds")
    ap.add_argument("--pid", type=int, default=0, help="attach to this pid instead of launching")
    ap.add_argument("cmd", nargs=argparse.REMAINDER,
                    help="-- <command ...> to launch and sample")
    args = ap.parse_args()

    proc = None
    if args.pid:
        pid = args.pid
    else:
        cmd = args.cmd
        if cmd and cmd[0] == "--":
            cmd = cmd[1:]
        if not cmd:
            ap.error("provide --pid or -- <command ...>")
        proc = subprocess.Popen(cmd)
        pid = proc.pid

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    t0 = time.monotonic()
    with open(args.out, "w") as out:
        while True:
            rss = read_rss_mb(pid)
            running = (proc.poll() is None) if proc else alive(pid)
            if rss is None and not running:
                break
            t = time.monotonic() - t0
            out.write('{"t_sec":%.3f,"epoch":%d,"rss_mb":%.3f}\n'
                      % (t, read_epoch(args.epoch_file), rss if rss else 0.0))
            out.flush()
            if not running:
                break
            time.sleep(args.dt)

    rc = proc.wait() if proc else 0
    sys.exit(rc)


if __name__ == "__main__":
    main()
