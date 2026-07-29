#!/usr/bin/env swift
//
//  make-icon.swift —— 生成 App 图标（AppIcon.icns）
//
//  纯代码矢量绘制，不依赖任何外部图片素材，可逐行审计。
//  由 build-app.sh 在打包时调用；产物不进版本库。
//
//  设计：圆角方底 + 冷色渐变（呼应"散热"）+ 风扇叶片剪影 + 中心轴盖。
//
//  用法：swift Scripts/make-icon.swift <输出目录>
//        在 <输出目录> 下生成 AppIcon.iconset/ 与 AppIcon.icns
//
//  只用 AppKit / CoreGraphics，无网络访问。
//

import AppKit
import Foundation

// MARK: - 绘制

/// 画一片扇叶：从轴心附近向外张开、带弧度的叶形。
/// - Parameters:
///   - angle: 叶片朝向（弧度）
///   - r0/r1: 叶片起止半径
///   - spread: 叶片在外缘的张角（弧度）
///   - curl: 弧度强度，正值让叶片顺时针弯曲，制造"转动"的观感
func bladePath(center c: CGPoint, angle: CGFloat, r0: CGFloat, r1: CGFloat,
               spread: CGFloat, curl: CGFloat) -> NSBezierPath {
    func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
        CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }
    let p = NSBezierPath()
    let rootA = angle - spread * 0.10
    let rootB = angle + spread * 0.10
    let tipA = angle - spread * 0.5 + curl
    let tipB = angle + spread * 0.5 + curl

    p.move(to: pt(r0, rootA))
    p.curve(to: pt(r1, tipA),
            controlPoint1: pt(r0 + (r1 - r0) * 0.35, rootA + curl * 0.30),
            controlPoint2: pt(r0 + (r1 - r0) * 0.75, tipA - curl * 0.25))
    p.appendArc(withCenter: c, radius: r1,
                startAngle: tipA * 180 / .pi, endAngle: tipB * 180 / .pi,
                clockwise: false)
    p.curve(to: pt(r0, rootB),
            controlPoint1: pt(r0 + (r1 - r0) * 0.75, tipB - curl * 0.25),
            controlPoint2: pt(r0 + (r1 - r0) * 0.35, rootB + curl * 0.30))
    p.close()
    return p
}

/// 按给定像素边长绘制图标。
/// 几何简化以「像素数」而非「逻辑点数」为准：16x16@2x 是 32 像素，
/// 细节预算就按 32 像素给，所以调用方必须传真实像素数。
func drawIcon(pixels S: CGFloat, into ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS 图标规范：内容不铺满画布，四周留白给系统加投影
    let inset = S * 0.0977
    let box = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = box.width * 0.2237   // Big Sur 之后的圆角比例

    let bg = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    let cs = CGColorSpaceCreateDeviceRGB()

    // ── 底：冷色渐变，左上偏亮
    ctx.saveGState()
    bg.addClip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.36, green: 0.72, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.13, green: 0.42, blue: 0.86, alpha: 1).cgColor,
        NSColor(srgbRed: 0.07, green: 0.24, blue: 0.60, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: box.minX, y: box.maxY),
                           end: CGPoint(x: box.maxX, y: box.minY),
                           options: [])

    // 顶部高光，模拟系统图标的玻璃质感；小尺寸省略，否则只会脏画面
    if S > 32 {
        let gloss = CGGradient(colorsSpace: cs, colors: [
            NSColor(white: 1, alpha: 0.28).cgColor,
            NSColor(white: 1, alpha: 0.0).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gloss,
                               start: CGPoint(x: box.midX, y: box.maxY),
                               end: CGPoint(x: box.midX, y: box.midY + box.height * 0.05),
                               options: [])
    }
    ctx.restoreGState()

    // ── 扇叶
    // 小尺寸不能把大图直接缩下去：叶片会细到消失、轴盖占比过大糊成一团。
    // ≤32 像素时改用更少更粗的叶片、更小的轴盖，并去掉投影。
    let tiny = S <= 32
    let small = S <= 64
    let c = CGPoint(x: box.midX, y: box.midY)
    let rOuter = box.width * (tiny ? 0.395 : 0.355)
    let rInner = box.width * (tiny ? 0.050 : 0.072)
    let blades = tiny ? 4 : 5
    let spreadK: CGFloat = tiny ? 0.72 : 0.86
    let curl: CGFloat = tiny ? 0.20 : 0.30

    ctx.saveGState()
    if !small {
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.006),
                      blur: S * 0.018,
                      color: NSColor(srgbRed: 0.02, green: 0.12, blue: 0.35, alpha: 0.45).cgColor)
    }
    for i in 0..<blades {
        let a = CGFloat(i) * (.pi * 2 / CGFloat(blades)) + .pi / 2
        let path = bladePath(center: c, angle: a, r0: rInner, r1: rOuter,
                             spread: .pi * 2 / CGFloat(blades) * spreadK,
                             curl: curl)
        NSColor(white: 1, alpha: tiny ? 1.0 : 0.95).setFill()
        path.fill()
    }
    ctx.restoreGState()

    // ── 中心轴盖
    let hubR = box.width * (tiny ? 0.062 : 0.088)
    let hub = NSBezierPath(ovalIn: CGRect(x: c.x - hubR, y: c.y - hubR,
                                          width: hubR * 2, height: hubR * 2))
    ctx.saveGState()
    hub.addClip()
    let hubGrad = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.97, green: 0.99, blue: 1.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0.72, green: 0.85, blue: 0.96, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hubGrad,
                           start: CGPoint(x: c.x - hubR, y: c.y + hubR),
                           end: CGPoint(x: c.x + hubR, y: c.y - hubR),
                           options: [])
    ctx.restoreGState()

    // ── 外描边，小尺寸下保住轮廓
    NSColor(srgbRed: 0.04, green: 0.16, blue: 0.42, alpha: 0.30).setStroke()
    bg.lineWidth = max(1, S * 0.004)
    bg.stroke()
}

// MARK: - 精确像素输出

/// 渲染成精确 `px × px` 像素的 PNG。
/// 不用 `NSImage.lockFocus()`：它在 Retina 屏上会按 backing scale 自动放大，
/// 得到的位图尺寸不可控（16 点会变成 32 像素），iconutil 会因尺寸不符报错。
func renderPNG(pixels px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: px, height: px)   // 1 点 = 1 像素

    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    drawIcon(pixels: CGFloat(px), into: gc.cgContext)
    gc.flushGraphics()
    NSGraphicsContext.current = saved

    return rep.representation(using: .png, properties: [:])
}

// MARK: - 主流程

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法：swift make-icon.swift <输出目录>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)

let fm = FileManager.default
try? fm.removeItem(at: iconset)
do {
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write("无法创建 \(iconset.path)：\(error)\n".data(using: .utf8)!)
    exit(1)
}

/// iconutil 要求的文件名与像素尺寸对应关系
let variants: [(name: String, px: Int)] = [
    ("icon_16x16.png",        16),
    ("icon_16x16@2x.png",     32),
    ("icon_32x32.png",        32),
    ("icon_32x32@2x.png",     64),
    ("icon_128x128.png",     128),
    ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256),
    ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512),
    ("icon_512x512@2x.png", 1024),
]

for v in variants {
    guard let png = renderPNG(pixels: v.px) else {
        FileHandle.standardError.write("渲染 \(v.name) 失败\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try png.write(to: iconset.appendingPathComponent(v.name))
    } catch {
        FileHandle.standardError.write("写入 \(v.name) 失败：\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
print("==> 已生成 \(variants.count) 个尺寸")

// 调用系统自带的 iconutil 合成 .icns
let icns = outDir.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
let errPipe = Pipe()
proc.standardError = errPipe
do {
    try proc.run()
} catch {
    FileHandle.standardError.write("无法执行 iconutil：\(error)\n".data(using: .utf8)!)
    exit(1)
}
proc.waitUntilExit()
let errOut = errPipe.fileHandleForReading.readDataToEndOfFile()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败（\(proc.terminationStatus)）：\n".data(using: .utf8)!)
    FileHandle.standardError.write(errOut)
    exit(1)
}

let bytes = ((try? fm.attributesOfItem(atPath: icns.path))?[.size] as? Int) ?? 0
print("==> AppIcon.icns 已生成（\(bytes) 字节）")
