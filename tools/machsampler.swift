import Foundation
import Darwin

// 纯 Mach `host_processor_info` 采样器：每秒采一次，持续指定秒数
// 用来和 macmon（IOReport / CLPC / SMC）做内存与 CPU 的横向对比

func readPerCore() -> [[UInt64]]? {
    var cpuInfo: processor_info_array_t?
    var n1: mach_msg_type_number_t = 0
    var nCPU: natural_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &nCPU, &cpuInfo, &n1) == KERN_SUCCESS,
          let info = cpuInfo else { return nil }
    defer {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                      vm_size_t(n1) * vm_size_t(MemoryLayout<integer_t>.size))
    }
    let st = Int(CPU_STATE_MAX)
    return (0..<Int(nCPU)).map { i in
        let b = i * st
        return [UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)])),
                UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)])),
                UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])),
                UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))]
    }
}

let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 15 : 15
var prev = readPerCore()
let end = Date().addingTimeInterval(secs)
while Date() < end {
    Thread.sleep(forTimeInterval: 1.0)
    let cur = readPerCore()
    if let p = prev, let c = cur, p.count == c.count {
        let used = zip(p, c).reduce(UInt64(0)) { $0 + (($1.1[0] + $1.1[1] + $1.1[2]) - ($1.0[0] + $1.0[1] + $1.0[2])) }
        let total = zip(p, c).reduce(UInt64(0)) { $0 + (($1.1[0] + $1.1[1] + $1.1[2] + $1.1[3]) - ($1.0[0] + $1.0[1] + $1.0[2] + $1.0[3])) }
        _ = total > 0 ? Double(used) / Double(total) : 0
    }
    prev = cur
}
print("machsampler done")
