#!/usr/bin/env swift
// CoreBar 图标生成器：同步上游最新设计的仪表盘网格、Sparkline 趋势线与状态指示点。
// 输出 1024×1024 PNG 及 AppIcon.icns。

import AppKit
import Foundation

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/app-icon.png"

func drawIcon(size: Int) -> NSImage {
    let scale = CGFloat(size) / 1024
    let canvasSize = CGSize(width: size, height: size)
    let image = NSImage(size: canvasSize)

    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    CGRect(origin: .zero, size: canvasSize).fill()

    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
    }

    let outerRect = rect(96, 96, 832, 832)
    let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 196 * scale, yRadius: 196 * scale)
    NSColor(red: 0.025, green: 0.027, blue: 0.03, alpha: 1).setFill()
    outerPath.fill()

    let borderPath = NSBezierPath(roundedRect: outerRect.insetBy(dx: 10 * scale, dy: 10 * scale), xRadius: 184 * scale, yRadius: 184 * scale)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    borderPath.lineWidth = max(1, 8 * scale)
    borderPath.stroke()

    let panelRect = rect(176, 236, 672, 552)
    let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 104 * scale, yRadius: 104 * scale)
    NSColor(red: 0.075, green: 0.078, blue: 0.082, alpha: 1).setFill()
    panelPath.fill()

    // 绘制参考刻度网格
    NSColor.white.withAlphaComponent(0.09).setStroke()
    for y in [348, 512, 676] as [CGFloat] {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: panelRect.minX + 52 * scale, y: y * scale))
        path.line(to: CGPoint(x: panelRect.maxX - 52 * scale, y: y * scale))
        path.lineWidth = max(1, 5 * scale)
        path.lineCapStyle = .round
        path.stroke()
    }

    // 绘制绿色 Sparkline
    let greenPoints = [
        CGPoint(x: 220, y: 552), CGPoint(x: 282, y: 540), CGPoint(x: 334, y: 560),
        CGPoint(x: 382, y: 500), CGPoint(x: 432, y: 622), CGPoint(x: 490, y: 420),
        CGPoint(x: 552, y: 604), CGPoint(x: 618, y: 490), CGPoint(x: 700, y: 532),
        CGPoint(x: 800, y: 492)
    ]
    drawSparkline(points: greenPoints, color: NSColor.systemGreen, lineWidth: 34 * scale, scale: scale)

    // 绘制青色 Sparkline
    let cyanPoints = [
        CGPoint(x: 224, y: 664), CGPoint(x: 312, y: 686), CGPoint(x: 402, y: 672),
        CGPoint(x: 492, y: 698), CGPoint(x: 590, y: 646), CGPoint(x: 704, y: 674),
        CGPoint(x: 798, y: 650)
    ]
    drawSparkline(points: cyanPoints, color: NSColor.systemCyan.withAlphaComponent(0.88), lineWidth: 20 * scale, scale: scale)

    // 绘制底部状态三色指示灯
    let dots: [(NSColor, CGRect)] = [
        (.systemGreen, CGRect(x: 256, y: 276, width: 42, height: 42)),
        (.systemPurple, CGRect(x: 330, y: 276, width: 42, height: 42)),
        (.systemBlue, CGRect(x: 404, y: 276, width: 42, height: 42))
    ]
    for (color, r) in dots {
        let scaledRect = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        color.withAlphaComponent(0.94).setFill()
        NSBezierPath(ovalIn: scaledRect).fill()
    }

    return image
}

func drawSparkline(points: [CGPoint], color: NSColor, lineWidth: CGFloat, scale: CGFloat) {
    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    for (i, p) in points.enumerated() {
        let sp = CGPoint(x: p.x * scale, y: p.y * scale)
        if i == 0 { path.move(to: sp) } else { path.line(to: sp) }
    }
    color.setStroke()
    path.lineWidth = max(1, lineWidth)
    path.stroke()
}

let image1024 = drawIcon(size: 1024)
guard let tiff = image1024.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("PNG 导出失败")
}
try png.write(to: URL(fileURLWithPath: out))
print("已成功生成最新图标: \(out)")
