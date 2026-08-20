// AirTrim 图标生成器：swift scripts/make-icon.swift <输出目录>
// 输入：assets/app-icon-source.png（设计稿 logo）。
// 处理：从四边 flood-fill 去除「与边缘连通的背景」→ 保留主体（浅色卡片 + 内部
//       黑色符号，符号被卡片包围不与边缘连通）→ 裁剪到主体包围盒 →
//       缩放到 macOS 网格 824pt 框居中于 1024 画布。
// 产物：AppIcon-1024.png + AppIcon.iconset/*.png（icns 由 iconutil 合成）。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func loadImage(at url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("无法读取 \(url.path)")
    }
    return img
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("CGImageDestination") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("写 PNG 失败 \(url.path)") }
}

/// 去除与四边连通的背景，保留主体，并裁到主体包围盒。
/// 背景色与主体内部符号同色（都是深色）时，靠「连通性」区分：
/// 背景连到画布边缘 → 移除；符号被浅色主体包围 → 保留。
func removeBackgroundAndCrop(_ source: CGImage) -> CGImage {
    let w = source.width, h = source.height
    let rowBytes = w * 4
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    var pixels = [UInt8](repeating: 0, count: rowBytes * h)
    let ctx = CGContext(data: &pixels, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: rowBytes,
                        space: sRGB, bitmapInfo: bitmapInfo)!
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))

    func luminance(_ i: Int) -> Int {
        (Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2])) / 3
    }
    let lumThreshold = 120   // 低于此亮度视为「背景/深色」，高于为「主体/浅色卡片」

    // 种子：四边上亮度 ≤ 阈值的像素；BFS 只穿过同样 ≤ 阈值的像素
    var isBg = [Bool](repeating: false, count: w * h)
    var queue: [Int] = []
    func seed(_ i: Int) { if !isBg[i] && luminance(i) <= lumThreshold { isBg[i] = true; queue.append(i) } }
    for x in 0..<w { seed(x); seed((h - 1) * w + x) }
    for y in 0..<h { seed(y * w); seed(y * w + w - 1) }

    var qi = 0
    while qi < queue.count {
        let i = queue[qi]; qi += 1
        let x = i % w, y = i / w
        if x > 0 { let n = i - 1; if !isBg[n] && luminance(n) <= lumThreshold { isBg[n] = true; queue.append(n) } }
        if x < w - 1 { let n = i + 1; if !isBg[n] && luminance(n) <= lumThreshold { isBg[n] = true; queue.append(n) } }
        if y > 0 { let n = i - w; if !isBg[n] && luminance(n) <= lumThreshold { isBg[n] = true; queue.append(n) } }
        if y < h - 1 { let n = i + w; if !isBg[n] && luminance(n) <= lumThreshold { isBg[n] = true; queue.append(n) } }
    }

    // 输出：背景透明；主体保留原色
    var out = [UInt8](repeating: 0, count: rowBytes * h)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            guard !isBg[i] else { continue }
            let pi = i * 4
            let a = Int(pixels[pi + 3])
            guard a > 8 else { continue }
            out[pi] = pixels[pi]; out[pi + 1] = pixels[pi + 1]
            out[pi + 2] = pixels[pi + 2]; out[pi + 3] = pixels[pi + 3]
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    precondition(maxX >= minX && maxY >= minY, "未保留任何主体像素——检查亮度阈值")

    let bw = maxX - minX + 1, bh = maxY - minY + 1
    var cropped = [UInt8](repeating: 0, count: bw * bh * 4)
    for y in 0..<bh {
        let srcRow = (minY + y) * rowBytes + minX * 4
        let dstRow = y * bw * 4
        cropped.replaceSubrange(dstRow..<(dstRow + bw * 4),
                                with: out[srcRow..<(srcRow + bw * 4)])
    }
    let provider = CGDataProvider(data: Data(cropped) as CFData)!
    return CGImage(width: bw, height: bh, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: bw * 4, space: sRGB,
                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

/// 把裁剪出的主体按比例缩放到 824pt 框，居中于 1024 画布（macOS 图标网格）。
func renderMaster(from art: CGImage) -> CGImage {
    let canvas: CGFloat = 1024, box: CGFloat = 824
    let ctx = CGContext(data: nil, width: 1024, height: 1024,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = box / CGFloat(max(art.width, art.height))
    let dw = CGFloat(art.width) * scale
    let dh = CGFloat(art.height) * scale
    ctx.draw(art, in: CGRect(x: (canvas - dw) / 2, y: (canvas - dh) / 2, width: dw, height: dh))
    return ctx.makeImage()!
}

/// 把 1024 主图等比缩小到目标尺寸（bicubic 高质量）。
func scaled(_ master: CGImage, to size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "build/icon")
let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()          // scripts/
    .appendingPathComponent("../assets/app-icon-source.png")
    .standardizedFileURL
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let art = removeBackgroundAndCrop(loadImage(at: sourceURL))
let master = renderMaster(from: art)
write(master, to: outDir.appendingPathComponent("AppIcon-1024.png"))

// iconutil 要求的全套尺寸
for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    write(scaled(master, to: size), to: iconset.appendingPathComponent("\(name).png"))
}
print("iconset → \(iconset.path)（源：\(sourceURL.path)）")
