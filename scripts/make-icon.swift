// AirTrim 图标生成器：swift scripts/make-icon.swift <输出目录>
// 产物：AppIcon.iconset/*.png + AppIcon-1024.png（icns 由 make-app.sh 的 iconutil 合成）。
// 设计：深紫渐变 squircle · 波形柱（暗柱 = 被剪掉的停顿）· 底部字幕条。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func renderIcon(canvas: CGFloat) -> CGImage {
    let scale = canvas / 1024
    let context = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)

    // macOS 图标网格：1024 画布内 824pt 圆角矩形居中，四周留投影边距
    let box = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.addPath(squircle)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 0.115, green: 0.095, blue: 0.32, alpha: 1),
            CGColor(red: 0.44, green: 0.20, blue: 0.88, alpha: 1),
        ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: box.minX, y: box.maxY),
        end: CGPoint(x: box.maxX, y: box.minY), options: [])

    // 波形柱：暗柱是被「一键紧凑」剪掉的停顿
    struct Bar { let height: CGFloat; let dim: Bool }
    let bars: [Bar] = [
        Bar(height: 210, dim: false),
        Bar(height: 350, dim: false),
        Bar(height: 470, dim: false),
        Bar(height: 250, dim: true),
        Bar(height: 400, dim: false),
        Bar(height: 250, dim: false),
    ]
    let barWidth: CGFloat = 64, gap: CGFloat = 40
    let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    var x = (1024 - totalWidth) / 2
    let centerY: CGFloat = 590
    for bar in bars {
        let rect = CGRect(x: x, y: centerY - bar.height / 2, width: barWidth, height: bar.height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2,
                               cornerHeight: barWidth / 2, transform: nil))
        context.setFillColor(CGColor(gray: 1, alpha: bar.dim ? 0.28 : 0.96))
        context.fillPath()
        x += barWidth + gap
    }

    // 字幕条
    let pill = CGRect(x: (1024 - 430) / 2, y: 252, width: 430, height: 58)
    context.addPath(CGPath(roundedRect: pill, cornerWidth: 29, cornerHeight: 29, transform: nil))
    context.setFillColor(CGColor(gray: 1, alpha: 0.96))
    context.fillPath()

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "build/icon")
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = renderIcon(canvas: 1024)
write(master, to: outDir.appendingPathComponent("AppIcon-1024.png"))

// iconutil 要求的全套尺寸；直接按目标尺寸重绘（矢量式，不做位图缩放）
for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    write(renderIcon(canvas: CGFloat(size)), to: iconset.appendingPathComponent("\(name).png"))
}
print("iconset → \(iconset.path)")
