#!/usr/bin/env swift
// CoreBar 图标生成器 —— 「菜单栏 · 光柱」。
//
// 语义：CoreBar 是菜单栏里的监视器。图标就是那个场景本身——
//   顶部一条亮起的菜单栏，栏里一枚被点亮的读数项，光从栏底倾泻进暗屏，
//   在屏幕下缘汇成一摊柔光。亮栏 / 暗屏的值关系是读得出来的关键。
//
// 为什么用代码画而不是文生图：圆角、栏高、光束锥度、光池的扁率、磨砂颗粒
// 都必须逐像素可控，且缩到 16px 仍要认得出。所有参数在下面集中定义。
//
// 用法: swiftc -O tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon <输出png>
// 整套流程（含 .icns）见 tools/make_icon.sh。

import AppKit
import Foundation

// ── 画布与模板 ────────────────────────────────────────────────
// macOS 图标模板：1024 画布内居中一个 824×824、圆角 185.4 的圆角方形。
let S: CGFloat = 1024
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let tileRadius: CGFloat = 185.4
let CX: CGFloat = S / 2
let CY: CGFloat = S / 2

// 菜单栏带：占据圆角方形顶部 stripH 高的一条。
let stripH: CGFloat = 176
let stripBot: CGFloat = tile.maxY - stripH          // 栏底 = 屏幕顶

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

// ── 磨砂颗粒 ──────────────────────────────────────────────────
func makeNoise(_ side: Int, _ seed: UInt64) -> CGImage {
    var st = seed
    func rnd() -> UInt8 {
        st = st &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: st >> 40)
    }
    var px = [UInt8](repeating: 255, count: side * side * 4)
    for i in 0..<(side * side) {
        let v = rnd()
        px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
    }
    let prov = CGDataProvider(data: Data(px) as CFData)!
    return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
let grainImg = makeNoise(512, 0x9E37_79B9_7F4A_7C15)

func grain(_ ctx: CGContext, _ rect: CGRect, alpha: CGFloat, blend: CGBlendMode = .softLight) {
    ctx.saveGState(); ctx.setBlendMode(blend); ctx.setAlpha(alpha)
    ctx.draw(grainImg, in: rect); ctx.restoreGState()
}

// ── 通用绘制 ──────────────────────────────────────────────────
func rounded(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}
func rimHighlight(_ ctx: CGContext, _ path: CGPath, width: CGFloat, color: CGColor) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip(); ctx.addPath(path)
    ctx.setStrokeColor(color); ctx.setLineWidth(width * 2); ctx.strokePath(); ctx.restoreGState()
}
func glow(_ ctx: CGContext, _ center: CGPoint, r: CGFloat, color: UInt32, alpha: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [c(color, alpha), c(color, 0)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
    ctx.restoreGState()
}
func clipTile(_ ctx: CGContext) { ctx.addPath(rounded(tile, tileRadius)); ctx.clip() }

// ── 底板：雾面磨砂 ────────────────────────────────────────────
func drawTile(_ ctx: CGContext) {
    let path = rounded(tile, tileRadius)

    // 外投影：让图标从 Dock / 访达里浮起来
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: c(0x000000, 0.55))
    ctx.addPath(path); ctx.setFillColor(c(0x0E0E12)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    // 竖向主渐变：顶部偏亮的石墨灰 → 底部近黑
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [c(0x5E5F6A), c(0x34353E), c(0x191A20), c(0x101116)] as CFArray,
                       locations: [0, 0.30, 0.72, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: CX, y: tile.maxY), end: CGPoint(x: CX, y: tile.minY), options: [])
    // 左上大片柔光（磨砂玻璃的“底光”）
    let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [c(0xFFFFFF, 0.15), c(0xFFFFFF, 0.05), c(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 330, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 860), endRadius: 780, options: [])
    // 斜向掠光
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [c(0xFFFFFF, 0.09), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: tile.minX, y: tile.midY + 300),
                           end: CGPoint(x: tile.maxX, y: tile.midY - 380), options: [])
    grain(ctx, tile, alpha: 0.19)
    // 四角压暗
    let vg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [c(0x000000, 0), c(0x000000, 0.34)] as CFArray, locations: [0.45, 1])!
    ctx.drawRadialGradient(vg, startCenter: CGPoint(x: CX, y: CY), startRadius: 240,
                           endCenter: CGPoint(x: CX, y: CY), endRadius: 760, options: [])
    ctx.restoreGState()

    // 一圈极细内描边，避免深底在深背景上糊掉
    ctx.addPath(path); ctx.setStrokeColor(c(0xFFFFFF, 0.13)); ctx.setLineWidth(2); ctx.strokePath()
}

// ── 语义零件 ──────────────────────────────────────────────────

/// 屏幕区压暗：把「亮栏 / 暗屏」的值关系立起来，否则栏读不出来。
func screenDarken(_ ctx: CGContext, amount: CGFloat = 0.34) {
    ctx.saveGState(); clipTile(ctx)
    ctx.setFillColor(c(0x000000, amount))
    ctx.fill(CGRect(x: tile.minX - 4, y: tile.minY, width: tile.width + 8, height: stripBot - tile.minY))
    // 屏幕里一层很淡的顶光，避免死黑
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [c(0xFFFFFF, 0.06), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: CX, y: stripBot),
                           end: CGPoint(x: CX, y: stripBot - 320), options: [])
    ctx.restoreGState()
}

/// 菜单栏带：比屏幕亮一档的磨砂条，下缘一道硬分隔 + 投在屏幕上的影子。
func menuBar(_ ctx: CGContext, lift: CGFloat = 1.0) {
    screenDarken(ctx)
    let r = CGRect(x: tile.minX - 4, y: stripBot, width: tile.width + 8, height: stripH + 4)
    ctx.saveGState(); clipTile(ctx)
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [c(0xFFFFFF, 0.42 * lift), c(0xFFFFFF, 0.22 * lift)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: CX, y: r.maxY), end: CGPoint(x: CX, y: r.minY), options: [])
    grain(ctx, r, alpha: 0.30)
    // 上缘顶光
    ctx.setFillColor(c(0xFFFFFF, 0.45 * lift))
    ctx.fill(CGRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 3))
    // 栏投在屏幕上的影子
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: c(0x000000, 0.85))
    ctx.setFillColor(c(0x000000, 0.55))
    ctx.fill(CGRect(x: r.minX, y: stripBot - 6, width: r.width, height: 6))
    ctx.restoreGState()
    // 下缘硬分隔
    ctx.setFillColor(c(0x000000, 0.62))
    ctx.fill(CGRect(x: r.minX, y: stripBot - 4, width: r.width, height: 4))
    ctx.setFillColor(c(0xFFFFFF, 0.30 * lift))
    ctx.fill(CGRect(x: r.minX, y: stripBot - 0.5, width: r.width, height: 1.5))
    ctx.restoreGState()
}

/// 状态项：栏里那枚被点亮的读数胶囊。
func statusItem(_ ctx: CGContext, _ r: CGRect, bright: CGFloat = 1.0) {
    let p = rounded(r, r.height / 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: c(0xFFFFFF, 0.30 * bright))
    ctx.addPath(p); ctx.setFillColor(c(0xFFFFFF, 0.30 + 0.58 * bright)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [c(0xFFFFFF, 0.85), c(0xD5D8E0, 0.55)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    grain(ctx, r, alpha: 0.34, blend: .overlay)
    ctx.restoreGState()
    rimHighlight(ctx, p, width: 1.3, color: c(0xFFFFFF, 0.85))
}

// ── 光柱 ──────────────────────────────────────────────────────
// 两层锥体：外层柔光晕 + 内层亮核，才像一束光而不是一块梯形色板。
func beamIcon(_ ctx: CGContext) {
    drawTile(ctx)
    menuBar(ctx)

    let barCenterY = stripBot + stripH / 2
    let itemW: CGFloat = 232, itemH: CGFloat = 60
    let itemR = CGRect(x: CX - itemW / 2, y: barCenterY - itemH / 2, width: itemW, height: itemH)

    // 光从「栏底 = 屏幕顶」涌出，向下倾泻、逐渐张开
    let beamTop = stripBot + 2
    let beamBot = tile.minY + 118
    let topHalf: CGFloat = 30      // 顶端半宽
    let botHalf: CGFloat = 150     // 底端半宽

    // 外层柔光锥
    ctx.saveGState(); clipTile(ctx)
    let outer = CGMutablePath()
    outer.move(to: CGPoint(x: CX - topHalf * 1.8, y: beamTop))
    outer.addLine(to: CGPoint(x: CX + topHalf * 1.8, y: beamTop))
    outer.addLine(to: CGPoint(x: CX + botHalf * 2.0, y: beamBot))
    outer.addLine(to: CGPoint(x: CX - botHalf * 2.0, y: beamBot))
    outer.closeSubpath()
    ctx.addPath(outer); ctx.clip()
    let colOuter = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [c(0xBFF3EC, 0.34), c(0x6FE3D6, 0.13), c(0x2FC4B4, 0)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(colOuter, start: CGPoint(x: CX, y: beamTop), end: CGPoint(x: CX, y: beamBot), options: [])
    ctx.restoreGState()

    // 内层亮核
    ctx.saveGState(); clipTile(ctx)
    let inner = CGMutablePath()
    inner.move(to: CGPoint(x: CX - topHalf, y: beamTop))
    inner.addLine(to: CGPoint(x: CX + topHalf, y: beamTop))
    inner.addLine(to: CGPoint(x: CX + botHalf, y: beamBot))
    inner.addLine(to: CGPoint(x: CX - botHalf, y: beamBot))
    inner.closeSubpath()
    ctx.addPath(inner); ctx.clip()
    let colInner = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [c(0xF2FFFC, 0.88), c(0xB6F2E8, 0.42), c(0x6FE3D6, 0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(colInner, start: CGPoint(x: CX, y: beamTop), end: CGPoint(x: CX, y: beamBot), options: [])
    ctx.restoreGState()

    // 底部光池：压扁的柔光，不是实体
    ctx.saveGState(); clipTile(ctx)
    let pool = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [c(0x9FEDE2, 0.46), c(0x45D6C4, 0)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.translateBy(x: CX, y: tile.minY + 168)
    ctx.scaleBy(x: 1, y: 0.32)
    ctx.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 275, options: [])
    ctx.restoreGState(); ctx.restoreGState()

    // 栏里的光源 + 光源光晕（把栏和光束连起来）
    statusItem(ctx, itemR)
    glow(ctx, CGPoint(x: CX, y: beamTop), r: 175, color: 0xFFFFFF, alpha: 0.44)
}

// ── 输出 ──────────────────────────────────────────────────────
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
beamIcon(ctx)
NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("已生成 \(out)  \(Int(S))×\(Int(S))")
