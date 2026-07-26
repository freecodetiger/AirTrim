import AVFoundation
import CoreMedia
import CoreText
import Foundation
import QuartzCore

/// 字幕烧录样式 v1：白字黑边、底部居中、安全边距（设计 D4，固定一套；模板化留 roadmap）。
public struct SubtitleStyle: Sendable {
    /// 字号 = min(高 × heightRatio, 宽 × widthRatio)：横竖构图都保证每行 ≥16 个中文字，
    /// 32 字上限的 cue（Subtitles.Rules.maxChars）最多折成 2 行（设计 D2）
    public var fontHeightRatio: CGFloat = 0.045
    public var fontWidthRatio: CGFloat = 0.05
    public var bottomMarginRatio: CGFloat = 0.07
    public var horizontalMarginRatio: CGFloat = 0.06
    public var fontName: String = "PingFangSC-Semibold"

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

    public static func burn(source: URL, cues: [SubtitleCue], to output: URL,
                            style: SubtitleStyle = SubtitleStyle(),
                            progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaEngineError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaEngineError.compositionFailed
        }
        let fullRange = CMTimeRange(start: .zero, duration: duration)
        try compVideo.insertTimeRange(fullRange, of: videoTrack, at: .zero)
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compAudio.insertTimeRange(fullRange, of: audioTrack, at: .zero)
        }

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
        parentLayer.addSublayer(overlayLayer(cues: cues, renderSize: geometry.renderSize, style: style))
        CATransaction.commit()
        CATransaction.flush()
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaEngineError.compositionFailed
        }
        session.videoComposition = videoComposition
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

    /// 每条 cue 一个 CALayer，contents = CoreText 预渲染位图，opacity 动画控制显隐。
    /// 不用 CATextLayer：它在离屏导出渲染器里不触发 display，出片无字（真机实测）。
    /// macOS 层坐标原点在左下，y = 底部安全边距即贴底。
    static func overlayLayer(cues: [SubtitleCue], renderSize: CGSize, style: SubtitleStyle) -> CALayer {
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: renderSize)
        let fontSize = style.fontSize(for: renderSize)
        let maxWidth = renderSize.width * (1 - 2 * style.horizontalMarginRatio)
        let bottomMargin = renderSize.height * style.bottomMarginRatio

        for cue in cues {
            guard let image = cueImage(cue.text, fontSize: fontSize,
                                       fontName: style.fontName, maxWidth: maxWidth) else { continue }
            let size = CGSize(width: image.width, height: image.height)
            let layer = CALayer()
            layer.contents = image
            layer.contentsScale = 1
            layer.frame = CGRect(x: (renderSize.width - size.width) / 2, y: bottomMargin,
                                 width: size.width, height: size.height)
            layer.shadowColor = CGColor(gray: 0, alpha: 1)
            layer.shadowOpacity = 0.55
            layer.shadowRadius = fontSize * 0.05
            layer.shadowOffset = .zero
            layer.opacity = 0
            layer.add(visibilityAnimation(cue: cue), forKey: "cue")
            overlay.addSublayer(layer)
        }
        return overlay
    }

    /// CoreText → CGImage：宽度固定为可用宽度（水平居中由段落样式完成），
    /// 高度按排版实际结果 + 描边余量
    static func cueImage(_ text: String, fontSize: CGFloat, fontName: String,
                         maxWidth: CGFloat) -> CGImage? {
        let attributed = attributedText(text, fontSize: fontSize, fontName: fontName)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let pad = ceil(fontSize * 0.2)
        let textWidth = maxWidth - 2 * pad
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil)
        guard fitted.height > 0,
              let context = CGContext(
                  data: nil, width: Int(ceil(maxWidth)), height: Int(ceil(fitted.height) + 2 * pad),
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let box = CGPath(rect: CGRect(x: pad, y: pad, width: textWidth, height: ceil(fitted.height)),
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

    static func attributedText(_ text: String, fontSize: CGFloat, fontName: String) -> NSAttributedString {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let paragraph: CTParagraphStyle = withUnsafeBytes(of: CTTextAlignment.center) { buffer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment, valueSize: buffer.count, value: buffer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            // 负值 = 描边 + 填充（白字黑边）；单位是字号的百分比
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -4.0,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
    }
}
