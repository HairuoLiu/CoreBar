import AppKit
import Foundation
import Darwin

// MARK: - 原生 C 传感器桥接（见 src/sensors.c / src/sensors.h）
//
// 替代 macmon 子进程：GPU 占用走 libIOReport，温度走 IOHID/AppleSMC，
// 都用 @_silgen_name 直接调 C，不经过任何子进程或 JSON 解析。
// 第一次调用 gpu_scaled_ratio 是 prime（返回 0），之后每次取真实值。
@_silgen_name("macmonbar_sensors_init")      func c_sensors_init() -> Int32
@_silgen_name("macmonbar_sensors_close")     func c_sensors_close()
@_silgen_name("macmonbar_gpu_scaled_ratio")  func c_gpu_ratio() -> Double
@_silgen_name("macmonbar_cpu_temp_c")        func c_cpu_temp() -> Double
@_silgen_name("macmonbar_gpu_temp_c")        func c_gpu_temp() -> Double

// MacMonBar — 菜单栏版 macmon
//
// 状态栏：CPU / GPU / RAM 百分比 + 温度（默认关闭）；标签固定英文，菜单与面板按系统中英双语（见 Loc）
// 面板：四项趋势图 2 × 2，底部逐核柱状图（可关）
// 配色两套互不重叠（见下方 MARK）：图表用身份色（蓝 / 玫红 / 青 / 紫），数值用绿 / 琥珀 / 红梯度
// 数据来源：CPU / 逐核 / 内存由本 App 用 Mach 本机采样；GPU 占用与温度由 src/sensors.c
//          （原生 C，桥接 libIOReport + IOHID/AppleSMC）直接提供。零子进程、零 Python。
// 细节（默认开关、阈值、实测宽度）见 README 与 docs/

// MARK: - 基础工具

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

private let kPad: CGFloat = 14          // 面板左右内边距，避免顶到边框
private let kLabelSmall = NSFont.systemFont(ofSize: 11, weight: .medium)   // 面板图表标题
private let kLabelBar = NSFont.systemFont(ofSize: 13, weight: .semibold)   // 状态栏标签：与系统菜单栏同字号（13pt），semibold 提分量
private let kValue = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
private let kRowTitle = NSFont.menuFont(ofSize: 0)   // 与原生菜单项同一号字，混排时不会一大一小

private func isDark(_ v: NSView) -> Bool {
    v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

// MARK: - 配色：两套互不重叠的色系
//
// ① 身份色 —— 只归图表用（趋势线、左上角标签、状态栏进度条）：
//    CPU 蓝 / GPU 玫红 / 内存青 / 温度紫。四种色相刻意避开绿、琥珀、红。
// ② 数值色 —— 只归右侧的百分比与温度值用：
//    绿（正常）/ 琥珀（偏高）/ 红（告警），按各自阈值变化。
// 两套色永不混用：图表不会和穿同色的数值撞上。看一眼右边就知道谁忙，
// 看一眼线的颜色就知道是谁。

private func cpuSeriesColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0x6BA4FF) : NSColor(hex: 0x1E6FD9) }
private func gpuSeriesColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0xE88AC8) : NSColor(hex: 0xB0449B) }
private func memSeriesColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0x45C4D8) : NSColor(hex: 0x0E8FA8) }
private func tempSeriesColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0xA888F2) : NSColor(hex: 0x7C59CF) }

private func hotColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0xFF7B6B) : NSColor(hex: 0xC4433A) }
private func warnColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0xFFC24A) : NSColor(hex: 0xB26A00) }
private func okColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0x5DCAA5) : NSColor(hex: 0x1D9E75) }

/// 数值梯度（百分比用）：绿 <50% / 琥珀 ≥50% / 红 ≥80%
private func levelColor(_ v: NSView, _ ratio: Double) -> NSColor {
    if ratio >= 0.80 { return hotColor(v) }
    if ratio >= 0.50 { return warnColor(v) }
    return okColor(v)
}

/// 温度数值：与百分比同一套绿/琥珀/红梯度，阈值按 °C（<60 / ≥60 / ≥80）
private func tempValueColor(_ v: NSView, _ c: Double) -> NSColor {
    if c >= 80 { return hotColor(v) }
    if c >= 60 { return warnColor(v) }
    return okColor(v)
}

private func drawText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
    let ps = NSMutableParagraphStyle()
    ps.alignment = align
    let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: ps]
    let size = (s as NSString).size(withAttributes: attr)
    // 预留位可能窄于实际文本（例如 "100%" 37.4pt 放进 34pt 的槽）：把绘制矩形至少放宽到文本
    // 实际宽度，并按对齐方式重新锚定，否则 NSString 会把最后一个字符折到第二行、再被单行高度裁掉。
    let w = max(rect.width, size.width + 1)
    let x: CGFloat
    switch align {
    case .right:  x = rect.maxX - w
    case .center: x = rect.midX - w / 2
    default:      x = rect.minX
    }
    let y = rect.midY - size.height / 2
    (s as NSString).draw(in: NSRect(x: x, y: y, width: w, height: size.height), withAttributes: attr)
}

// MARK: - 中英双语
// 按系统首选语言取串：zh-* → 中文，其余 → 英文。
// 做成 var 而不是 computed property，是为了离屏渲染验证时能强制切语言。
// 语言在启动时解析一次；改系统语言后需重启 App 才生效。
// 状态栏的 CPU / GPU / RAM 标签按需求固定英文，不走这里。
private enum Loc {
    static var isChinese = (Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

// MARK: - 全核 CPU 采样（Mach）

struct CPUCoreSampler {
    private var prevUsed: UInt64 = 0
    private var prevTotal: UInt64 = 0
    private var prevCore: [[UInt64]] = []
    var hasBaseline = false

    private func readTicks() -> (used: UInt64, total: UInt64, cores: [[UInt64]])? {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUs, &cpuInfo, &numCPUInfo)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            let bytes = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
        }
        var used: UInt64 = 0
        var total: UInt64 = 0
        var cores: [[UInt64]] = []
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(numCPUs) {
            let b = i * stride
            let u = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]))
            let s = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
            let n = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
            used += u + s + n
            total += u + s + n + idle
            cores.append([u, s, n, idle])
        }
        return (used, total, cores)
    }

    mutating func sample() -> (overall: Double?, perCore: [Double]) {
        guard let t = readTicks() else { return (nil, []) }
        var perCore: [Double] = []
        if hasBaseline, prevCore.count == t.cores.count {
            perCore = zip(prevCore, t.cores).map { a, b in
                let du = (b[0] + b[1] + b[2]) - (a[0] + a[1] + a[2])
                let dt = (b[0] + b[1] + b[2] + b[3]) - (a[0] + a[1] + a[2] + a[3])
                return dt > 0 ? Double(du) / Double(dt) : 0
            }
        }
        let dUsed = t.used >= prevUsed ? t.used - prevUsed : 0
        let dTotal = t.total >= prevTotal ? t.total - prevTotal : 0
        defer {
            prevUsed = t.used
            prevTotal = t.total
            prevCore = t.cores
        }
        guard hasBaseline else {
            hasBaseline = true
            return (nil, [])
        }
        guard dTotal > 0 else { return (nil, perCore) }
        return (Double(dUsed) / Double(dTotal), perCore)
    }

    mutating func reset() {
        if let t = readTicks() {
            prevUsed = t.used
            prevTotal = t.total
            prevCore = t.cores
            hasBaseline = true
        }
    }
}

// MARK: - 内存采样（Mach，本机）

/// 内存占用率：一次 host_statistics64，无需子进程。
///
/// 口径与 macmon 完全一致（已按其源码核对，实测差 7 页 ≈ 0.1 MB）：
///   used = active + inactive + wire + speculative + compressor − purgeable − external
/// 注意 external / purgeable 是 active / inactive 的子集，所以要减掉，
/// 否则会把"文件缓存占的可回收页"算成已用。
struct MemorySampler {
    private static let totalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    private static let pageSize: UInt64 = UInt64(sysconf(_SC_PAGESIZE))

    func sample() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, Self.totalBytes > 0 else { return nil }

        let a = Int64(stats.active_count)
        let i = Int64(stats.inactive_count)
        let w = Int64(stats.wire_count)
        let s = Int64(stats.speculative_count)
        let c = Int64(stats.compressor_page_count)
        let pu = Int64(stats.purgeable_count)
        let ex = Int64(stats.external_page_count)
        let pages = max(a + i + w + s + c - pu - ex, 0)

        let used = UInt64(pages) * Self.pageSize
        return min(max(Double(used) / Double(Self.totalBytes), 0), 1)
    }
}

// MARK: - 状态栏：CPU / GPU / RAM 三条 + 温度

final class MeterView: NSView {
    var cpu: Double = 0
    var gpu: Double = 0
    var mem: Double = 0
    var temp: Double = 0
    var showTemp = false                 // 默认关闭
    var showBars = false                 // 默认隐藏状态栏进度条（菜单可开启）
    var colorPct = true                  // 百分比按占用率着色，默认开启（菜单可关闭）
    var sensorsAvailable = true           // false 时 GPU / 温度显示"—"（原生传感器未初始化时）

    private enum L {
        static let pad: CGFloat = 3       // 状态项左右内边距
        static let label: CGFloat = 32    // 容纳 13pt semibold 的 "RAM"（29.5）+ 居中余量
        static let pair: CGFloat = 2      // 标签与数值之间的间隙
        static let bar: CGFloat = 24
        // 数值左对齐、紧贴标签，右侧的余量留给分组间隔，所以槽位按常用最大值定尺：
        static let value: CGFloat = 34    // "99%" = 29.1；罕见的 "100%"（37.4）向右溢出 3.4pt，仍不碰到分隔线
        static let temp: CGFloat = 38     // 右对齐贴边；"99°C" = 32.1，"100°C"（40.4）向左溢出 2.4pt 由 gap 吸收
        static let gap: CGFloat = 10      // 指标之间的间隔（含分隔线）
        static let sepH: CGFloat = 14     // 分隔线高度
    }

    private var unit: CGFloat {
        let barPart = showBars ? (L.bar + 3) : 0
        return L.label + L.pair + barPart + L.value
    }

    var preferredWidth: CGFloat {
        let gaps = showTemp ? 3 : 2
        return L.pad + unit * 3 + L.gap * CGFloat(gaps) + (showTemp ? L.temp : 0) + L.pad
    }

    /// 指标之间画一条细竖线分隔，并返回下一个指标起点
    private func advanceAfter(_ x: CGFloat) -> CGFloat {
        let nx = x + L.gap
        let dx = x + L.gap / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: dx, y: (bounds.height - L.sepH) / 2))
        path.line(to: NSPoint(x: dx, y: (bounds.height + L.sepH) / 2))
        path.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        path.stroke()
        return nx
    }

    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = L.pad
        x = metric(name: "CPU", ratio: cpu, available: true, series: cpuSeriesColor(self), x: x)
        x = advanceAfter(x)
        x = metric(name: "GPU", ratio: gpu, available: sensorsAvailable, series: gpuSeriesColor(self), x: x)
        x = advanceAfter(x)
        x = metric(name: "RAM", ratio: mem, available: true, series: memSeriesColor(self), x: x)  // 状态栏标签固定英文；内存为本机采样，不依赖 macmon
        if showTemp {
            x = advanceAfter(x)
            let r = NSRect(x: x, y: 0, width: L.temp, height: bounds.height)
            if sensorsAvailable {
                drawText(String(format: "%.0f°C", temp), in: r, font: kValue, color: tempValueColor(self, temp), align: .right)
            } else {
                drawText("—", in: r, font: kValue, color: .tertiaryLabelColor, align: .right)
            }
        }
    }

    /// available = false 表示数据源缺失，显示"—"而不是误导性的 0%
    private func metric(name: String, ratio: Double, available: Bool, series: NSColor, x: CGFloat) -> CGFloat {
        // 数值左对齐紧贴标签：把余量全部推到组间，组内不再留死空白
        // （原先右对齐时，"5%" 这类短值左侧会空出 17pt）
        drawText(name, in: NSRect(x: x, y: 0, width: L.label, height: bounds.height),
                 font: kLabelBar, color: .secondaryLabelColor, align: .center)
        var cx = x + L.label + L.pair

        if showBars {
            let barRect = NSRect(x: cx, y: bounds.midY - 3.5, width: L.bar, height: 7)
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 3.5, yRadius: 3.5).fill()
            if available {
                let pct = min(max(ratio, 0), 1)
                if pct > 0.01 {
                    var f = barRect
                    f.size.width = max(4, L.bar * CGFloat(pct))
                    (pct >= 0.80 ? hotColor(self) : series).setFill()
                    NSBezierPath(roundedRect: f, xRadius: 3.5, yRadius: 3.5).fill()
                }
            }
            cx += L.bar + 3
        }

        let valueRect = NSRect(x: cx, y: 0, width: L.value, height: bounds.height)
        if available {
            let pct = min(max(ratio, 0), 1)
            let color = colorPct ? levelColor(self, pct) : NSColor.labelColor
            drawText(String(format: "%.0f%%", pct * 100), in: valueRect,
                     font: kValue, color: color, align: .left)
        } else {
            drawText("—", in: valueRect, font: kValue, color: .tertiaryLabelColor, align: .left)
        }
        return cx + L.value
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - 面板：2 行 × 2 列趋势图 + 逐核柱状图

final class PanelView: NSView {
    var cpu: Double = 0
    var gpu: Double = 0
    var mem: Double = 0
    var temp: Double = 0
    var cpuHist: [Double] = []
    var gpuHist: [Double] = []
    var memHist: [Double] = []
    var tempHist: [Double] = []
    var cores: [Double] = []
    var showCores = true                 // 默认打开
    var sensorsAvailable = true           // false 时 GPU / 温度显示"—"（原生传感器未初始化时）
    let capacity = 120

    private enum L {
        static let cellH: CGFloat = 44    // 标题 15 + 图 29
        static let colGap: CGFloat = 12
        static let rowGap: CGFloat = 8
        static let coreH: CGFloat = 26
        static let coreGap: CGFloat = 10
    }

    var preferredHeight: CGFloat {
        var h = L.cellH * 2 + L.rowGap
        if showCores && !cores.isEmpty { h += L.coreGap + L.coreH }
        return h
    }

    private var contentRect: NSRect {
        NSRect(x: kPad, y: 0, width: max(0, bounds.width - kPad * 2), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = contentRect
        let cellW = (c.width - L.colGap) / 2
        let coreBlock: CGFloat = (showCores && !cores.isEmpty) ? (L.coreGap + L.coreH) : 0
        let row1Y = coreBlock
        let row0Y = coreBlock + L.cellH + L.rowGap

        trend(name: "CPU", data: cpuHist, series: cpuSeriesColor(self), current: cpu, unit: "%", ratio: cpu,
              available: true,
              rect: NSRect(x: c.minX, y: row0Y, width: cellW, height: L.cellH))
        trend(name: "GPU", data: gpuHist, series: gpuSeriesColor(self), current: gpu, unit: "%", ratio: gpu,
              available: sensorsAvailable,
              rect: NSRect(x: c.minX + cellW + L.colGap, y: row0Y, width: cellW, height: L.cellH))
        trend(name: Loc.t("内存", "RAM"), data: memHist, series: memSeriesColor(self), current: mem, unit: "%", ratio: mem,
              available: true,
              rect: NSRect(x: c.minX, y: row1Y, width: cellW, height: L.cellH))
        trend(name: Loc.t("温度", "Temperature"), data: tempHist, series: tempSeriesColor(self), current: temp, unit: "°C",
              ratio: (temp - 30) / 70, available: sensorsAvailable,
              rect: NSRect(x: c.minX + cellW + L.colGap, y: row1Y, width: cellW, height: L.cellH))

        if coreBlock > 0 {
            coreRow(rect: NSRect(x: c.minX, y: 0, width: c.width, height: L.coreH))
        }
    }

    /// 标题行（名称 + 当前值）+ 面积图。图按实际样本数铺满整格宽度
    private func trend(name: String, data: [Double], series: NSColor, current: Double,
                       unit: String, ratio: Double, available: Bool, rect: NSRect) {
        let headRect = NSRect(x: rect.minX, y: rect.maxY - 15, width: rect.width, height: 15)
        drawText(name, in: headRect, font: kLabelSmall, color: series)
        let valueText: String
        let valueColor: NSColor
        if available {
            valueText = unit == "%" ? String(format: "%.0f%%", current * 100) : String(format: "%.0f%@", current, unit)
            valueColor = unit == "%" ? levelColor(self, ratio) : tempValueColor(self, current)
        } else {
            valueText = "—"                       // 数据源缺失，不显示会误导的 0
            valueColor = .tertiaryLabelColor
        }
        drawText(valueText, in: headRect, font: kValue, color: valueColor, align: .right)

        let chart = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 16)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: chart, xRadius: 4, yRadius: 4).fill()

        // 50% 参考线只对百分比有意义；温度图是 (t-30)/70 归一化的，midY 不代表任何温度
        if unit == "%" {
            let dash = NSBezierPath()
            dash.move(to: NSPoint(x: chart.minX + 2, y: chart.midY.rounded() + 0.5))
            dash.line(to: NSPoint(x: chart.maxX - 2, y: chart.midY.rounded() + 0.5))
            dash.lineWidth = 1
            dash.setLineDash([2, 2], count: 2, phase: 0)
            NSColor.labelColor.withAlphaComponent(0.14).setStroke()
            dash.stroke()
        }

        guard data.count > 1 else { return }
        let step = (chart.width - 4) / CGFloat(data.count - 1)
        let pts = data.enumerated().map { i, v in
            NSPoint(x: chart.minX + 2 + CGFloat(i) * step,
                    y: chart.minY + 2 + CGFloat(min(max(v, 0), 1)) * (chart.height - 5))
        }

        let area = NSBezierPath()
        area.move(to: NSPoint(x: pts[0].x, y: chart.minY + 1))
        for p in pts { area.line(to: p) }
        area.line(to: NSPoint(x: pts[pts.count - 1].x, y: chart.minY + 1))
        area.close()
        // 29pt 高的小图上，填充太浓会把整格糊住，看不出线条起伏
        series.withAlphaComponent(isDark(self) ? 0.16 : 0.12).setFill()
        area.fill()

        let line = NSBezierPath()
        line.move(to: pts[0])
        for p in pts.dropFirst() { line.line(to: p) }
        line.lineWidth = 1.8
        line.lineJoinStyle = .round
        series.setStroke()
        line.stroke()
        // 末端圆点已删：标题行右侧就写着当前值，圆点只是在小图上重复它
    }

    /// 12 个核的逐核占用率
    private func coreRow(rect: NSRect) {
        let n = cores.count
        guard n > 0 else { return }
        let gap: CGFloat = 2
        let bw = (rect.width - CGFloat(n - 1) * gap) / CGFloat(n)
        for i in 0..<n {
            let x = rect.minX + CGFloat(i) * (bw + gap)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY, width: bw, height: rect.height),
                         xRadius: 1.5, yRadius: 1.5).fill()
            let v = min(max(cores[i], 0), 1)
            let fh = max(2, rect.height * CGFloat(v))
            cpuSeriesColor(self).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY, width: bw, height: fh),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - 菜单行：只画「勾选 + 标题」，不再挂右列说明
//
// 行尾那列开销标注（"+48pt · 内存≈0" 之类）已经去掉：每一项实测都是 0 字节，
// 占着半行宽度却没有信息量。数字没有丢——它们在 docs/performance.md 里，
// 想查代价的人去那儿看，菜单只负责让你开关。
//
// 之所以仍然自绘：原生 NSMenuItem 的行高和缩进不可控，这里要勾选列与面板
// 内边距对齐、标题垂直居中。代价是高亮底色和点击转发要自己接（见下）。
// 行宽不再被说明文字撑开，由标题决定。
final class MenuRowView: NSView {
    static let rowHeight: CGFloat = 22

    private let rowTitle: String
    private weak var item: NSMenuItem?

    private static let checkCol: CGFloat = 20    // 勾选列宽：让标题起点与原生菜单行对齐
    private static let tailPad: CGFloat = 13     // 右端留白，与面板内边距同一档

    init(item: NSMenuItem, title: String) {
        self.rowTitle = title
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.rowHeight))
        self.item = item
        autoresizingMask = [.width]           // 行宽跟着菜单走
    }
    required init?(coder: NSCoder) { fatalError("手写布局，不用 Storyboard") }

    override var intrinsicContentSize: NSSize {
        let w = Self.checkCol + line(rowTitle, font: kRowTitle).size().width + Self.tailPad
        return NSSize(width: w, height: Self.rowHeight)
    }

    override var acceptsFirstResponder: Bool { false }

    /// 上一次画的时候是不是高亮态。用来判断「状态变了没有」，
    /// 避免菜单打开期间无脑重绘（详见 AppDelegate.syncRows）。
    private var lastHot = false

    func syncHighlight() {
        if (item?.isHighlighted ?? false) != lastHot { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let hot = item?.isHighlighted ?? false
        lastHot = hot
        if hot {
            // 原生菜单的高亮色本来就跟着系统强调色走，直接用 controlAccentColor；
            // 旧版的 selectedMenuItemColor 在 macOS 11 已废弃（官方建议挂 NSVisualEffectView，
            // 对一行自绘菜单来说太重）。
            NSColor.controlAccentColor.setFill()
            bounds.fill()
        }

        if item?.state == .on {
            let c = line("✓", font: NSFont.systemFont(ofSize: 11, weight: .semibold), hot: hot)
            c.draw(at: NSPoint(x: 5, y: centerY(c)))
        }

        let t = line(rowTitle, font: kRowTitle, hot: hot)
        t.draw(at: NSPoint(x: Self.checkCol, y: centerY(t)))
    }

    /// 视图接手之后，点击不会自动落到 NSMenuItem 的动作上，得自己转一次。
    override func mouseUp(with event: NSEvent) {
        guard let it = item, let m = it.menu else { return }
        m.performActionForItem(at: m.index(of: it))
        m.cancelTracking()
    }

    private func centerY(_ s: NSAttributedString) -> CGFloat { (bounds.height - s.size().height) / 2 }

    private func line(_ s: String, font: NSFont, hot: Bool = false, muted: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: hot ? NSColor.selectedMenuItemTextColor.withAlphaComponent(muted ? 0.7 : 1)
                                  : (muted ? NSColor.secondaryLabelColor : NSColor.labelColor)
        ])
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let meter = MeterView()
    private let panel = PanelView()
    private var intervalMs = 2000
    private var menu: NSMenu!
    private var panelItem: NSMenuItem!
    private var menuOpen = false
    private var rowSync: Timer?
    private var cpuSampler = CPUCoreSampler()
    private let memSampler = MemorySampler()
    private var cpuLoad: Double = 0
    private var memLoad: Double = 0
    private var lastSignature = ""

    /// 原生传感器是否就绪（C 模块 init 成功）。失败则 GPU / 温度 显示 "—"，
    /// 但 CPU / 逐核 / 内存仍是本机采样，菜单栏照常工作。
    private var sensorsAvailable = false

    /// 统一采样定时器：CPU / 内存 / GPU / 温度 全由它驱动，挂在 RunLoop .common
    /// 上，菜单展开时也照常触发。
    private var samplerTimer: Timer?

    private static let fixedPanelWidth: CGFloat = 300

    func applicationDidFinishLaunching(_: Notification) {
        // 原生 C 传感器：GPU 占用走 libIOReport，温度走 IOHID/AppleSMC。
        // 失败（极少）只影响 GPU / 温度，CPU / 内存 仍由本 App 自己采样。
        sensorsAvailable = (c_sensors_init() == 0)
        meter.sensorsAvailable = sensorsAvailable
        panel.sensorsAvailable = sensorsAvailable

        statusItem.button?.title = ""
        statusItem.button?.image = nil
        statusItem.button?.toolTip = Loc.t("CPU / GPU / 内存 占用率 —— 点击展开趋势图",
                                           "CPU / GPU / RAM usage — click to expand trend charts")
        meter.frame = NSRect(x: 0, y: 0, width: meter.preferredWidth, height: 22)
        meter.autoresizingMask = [.width, .height]
        statusItem.button?.addSubview(meter)
        statusItem.length = meter.preferredWidth
        buildMenu()
        startSampler()
    }

    func applicationWillTerminate(_: Notification) { c_sensors_close() }

    private var contentWidth: CGFloat { Self.fixedPanelWidth - 24 }

    /// 造一个自绘开关行：勾选 + 标题，行尾不再挂开销说明。
    /// 代价数字没有丢——在 docs/performance.md 里，每项实测都是 0 字节，
    /// 钉在行尾只是白占半行宽度。
    private func rowItem(_ title: String, tip: String,
                         action: Selector, on: Bool, tag: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.state = on ? .on : .off
        it.tag = tag
        it.toolTip = tip
        let row = MenuRowView(item: it, title: title)
        // 行宽锁死在面板宽度上：菜单不会被超长标题撑宽，各行也保持同宽。
        row.frame = NSRect(x: 0, y: 0, width: contentWidth, height: MenuRowView.rowHeight)
        it.view = row
        return it
    }

    /// 自绘行接手之后，改 state 不会自动重画，勾记得手动刷。
    private func refreshRow(_ item: NSMenuItem, _ on: Bool) {
        item.state = on ? .on : .off
        (item.view as? MenuRowView)?.needsDisplay = true
    }

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self

        panel.frame = NSRect(x: 0, y: 0, width: contentWidth, height: panel.preferredHeight)
        panelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(NSMenuItem.separator())

        // 核数从内核读，不写死——写死会在 M4 之类的机器上给出错误数字
        let n = ProcessInfo.processInfo.activeProcessorCount
        menu.addItem(rowItem(Loc.t("显示每个核心（\(n) 核）", "Per-core bars (\(n) cores)"),
                             tip: Loc.t("进程内反复开关实测：内存 Δ = 0 字节。开启后只在面板展开时底部多 36pt（coreGap 10 + coreH 26）画一排逐核柱子，面板收起时不占内存。",
                                        "Intra-process ON/OFF cycling: RAM Δ = 0 bytes. On, it only adds 36pt (coreGap 10 + coreH 26) of per-core bars at the panel bottom when expanded; no RAM when the panel is closed."),
                             action: #selector(toggleCores(_:)),
                             on: panel.showCores))

        menu.addItem(rowItem(Loc.t("状态栏显示温度", "Temperature in menu bar"),
                             tip: Loc.t("进程内反复开关实测：内存 footprint Δ = 0 字节，CPU Δ 在 ±0.04 pp 噪声内。变的只是状态栏那一行多 48pt（显示 \"99°C\"），MeterView 是绘制式渲染，不占额外内存。",
                                        "Intra-process ON/OFF cycling: footprint Δ = 0 bytes, CPU Δ within ±0.04 pp noise. The only change is a 48pt-wider menu-bar slot (the \"99°C\" readout); MeterView draws each frame, so no extra RAM."),
                             action: #selector(toggleTemp(_:)),
                             on: meter.showTemp))

        menu.addItem(rowItem(Loc.t("状态栏显示进度条", "Gauges in menu bar"),
                             tip: Loc.t("进程内反复开关实测：内存 Δ = 0 字节。开关只是把状态栏加宽 81pt，每帧多画 6 个圆角矩形（CPU 增量测不出），并无新增缓冲区。",
                                        "Intra-process ON/OFF cycling: RAM Δ = 0 bytes. The toggle only widens the bar by 81pt and draws 6 extra rounded rects per frame (CPU gain unmeasurable); no new buffer."),
                             action: #selector(toggleBars(_:)),
                             on: meter.showBars))

        menu.addItem(rowItem(Loc.t("百分比颜色区分", "Colour-code percentages"),
                             tip: Loc.t("进程内反复开关实测：内存 Δ = 0 字节。开启后每帧多建 3 个 NSColor（CPU/GPU/RAM 各一），瞬时分配、随即释放，稳态内存不涨。",
                                        "Intra-process ON/OFF cycling: RAM Δ = 0 bytes. On, it builds 3 extra NSColors per frame (CPU/GPU/RAM), transient allocations, no steady RAM growth."),
                             action: #selector(toggleColor(_:)),
                             on: meter.colorPct))

        let intervalItem = NSMenuItem(title: Loc.t("刷新间隔", "Refresh interval"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for ms in [1000, 2000, 5000] {
            sub.addItem(rowItem(Loc.t("\(ms / 1000) 秒", "\(ms / 1000) s"),
                                tip: Loc.t("刷新快慢不改变内存：缓冲区大小固定，变的只是每秒采样几次（影响的是 CPU，约 ±0.1%）。",
                                           "Refresh rate does not change memory: buffers are fixed size; only the sampling rate changes (that moves CPU, roughly ±0.1%)."),
                                action: #selector(setInterval(_:)),
                                on: ms == intervalMs,
                                tag: ms))
        }
        intervalItem.submenu = sub
        menu.addItem(intervalItem)

        let quitItem = NSMenuItem(title: Loc.t("退出 MacMonBar", "Quit MacMonBar"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleCores(_ sender: NSMenuItem) {
        panel.showCores.toggle()
        refreshRow(sender, panel.showCores)
        panel.setFrameSize(NSSize(width: contentWidth, height: panel.preferredHeight))
        panel.needsDisplay = true
        DispatchQueue.main.async { self.menu.update() }
    }

    @objc private func toggleTemp(_ sender: NSMenuItem) {
        meter.showTemp.toggle()
        refreshRow(sender, meter.showTemp)
        statusItem.length = meter.preferredWidth
        meter.needsDisplay = true
    }

    @objc private func toggleBars(_ sender: NSMenuItem) {
        meter.showBars.toggle()
        refreshRow(sender, meter.showBars)
        statusItem.length = meter.preferredWidth
        meter.needsDisplay = true
    }

    @objc private func toggleColor(_ sender: NSMenuItem) {
        meter.colorPct.toggle()
        refreshRow(sender, meter.colorPct)
        meter.needsDisplay = true
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        intervalMs = sender.tag
        for it in sender.menu?.items ?? [] { refreshRow(it, it.tag == intervalMs) }
        cpuSampler.reset()
        startSampler()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func menuWillOpen(_: NSMenu) {
        menuOpen = true
        refreshPanel()
        startRowSync()
    }

    func menuDidClose(_: NSMenu) {
        menuOpen = false
        rowSync?.invalidate()
        rowSync = nil
    }

    /// 自绘行的底色取决于 isHighlighted，但菜单跟踪期间 AppKit 不保证
    /// 会给这些自定义 view 发重绘。菜单开着时以 30 Hz 探一下有没有变，
    /// **状态没变就不画**，所以真正重绘的只有鼠标划过的那几行。
    /// 菜单一关就停，常驻开销为零。
    private func startRowSync() {
        guard rowSync == nil else { return }
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, let m = self.menu else { return }
            Self.syncRows(m)
        }
        RunLoop.main.add(t, forMode: .common)
        rowSync = t
    }

    private static func syncRows(_ m: NSMenu) {
        for it in m.items {
            (it.view as? MenuRowView)?.syncHighlight()
            if let sub = it.submenu { syncRows(sub) }
        }
    }

    /// 统一采样入口：CPU / 逐核 / 内存（本机 Mach）+ GPU 占用 / 温度（原生 C 传感器）。
    /// 全部由一个挂在 RunLoop .common 上的 Timer 驱动，菜单展开（eventTracking）时也照常触发。
    private func startSampler() {
        samplerTimer?.invalidate()
        samplerTimer = nil
        // sensorsAvailable 在 applicationDidFinishLaunching 里由 c_sensors_init() 决定：
        // 成功则 GPU / 温度 来自原生 C 传感器；失败则这两项显示 "—"，
        // 但 CPU / 内存 仍是本机采样，菜单栏照常工作。
        let t = Timer(timeInterval: Double(intervalMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        samplerTimer = t
        tick()   // 立即画一帧，避免首屏空等一个完整间隔
    }

    /// 一次完整采样：本机 CPU / 内存，加上（若传感器就绪）C 模块的 GPU 占用与温度，
    /// 更新状态栏、面板与历史曲线。
    private func tick() {
        sampleLocal()   // CPU + 逐核 + 内存（本机 Mach）

        if sensorsAvailable {
            let gpu = c_gpu_ratio()      // 首次调用是 prime，返回 0，之后为真实占用
            let ct  = c_cpu_temp()
            meter.gpu = gpu
            meter.temp = ct
            panel.gpu = gpu
            panel.temp = ct
            append(&panel.gpuHist, gpu)
            append(&panel.tempHist, (ct - 30) / 70)
        }

        meter.cpu = cpuLoad
        meter.mem = memLoad
        panel.cpu = cpuLoad
        panel.mem = memLoad

        let sig = String(format: "%.0f|%.0f|%.0f|%.0f",
                         cpuLoad * 100, meter.gpu * 100, memLoad * 100, meter.temp)
        guard sig != lastSignature else { return }
        lastSignature = sig
        meter.needsDisplay = true
        if menuOpen { refreshPanel() }
    }

    /// 唯一的本机采样入口（CPU + 逐核 + 内存）：菜单栏、面板、历史曲线都从这里取值。
    private func sampleLocal() {
        let s = cpuSampler.sample()
        if let load = s.overall { cpuLoad = load }
        if !s.perCore.isEmpty { panel.cores = s.perCore }
        append(&panel.cpuHist, cpuLoad)

        if let m = memSampler.sample() { memLoad = m }
        append(&panel.memHist, memLoad)
    }

    private func append(_ arr: inout [Double], _ v: Double) {
        arr.append(min(max(v, 0), 1))
        if arr.count > panel.capacity { arr.removeFirst() }
    }

    private func refreshPanel() {
        panel.needsDisplay = true
        panel.setFrameSize(NSSize(width: contentWidth, height: panel.preferredHeight))
        DispatchQueue.main.async { self.menu.update() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
