import AppKit
import Foundation
import Darwin

// MacMonBar — 菜单栏版 macmon
//
// 状态栏：CPU / GPU / RAM 百分比 + 温度（默认关闭）；指标间用细竖线分隔
//          状态栏标签固定英文；菜单与面板文案按系统语言中英双语（见 Loc）
//          进度条默认关闭（菜单可开启）；百分比按占用率着色默认开启（绿<50% / 琥珀50-80% / 红≥80%）
//          状态栏标签 13pt semibold（与系统菜单栏同字号），在预留位内居中
// 面板：四项趋势图，2 行 × 2 列；底部默认显示 12 个核的逐核柱状图（可关）
// 配色分两套互不重叠的色系（见下方 MARK）：
//          图表用身份色（CPU 蓝 / GPU 玫红 / 内存青 / 温度紫，刻意避开绿琥珀红）；
//          数值用绿/琥珀/红梯度（百分比 <50/≥50/≥80%，温度 <60/≥60/≥80°C）
//
// 数据来源：
//   · CPU 占用率 —— 本 App 自己用 Mach host_processor_info 统计全部 12 核
//   · GPU / 内存 / 温度 —— 常驻的 `macmon pipe` 子进程

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

// MARK: - 状态栏：CPU / GPU / RAM 三条 + 温度

final class MeterView: NSView {
    var cpu: Double = 0
    var gpu: Double = 0
    var mem: Double = 0
    var temp: Double = 0
    var showTemp = false                 // 默认关闭
    var showBars = false                 // 默认隐藏状态栏进度条（菜单可开启）
    var colorPct = true                  // 百分比按占用率着色，默认开启（菜单可关闭）
    var macmonAvailable = true           // false 时 GPU / 内存 / 温度显示"—"

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
        x = metric(name: "GPU", ratio: gpu, available: macmonAvailable, series: gpuSeriesColor(self), x: x)
        x = advanceAfter(x)
        x = metric(name: "RAM", ratio: mem, available: macmonAvailable, series: memSeriesColor(self), x: x)  // 状态栏标签固定英文
        if showTemp {
            x = advanceAfter(x)
            let r = NSRect(x: x, y: 0, width: L.temp, height: bounds.height)
            if macmonAvailable {
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
    var macmonAvailable = true           // false 时 GPU / 内存 / 温度显示"—"
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
              available: macmonAvailable,
              rect: NSRect(x: c.minX + cellW + L.colGap, y: row0Y, width: cellW, height: L.cellH))
        trend(name: Loc.t("内存", "RAM"), data: memHist, series: memSeriesColor(self), current: mem, unit: "%", ratio: mem,
              available: macmonAvailable,
              rect: NSRect(x: c.minX, y: row1Y, width: cellW, height: L.cellH))
        trend(name: Loc.t("温度", "Temperature"), data: tempHist, series: tempSeriesColor(self), current: temp, unit: "°C",
              ratio: (temp - 30) / 70, available: macmonAvailable,
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

        let dash = NSBezierPath()
        dash.move(to: NSPoint(x: chart.minX + 2, y: chart.midY.rounded() + 0.5))
        dash.line(to: NSPoint(x: chart.maxX - 2, y: chart.midY.rounded() + 0.5))
        dash.lineWidth = 1
        dash.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        dash.stroke()

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
        series.withAlphaComponent(isDark(self) ? 0.22 : 0.18).setFill()
        area.fill()

        let line = NSBezierPath()
        line.move(to: pts[0])
        for p in pts.dropFirst() { line.line(to: p) }
        line.lineWidth = 1.8
        line.lineJoinStyle = .round
        series.setStroke()
        line.stroke()

        let last = pts[pts.count - 1]
        series.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - 2.2, y: last.y - 2.2, width: 4.4, height: 4.4)).fill()
    }

    /// 12 个核的逐核占用率
    private func coreRow(rect: NSRect) {
        let n = cores.count
        guard n > 0 else { return }
        let gap: CGFloat = 2
        let bw = (rect.width - CGFloat(n - 1) * gap) / CGFloat(n)
        for i in 0..<n {
            let x = rect.minX + CGFloat(i) * (bw + gap)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
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

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let meter = MeterView()
    private let panel = PanelView()
    private var proc: Process?
    private var buf = Data()
    private var intervalMs = 2000
    private var menu: NSMenu!
    private var panelItem: NSMenuItem!
    private var menuOpen = false
    private var cpuSampler = CPUCoreSampler()
    private var cpuLoad: Double = 0
    private var lastSignature = ""

    /// macmon 是否在位。它同时决定三件事：
    /// GPU / 内存 / 温度 有无数据、菜单是否显示安装提示、CPU 由谁驱动心跳。
    private var macmonAvailable = false
    private var fallbackTimer: Timer?

    /// 后台线程收到的原始字节先入队，再由挂在 RunLoop .common 模式上的定时器取走。
    /// 原因：NSMenu 展开时会跑 NSEventTrackingRunLoopMode 的嵌套循环，
    /// DispatchQueue.main 的 block 在该模式下不会被派发，导致菜单展开时图表静止。
    private let pendingLock = NSLock()
    private var pending = Data()
    private var drainTimer: Timer?

    private static let fixedPanelWidth: CGFloat = 300

    private var macmonPath: String { ("~/.local/bin/macmon" as NSString).expandingTildeInPath }

    func applicationDidFinishLaunching(_: Notification) {
        macmonAvailable = FileManager.default.isExecutableFile(atPath: macmonPath)
        meter.macmonAvailable = macmonAvailable
        panel.macmonAvailable = macmonAvailable

        statusItem.button?.title = ""
        statusItem.button?.image = nil
        statusItem.button?.toolTip = Loc.t("CPU / GPU / 内存 占用率 —— 点击展开趋势图",
                                           "CPU / GPU / RAM usage — click to expand trend charts")
        meter.frame = NSRect(x: 0, y: 0, width: meter.preferredWidth, height: 22)
        meter.autoresizingMask = [.width, .height]
        statusItem.button?.addSubview(meter)
        statusItem.length = meter.preferredWidth
        buildMenu()
        installDrainTimer()
        startSampler()
    }

    func applicationWillTerminate(_: Notification) { proc?.terminate() }

    private var contentWidth: CGFloat { Self.fixedPanelWidth - 24 }

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self

        panel.frame = NSRect(x: 0, y: 0, width: contentWidth, height: panel.preferredHeight)
        panelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(NSMenuItem.separator())

        if !macmonAvailable {
            let hint = NSMenuItem(title: Loc.t("未找到 macmon —— 点此查看安装说明",
                                               "macmon not found — click for install instructions"),
                                  action: #selector(openMacmonDocs), keyEquivalent: "")
            hint.target = self
            menu.addItem(hint)
            menu.addItem(NSMenuItem.separator())
        }

        let coreItem = NSMenuItem(title: Loc.t("显示每个核心（12 核）", "Show every core (12 cores)"), action: #selector(toggleCores(_:)), keyEquivalent: "")
        coreItem.target = self
        coreItem.state = .on                 // 默认打开
        menu.addItem(coreItem)

        let tempItem = NSMenuItem(title: Loc.t("状态栏显示温度", "Show temperature in menu bar"), action: #selector(toggleTemp(_:)), keyEquivalent: "")
        tempItem.target = self
        tempItem.state = .off                // 默认关闭
        menu.addItem(tempItem)

        let barsItem = NSMenuItem(title: Loc.t("状态栏显示进度条", "Show gauges in menu bar"), action: #selector(toggleBars(_:)), keyEquivalent: "")
        barsItem.target = self
        barsItem.state = .off                // 默认隐藏
        menu.addItem(barsItem)

        let colorItem = NSMenuItem(title: Loc.t("百分比颜色区分", "Colour-code percentages"), action: #selector(toggleColor(_:)), keyEquivalent: "")
        colorItem.target = self
        colorItem.state = .on                // 默认开启
        menu.addItem(colorItem)

        let intervalItem = NSMenuItem(title: Loc.t("刷新间隔", "Refresh interval"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for ms in [1000, 2000, 5000] {
            let it = NSMenuItem(title: Loc.t("\(ms / 1000) 秒", "\(ms / 1000) s"), action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.tag = ms
            it.state = ms == intervalMs ? .on : .off
            sub.addItem(it)
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
        sender.state = panel.showCores ? .on : .off
        panel.setFrameSize(NSSize(width: contentWidth, height: panel.preferredHeight))
        panel.needsDisplay = true
        DispatchQueue.main.async { self.menu.update() }
    }

    @objc private func toggleTemp(_ sender: NSMenuItem) {
        meter.showTemp.toggle()
        sender.state = meter.showTemp ? .on : .off
        statusItem.length = meter.preferredWidth
        meter.needsDisplay = true
    }

    @objc private func toggleBars(_ sender: NSMenuItem) {
        meter.showBars.toggle()
        sender.state = meter.showBars ? .on : .off
        statusItem.length = meter.preferredWidth
        meter.needsDisplay = true
    }

    @objc private func toggleColor(_ sender: NSMenuItem) {
        meter.colorPct.toggle()
        sender.state = meter.colorPct ? .on : .off
        meter.needsDisplay = true
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        intervalMs = sender.tag
        for it in sender.menu?.items ?? [] { it.state = it.tag == intervalMs ? .on : .off }
        cpuSampler.reset()
        startSampler()
    }

    @objc private func quit() {
        proc?.terminate()
        NSApp.terminate(nil)
    }

    @objc private func openMacmonDocs() {
        if let url = URL(string: "https://github.com/vladkens/macmon#-installation") {
            NSWorkspace.shared.open(url)
        }
    }

    func menuWillOpen(_: NSMenu) { menuOpen = true; refreshPanel() }
    func menuDidClose(_: NSMenu) { menuOpen = false }

    private func startSampler() {
        proc?.terminate()
        proc = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        buf.removeAll(keepingCapacity: true)

        macmonAvailable = FileManager.default.isExecutableFile(atPath: macmonPath)
        meter.macmonAvailable = macmonAvailable
        panel.macmonAvailable = macmonAvailable

        // 没有 macmon：GPU / 内存 / 温度 无从取得（显示"—"），
        // 但 CPU 与逐核仍由本 App 自己采样，不能跟着一起停摆——
        // 这里用独立 Timer 驱动，而不是依赖 macmon 的 JSON 到达。
        guard macmonAvailable else {
            scheduleCPUTick()
            meter.needsDisplay = true
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: macmonPath)
        p.arguments = ["pipe", "-i", String(intervalMs)]
        p.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.enqueue(data)
        }
        try? p.run()
        proc = p
    }

    /// macmon 缺失时的兜底心跳
    private func scheduleCPUTick() {
        fallbackTimer?.invalidate()
        let t = Timer(timeInterval: Double(intervalMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.tickCPU()
        }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t
    }

    private func tickCPU() {
        let s = cpuSampler.sample()
        if let load = s.overall { cpuLoad = load }
        if !s.perCore.isEmpty { panel.cores = s.perCore }
        meter.cpu = cpuLoad
        panel.cpu = cpuLoad
        append(&panel.cpuHist, cpuLoad)
        meter.needsDisplay = true
    }

    private func enqueue(_ d: Data) {
        pendingLock.lock()
        pending.append(d)
        pendingLock.unlock()
    }

    /// 以 .common 模式挂在 Main RunLoop 上，因此在菜单展开（eventTracking）时同样会被触发。
    @objc private func drainPending() {
        pendingLock.lock()
        let d = pending
        pending.removeAll(keepingCapacity: true)
        pendingLock.unlock()
        if !d.isEmpty { ingest(d) }
    }

    private func installDrainTimer() {
        drainTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.drainPending() }
        RunLoop.main.add(t, forMode: .common)
        drainTimer = t
    }

    private func ingest(_ data: Data) {
        buf.append(data)
        while let idx = buf.firstIndex(of: 0x0A) {
            let line = Data(buf.prefix(upTo: idx))
            buf.removeSubrange(buf.startIndex...idx)
            guard let dict = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            apply(dict)
            if menuOpen { refreshPanel() }
        }
    }

    private func apply(_ d: [String: Any]) {
        let s = cpuSampler.sample()
        if let load = s.overall { cpuLoad = load }
        if !s.perCore.isEmpty { panel.cores = s.perCore }

        let gpu = num(d["gpu_scaled_ratio"])
        let temp = (d["temp"] as? [String: Any]).map { num($0["cpu_temp_avg"]) } ?? 0
        let mem = d["memory"] as? [String: Any] ?? [:]
        let memPct = num(mem["ram_total"]) > 0 ? num(mem["ram_usage"]) / num(mem["ram_total"]) : 0

        meter.cpu = cpuLoad
        meter.gpu = gpu
        meter.mem = memPct
        meter.temp = temp

        panel.cpu = cpuLoad
        panel.gpu = gpu
        panel.mem = memPct
        panel.temp = temp

        append(&panel.cpuHist, cpuLoad)
        append(&panel.gpuHist, gpu)
        append(&panel.memHist, memPct)
        append(&panel.tempHist, (temp - 30) / 70)

        let sig = String(format: "%.0f|%.0f|%.0f|%.0f", cpuLoad * 100, gpu * 100, memPct * 100, temp)
        guard sig != lastSignature else { return }
        lastSignature = sig
        meter.needsDisplay = true
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

    private func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let n = v as? Double { return n }
        return 0
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
