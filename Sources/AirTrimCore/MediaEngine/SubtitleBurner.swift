import AVFoundation
import CoreMedia
import CoreText
import Foundation
import QuartzCore

/// 字幕烧录样式 v2：系统字体、半透明背景条、柔和描边（D4 演进）。
public struct SubtitleStyle: Sendable {
    public var fontHeightRatio: CGFloat = 0.045
    public var fontWidthRatio: CGFloat = 0.05
    public var bottomMarginRatio: CGFloat = 0.07
    public var horizontalMarginRatio: CGFloat = 0.06
    public var fontName: String = "PingFangSC-Semibold"
    /// 背景条：圆角 + 内边距 + 半透明黑底
    public var backgroundOpacity: CGFloat = 0.55
    public var backgroundCornerRadius: CGFloat = 6
    public var backgroundPaddingV: CGFloat = 4
    public var backgroundPaddingH: CGFloat = 12
    /// 行间距（多行文本行距，单位 pt）
    public var lineSpacing: CGFloat = 4

    public init() {}

    public func fontSize(for renderSize: CGSize) -> CGFloat {
        min(renderSize.height * fontHeightRatio, renderSize.width * fontWidthRatio).rounded()
    }
}

/// 字幕烧录导出（MediaEngine 唯一 owner）：整段直通合成 + CoreAnimation 叠字幕层
/// + AVAssetExportSession 出 MP4。源文件只读（ADR-0004）；输出永远是新文件。
public enum SubtitleBurner {
    /// AVAssetExportSession 非 Sendable，但 progress/status 文档保证线程安全读取；
    /// 只为跨 Task 轮询进度与取消而包装。
    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    /// - Parameters:
    ///   - cues: 源时间轴字幕（内部按 edits 重定时到成片轴）
    ///   - edits: 剪辑状态（缺省空 = 整段直通，M1 行为不变）
    public static func burn(source: URL, cues: [SubtitleCue], to output: URL,
                            edits: EditList = EditList(),
                            style: SubtitleStyle = SubtitleStyle(),
                            progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaEngineError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)

        // 预览与导出同一合成路径（跳切 + 切点音频淡化）
        let composed = try await PreviewComposer.compose(url: source, edits: edits)
        let composition = composed.composition
        guard let compVideo = composition.tracks(withMediaType: .video).first else {
            throw MediaEngineError.compositionFailed
        }
        let duration = composition.duration
        let fullRange = CMTimeRange(start: .zero, duration: duration)
        let renderCues = Subtitles.retime(cues, through: edits)

        let geometry = renderGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = geometry.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps > 1 ? Int32(fps.rounded()) : 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = fullRange
        instruction.enablePostProcessing = true
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layerInstruction.setTransform(geometry.transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: geometry.renderSize)
        let parentLayer = CALayer()
        parentLayer.frame = videoLayer.frame
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer(cues: renderCues, renderSize: geometry.renderSize, style: style))
        CATransaction.commit()
        CATransaction.flush()
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaEngineError.compositionFailed
        }
        session.videoComposition = videoComposition
        session.audioMix = composed.audioMix
        session.outputURL = output
        session.outputFileType = .mp4
        try? FileManager.default.removeItem(at: output)

        let box = ExportBox(session)
        let poller = Task {
            while !Task.isCancelled {
                progress?(Double(box.session.progress))
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }
        await withTaskCancellationHandler {
            await box.session.export()
        } onCancel: {
            box.session.cancelExport()
        }
        switch box.session.status {
        case .completed:
            progress?(1.0)
        case .cancelled:
            throw CancellationError()
        default:
            throw MediaEngineError.exportFailed(box.session.error?.localizedDescription)
        }
    }

    /// 竖拍等带 preferredTransform 的素材：渲染尺寸取变换后外接框，
    /// 并把变换平移回原点（经典 iPhone 竖拍 90° 处理）。
    static func renderGeometry(naturalSize: CGSize, preferredTransform t: CGAffineTransform)
        -> (renderSize: CGSize, transform: CGAffineTransform) {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(t)
        let renderSize = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        let transform = t.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return (renderSize, transform)
    }

    /// 每条 cue 产出两个子层：背景条（半透明黑底圆角矩形）+ 文字层（CoreText 位图）。
    /// CoreText 不用 CATextLayer：离屏导出不触发 display，出片无字。
    static func overlayLayer(cues: [SubtitleCue], renderSize: CGSize, style: SubtitleStyle) -> CALayer {
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: renderSize)
        let fontSize = style.fontSize(for: renderSize)
        let maxTextWidth = renderSize.width * (1 - 2 * style.horizontalMarginRatio)
        let bottomMargin = renderSize.height * style.bottomMarginRatio

        for cue in cues {
            guard let textImage = cueImage(cue.text, fontSize: fontSize,
                                           fontName: style.fontName,
                                           maxWidth: maxTextWidth,
                                           lineSpacing: style.lineSpacing) else { continue }
            let textSize = CGSize(width: textImage.width, height: textImage.height)

            // 背景条：文字尺寸 + 内边距，圆角，半透明黑底
            let bgW = textSize.width + 2 * style.backgroundPaddingH
            let bgH = textSize.height + 2 * style.backgroundPaddingV
            let bgLayer = CAShapeLayer()
            bgLayer.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: bgW, height: bgH),
                                  cornerWidth: style.backgroundCornerRadius,
                                  cornerHeight: style.backgroundCornerRadius, transform: nil)
            bgLayer.fillColor = CGColor(gray: 0, alpha: style.backgroundOpacity)
            bgLayer.frame = CGRect(x: (renderSize.width - bgW) / 2, y: bottomMargin,
                                   width: bgW, height: bgH)
            bgLayer.opacity = 0
            bgLayer.add(visibilityAnimation(cue: cue), forKey: "cue")
            overlay.addSublayer(bgLayer)

            // 文字层：居中叠在背景条上
            let textLayer = CALayer()
            textLayer.contents = textImage
            textLayer.contentsScale = 1
            textLayer.frame = CGRect(x: (renderSize.width - textSize.width) / 2,
                                     y: bottomMargin + style.backgroundPaddingV,
                                     width: textSize.width, height: textSize.height)
            textLayer.opacity = 0
            textLayer.add(visibilityAnimation(cue: cue), forKey: "cue")
            overlay.addSublayer(textLayer)
        }
        return overlay
    }

    /// CoreText → CGImage：宽度固定，高度按排版结果 + 阴影余量
    static func cueImage(_ text: String, fontSize: CGFloat, fontName: String,
                         maxWidth: CGFloat, lineSpacing: CGFloat = 4) -> CGImage? {
        let attributed = attributedText(text, fontSize: fontSize, fontName: fontName,
                                        lineSpacing: lineSpacing)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let shadowPad = ceil(fontSize * 0.15)
        let textWidth = maxWidth
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil)
        let totalW = Int(ceil(maxWidth + 2 * shadowPad))
        let totalH = Int(ceil(fitted.height) + 2 * shadowPad)
        guard fitted.height > 0,
              let context = CGContext(
                  data: nil, width: totalW, height: totalH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // 先画阴影（略微偏移的模糊黑字）
        let shadowContext = CGContext(
            data: nil, width: totalW, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        if let shadowCtx = shadowContext {
            let shadowAttr = attributedText(text, fontSize: fontSize, fontName: fontName,
                                            color: CGColor(gray: 0, alpha: 0.65),
                                            lineSpacing: lineSpacing)
            let shadowSetter = CTFramesetterCreateWithAttributedString(shadowAttr)
            let shadowBox = CGPath(rect: CGRect(x: shadowPad + 1, y: shadowPad - 1,
                                                width: textWidth, height: ceil(fitted.height)),
                                   transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(shadowSetter, CFRange(location: 0, length: 0),
                                                 shadowBox, nil), shadowCtx)
            if let shadowImg = shadowCtx.makeImage() {
                context.setShadow(offset: .zero, blur: fontSize * 0.25,
                                  color: CGColor(gray: 0, alpha: 0.5))
                context.draw(shadowImg, in: CGRect(x: 0, y: 0, width: totalW, height: totalH))
            }
        }

        // 再画主文字
        let box = CGPath(rect: CGRect(x: shadowPad, y: shadowPad,
                                      width: textWidth, height: ceil(fitted.height)),
                         transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), box, nil),
                    context)
        return context.makeImage()
    }

    /// 显隐动画：激活区间内 opacity=1，区间外回落模型值 0。
    /// CoreAnimation 时间轴只收 Double 秒——这是渲染边界的显示转换，
    /// 权威时间仍是 cue 里的 CMTime。
    static func visibilityAnimation(cue: SubtitleCue) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 1.0
        // beginTime 0 在 CoreAnimation 里意味着"现在"，必须用 AVCoreAnimationBeginTimeAtZero
        animation.beginTime = max(cue.start.seconds, AVCoreAnimationBeginTimeAtZero)
        animation.duration = max(0, CMTimeSubtract(cue.end, cue.start).seconds)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .removed
        return animation
    }

    static func attributedText(_ text: String, fontSize: CGFloat, fontName: String,
                               color: CGColor = CGColor(gray: 1, alpha: 1),
                               lineSpacing: CGFloat = 4) -> NSAttributedString {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        var lineSp = lineSpacing
        var settings: [CTParagraphStyleSetting] = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                    value: &alignment),
            CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
                                    value: &lineSp),
        ]
        let paragraph = CTParagraphStyleCreate(&settings, settings.count)
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -2.5,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 0.35),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
    }
}
