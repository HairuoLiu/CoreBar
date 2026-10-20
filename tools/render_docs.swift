#!/usr/bin/env swift
// render_docs.swift — 从 src/main.swift 派生一个离线渲染程序，重新生成 docs/ 里的所有截图。
// 替代原 render_docs.py（项目工具链不再依赖 Python）。
//
// 原理：截断 main.swift 末尾的 NSApplication 启动代码，接上一段采集 + 光栅化代码。
// 这样图片永远是 App 自己的 draw(_:) 画出来的，不会和真实渲染脱节。
// 采集数据全部来自本进程：Mach 采 CPU / 内存，src/sensors.c（C 桥接）采 GPU / 温度。
//
// 用法（在仓库根目录）：
//   swift tools/render_docs.swift [输出目录]      # 默认 docs/
import Foundation

let fm = FileManager.default

// 仓库根目录：本脚本位于 <root>/tools/render_docs.swift
let selfPath = #filePath
var root = URL(fileURLWithPath: selfPath).deletingLastPathComponent().deletingLastPathComponent().path
if !fm.fileExists(atPath: root + "/src/main.swift") {
    root = fm.currentDirectoryPath   // 兜底：按当前工作目录
}
let srcPath = root + "/src/main.swift"

// 与 main.swift 末尾的启动代码对齐；截断点之后的内容不参与编译。
let anchor = "let app = NSApplication.shared"

// MARK: - 追加到 main.swift 末尾的采集 + 渲染 harness
let harness = #"""
// MARK: - 离线渲染（供 docs/ 截图用，不参与 App 运行）

func renderPNG(_ view: NSView, w: CGFloat, h: CGFloat, scale: CGFloat, dark: Bool, path: String) {
    let pw = Int(w * scale), ph = Int(h * scale)
    var planes: [UnsafeMutablePointer<UInt8>?] = [nil]
    let rep = NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: pw, pixelsHigh: ph,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.scaleBy(x: scale, y: scale)
    NSGraphicsContext.current = ctx
    let appearance = dark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
    view.appearance = appearance
    view.frame = NSRect(x: 0, y: 0, width: w, height: h)
    // 动态色（labelColor / secondaryLabelColor）必须在这个 block 里解析，否则取到 aqua 的值
    appearance!.performAsCurrentDrawingAppearance {
        (dark ? NSColor(hex: 0x2A2A2C) : NSColor(hex: 0xECECEE)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        view.draw(view.bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: - 采集真实数据（全部本进程，无子进程）

guard c_sensors_init() == 0 else {
    FileHandle.standardError.write("sensors init 失败\n".data(using: .utf8)!)
    exit(1)
}

var sampler = CPUCoreSampler()
var memSampler = MemorySampler()
var cpuH: [Double] = [], gpuH: [Double] = [], memH: [Double] = [], tempH: [Double] = []
var coreVals: [Double] = []
var curCpu = 0.0, curGpu = 0.0, curMem = 0.0, curTemp = 0.0

func push(_ arr: inout [Double], _ v: Double) {
    arr.append(min(max(v, 0), 1))
    if arr.count > 120 { arr.removeFirst() }
}

// 130 × 200ms = 26 秒，和原来读 macmon 管道的时长一致
for _ in 0..<130 {
    let s = sampler.sample()
    if let o = s.overall { curCpu = o }
    if !s.perCore.isEmpty { coreVals = s.perCore }
    if let m = memSampler.sample() { curMem = m }
    curGpu = c_gpu_ratio()     // 首次调用是 prime（返回 0），之后为真实占用
    curTemp = c_cpu_temp()
    push(&cpuH, curCpu); push(&gpuH, curGpu); push(&memH, curMem); push(&tempH, (curTemp - 30) / 70)
    usleep(200_000)
}
c_sensors_close()

// docs/ 放英文版（给 README.md），docs/zh/ 放中文版（给 README.zh-CN.md）
let baseOut = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

for (sub, chinese) in [("", false), ("zh", true)] {
    Loc.isChinese = chinese
    let outDir = baseOut + "/" + sub
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    func out(_ n: String) -> String { outDir + "/" + n }

    for dark in [false, true] {
        let suffix = dark ? "dark" : "light"

        // 展开面板
        let p = PanelView()
        p.cpu = curCpu; p.gpu = curGpu; p.mem = curMem; p.temp = curTemp
        p.cpuHist = cpuH; p.gpuHist = gpuH; p.memHist = memH; p.tempHist = tempH
        p.cores = coreVals
        p.showCores = true
        renderPNG(p, w: 300, h: p.preferredHeight, scale: 2, dark: dark, path: out("panel-" + suffix + ".png"))

        // 菜单栏：默认（无进度条、无温度）
        let m1 = MeterView()
        m1.cpu = curCpu; m1.gpu = curGpu; m1.mem = curMem; m1.temp = curTemp
        m1.showTemp = false; m1.showBars = false
        renderPNG(m1, w: m1.preferredWidth, h: 22, scale: 3, dark: dark, path: out("statusbar-" + suffix + ".png"))

        // 菜单栏：开进度条
        let m2 = MeterView()
        m2.cpu = curCpu; m2.gpu = curGpu; m2.mem = curMem; m2.temp = curTemp
        m2.showTemp = false; m2.showBars = true
        renderPNG(m2, w: m2.preferredWidth, h: 22, scale: 3, dark: dark, path: out("statusbar-bars-" + suffix + ".png"))

        // 菜单栏：开温度
        let m3 = MeterView()
        m3.cpu = curCpu; m3.gpu = curGpu; m3.mem = curMem; m3.temp = curTemp
        m3.showTemp = true; m3.showBars = false
        renderPNG(m3, w: m3.preferredWidth, h: 22, scale: 3, dark: dark, path: out("statusbar-temp-" + suffix + ".png"))
    }

    // 降级状态：传感器没初始化成功（GPU / 温度 显示 "—"）
    let nc = PanelView()
    nc.cpu = curCpu; nc.cores = coreVals; nc.showCores = true
    nc.sensorsAvailable = false
    renderPNG(nc, w: 300, h: nc.preferredHeight, scale: 2, dark: false, path: out("panel-no-macmon-light.png"))

    let nm = MeterView()
    nm.cpu = curCpu; nm.showTemp = false
    nm.sensorsAvailable = false
    renderPNG(nm, w: nm.preferredWidth, h: 22, scale: 3, dark: false, path: out("statusbar-no-macmon-light.png"))
}

print(String(format: "rendered cpu=%.0f%% gpu=%.0f%% mem=%.0f%% temp=%.0fC cores=%d barW=%.0fpt",
             curCpu * 100, curGpu * 100, curMem * 100, curTemp, coreVals.count,
             MeterView().preferredWidth))
"""#

// MARK: - 生成、编译、运行

guard fm.fileExists(atPath: srcPath) else {
    FileHandle.standardError.write("找不到 \(srcPath)\n".data(using: .utf8)!)
    exit(1)
}
guard let src = try? String(contentsOfFile: srcPath, encoding: .utf8) else {
    FileHandle.standardError.write("读取 \(srcPath) 失败\n".data(using: .utf8)!)
    exit(1)
}
guard let range = src.range(of: anchor) else {
    FileHandle.standardError.write("错误：未在 src/main.swift 找到启动代码锚点\n".data(using: .utf8)!)
    exit(1)
}
let body = String(src[src.startIndex..<range.lowerBound])

let outdir: String
if CommandLine.arguments.count > 1 {
    outdir = CommandLine.arguments[1]
} else {
    outdir = root + "/docs"
}

let tmp = fm.temporaryDirectory.appendingPathComponent("macmonbar-render-\(ProcessInfo.processInfo.processIdentifier)")
try? fm.removeItem(at: tmp)
try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

let gen = tmp.appendingPathComponent("render_docs.swift").path
let exe = tmp.appendingPathComponent("render_docs").path

do {
    try (body + "\n" + harness).write(toFile: gen, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write("写临时文件失败：\(error)\n".data(using: .utf8)!)
    exit(1)
}

// 同时编译 sensors.c：harness 要调 c_sensors_init / c_gpu_ratio / c_cpu_temp
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/env")
compile.arguments = ["swiftc", "-O", "-target", "arm64-apple-macosx13.0",
                     gen, root + "/src/sensors.c", "-o", exe,
                     "-framework", "IOKit", "-framework", "CoreFoundation"]
let cerr = Pipe()
compile.standardError = cerr
compile.standardOutput = FileHandle.nullDevice
do { try compile.run() } catch {
    FileHandle.standardError.write("启动 swiftc 失败：\(error)\n".data(using: .utf8)!)
    exit(1)
}
let errData = cerr.fileHandleForReading.readDataToEndOfFile()
compile.waitUntilExit()
if compile.terminationStatus != 0 {
    let msg = String(data: errData, encoding: .utf8) ?? "编译失败"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(1)
}

let run = Process()
run.executableURL = URL(fileURLWithPath: exe)
run.arguments = [outdir]
do { try run.run() } catch {
    FileHandle.standardError.write("运行渲染程序失败：\(error)\n".data(using: .utf8)!)
    exit(1)
}
run.waitUntilExit()
exit(run.terminationStatus)
