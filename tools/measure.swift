#!/usr/bin/env swift
// measure.swift — 进程 CPU% / RSS / 物理 footprint 采样器（替代原 measure.py / measure_state.py / power_ab.py）。
//
// 三种用法：
//   measure <秒数> <pid|pattern> [pid|pattern ...]   采样给定进程（measure.py）
//   measure --launch <秒数> <二进制路径>             启动 App、测 N 秒主进程 CPU 时间 + footprint（measure_state.py）
//   measure --power <轮数> <秒数> <bin1> <bin2>      两状态 A/B，输出每分钟 core-s（power_ab.py）
//
// 编译：swiftc -O -target arm64-apple-macosx13.0 tools/measure.swift -o /tmp/measure
//
// 两个踩过的坑（都已在代码里规避）：
//   1. ri_user_time / ri_system_time 的单位是 Mach tick（Apple Silicon 上 1 tick = 41.6667 ns），
//      不是纳秒；早期脚本按 1e9 除，把 CPU 时间低估了 41.67 倍。这里用 mach_timebase_info 换算。
//   2. proc_pid_rusage flavor 4 的缓冲区必须是**完整**的 struct rusage_info_v4——在这个 SDK 上
//      它是 296 字节（含 ri_llus_sc 等新字段）。自己缩水一个 96 字节的“够用版”会让内核多写
//      200 字节，直接踩爆栈金丝雀（__stack_chk_fail）。所以这里直接用 Darwin 的原生结构体。
import Foundation
import Darwin

private func nsPerTick() -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info.denom != 0 ? Double(info.numer) / Double(info.denom) : 1.0
}
private let TICK_NS = nsPerTick()

/// proc_pid_rusage flavor 4 (RUSAGE_INFO_V4)。缓冲区用 Darwin 原生结构体，尺寸由编译器保证。
private func rusage(_ pid: Int32) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        let raw = UnsafeMutableRawPointer(ptr)
        return proc_pid_rusage(pid, 4, raw.assumingMemoryBound(to: UnsafeMutableRawPointer?.self))
    }
    return kr == 0 ? info : nil
}

private func cpuSeconds(_ pid: Int32) -> Double? {
    guard let r = rusage(pid) else { return nil }
    return (Double(r.ri_user_time) + Double(r.ri_system_time)) * TICK_NS / 1e9
}

private func footprintMiB(_ pid: Int32) -> Double? {
    guard let r = rusage(pid) else { return nil }
    return Double(r.ri_phys_footprint) / 1048576.0
}

private func resolve(_ token: String) -> [(String, Int32)] {
    if token.allSatisfy({ $0.isNumber }), let pid = Int32(token) { return [(token, pid)] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", token]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let pids = out.split(separator: "\n").compactMap { Int32($0) }
    return pids.enumerated().map { ("\(token)#\($0.offset)", $0.element) }
}

// ---- 模式 1：采样给定进程的 CPU% / RSS / footprint ----
private func sample(_ secs: Double, _ tokens: [String]) {
    var targets: [(String, Int32)] = []
    for t in tokens { targets += resolve(t) }
    if targets.isEmpty { print("没有匹配到进程"); return }
    var a: [String: rusage_info_v4?] = [:]
    for (n, pid) in targets { a[n] = rusage(pid) }
    Thread.sleep(forTimeInterval: secs)
    for (n, pid) in targets {
        guard let x = a[n] ?? nil, let y = rusage(pid) else {
            print(String(format: "%-28@ pid=%-8d 已退出", n as NSString, pid)); continue
        }
        let cpu = (Double(y.ri_user_time + y.ri_system_time) - Double(x.ri_user_time + x.ri_system_time))
                   * TICK_NS / 1e9 / secs * 100
        print(String(format: "%-28@ pid=%-8d CPU %6.3f%%   RSS %7.1f MiB   物理内存 %7.1f MiB",
                     n as NSString, pid, cpu,
                     Double(y.ri_resident_size) / 1048576.0, Double(y.ri_phys_footprint) / 1048576.0))
    }
}

// ---- 模式 2：启动一个二进制，测 N 秒主进程 CPU 时间 + footprint ----
private func launchAndMeasure(_ secs: Double, _ binary: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { print("启动失败：\(error)"); return }
    Thread.sleep(forTimeInterval: 6)   // 等它起稳
    guard let a = cpuSeconds(p.processIdentifier) else { print("采样失败"); p.terminate(); return }
    Thread.sleep(forTimeInterval: secs)
    guard let b = cpuSeconds(p.processIdentifier) else { print("采样失败"); p.terminate(); return }
    let delta = b - a
    print(String(format: "主进程           CPU 时间 %.4f s / %.0f s   占用率 %.3f%%",
                 delta, secs, delta / secs * 100))
    print(String(format: "CORE_SECONDS=%.6f", delta))
    if let fp = footprintMiB(p.processIdentifier) { print(String(format: "物理内存 footprint %.1f MiB", fp)) }
    p.terminate()
    Thread.sleep(forTimeInterval: 0.5)
    kill(p.processIdentifier, SIGKILL)
}

// ---- 模式 3：两状态功耗 A/B ----
private func runOnce(_ binary: String, _ secs: Double) -> Double {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    Thread.sleep(forTimeInterval: 6)
    let a = cpuSeconds(p.processIdentifier)
    Thread.sleep(forTimeInterval: secs)
    let b = cpuSeconds(p.processIdentifier)
    let total = (a != nil && b != nil) ? (b! - a!) : 0
    p.terminate()
    Thread.sleep(forTimeInterval: 1)
    kill(p.processIdentifier, SIGKILL)
    return total
}

private func powerAB(_ reps: Int, _ secs: Double, _ bins: [String]) {
    for binary in bins {
        print("\n=== \(binary) ===")
        var vals: [Double] = []
        for i in 0..<reps {
            let t = runOnce(binary, secs)
            vals.append(t)
            print(String(format: "  第 %d 轮: %.0fs 内 CPU 时间 %.4f s (= 每分钟 %.4f core-s)",
                         i + 1, secs, t, t / secs * 60))
        }
        let avg = vals.reduce(0, +) / Double(vals.count)
        print(String(format: "  平均: 每分钟 %.4f core-seconds", avg / secs * 60))
    }
}

// ---- 入口 ----
let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    print("用法：")
    print("  measure <秒数> <pid|pattern> [...]      采样给定进程")
    print("  measure --launch <秒数> <二进制>        启动并测主进程 CPU + footprint")
    print("  measure --power <轮数> <秒数> <bin...>  两状态 A/B")
    exit(0)
}
switch args[0] {
case "--launch":
    if args.count >= 3, let s = Double(args[1]) { launchAndMeasure(s, args[2]) }
case "--power":
    let reps = args.count > 1 ? Int(args[1]) ?? 2 : 2
    let secs = args.count > 2 ? Double(args[2]) ?? 120 : 120
    powerAB(reps, secs, Array(args.dropFirst(3)))
default:
    if let s = Double(args[0]) { sample(s, Array(args.dropFirst())) }
}
exit(0)
