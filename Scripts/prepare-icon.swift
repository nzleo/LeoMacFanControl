#!/usr/bin/env swift
//
//  prepare-icon.swift —— 把位图素材处理成 App 图标的大尺寸切片。
//
//  这是叠加在 make-icon.swift 之上的一层：make-icon.swift 先用纯代码画出全部
//  10 个尺寸，本脚本再把 128 像素及以上的尺寸替换成位图版，最后重跑 iconutil。
//  小尺寸（16/32/64）刻意保留代码绘制版——原因见 README 的图标一节。
//
//  三件必须做的事：
//   1. 源图没有 alpha 通道、四角是纯黑。直接进 .icns 的话 Finder / Dock 里会是
//      黑方块托着圆角蓝底，所以必须先抠成透明。
//   2. 圆角方形的边界靠逐像素扫描测量，不硬编码——换一张素材也不用改代码。
//   3. 遮罩用超椭圆（Lamé 曲线），指数 n 由二分法解出，使其最小曲率半径
//      等于 Big Sur 的 22.37% 圆角比例。没有魔法常数。
//
//  用法：swift Scripts/prepare-icon.swift <源PNG> <iconset目录> [README用PNG输出路径]
//
//  只用 AppKit / CoreGraphics，无网络访问。
//
import AppKit
import Foundation

// MARK: - 工具

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("prepare-icon: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

/// 把任意 PNG 读成可逐像素访问的 RGBA8 位图（非预乘，deviceRGB）
func loadRGBA(_ url: URL) -> NSBitmapImageRep? {
    guard let src = NSImage(contentsOf: url) else { return nil }
    let w = Int(src.size.width.rounded()), h = Int(src.size.height.rounded())
    // NSImage.size 对某些 PNG 会返回点数而非像素数，优先取原始 rep 的像素尺寸
    var pw = w, ph = h
    if let r = src.representations.first { pw = r.pixelsWide; ph = r.pixelsHigh }

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pw, pixelsHigh: ph,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pw, height: ph)
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    gc.imageInterpolation = .high
    src.draw(in: NSRect(x: 0, y: 0, width: pw, height: ph),
             from: .zero, operation: .copy, fraction: 1.0)
    gc.flushGraphics()
    NSGraphicsContext.current = saved
    return rep
}

/// 取像素（左上原点坐标系）
@inline(__always)
func px(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    guard let base = rep.bitmapData else { return (0, 0, 0, 0) }
    let p = base + y * rep.bytesPerRow + x * (rep.bitsPerPixel / 8)
    return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
}

@inline(__always)
func luma(_ r: Int, _ g: Int, _ b: Int) -> Double {
    0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
}

// MARK: - 边界测量

/// 扫描出「亮度 > threshold」像素的包围盒。
/// 源图的圆角方外面有一圈深色投影，阈值太低会把投影也框进来，
/// 所以这里对多个阈值各测一遍，让分界点自己显形。
func boundingBox(_ rep: NSBitmapImageRep, threshold: Double) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h {
        for x in 0..<w {
            let c = px(rep, x, y)
            if c.a > 8 && luma(c.r, c.g, c.b) > threshold {
                if x < x0 { x0 = x }
                if y < y0 { y0 = y }
                if x > x1 { x1 = x }
                if y > y1 { y1 = y }
            }
        }
    }
    return x1 >= x0 && y1 >= y0 ? (x0, y0, x1, y1) : nil
}

// MARK: - 超椭圆（squircle）

/// 超椭圆采样点：(|x|/a)^n + (|y|/a)^n = 1，以原点为中心。
func superellipse(a: Double, n: Double, samples: Int) -> [CGPoint] {
    var pts: [CGPoint] = []
    pts.reserveCapacity(samples)
    let two = 2.0 / n
    for i in 0..<samples {
        let t = Double(i) / Double(samples) * 2 * Double.pi
        let ct = cos(t), st = sin(t)
        // 保号的 |cos|^(2/n)，把第一象限的曲线镜像到四个象限
        let x = a * copysign(pow(abs(ct), two), ct)
        let y = a * copysign(pow(abs(st), two), st)
        pts.append(CGPoint(x: x, y: y))
    }
    return pts
}

/// 离散最小曲率半径：取连续三点的外接圆半径的最小值。
/// 超椭圆（n>2）的曲率在 45° 对角线附近最大，即半径最小，那里就是"圆角"。
func minCurvatureRadius(_ pts: [CGPoint]) -> Double {
    var best = Double.greatestFiniteMagnitude
    let n = pts.count
    // 采样步长取大一点，避免相邻点过近导致数值噪声
    let step = max(1, n / 360)
    for i in stride(from: 0, to: n, by: step) {
        let p0 = pts[(i - step + n) % n], p1 = pts[i], p2 = pts[(i + step) % n]
        let a = hypot(p1.x - p0.x, p1.y - p0.y)
        let b = hypot(p2.x - p1.x, p2.y - p1.y)
        let c = hypot(p2.x - p0.x, p2.y - p0.y)
        // 海伦公式求面积，再由 R = abc / 4A 得外接圆半径
        let s = (a + b + c) / 2
        let area2 = s * (s - a) * (s - b) * (s - c)
        guard area2 > 1e-12 else { continue }
        let r = a * b * c / (4 * sqrt(area2))
        if r.isFinite && r > 0 { best = min(best, r) }
    }
    return best
}

/// 二分求指数 n，使超椭圆的最小曲率半径等于 targetRadius。
/// n 越大越方（圆角半径越小），所以半径对 n 单调递减。
func solveExponent(a: Double, targetRadius: Double) -> (n: Double, achieved: Double) {
    var lo = 2.0, hi = 16.0
    var n = 4.0, achieved = 0.0
    for _ in 0..<60 {
        n = (lo + hi) / 2
        achieved = minCurvatureRadius(superellipse(a: a, n: n, samples: 2880))
        if achieved > targetRadius { lo = n } else { hi = n }
    }
    return (n, achieved)
}

func superellipsePath(center c: CGPoint, a: Double, n: Double) -> NSBezierPath {
    let pts = superellipse(a: a, n: n, samples: 1440)
    let p = NSBezierPath()
    p.move(to: CGPoint(x: c.x + pts[0].x, y: c.y + pts[0].y))
    for q in pts.dropFirst() { p.line(to: CGPoint(x: c.x + q.x, y: c.y + q.y)) }
    p.close()
    return p
}

// MARK: - 主流程

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("用法：swift prepare-icon.swift <源PNG> <iconset目录> [README用PNG输出路径]")
}
let srcURL = URL(fileURLWithPath: args[1])
let iconsetDir = URL(fileURLWithPath: args[2], isDirectory: true)
let readmeOut: URL? = args.count >= 4 ? URL(fileURLWithPath: args[3]) : nil

let fm = FileManager.default
guard fm.fileExists(atPath: srcURL.path) else { fail("找不到源图：\(srcURL.path)") }
guard fm.fileExists(atPath: iconsetDir.path) else { fail("找不到 iconset 目录：\(iconsetDir.path)") }

guard let src = loadRGBA(srcURL) else { fail("无法读取源图") }
let SW = src.pixelsWide, SH = src.pixelsHigh
print("==> 源图：\(SW)×\(SH)，原始 alpha：\(src.hasAlpha ? "有" : "无")")

// ── 1. 多阈值测量边界
print("==> 圆角方边界测量（逐像素扫描非黑像素）：")
var chosen: (x0: Int, y0: Int, x1: Int, y1: Int)?
for t in [4.0, 8.0, 16.0, 24.0, 32.0, 48.0, 64.0] {
    guard let b = boundingBox(src, threshold: t) else {
        print("    阈值 \(Int(t))：无匹配像素")
        continue
    }
    let w = b.x1 - b.x0 + 1, h = b.y1 - b.y0 + 1
    print("    阈值 \(Int(t))：x \(b.x0)…\(b.x1)  y \(b.y0)…\(b.y1)  →  \(w)×\(h)")
    // 取 32 作为工作阈值：足以跳过投影，又不会切掉圆角方本体的暗边
    if Int(t) == 32 { chosen = b }
}
guard let bb = chosen else { fail("边界测量失败") }
let bw = bb.x1 - bb.x0 + 1, bh = bb.y1 - bb.y0 + 1
print("    采用阈值 32 的结果：\(bw)×\(bh)，左上 (\(bb.x0), \(bb.y0))")

// 精确用测得的包围盒，不强行按长边裁成正方形。
// 这张素材的圆角方是 685×662（略扁），按长边裁会把包围盒之外的黑色行也圈进来，
// 而超椭圆在上下边中点几乎顶满内容框，那些黑行就会变成肉眼可见的黑带。
// 改成把包围盒拉伸填满正方形内容框：垂直方向拉伸不到 4%，卡通图上完全看不出来，
// 但能保证蓝色铺满遮罩、不可能残留黑边。
let cropX = bb.x0, cropY = bb.y0
let cropW = bw, cropH = bh
print("==> 裁剪区：\(cropW)×\(cropH)，左上 (\(cropX), \(cropY))")
print(String(format: "    拉伸填满正方形：横向 ×%.4f，纵向 ×%.4f",
             824.0 / Double(cropW), 824.0 / Double(cropH)))

// 采样底色，供比对代码绘制版的配色
do {
    let c = px(src, cropX + cropW / 2, cropY + Int(Double(cropH) * 0.08))
    print(String(format: "==> 顶部底色采样：#%02X%02X%02X", c.r, c.g, c.b))
    let c2 = px(src, cropX + cropW / 2, cropY + Int(Double(cropH) * 0.95))
    print(String(format: "==> 底部底色采样：#%02X%02X%02X", c2.r, c2.g, c2.b))
}

// ── 2. 解超椭圆指数
// macOS Big Sur 图标规范：1024 画布里内容占 824（四周留白 9.77%），
// 圆角半径为内容宽度的 22.37%。代码绘制版用的是同一组比例，
// 两边保持一致才不会在 64→128 的尺寸交界处看到明显跳变。
let MASTER = 1024.0
let INSET_RATIO = 0.0977
let RADIUS_RATIO = 0.2237
let contentSide = MASTER * (1 - INSET_RATIO * 2)
let MASK_INSET = 1.5     // 稍微内收，避免源图圆角与遮罩不完全吻合时留下黑边残留
let a = contentSide / 2 - MASK_INSET
let target = contentSide * RADIUS_RATIO
let solved = solveExponent(a: a, targetRadius: target)
print(String(format: "==> 超椭圆遮罩：内容边长 %.0f，目标圆角半径 %.1f（%.2f%%）",
             contentSide, target, RADIUS_RATIO * 100))
print(String(format: "    解出指数 n = %.4f，实测最小曲率半径 %.1f（偏差 %.2f%%）",
             solved.n, solved.achieved, abs(solved.achieved - target) / target * 100))

// ── 3. 合成 1024 主图（透明背景 + 超椭圆遮罩）
guard let master = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: Int(MASTER), pixelsHigh: Int(MASTER),
                                    bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0) else {
    fail("无法创建主图缓冲")
}
master.size = NSSize(width: MASTER, height: MASTER)
guard let mgc = NSGraphicsContext(bitmapImageRep: master) else { fail("无法创建绘图上下文") }
do {
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = mgc
    mgc.imageInterpolation = .high
    mgc.cgContext.clear(CGRect(x: 0, y: 0, width: MASTER, height: MASTER))

    let inset = MASTER * INSET_RATIO
    let contentRect = CGRect(x: inset, y: inset, width: contentSide, height: contentSide)
    let center = CGPoint(x: contentRect.midX, y: contentRect.midY)

    mgc.cgContext.saveGState()
    superellipsePath(center: center, a: a, n: solved.n).addClip()

    // 源图裁剪区 → 内容框。NSImage 的 from: 用左下原点，故 y 需翻转
    let flippedY = SH - cropY - cropH
    let srcImage = NSImage(size: NSSize(width: SW, height: SH))
    srcImage.addRepresentation(src)
    srcImage.draw(in: contentRect,
                  from: NSRect(x: cropX, y: flippedY, width: cropW, height: cropH),
                  operation: .sourceOver, fraction: 1.0)
    mgc.cgContext.restoreGState()
    mgc.flushGraphics()
    NSGraphicsContext.current = saved
}

// ── 4. 复检：四角 alpha + 全图"不透明近黑像素"计数
print("==> 透明化复检：")
let corners = [("左上", 0, 0), ("右上", Int(MASTER) - 1, 0),
               ("左下", 0, Int(MASTER) - 1), ("右下", Int(MASTER) - 1, Int(MASTER) - 1)]
for (name, x, y) in corners {
    print("    画布\(name)角 alpha = \(px(master, x, y).a)")
}
let ci = Int(MASTER * INSET_RATIO)
let cj = Int(MASTER * INSET_RATIO + contentSide) - 1
for (name, x, y) in [("左上", ci, ci), ("右上", cj, ci), ("左下", ci, cj), ("右下", cj, cj)] {
    print("    内容框\(name)角 alpha = \(px(master, x, y).a)")
}
// 光数"全图有多少近黑像素"没有意义：这张素材本身就有黑眼睛和接近黑的深蓝描边。
// 要把「源图残留的黑底」和「素材自带的深色」区分开，靠的是色度而不是亮度：
//   · 残留的黑底来自源图四角的纯黑 (0,0,0)，是中性色，R≈G≈B
//   · 素材自带的深色边框是深蓝 (0,21,141) 这类，蓝通道远高于红通道
// 所以判定条件是「亮度低 且 接近中性」。再按超椭圆隐函数
// f = (|x|/a)^n + (|y|/a)^n 分出贴边区（f>0.85），只有贴边区出现中性近黑才算残留。
do {
    let inset = MASTER * INSET_RATIO
    let ccx = inset + contentSide / 2, ccy = inset + contentSide / 2
    var edgeTotal = 0, edgeNeutralBlack = 0, edgeDarkChroma = 0, innerDark = 0
    var worstEdge: (x: Int, y: Int, r: Int, g: Int, b: Int)? = nil
    for y in 0..<Int(MASTER) {
        for x in 0..<Int(MASTER) {
            let c = px(master, x, y)
            guard c.a > 128 else { continue }
            let dark = luma(c.r, c.g, c.b) < 20
            let chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
            let dx = abs(Double(x) + 0.5 - ccx), dy = abs(Double(y) + 0.5 - ccy)
            let f = pow(dx / a, solved.n) + pow(dy / a, solved.n)
            if f > 0.85 {
                edgeTotal += 1
                if dark {
                    if chroma < 12 {
                        edgeNeutralBlack += 1
                        if worstEdge == nil { worstEdge = (x, y, c.r, c.g, c.b) }
                    } else {
                        edgeDarkChroma += 1
                    }
                }
            } else if dark {
                innerDark += 1
            }
        }
    }
    print("    遮罩贴边区（f>0.85）不透明像素：\(edgeTotal)")
    print("      ├─ 中性近黑（= 源图黑底残留）：\(edgeNeutralBlack)")
    print("      └─ 有色近黑（= 素材自带深蓝描边）：\(edgeDarkChroma)")
    print("    内部近黑像素：\(innerDark)（黑眼睛与深色描边，属正常内容）")
    if edgeNeutralBlack == 0 {
        print("    ✅ 遮罩边界无黑底残留")
    } else if let w = worstEdge {
        print("    ⚠️ 贴边区有 \(edgeNeutralBlack) 个中性近黑像素，"
            + "例如 (\(w.x), \(w.y)) = rgb(\(w.r), \(w.g), \(w.b))，需加大 MASK_INSET")
    }
}

guard let masterPNG = master.representation(using: .png, properties: [:]) else {
    fail("主图编码失败")
}

// ── 5. 只覆盖 128 像素及以上的尺寸
// 小尺寸留给代码绘制版：这张素材细节太密（笑脸、冰块、滑块上的红黄绿圆点），
// 缩到 16/32 像素会糊成一团色斑，而代码版在 ≤32 像素时会切换成
// 4 片粗叶、去投影的简化几何，轮廓明显更清楚。
let bitmapSizes: [(name: String, px: Int)] = [
    ("icon_128x128.png",     128),
    ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256),
    ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512),
    ("icon_512x512@2x.png", 1024),
]

let masterImage = NSImage(size: NSSize(width: MASTER, height: MASTER))
masterImage.addRepresentation(master)

/// 从 1024 主图高质量缩放出指定像素尺寸
func scaled(to n: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: n, pixelsHigh: n,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: n, height: n)
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    gc.imageInterpolation = .high      // Lanczos 级别的高质量重采样
    gc.cgContext.clear(CGRect(x: 0, y: 0, width: n, height: n))
    masterImage.draw(in: NSRect(x: 0, y: 0, width: n, height: n),
                     from: .zero, operation: .sourceOver, fraction: 1.0)
    gc.flushGraphics()
    NSGraphicsContext.current = saved
    return rep
}

for v in bitmapSizes {
    let data: Data?
    if v.px == Int(MASTER) {
        data = masterPNG
    } else {
        data = scaled(to: v.px)?.representation(using: .png, properties: [:])
    }
    guard let d = data else { fail("生成 \(v.name) 失败") }
    do { try d.write(to: iconsetDir.appendingPathComponent(v.name)) }
    catch { fail("写入 \(v.name) 失败：\(error)") }
}
print("==> 已用位图版覆盖 \(bitmapSizes.count) 个尺寸（128px 及以上）")
print("    16 / 32 / 64 像素保留代码绘制版")

// README 展示用的 256px
if let out = readmeOut {
    guard let d = scaled(to: 256)?.representation(using: .png, properties: [:]) else {
        fail("生成 README 图标失败")
    }
    try? fm.createDirectory(at: out.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    do { try d.write(to: out); print("==> README 图标：\(out.path)") }
    catch { fail("写入 README 图标失败：\(error)") }
}

// ── 6. 重跑 iconutil
let icns = iconsetDir.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
do {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconsetDir.path, "-o", icns.path]
    let ep = Pipe(); p.standardError = ep
    try p.run(); p.waitUntilExit()
    let e = ep.fileHandleForReading.readDataToEndOfFile()
    guard p.terminationStatus == 0 else {
        FileHandle.standardError.write(e)
        fail("iconutil 失败（\(p.terminationStatus)）")
    }
} catch { fail("无法执行 iconutil：\(error)") }
let icnsBytes = ((try? fm.attributesOfItem(atPath: icns.path))?[.size] as? Int) ?? 0
print("==> AppIcon.icns 已重建（\(icnsBytes) 字节）")

// ── 7. 让系统解析一次 .icns，确认不是"文件能写但系统读不出来"
let sysIcon = NSWorkspace.shared.icon(forFile: icns.path)
print("==> NSWorkspace 解析 .icns：\(sysIcon.representations.count) 个 representation")
if let parsed = NSImage(contentsOf: icns) {
    let sizes = parsed.representations
        .map { "\($0.pixelsWide)" }
        .sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        .joined(separator: ", ")
    print("==> .icns 内含尺寸：\(sizes)")
    if parsed.representations.isEmpty { fail(".icns 解析出 0 个尺寸") }
} else {
    fail("NSImage 无法解析生成的 .icns")
}

// ── 8. 拼版预览，便于肉眼检查各尺寸
let previewDir = URL(fileURLWithPath: "/tmp/iconcheck", isDirectory: true)
try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
do {
    let shown = [16, 32, 64, 128, 256, 512]
    let pad = 24, label = 22
    let cellW = shown.reduce(0) { $0 + $1 + pad }
    let maxH = (shown.max() ?? 512) + pad * 2 + label
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: cellW + pad, pixelsHigh: maxH,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        fail("无法创建预览缓冲")
    }
    rep.size = NSSize(width: cellW + pad, height: maxH)
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { fail("预览上下文失败") }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    gc.imageInterpolation = .high
    // 中灰底：透明区域若有黑边残留，在灰底上一眼就能看出来
    NSColor(white: 0.55, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: cellW + pad, height: maxH).fill()

    var x = pad
    for s in shown {
        // 直接读 iconset 里的实际文件，确保预览反映的是最终产物
        let file: String
        switch s {
        case 16:  file = "icon_16x16.png"
        case 32:  file = "icon_32x32.png"
        case 64:  file = "icon_32x32@2x.png"
        case 128: file = "icon_128x128.png"
        case 256: file = "icon_256x256.png"
        default:  file = "icon_512x512.png"
        }
        if let img = NSImage(contentsOf: iconsetDir.appendingPathComponent(file)) {
            img.draw(in: NSRect(x: x, y: maxH - pad - s, width: s, height: s),
                     from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let tag = "\(s)px" + (s <= 64 ? " 代码" : " 位图")
        NSAttributedString(string: tag, attributes: attrs)
            .draw(at: NSPoint(x: x, y: maxH - pad - s - label))
        x += s + pad
    }
    gc.flushGraphics()
    NSGraphicsContext.current = saved

    let out = previewDir.appendingPathComponent("preview.png")
    if let d = rep.representation(using: .png, properties: [:]) {
        try? d.write(to: out)
        print("==> 拼版预览：\(out.path)")
    }
}

// 小尺寸放大版：16/32/64 在 1:1 下根本看不清，放大 6 倍才能判断轮廓是否糊掉。
// 用最近邻插值，保持像素边界清晰，看到的就是系统真正显示的那些像素。
do {
    let items = [("icon_16x16.png", 16), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64)]
    let zoom = 6, pad = 20, label = 24
    let cellSide = 64 * zoom
    let W = items.count * (cellSide + pad) + pad
    let H = cellSide + pad * 2 + label
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: W, pixelsHigh: H,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { exit(0) }
    rep.size = NSSize(width: W, height: H)
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { exit(0) }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    gc.imageInterpolation = .none      // 最近邻，看清每个像素
    NSColor(white: 0.55, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    var x = pad
    for (file, s) in items {
        let drawn = s * zoom
        if let img = NSImage(contentsOf: iconsetDir.appendingPathComponent(file)) {
            img.draw(in: NSRect(x: x, y: H - pad - drawn, width: drawn, height: drawn),
                     from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        NSAttributedString(string: "\(s)px ×\(zoom) 代码绘制", attributes: attrs)
            .draw(at: NSPoint(x: x, y: H - pad - drawn - label))
        x += cellSide + pad
    }
    gc.flushGraphics()
    NSGraphicsContext.current = saved

    let out = previewDir.appendingPathComponent("preview-small.png")
    if let d = rep.representation(using: .png, properties: [:]) {
        try? d.write(to: out)
        print("==> 小尺寸放大预览：\(out.path)")
    }
}
