import Foundation
import Darwin

// 验证 Mach 全核采样器的准确性：造 N 个满载线程，看测得值是否接近 N/总核数

func readTicks() -> (used: UInt64, total: UInt64, cores: Int)? {
    var cpuInfo: processor_info_array_t?
    var numCPUInfo: mach_msg_type_number_t = 0
    var numCPUs: natural_t = 0
    let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
    guard kr == KERN_SUCCESS, let info = cpuInfo else { return nil }
    defer {
        let bytes = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
    }
    var used: UInt64 = 0
    var total: UInt64 = 0
    let stride = Int(CPU_STATE_MAX)
    for i in 0..<Int(numCPUs) {
        let b = i * stride
        let u = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]))
        let s = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
        let n = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        let idle = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
        used += u + s + n
        total += u + s + n + idle
    }
    return (used, total, Int(numCPUs))
}

func measure(seconds: Double) -> (Double, Int) {
    guard let a = readTicks() else { return (0, 0) }
    Thread.sleep(forTimeInterval: seconds)
    guard let b = readTicks() else { return (0, 0) }
    let du = b.used - a.used
    let dt = b.total - a.total
    return (dt > 0 ? Double(du) / Double(dt) : 0, b.cores)
}

var stop = false
func burn(_ n: Int) -> [Thread] {
    (0..<n).map { _ in
        Thread { while !stop { _ = Int.random(in: 0...1_000_000) % 7 } }
    }
}

let idle = measure(seconds: 3)
print(String(format: "空闲:      %5.1f%%  (核数 %d)", idle.0 * 100, idle.1))

for n in [4, 6, 12] {
    stop = false
    let ts = burn(n)
    ts.forEach { $0.stackSize = 1 << 19; $0.start() }
    Thread.sleep(forTimeInterval: 0.5)
    let r = measure(seconds: 4)
    stop = true
    ts.forEach { _ in }
    print(String(format: "满载 %2d 线程: %5.1f%%  理论值 %.1f%%", n, r.0 * 100, Double(n) / Double(r.1) * 100))
    Thread.sleep(forTimeInterval: 2)
}
print("完成")
