#!/usr/bin/env swift
// CoreBar 图标生成器：纯灰阶、精确几何，输出 1024×1024 PNG。
//
// 为什么用代码画而不是文生图：图标是几何产品——三条柱的比例、圆角、
// 留白、1px 高光都必须可控，且 16px 下仍要认得出。美术方向来自生成的
// 参考图（深炭底 + 白色柱 + 细基线），几何由这里决定。
//
// 用法: swiftc -O tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon <输出png>

import AppKit
import Foundation

let S: CGFloat = 1024          // 画布
let tileInset: CGFloat = 100   // macOS 图标模板：824×824 的圆角方形居中
let tile = NSRect(x: tileInset, y: tileInset, width: S - tileInset * 2, height: S - tileInset * 2)
let radius: CGFloat = 185.4    // 824 对应的模板圆角

func gray(_ v: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: v, green: v, blue: v, alpha: a) }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// ── 圆角方形：深炭渐变 + 顶部 1px 高光 ─────────────────────────────
let squircle = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// 投影：贴着底部的柔和暗影，让图标从菜单栏/访达背景里浮起来
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
gray(0.06).setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()
let bg = NSGradient(starting: gray(0.235), ending: gray(0.035))!   // #3C3C3C → #090909
bg.draw(in: tile, angle: -90)
// 顶部内高光，模拟苹果图标那层很浅的顶光
gray(1.0, 0.10).setFill()
NSRect(x: tile.minX, y: tile.maxY - 3, width: tile.width, height: 3).fill()
ctx.restoreGState()

// 一圈极细的内描边，避免深色底在深色背景上糊掉
gray(1.0, 0.07).setStroke()
squircle.lineWidth = 2
squircle.stroke()

// ── 三条柱：CPU / GPU / RAM ─────────────────────────────────────
// 宽 108、间距 48 → 整组 420，视觉重心居中
let barW: CGFloat = 108
let gap: CGFloat = 48
let groupW = barW * 3 + gap * 2
let groupX = (S - groupW) / 2
let baselineY: CGFloat = 340        // 基线
let barBottom: CGFloat = baselineY + 22
let heights: [CGFloat] = [160, 256, 356]   // 由低到高，读起来像"占用率"

for (i, h) in heights.enumerated() {
    let x = groupX + CGFloat(i) * (barW + gap)
    let r = NSRect(x: x, y: barBottom, width: barW, height: h)
    let p = NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28)
    ctx.saveGState()
    p.addClip()
    // 每根柱都用同一条竖向渐变：顶部纯白，底部浅灰
    let g = NSGradient(starting: gray(1.0), ending: gray(0.78))!
    g.draw(in: r, angle: -90)
    ctx.restoreGState()
}

// ── 基线：与柱组等宽的细线 ─────────────────────────────────────
gray(0.62, 0.75).setFill()
NSBezierPath(roundedRect: NSRect(x: groupX, y: baselineY, width: groupW, height: 5),
             xRadius: 2.5, yRadius: 2.5).fill()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("已生成 \(out)  \(Int(S))×\(Int(S))")
