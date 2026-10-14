import AppKit
import Foundation
import Darwin

// MacMonBar — 菜单栏版 macmon
//
// 状态栏：CPU / GPU / 内存 百分比 + 温度（默认关闭）；指标间用细竖线分隔
//          进度条默认关闭（菜单可开启）；百分比按占用率着色默认开启（绿<50% / 琥珀50-80% / 红≥80%）
// 面板：四项趋势图，2 行 × 2 列；底部默认显示 12 个核的逐核柱状图（可关）
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
private let kLabelSmall = NSFont.systemFont(ofSize: 11, weight: .medium)
private let kValue = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

private func isDark(_ v: NSView) -> Bool {
    v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

private func cpuColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0x6BA4FF) : NSColor(hex: 0x1E6FD9) }
private func gpuColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0xFFB340) : NSColor(hex: 0xE07B00) }
private func memColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0x5DCAA5) : NSColor(hex: 0x1D9E75) }
private func hotColor(_ v: NSView) -> NSColor { isDark(v) ? NSColor(hex: 0xFF7B6B) : NSColor(hex: 0xC4433A) }

private func tempColor(_ v: NSView, _ c: Double) -> NSColor {
    if c >= 80 { return hotColor(v) }
    if c >= 60 { return isDark(v) ? NSColor(hex: 0xFFC24A) : NSColor(hex: 0xB26A00) }
    return memColor(v)
}

private func levelColor(_ v: NSView, _ ratio: Double) -> NSColor {
    if ratio >= 0.80 { return hotColor(v) }
    if ratio >= 0.50 { return isDark(v) ? NSColor(hex: 0xFFC24A) : NSColor(hex: 0xB26A00) }
    return memColor(v)
}

private func drawText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
    let ps = NSMutableParagraphStyle()
    ps.alignment = align
    let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: ps]
    let size = (s as NSString).size(withAttributes: attr)
    let y = rect.midY - size.height / 2
    (s as NSString).draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: size.height), withAttributes: attr)
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

// MARK: - 状态栏：CPU / GPU / 内存 三条 + 温度

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
        static let label: CGFloat = 30    // 需容纳 11pt medium 的 "CPU"/"内存"
        static let bar: CGFloat = 24
        static let value: CGFloat = 34    // 容纳 13pt 等宽 "100%"
        static let temp: CGFloat = 34
        static let gap: CGFloat = 14      // 指标之间的间隔（含分隔线）
        static let sepH: CGFloat = 14     // 分隔线高度
    }

    private var unit: CGFloat {
        let barPart = showBars ? (L.bar + 4) : 0
        return L.label + 3 + barPart + L.value
    }

    var preferredWidth: CGFloat {
        let gaps = showTemp ? 3 : 2
        return 4 + unit * 3 + L.gap * CGFloat(gaps) + (showTemp ? L.temp : 0) + 4
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
        var x: CGFloat = 4
        x = metric(name: "CPU", ratio: cpu, available: true, series: cpuColor(self), x: x)
        x = advanceAfter(x)
        x = metric(name: "GPU", ratio: gpu, available: macmonAvailable, series: gpuColor(self), x: x)
        x = advanceAfter(x)
        x = metric(name: "内存", ratio: mem, available: macmonAvailable, series: memColor(self), x: x)
        if showTemp {
            x = advanceAfter(x)
            let r = NSRect(x: x, y: 0, width: L.temp, height: bounds.height)
            if macmonAvailable {
                drawText(String(format: "%.0f°C", temp), in: r, font: kValue, color: tempColor(self, temp), align: .right)
            } else {
                drawText("—", in: r, font: kValue, color: .tertiaryLabelColor, align: .right)
            }
        }
    }

    /// available = false 表示数据源缺失，显示"—"而不是误导性的 0%
    private func metric(name: String, ratio: Double, available: Bool, series: NSColor, x: CGFloat) -> CGFloat {
        drawText(name, in: NSRect(x: x, y: 0, width: L.label, height: bounds.height),
                 font: kLabelSmall, color: .secondaryLabelColor, align: .right)
        var cx = x + L.label + 3

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
            cx += L.bar + 4
        }

        let valueRect = NSRect(x: cx, y: 0, width: L.value, height: bounds.height)
        if available {
            let pct = min(max(ratio, 0), 1)
            let color = colorPct ? levelColor(self, pct) : NSColor.labelColor
            drawText(String(format: "%.0f%%", pct * 100), in: valueRect,
                     font: kValue, color: color, align: .right)
        } else {
            drawText("—", in: valueRect, font: kValue, color: .tertiaryLabelColor, align: .right)
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

        trend(name: "CPU", data: cpuHist, series: cpuColor(self), current: cpu, unit: "%", ratio: cpu,
              available: true,
              rect: NSRect(x: c.minX, y: row0Y, width: cellW, height: L.cellH))
        trend(name: "GPU", data: gpuHist, series: gpuColor(self), current: gpu, unit: "%", ratio: gpu,
              available: macmonAvailable,
              rect: NSRect(x: c.minX + cellW + L.colGap, y: row0Y, width: cellW, height: L.cellH))
        trend(name: "内存", data: memHist, series: memColor(self), current: mem, unit: "%", ratio: mem,
              available: macmonAvailable,
              rect: NSRect(x: c.minX, y: row1Y, width: cellW, height: L.cellH))
        trend(name: "温度", data: tempHist, series: tempColor(self, temp), current: temp, unit: "°C",
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
            valueColor = unit == "%" ? levelColor(self, ratio) : tempColor(self, current)
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
            (v >= 0.75 ? hotColor(self) : cpuColor(self)).setFill()
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
    private var intervalMs = 1000
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
        statusItem.button?.toolTip = "CPU / GPU / 内存 占用率 —— 点击展开趋势图"
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
            let hint = NSMenuItem(title: "未找到 macmon —— 点此查看安装说明",
                                  action: #selector(openMacmonDocs), keyEquivalent: "")
            hint.target = self
            menu.addItem(hint)
            menu.addItem(NSMenuItem.separator())
        }

        let coreItem = NSMenuItem(title: "显示每个核心（12 核）", action: #selector(toggleCores(_:)), keyEquivalent: "")
        coreItem.target = self
        coreItem.state = .on                 // 默认打开
        menu.addItem(coreItem)

        let tempItem = NSMenuItem(title: "状态栏显示温度", action: #selector(toggleTemp(_:)), keyEquivalent: "")
        tempItem.target = self
        tempItem.state = .off                // 默认关闭
        menu.addItem(tempItem)

        let barsItem = NSMenuItem(title: "状态栏显示进度条", action: #selector(toggleBars(_:)), keyEquivalent: "")
        barsItem.target = self
        barsItem.state = .off                // 默认隐藏
        menu.addItem(barsItem)

        let colorItem = NSMenuItem(title: "百分比颜色区分", action: #selector(toggleColor(_:)), keyEquivalent: "")
        colorItem.target = self
        colorItem.state = .on                // 默认开启
        menu.addItem(colorItem)

        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for ms in [1000, 2000, 5000] {
            let it = NSMenuItem(title: "\(ms / 1000) 秒", action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.tag = ms
            it.state = ms == intervalMs ? .on : .off
            sub.addItem(it)
        }
        intervalItem.submenu = sub
        menu.addItem(intervalItem)

        let quitItem = NSMenuItem(title: "退出 MacMonBar", action: #selector(quit), keyEquivalent: "q")
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
