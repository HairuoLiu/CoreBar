#!/usr/bin/env python3
"""测量 MacMonBar 在两种状态下的 CPU 时间。

用法: measure_state.py <二进制路径> <秒数>
会启动目标二进制、测量其主进程 + macmon pipe 子进程的 CPU 时间，然后按 pid 精确终止
（不用 pkill -f，避免模式匹配到脚本自身命令行导致自杀）。
"""
import ctypes
import os
import signal
import subprocess
import sys
import time

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)


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


def rusage(pid):
    r = RUsageV4()
    if libproc.proc_pid_rusage(pid, 4, ctypes.byref(r)) != 0:
        return None
    return ((r.utime + r.stime) / 1e9, r.pf / (1024 * 1024))


def cpu_seconds(pid):
    v = rusage(pid)
    return None if v is None else v[0]


def child_pipe(main_pid):
    """找到主进程派生的 macmon pipe 子进程"""
    out = subprocess.run(["pgrep", "-P", str(main_pid)], capture_output=True, text=True).stdout.split()
    for pid in out:
        try:
            cmd = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        except Exception:
            continue
        if "macmon" in cmd:
            return int(pid)
    return int(out[0]) if out else None


def main():
    binary = sys.argv[1]
    secs = float(sys.argv[2])

    proc = subprocess.Popen([binary], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(6)
    kid = child_pipe(proc.pid)

    targets = [("主进程", proc.pid)]
    if kid:
        targets.append(("macmon pipe 子进程", kid))

    a = {n: cpu_seconds(p) for n, p in targets}
    time.sleep(secs)
    b = {n: cpu_seconds(p) for n, p in targets}

    total = 0.0
    for n, p in targets:
        x, y = a.get(n), b.get(n)
        if x is None or y is None:
            print(f"{n:24s} 采样失败")
            continue
        delta = y - x
        total += delta
        print(f"{n:24s} CPU 时间 {delta:.4f} s / {secs:.0f} s   占用率 {delta / secs * 100:.3f}%")

    print(f"{'合计':24s} CPU 时间 {total:.4f} s   平均占用 {total / secs * 100:.3f}% 个核心")
    print(f"CORE_SECONDS={total:.6f}")

    for n, p in targets:
        v = rusage(p)
        if v:
            print(f"{n:24s} 物理内存 footprint {v[1]:.1f} MiB")

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


if __name__ == "__main__":
    main()
