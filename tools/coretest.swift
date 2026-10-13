import Foundation
import Darwin

// 逐核（全部 12 核）占用率采样，用于和 mactop 的 core_usages 交叉验证

func readPerCore() -> [[UInt64]]? {
    var cpuInfo: processor_info_array_t?
    var numCPUInfo: mach_msg_type_number_t = 0
    var numCPUs: natural_t = 0
    let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
    guard kr == KERN_SUCCESS, let info = cpuInfo else { return nil }
    defer {
        let bytes = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
    }
    let stride = Int(CPU_STATE_MAX)
    var out: [[UInt64]] = []
    for i in 0..<Int(numCPUs) {
        let b = i * stride
        let u = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]))
        let s = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
        let n = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        let idle = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
        out.append([u, s, n, idle])
    }
    return out
}

func sample(seconds: Double) -> [Double] {
    guard let a = readPerCore() else { return [] }
    Thread.sleep(forTimeInterval: seconds)
    guard let b = readPerCore(), b.count == a.count else { return [] }
    return zip(a, b).map { x, y in
        let used = (y[0] + y[1] + y[2]) - (x[0] + x[1] + x[2])
        let total = (y[0] + y[1] + y[2] + y[3]) - (x[0] + x[1] + x[2] + x[3])
        return total > 0 ? Double(used) / Double(total) : 0
    }
}

let idle = sample(seconds: 2)   // 预热
let r = sample(seconds: 3)
print("核心数: \(r.count)")
for (i, v) in r.enumerated() {
    let bar = String(repeating: "█", count: Int(round(v * 30)))
    print(String(format: "  core %2d  %5.1f%%  %@", i, v * 100, bar))
}
let total = r.reduce(0, +) / Double(max(r.count, 1))
print(String(format: "全核平均: %.1f%%", total * 100))
