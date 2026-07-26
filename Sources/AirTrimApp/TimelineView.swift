import AirTrimCore
import CoreMedia
import SwiftUI

/// 底部轨道（设计 m2 §5）：标尺 + 波形背景 + 字幕块 + 停顿建议/切割区间 + 播放头。
/// 全部内容从 Transcript/EditSession/cues 派生绘制，自身不持有任何时间状态。
struct TrackAreaView: View {
    @EnvironmentObject var model: AppModel
    /// 1 = 整段适配窗宽；>1 放大（横向滚动）
    @State private var zoom: CGFloat = 1

    private var durationSeconds: Double {
        max(model.transcript?.sourceDuration.seconds ?? 0, 0.001)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        track(width: max(geo.size.width * zoom, geo.size.width))
                            .id("track")
                    }
                    .onChange(of: model.currentSourceSeconds) { _, seconds in
                        guard model.isPlaying, zoom > 1 else { return }
                        // 跟随播放：把播放头维持在可视区中部
                        proxy.scrollTo("playhead", anchor: .center)
                    }
                }
            }
            zoomBar
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...20).frame(width: 140)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Spacer()
            Text(timecode(model.currentSourceSeconds) + " / " + timecode(durationSeconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - 轨道主体

    private func track(width: CGFloat) -> some View {
        let pps = width / durationSeconds   // px per second
        return ZStack(alignment: .topLeading) {
            canvasLayers(width: width, pps: pps)
            cueBlocks(pps: pps)
            suggestionBlocks(pps: pps)
            playhead(pps: pps)
        }
        .frame(width: width, height: 118)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { model.scrub(toSourceSeconds: $0.location.x / pps) }
        )
    }

    /// 标尺刻度 + 波形 + 剪切区域着色（纯绘制走 Canvas，几百个元素零视图开销）
    private func canvasLayers(width: CGFloat, pps: CGFloat) -> some View {
        Canvas { ctx, size in
            let rulerH: CGFloat = 18
            let waveTop = rulerH + 2
            let waveH: CGFloat = 62

            // 波形背景（sqrt 视觉缩放：轻语可见）
            if let peaks = model.waveformPeaks, !peaks.isEmpty {
                let binW = size.width / CGFloat(peaks.count)
                var path = Path()
                for (i, peak) in peaks.enumerated() {
                    let h = max(1, CGFloat(sqrt(peak)) * waveH)
                    path.addRect(CGRect(x: CGFloat(i) * binW, y: waveTop + (waveH - h) / 2,
                                        width: max(binW - 0.5, 0.5), height: h))
                }
                ctx.fill(path, with: .color(.secondary.opacity(0.35)))
            }

            // 剪切区间：accepted 红色蒙层直接压在波形上（"这段没了"）
            for cut in model.session.current.edits.cuts {
                let rect = CGRect(x: cut.start.seconds * pps, y: waveTop,
                                  width: max(cut.duration.seconds * pps, 1), height: waveH)
                ctx.fill(Path(rect), with: .color(.red.opacity(0.28)))
            }

            // 标尺
            let step = Self.tickStep(pxPerSecond: pps)
            var t: Double = 0
            while t <= durationSeconds {
                let x = t * pps
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: rulerH - 5))
                                  $0.addLine(to: CGPoint(x: x, y: rulerH)) },
                           with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                ctx.draw(Text(timecode(t)).font(.system(size: 9, design: .monospaced))
                             .foregroundStyle(.secondary),
                         at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                t += step
            }
        }
    }

    /// 字幕块行（可点击：选中卡片 + 播放头定位）
    private func cueBlocks(pps: CGFloat) -> some View {
        ForEach(Array(model.cues.enumerated()), id: \.offset) { _, cue in
            let x = cue.start.seconds * pps
            let w = max(cue.end.seconds * pps - x, 6)
            let isCurrent = model.currentCueText == cue.text
            RoundedRectangle(cornerRadius: 3)
                .fill(isCurrent ? Color.accentColor.opacity(0.85) : Color.accentColor.opacity(0.45))
                .overlay(alignment: .leading) {
                    Text(cue.text)
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 3)
                }
                .frame(width: w, height: 22)
                .offset(x: x, y: 88)
                .onTapGesture {
                    model.scrub(toSourceSeconds: cue.start.seconds)
                    if let transcript = model.transcript {
                        let sentence = model.session.current.patch
                            .effectiveSentences(in: transcript)
                            .last { transcript.sentenceRange($0).map {
                                CMTimeCompare($0.start, cue.start) <= 0 } ?? false }
                        model.selectedSentenceStart = sentence?.words.lowerBound
                    }
                }
        }
    }

    /// 停顿建议块（proposed 橙色，点击弹审阅泡）
    private func suggestionBlocks(pps: CGFloat) -> some View {
        ForEach(model.proposedPauses) { suggestion in
            let x = suggestion.originalGap.start.seconds * pps
            let w = max(suggestion.originalGap.duration.seconds * pps, 6)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.orange.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.orange, lineWidth: 1))
                .frame(width: w, height: 62)
                .offset(x: x, y: 20)
                .onTapGesture { model.selectedSuggestionID = suggestion.id }
                .popover(isPresented: Binding(
                    get: { model.selectedSuggestionID == suggestion.id },
                    set: { if !$0 { model.selectedSuggestionID = nil } }
                )) {
                    SuggestionReviewPopover(suggestion: suggestion)
                }
                .help("停顿 \(String(format: "%.1f", suggestion.originalGap.duration.seconds))s，建议剪 \(String(format: "%.1f", suggestion.cut.duration.seconds))s")
        }
    }

    private func playhead(pps: CGFloat) -> some View {
        Rectangle()
            .fill(.red)
            .frame(width: 2, height: 118)
            .offset(x: model.currentSourceSeconds * pps - 1)
            .id("playhead")
            .allowsHitTesting(false)
    }

    /// 刻度步长：保证相邻刻度 ≥60px（自适应缩放）
    static func tickStep(pxPerSecond: Double) -> Double {
        for step in [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600] where step * pxPerSecond >= 60 {
            return step
        }
        return 600
    }

    private func timecode(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 紧凑度控制条：滑杆（松→紧）· 一键紧凑 · 已省时长 · 原片/成片预览切换
struct TightenBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("紧凑度").font(.callout)
            Text("松").font(.caption2).foregroundStyle(.tertiary)
            Slider(value: $model.tightenIntensity, in: 0...1) { editing in
                if !editing { model.rerunPauseAnalysis() }   // 松手才重跑，避免 undo/UI 抖动
            }
            .frame(width: 150)
            Text("紧").font(.caption2).foregroundStyle(.tertiary)

            Divider().frame(height: 16)

            if model.transcript?.silences.isEmpty ?? true {
                Text("正在准备停顿分析…").font(.caption).foregroundStyle(.secondary)
            } else if !model.proposedPauses.isEmpty {
                Text("\(model.proposedPauses.count) 处停顿 · 可省 \(String(format: "%.1f", model.proposedSavings))s")
                    .font(.caption).foregroundStyle(.orange)
                Button("一键紧凑") { model.acceptAllPauses() }
                    .help("接受全部停顿建议（⌘Z 可整体撤销）")
            } else {
                Text("没有可剪的停顿").font(.caption).foregroundStyle(.secondary)
            }

            if model.removedSeconds > 0 {
                Text("已剪 \(String(format: "%.1f", model.removedSeconds))s")
                    .font(.caption).foregroundStyle(.red)
            }

            Spacer()

            Toggle("成片预览", isOn: $model.previewTightened)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("开：播放器按剪辑后的成片播放；关：播放原片")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// 建议审阅泡：跳听 / 接受 / 拒绝（cut-quality skill 审阅交互）
struct SuggestionReviewPopover: View {
    @EnvironmentObject var model: AppModel
    let suggestion: EditSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("停顿 \(String(format: "%.1f", suggestion.originalGap.duration.seconds)) 秒 · 建议剪掉 \(String(format: "%.1f", suggestion.cut.duration.seconds)) 秒",
                  systemImage: "waveform.badge.minus")
                .font(.callout)
            Text("保留自然停顿，切点带词边界保护")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    model.audition(suggestionID: suggestion.id)
                } label: {
                    Label("跳听", systemImage: "ear")
                }
                .help("播放剪掉后的效果：切点前后各 1.5 秒")
                Spacer()
                Button("拒绝") { model.reject(suggestionID: suggestion.id) }
                Button("剪掉") { model.accept(suggestionID: suggestion.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
