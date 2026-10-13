#!/usr/bin/env python3
"""MacMonBar 两状态功耗 A/B 复测脚本。

状态 1：菜单栏常驻，菜单不展开
状态 2：菜单展开，4 张趋势图 + 12 核心条每秒实时重绘

用法: power_ab.py [轮数] [每轮秒数]
"""
import ctypes
import os
import signal
import subprocess
import sys
import time

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)

APP = "/Users/hai/Applications/MacMonBar.app/Contents/MacOS/MacMonBar"
OPEN = "/tmp/MacMonBarOpen2"


class RUsageV4(ctypes.Structure):
    _fields_ = [
        ("uuid", ctypes.c_uint8 * 16),
        ("utime", ctypes.c_uint64),
        ("stime", ctypes.c_uint64),
        ("idle_wkups", ctypes.c_uint64),
        ("intr_wkups", ctypes.c_uint64),
        ("pageins", ctypes.c_uint64),
        ("wired", ctypes.c_uint64),
        ("rss", ctypes.c_uint64),
        ("pf", ctypes.c_uint64),
        ("start", ctypes.c_uint64),
        ("exit", ctypes.c_uint64),
    ]


def cpu_seconds(pid):
    r = RUsageV4()
    if libproc.proc_pid_rusage(pid, 4, ctypes.byref(r)) != 0:
        return None
    return (r.utime + r.stime) / 1e9


def child_pipe(main_pid):
    """主进程只派生一个 `macmon pipe` 子进程，直接取第一个子 pid。
    不调用 ps/ pkill：ps 在部分沙箱环境下被禁止，pkill -f 会误杀自身。"""
    out = subprocess.run(["pgrep", "-P", str(main_pid)],
                         capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def run_once(binary, secs):
    proc = subprocess.Popen([binary], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(6)
    kid = child_pipe(proc.pid)
    targets = [("main", proc.pid)]
    if kid:
        targets.append(("pipe", kid))
    a = {n: cpu_seconds(p) for n, p in targets}
    time.sleep(secs)
    b = {n: cpu_seconds(p) for n, p in targets}
    total = 0.0
    for n, p in targets:
        x, y = a.get(n), b.get(n)
        if x is None or y is None:
            continue
        total += y - x
    for _, p in targets:
        try:
            os.kill(p, signal.SIGTERM)
        except Exception:
            pass
    try:
        os.kill(proc.pid, signal.SIGTERM)
    except Exception:
        pass
    time.sleep(1.0)
    for _, p in targets:
        try:
            os.kill(p, signal.SIGKILL)
        except Exception:
            pass
    try:
        os.kill(proc.pid, signal.SIGKILL)
    except Exception:
        pass
    return total


def main():
    reps = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 120

    for name, binary in [("状态1 菜单栏常驻/菜单关闭", APP),
                         ("状态2 菜单展开/每秒重绘", OPEN)]:
        print(f"\n=== {name} ===", flush=True)
        vals = []
        for i in range(reps):
            t = run_once(binary, secs)
            vals.append(t)
            print(f"  第 {i + 1} 轮: {secs:.0f}s 内 CPU 时间 {t:.4f} s "
                  f"(= 每分钟 {t / secs * 60:.4f} core-s)", flush=True)
        avg = sum(vals) / len(vals)
        print(f"  平均: 每分钟 {avg / secs * 60:.4f} core-seconds", flush=True)


if __name__ == "__main__":
    main()
