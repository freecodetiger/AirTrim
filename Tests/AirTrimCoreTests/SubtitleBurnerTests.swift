import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import Testing
@testable import AirTrimCore

@Suite("字幕烧录几何与图层")
struct SubtitleBurnerTests {
    @Test func landscapeIdentityKeepsSize() {
        let geo = SubtitleBurner.renderGeometry(
            naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: .identity)
        #expect(geo.renderSize == CGSize(width: 1920, height: 1080))
        #expect(geo.transform == .identity)
    }

    @Test func portraitRotationSwapsRenderSize() {
        // iPhone 竖拍：naturalSize 仍是 1920×1080，preferredTransform 旋转 90°
        let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let geo = SubtitleBurner.renderGeometry(
            naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: rotate)
        #expect(geo.renderSize == CGSize(width: 1080, height: 1920))
        // 变换后原点必须回到 (0,0)：任意角点应落在渲染框内
        let mapped = CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080))
            .applying(geo.transform)
        #expect(abs(mapped.minX) < 0.001 && abs(mapped.minY) < 0.001)
    }

    @Test func overlayHasOneLayerPerCueWithTimedVisibility() {
        let cues = [
            SubtitleCue(start: CMTime(value: 0, timescale: 600),
                        end: CMTime(value: 1200, timescale: 600), text: "第一条字幕"),
            SubtitleCue(start: CMTime(value: 1800, timescale: 600),
                        end: CMTime(value: 3000, timescale: 600), text: "第二条字幕内容比较长会自动换行显示"),
        ]
        let overlay = SubtitleBurner.overlayLayer(
            cues: cues, renderSize: CGSize(width: 1080, height: 1920), style: SubtitleStyle())
        let layers = overlay.sublayers ?? []
        #expect(layers.count == 2)

        for (i, layer) in layers.enumerated() {
            #expect(layer.opacity == 0)  // 模型值 0：动画区间外不可见
            let animation = try? #require(layer.animation(forKey: "cue") as? CABasicAnimation)
            guard let animation else { continue }
            let expectedBegin = max(cues[i].start.seconds, AVCoreAnimationBeginTimeAtZero)
            #expect(abs(animation.beginTime - expectedBegin) < 0.001)
            #expect(abs(animation.duration - CMTimeSubtract(cues[i].end, cues[i].start).seconds) < 0.001)
            #expect(animation.isRemovedOnCompletion == false)
        }
        // 字幕层都应贴近底部安全边距、水平居中
        let style = SubtitleStyle()
        for layer in layers {
            #expect(abs(layer.frame.minY - 1920 * style.bottomMarginRatio) < 0.001)
            #expect(abs(layer.frame.midX - 540) < 0.001)
        }
    }

    @Test func fontSizeAdaptsToOrientation() {
        let style = SubtitleStyle()
        // 竖拍受宽度约束（每行 ≥16 字），横拍受高度约束
        let portrait = style.fontSize(for: CGSize(width: 1080, height: 1920))
        let landscape = style.fontSize(for: CGSize(width: 1920, height: 1080))
        #expect(portrait == (1080 * style.fontWidthRatio).rounded())
        #expect(landscape == (1080 * style.fontHeightRatio).rounded())
        // 每行至少放得下 16 个中文字（字宽 ≈ 字号；扣掉位图内边距）：
        // 32 字上限的 cue 才能保证 ≤2 行（设计 D2）
        let usable = 1080 * (1 - 2 * style.horizontalMarginRatio) - 2 * (portrait * 0.2).rounded(.up)
        #expect(usable / portrait >= 16)
    }
}
