#!/usr/bin/env swift
//
//  crop-screenshots.swift —— 从一张整屏截图里自动裁出 README 用的配图。
//
//  为什么要自动检测而不是写死坐标：换一张截图（不同分辨率、面板位置不同、
//  壁纸不同）就得重新量坐标，写死等于一次性脚本。这里改成按图像特征找边界。
//
//  检测思路：
//   · 菜单栏是屏幕顶部一条横贯全宽的半透明暗带，先按"整行都偏暗"找出它的下边缘。
//   · 控制面板是浮在壁纸上的圆角暗色弹窗。壁纸（雪山蓝天）明显更亮且更蓝，
//     所以用"暗且低饱和"做掩膜，再用行/列投影定位面板矩形。
//     投影法对单个矩形目标足够稳，比连通域分析简单得多。
//
//  用法：swift Scripts/crop-screenshots.swift <源截图> <输出目录>
//
//  只用 AppKit / CoreGraphics，无网络访问。
//
import AppKit
import Foundation

func fail(_ m: String) -> Never {
    FileHandle.standardError.write("crop-screenshots: \(m)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 读图

func loadRGBA(_ url: URL) -> NSBitmapImageRep? {
    guard let img = NSImage(contentsOf: url),
          let first = img.representations.first else { return nil }
    let w = first.pixelsWide, h = first.pixelsHigh
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: w, height: h)
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
             from: .zero, operation: .copy, fraction: 1.0)
    gc.flushGraphics()
    NSGraphicsContext.current = saved
    return rep
}

@inline(__always)
func px(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    guard let b = r.bitmapData else { return (0, 0, 0) }
    let p = b + y * r.bytesPerRow + x * (r.bitsPerPixel / 8)
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

@inline(__always)
func luma(_ c: (r: Int, g: Int, b: Int)) -> Double {
    0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)
}

/// 饱和度（HSV 的 S，0~1）。壁纸的蓝天饱和度高，面板是中性灰。
@inline(__always)
func sat(_ c: (r: Int, g: Int, b: Int)) -> Double {
    let mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b))
    return mx == 0 ? 0 : Double(mx - mn) / Double(mx)
}

// MARK: - 主流程

let args = CommandLine.arguments
guard args.count >= 3 else { fail("用法：swift crop-screenshots.swift <源截图> <输出目录>") }
let srcURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let fm = FileManager.default
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let src = loadRGBA(srcURL) else { fail("无法读取源图") }
let W = src.pixelsWide, H = src.pixelsHigh
print("==> 源图：\(W)×\(H)")

// ── 1. 找菜单栏下边缘
// 菜单栏横贯全宽且整体偏暗（半透明黑覆盖在壁纸上）。
// 逐行算平均亮度，从顶部往下找第一处"亮度显著跳升"的位置，那就是菜单栏底边。
var rowLuma = [Double](repeating: 0, count: H)
for y in 0..<H {
    var s = 0.0
    for x in 0..<W { s += luma(px(src, x, y)) }
    rowLuma[y] = s / Double(W)
}
print("==> 顶部若干行平均亮度：" + (0..<min(40, H)).map { String(format: "%.0f", rowLuma[$0]) }
        .enumerated().filter { $0.offset % 4 == 0 }.map { $0.element }.joined(separator: " "))

var menubarBottom = 0
// 菜单栏一定在很靠上的位置，只在前 8% 高度里找
let searchLimit = max(12, Int(Double(H) * 0.08))
let topAvg = rowLuma[0..<min(6, H)].reduce(0, +) / Double(min(6, H))
for y in 1..<searchLimit {
    // 相邻行亮度跳升超过 18，且已经比顶部明显亮，判为出了菜单栏
    if rowLuma[y] - rowLuma[y - 1] > 18 && rowLuma[y] > topAvg + 15 {
        menubarBottom = y
        break
    }
}
if menubarBottom == 0 {
    // 兜底：找前 searchLimit 行里亮度梯度最大的位置
    var bestG = 0.0
    for y in 1..<searchLimit where rowLuma[y] - rowLuma[y - 1] > bestG {
        bestG = rowLuma[y] - rowLuma[y - 1]; menubarBottom = y
    }
}
print("==> 菜单栏下边缘：y = \(menubarBottom)（该行亮度 \(String(format: "%.0f", rowLuma[menubarBottom]))，"
    + "上一行 \(String(format: "%.0f", rowLuma[menubarBottom - 1]))）")

// ── 2. 找控制面板边界
//
// 先说一个实测推翻的假设：这个面板**不是**中性灰低饱和。实测面板内部是
// rgb(0,63,98)、饱和度 1.00——macOS 的深色毛玻璃把背后的蓝天透了上来，
// 面板和壁纸都是高饱和蓝色，所以饱和度完全没有区分力。
// 有区分力的是亮度：面板内部约 52，同高度的壁纸约 78~190。
//
// 但也不能用一个绝对亮度阈值：壁纸从上到下有渐变（天空 78 → 雪山 190），
// 换张壁纸就得重新调。改成**逐行局部对比**——把面板列的平均亮度和
// 同一行壁纸的平均亮度相比，面板显著更暗即判为面板行。这样自动免疫
// 壁纸的明暗分布，也不依赖任何写死的阈值。
let panelSearchTop = menubarBottom + 2

// 第 1 步：粗定列。阈值取"菜单栏以下区域亮度的 25 百分位"，
// 面板是画面里最大的暗区，这个分位数会自然落在面板亮度附近。
var lumaSamples: [Double] = []
lumaSamples.reserveCapacity((H - panelSearchTop) * W / 16)
for y in stride(from: panelSearchTop, to: H, by: 2) {
    for x in stride(from: 0, to: W, by: 2) { lumaSamples.append(luma(px(src, x, y))) }
}
lumaSamples.sort()
let darkThresh = lumaSamples[lumaSamples.count / 4]
print(String(format: "==> 暗区阈值（P25）：%.1f", darkThresh))

var colCount = [Int](repeating: 0, count: W)
for x in 0..<W {
    var n = 0
    for y in panelSearchTop..<H where luma(px(src, x, y)) <= darkThresh { n += 1 }
    colCount[x] = n
}
let maxCol = colCount.max() ?? 0
guard maxCol > 0 else { fail("未检测到面板区域") }
let colThresh = Int(Double(maxCol) * 0.55)
var px0 = W, px1 = -1
for x in 0..<W where colCount[x] >= colThresh {
    if x < px0 { px0 = x }
    if x > px1 { px1 = x }
}
guard px1 > px0 else { fail("面板列定位失败") }

// 第 2 步：用局部对比定行。参考条取面板右侧一段纯壁纸区域。
let refStart = min(W - 1, px1 + 40)
let refEnd = min(W - 1, px1 + 160)
guard refEnd > refStart else { fail("找不到壁纸参考条（面板太靠右？）") }
func rowMean(_ y: Int, _ x0: Int, _ x1: Int) -> Double {
    var s = 0.0
    for x in x0...x1 { s += luma(px(src, x, y)) }
    return s / Double(x1 - x0 + 1)
}
let MARGIN = 15.0   // 实测面板与同行壁纸的亮度差始终 > 20，留 15 的判定余量
var py0 = H, py1 = -1
for y in panelSearchTop..<H {
    if rowMean(y, px0, px1) < rowMean(y, refStart, refEnd) - MARGIN {
        if y < py0 { py0 = y }
        if y > py1 { py1 = y }
    }
}
guard py1 > py0 else { fail("面板行定位失败") }

print("==> 面板检测结果：x \(px0)…\(px1)，y \(py0)…\(py1)  →  "
    + "\((px1 - px0 + 1))×\((py1 - py0 + 1))")
print("    列阈值 \(colThresh)/\(maxCol)；行判据 = 面板列均值 < 壁纸参考条(x \(refStart)…\(refEnd))均值 − \(Int(MARGIN))")
print(String(format: "    抽样对比 y=300：面板 %.1f  vs  壁纸 %.1f",
             rowMean(300, px0, px1), rowMean(300, refStart, refEnd)))

// ── 3. 裁图工具
/// 从源图裁一块并按 scale 缩放输出。scale=1 表示原生像素、不做任何重采样。
func crop(_ rect: CGRect, scale: Int, to name: String, interpolation: NSImageInterpolation = .high) {
    let x = max(0, Int(rect.minX)), y = max(0, Int(rect.minY))
    let w = min(W - x, Int(rect.width)), h = min(H - y, Int(rect.height))
    guard w > 0, h > 0 else { fail("裁剪区非法：\(name)") }
    let ow = w * scale, oh = h * scale

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: ow, pixelsHigh: oh,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { fail("缓冲失败") }
    rep.size = NSSize(width: ow, height: oh)
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { fail("上下文失败") }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    gc.imageInterpolation = interpolation

    let img = NSImage(size: NSSize(width: W, height: H))
    img.addRepresentation(src)
    // NSImage 的 from: 用左下原点，y 需翻转
    let flippedY = H - y - h
    img.draw(in: NSRect(x: 0, y: 0, width: ow, height: oh),
             from: NSRect(x: x, y: flippedY, width: w, height: h),
             operation: .copy, fraction: 1.0)
    gc.flushGraphics()
    NSGraphicsContext.current = saved

    guard let d = rep.representation(using: .png, properties: [:]) else { fail("编码失败：\(name)") }
    let url = outDir.appendingPathComponent(name)
    do { try d.write(to: url) } catch { fail("写入失败 \(name)：\(error)") }
    let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    let note = scale == 1 ? "原生像素" : "放大 \(scale)×"
    print("==> \(name)：\(ow)×\(oh)（\(note)），\(bytes / 1024) KB")
}

// ── 4. 主图：面板本体 + 四周留 20px 桌面背景当呼吸感
//
// 上边界是个例外：面板是从菜单栏图标下方弹出的，紧贴菜单栏下沿，
// 中间根本不存在桌面背景可留。硬留 20px 会把菜单栏图标切掉半截，
// 比没有留白难看得多。所以上边留白只取到菜单栏下沿为止。
let BREATH = 20.0
let topPad = min(BREATH, Double(py0 - menubarBottom - 1))
let heroTop = Double(py0) - topPad
let hero = CGRect(x: Double(px0) - BREATH, y: heroTop,
                  width: Double(px1 - px0 + 1) + BREATH * 2,
                  height: Double(py1 - py0 + 1) + topPad + BREATH)
print("==> 主图留白：左右下各 \(Int(BREATH))px，上 \(Int(topPad))px（受菜单栏下沿 y=\(menubarBottom) 限制）")
// 源图是非 Retina 截图（72 DPI），放大只会糊，不会增加信息量 → 主图保持原生像素
crop(hero, scale: 1, to: "panel.png")

// ── 5. 菜单栏特写：从最左侧起，带上若干相邻图标作为上下文
// 我们的图标就在最左边，所以上下文只能往右取。
let mbWidth = min(W, 190)
let menubar = CGRect(x: 0, y: 0, width: Double(mbWidth), height: Double(menubarBottom + 1))
// 这块太小（约 190×28），不放大在 README 里根本看不清；
// 放大是有损的，但此处目的是"指位置"而非"看细节"，可以接受。
crop(menubar, scale: 3, to: "menubar.png")

// ── 6. 状态徽标特写：面板顶部（大字温度 + 两个状态徽标）
// 单独出这张是因为"守护进程运行中 / 正在控速"正是安装守护进程后要确认的东西，
// 放在安装步骤旁边比文字描述直观。
let badgeH = Double(py1 - py0 + 1) * 0.22
let badges = CGRect(x: Double(px0), y: Double(py0),
                    width: Double(px1 - px0 + 1), height: badgeH)
crop(badges, scale: 2, to: "status-badges.png")

print("==> 完成，输出目录：\(outDir.path)")
