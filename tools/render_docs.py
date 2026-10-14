#!/usr/bin/env python3
"""从 src/main.swift 派生一个离线渲染程序，重新生成 docs/ 里的所有截图。

原理：截断 main.swift 末尾的 NSApplication 启动代码，接上一段采集 + 光栅化代码。
这样图片永远是 App 自己的 draw(_:) 画出来的，不会和真实渲染脱节。

用法:
    python3 tools/render_docs.py [输出目录]       # 默认 docs/
"""
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "main.swift")
BOOTSTRAP = "let app = NSApplication.shared"

HARNESS = r'''
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

// MARK: - 采集真实数据

let fm = FileManager.default
let bin = [NSHomeDirectory() + "/.local/bin/macmon", "/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"]
    .first { fm.isExecutableFile(atPath: $0) }!

var sampler = CPUCoreSampler()
var cpuH: [Double] = [], gpuH: [Double] = [], memH: [Double] = [], tempH: [Double] = []
var coreVals: [Double] = []
var curCpu = 0.0, curGpu = 0.0, curMem = 0.0, curTemp = 0.0

func push(_ arr: inout [Double], _ v: Double) {
    arr.append(min(max(v, 0), 1))
    if arr.count > 120 { arr.removeFirst() }
}

let mp = Process()
mp.executableURL = URL(fileURLWithPath: bin)
mp.arguments = ["pipe", "-i", "200"]
let pp = Pipe()
mp.standardOutput = pp
mp.standardError = FileHandle.nullDevice
try! mp.run()

let fh = pp.fileHandleForReading
let deadline = Date().addingTimeInterval(26)
var raw = Data()
while Date() < deadline {
    let d = fh.availableData
    if d.isEmpty { break }
    raw.append(d)
    while let nl = raw.firstIndex(of: 0x0A) {
        let line = Data(raw.prefix(upTo: nl))
        raw.removeSubrange(raw.startIndex...nl)
        guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
        let s = sampler.sample()
        if let o = s.overall { curCpu = o }
        if !s.perCore.isEmpty { coreVals = s.perCore }
        curGpu = (j["gpu_scaled_ratio"] as? NSNumber)?.doubleValue ?? 0
        curTemp = ((j["temp"] as? [String: Any])?["cpu_temp_avg"] as? NSNumber)?.doubleValue ?? 0
        let m = j["memory"] as? [String: Any] ?? [:]
        let rt = (m["ram_total"] as? NSNumber)?.doubleValue ?? 0
        let ru = (m["ram_usage"] as? NSNumber)?.doubleValue ?? 0
        curMem = rt > 0 ? ru / rt : 0
        push(&cpuH, curCpu); push(&gpuH, curGpu); push(&memH, curMem); push(&tempH, (curTemp - 30) / 70)
    }
}
mp.terminate()

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

    // 降级状态：没有 macmon
    let nc = PanelView()
    nc.cpu = curCpu; nc.cores = coreVals; nc.showCores = true
    nc.macmonAvailable = false
    renderPNG(nc, w: 300, h: nc.preferredHeight, scale: 2, dark: false, path: out("panel-no-macmon-light.png"))

    let nm = MeterView()
    nm.cpu = curCpu; nm.showTemp = false
    nm.macmonAvailable = false
    renderPNG(nm, w: nm.preferredWidth, h: 22, scale: 3, dark: false, path: out("statusbar-no-macmon-light.png"))
}

print(String(format: "rendered cpu=%.0f%% gpu=%.0f%% mem=%.0f%% temp=%.0fC cores=%d barW=%.0fpt",
             curCpu * 100, curGpu * 100, curMem * 100, curTemp, coreVals.count,
             MeterView().preferredWidth))
'''


def main() -> int:
    outdir = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs"))
    os.makedirs(outdir, exist_ok=True)

    src = open(SRC, encoding="utf-8").read()
    idx = src.find(BOOTSTRAP)
    if idx < 0:
        print("错误：未在 src/main.swift 找到启动代码锚点", file=sys.stderr)
        return 1
    body = src[:idx]

    with tempfile.TemporaryDirectory() as tmp:
        gen = os.path.join(tmp, "render_docs.swift")
        with open(gen, "w", encoding="utf-8") as f:
            f.write(body)
            f.write(HARNESS)
        exe = os.path.join(tmp, "render_docs")
        r = subprocess.run(["swiftc", "-O", "-target", "arm64-apple-macosx13.0", gen, "-o", exe],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            return 1
        r = subprocess.run([exe, outdir], capture_output=True, text=True)
        print(r.stdout.strip() or r.stderr.strip())
        return r.returncode


if __name__ == "__main__":
    raise SystemExit(main())
