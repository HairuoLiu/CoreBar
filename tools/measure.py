#!/usr/bin/env python3
"""按 pid 采样 CPU% 与物理内存(footprint)，用于对比不同 UI 形态的开销。

用法: measure.py <秒数> <pid|pattern> [pid|pattern ...]
"""
import ctypes
import subprocess
import sys
import time

# --- Mach 时间基准 ---------------------------------------------------------
# ri_user_time / ri_system_time 的单位是 Mach tick，不是纳秒。
# Apple Silicon 上 numer/denom = 125/3，即 1 tick = 41.6667 ns；
# 直接 /1e9 会把 CPU 时间低估 41.67 倍。
class _MachTB(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
_tb = _MachTB()
ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(_tb))
NS_PER_TICK = _tb.numer / _tb.denom if _tb.denom else 1.0


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
        ("phys_footprint", ctypes.c_uint64),
        ("start", ctypes.c_uint64),
        ("exit", ctypes.c_uint64),
    ]


def resolve(token):
    if token.isdigit():
        return [(token, int(token))]
    out = subprocess.run(["pgrep", "-f", token], capture_output=True, text=True).stdout.split()
    return [(token + f"#{i}", int(p)) for i, p in enumerate(out)]


def snap(pid):
    r = RUsageV4()
    if libproc.proc_pid_rusage(pid, 4, ctypes.byref(r)) != 0:
        return None
    return (r.utime + r.stime, r.rss, r.phys_footprint)


def main():
    secs = float(sys.argv[1])
    targets = []
    for tok in sys.argv[2:]:
        targets += resolve(tok)
    if not targets:
        print("没有匹配到进程")
        return
    a = {name: snap(pid) for name, pid in targets}
    time.sleep(secs)
    b = {name: snap(pid) for name, pid in targets}
    for name, pid in targets:
        x, y = a[name], b[name]
        if x is None or y is None:
            print(f"{name:28s} pid={pid:<8d} 已退出")
            continue
        cpu = (y[0] - x[0]) * NS_PER_TICK / 1e9 / secs * 100
        print(f"{name:28s} pid={pid:<8d} CPU {cpu:6.3f}%   RSS {y[1]/1048576:7.1f} MiB   物理内存 {y[2]/1048576:7.1f} MiB")


if __name__ == "__main__":
    main()
