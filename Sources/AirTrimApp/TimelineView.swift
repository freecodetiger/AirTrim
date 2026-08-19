import AirTrimCore
import CoreMedia
import SwiftUI

/// 底部轨道（设计 m2 §5）：标尺 + 波形背景 + 字幕块 + 停顿建议/切割区间 + 播放头。
/// 全部内容从 Transcript/EditSession/cues 派生绘制，自身不持有任何时间状态。
///
/// 播放与轨道各走各路：播放头随时间移动，但 ScrollView 不自动追（避免手势冲突）。
/// zoom > 1 时点「追」按钮手动定位到播放头。
struct TrackAreaView: View {
    @EnvironmentObject var model: AppModel
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
                    // 跳听 / 试听句 / seek 时定位到对应位置（延迟一帧等布局落定）
                    .onChange(of: model.navigateTimelineTo) { _, target in
                        guard target != nil else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo("playhead", anchor: .center)
                            model.navigateTimelineTo = nil
                        }
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
            // 放大时提供手动"追播放头"按钮
            if zoom > 1 {
                Button {
                    model.scrub(toSourceSeconds: model.currentSourceSeconds)
                } label: {
                    Image(systemName: "location.fill")
                        .font(.caption)
                }
                .help("定位到播放头")
            }
            Spacer()
            // 悬停时显示鼠标位置（毫秒精度，精确剪反馈）；否则显示播放头
            Text((hoverSeconds.map { timecodeMs($0) } ?? timecodeMs(model.currentSourceSeconds))
                 + " / " + timecode(durationSeconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(hoverSeconds != nil ? Color.accentColor : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - 轨道主体

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        let pps = width / durationSeconds   // px per second
        let base = ZStack(alignment: .topLeading) {
            canvasLayers(width: width, pps: pps)
            cueBlocks(pps: pps)
            suggestionBlocks(pps: pps)
            playhead(pps: pps)
            // 剪刀模式起点标记线（瞬态 UI 状态）
            if model.isManualCutMode, let start = model.manualCutStart {
                Rectangle().fill(.orange.opacity(0.85))
                    .frame(width: 2, height: 118)
                    .offset(x: start.seconds * pps - 1)
                    .allowsHitTesting(false)
            }
            // 常驻跟手细线：鼠标在轨道中就一直有反馈（剪刀模式显示吸附后的位置）
            if let h = hoverSeconds {
                let pos = model.isManualCutMode ? snappedSeconds(h) : h
                Rectangle()
                    .fill(model.isManualCutMode ? Color.orange.opacity(0.9) : Color.secondary.opacity(0.55))
                    .frame(width: 1, height: 118)
                    .offset(x: pos * pps - 0.5)
                    .allowsHitTesting(false)
            }
            // 剪刀区间预览：起点 → 当前鼠标（吸附后），第二击前先看到要剪什么
            if model.isManualCutMode, let start = model.manualCutStart, let h = hoverSeconds {
                let lo = min(start.seconds, snappedSeconds(h))
                let hi = max(start.seconds, snappedSeconds(h))
                if hi > lo {
                    Rectangle().fill(.orange.opacity(0.18))
                        .frame(width: (hi - lo) * pps, height: 118)
                        .offset(x: lo * pps, y: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, height: 118)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverSeconds = min(max(location.x / pps, 0), durationSeconds)
            case .ended:
                hoverSeconds = nil
            }
        }
        .onHover { inside in
            guard model.isManualCutMode else { return }
            if inside && !scissorsCursorActive {
                Self.scissorsCursor.push()
                scissorsCursorActive = true
            } else if !inside && scissorsCursorActive {
                NSCursor.pop()
                scissorsCursorActive = false
            }
        }
        .onChange(of: model.isManualCutMode) { _, active in
            if !active && scissorsCursorActive {   // 模式关闭时若光标还压着，弹回
                NSCursor.pop()
                scissorsCursorActive = false
            }
        }

        if model.isManualCutMode {
            base.highPriorityGesture(
                SpatialTapGesture().onEnded { value in
                    model.manualCut(at: value.location.x / pps)
                }
            )
        } else {
            base.highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { model.scrub(toSourceSeconds: $0.location.x / pps) }
                    .onEnded { _ in model.endScrub() }
            )
        }
    }

    /// 剪刀模式下鼠标位置吸附后的秒值（与 manualCut 同语义，预览即落点）
    private func snappedSeconds(_ s: Double) -> Double {
        guard let transcript = model.transcript else { return s }
        let t = CMTime(seconds: s, preferredTimescale: 600)
        return ManualCutSnap.snap(t, transcript: transcript).seconds
    }

    /// 剪刀模式下轨道光标（SF Symbol scissors）
    private static let scissorsCursor: NSCursor = {
        let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "剪刀") ?? NSImage()
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }()
    @State private var scissorsCursorActive = false
    /// 鼠标悬停在轨道上的位置（源轴秒；nil = 不在轨道上）
    @State private var hoverSeconds: Double?

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

    /// 建议块（proposed，按 kind 着色：停顿橙 / 语气词蓝 / 废话紫），点击弹审阅泡
    private func suggestionBlocks(pps: CGFloat) -> some View {
        ForEach(model.proposedSuggestions) { suggestion in
            let x = suggestion.originalGap.start.seconds * pps
            let w = max(suggestion.originalGap.duration.seconds * pps, 6)
            let color = Self.color(for: suggestion.kind)
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color, lineWidth: 1))
                .frame(width: w, height: 62)
                .offset(x: x, y: 20)
                .onTapGesture { model.selectedSuggestionID = suggestion.id }
                .popover(isPresented: Binding(
                    get: { model.selectedSuggestionID == suggestion.id },
                    set: { if !$0 { model.selectedSuggestionID = nil } }
                )) {
                    SuggestionReviewPopover(suggestion: suggestion)
                }
                .help(Self.helpText(for: suggestion))
        }
    }

    static func color(for kind: EditSuggestion.Kind) -> Color {
        switch kind {
        case .pause: .orange
        case .filler: .blue
        case .verbosity: .purple
        }
    }

    static func helpText(for s: EditSuggestion) -> String {
        let saved = String(format: "%.1f", s.cut.duration.seconds)
        switch s.kind {
        case .pause:
            return "停顿 \(String(format: "%.1f", s.originalGap.duration.seconds))s，建议剪 \(saved)s"
        case .filler:
            return "语气词「\(s.detail ?? "")」，建议剪 \(saved)s"
        case .verbosity:
            return "\(s.category.map(verbosityLabel) ?? "废话")，建议整句剪 \(saved)s"
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

    /// 毫秒精度时码（悬停反馈 / 播放头显示用）
    private func timecodeMs(_ seconds: Double) -> String {
        let s = Int(seconds)
        let ms = Int((seconds - Double(s)) * 1000)
        return String(format: "%02d:%02d.%03d", s / 60, s % 60, ms)
    }
}

/// verbosity 分类的显示名（LLM 契约四分类）
func verbosityLabel(_ c: EditSuggestion.VerbosityCategory) -> String {
    switch c {
    case .repetition: "重复表达"
    case .falseStart: "口误重来"
    case .offTopic: "离题"
    case .padding: "凑字"
    }
}

/// 建议控制条：门槛+保留双滑杆 · 一键紧凑 · 清除语气词 · 识别废话 · 原片/成片切换
struct TightenBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showVerbosityPanel = false

    var body: some View {
        HStack(spacing: 10) {
            // 滑杆1：剪哪些——只剪 ≥ X 秒的停顿（短气口留给节奏）
            Text("门槛 ≥\(String(format: "%.1f", model.tightenMinGap))s")
                .font(.callout).monospacedDigit()
                .help("只剪不短于此时长的停顿；往右拉只清长冷场，保留短气口")
            Slider(value: $model.tightenMinGap, in: 0.3...2.0, step: 0.1) { editing in
                if !editing { model.rerunPauseAnalysis() }   // 松手才重跑，避免 undo/UI 抖动
            }
            .frame(width: 110)

            // 滑杆2：剪完留多少——停顿残留量（呼吸感）
            Text("保留").font(.callout)
                .help("剪完后每处停顿保留多少：松（句中150/句尾250ms）→ 紧（80ms）")
            Text("松").font(.caption2).foregroundStyle(.tertiary)
            Slider(value: $model.tightenIntensity, in: 0...1) { editing in
                if !editing { model.rerunPauseAnalysis() }
            }
            .frame(width: 110)
            Text("紧").font(.caption2).foregroundStyle(.tertiary)

            Divider().frame(height: 16)

            // 手动精确剪（剪刀模式，docs/design/manual-cut.md）
            Button {
                model.toggleManualCutMode()
            } label: {
                Image(systemName: "scissors")
                    .foregroundStyle(model.isManualCutMode ? Color.accentColor : Color.secondary)
            }
            .help("精确剪：点击定起点，再点剪掉（⌘Z 可撤回）")
            if model.isManualCutMode {
                Text(model.manualCutStart == nil ? "点起点…" : "点终点剪掉")
                    .font(.caption).foregroundStyle(.orange)
            }

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

            Divider().frame(height: 16)

            // 清除语气词（本地词表，即时）
            Button("清除语气词") { model.runFillerAnalysis() }
                .disabled(model.transcript?.silences.isEmpty ?? true)
                .help((model.transcript?.silences.isEmpty ?? true)
                    ? "波形分析中，稍候再试"
                    : "本地词表匹配嗯/啊/呃等语气词，即时出建议")
            if !model.proposedFillers.isEmpty {
                let savings = model.proposedFillers.reduce(0.0) { $0 + $1.cut.duration.seconds }
                Text("\(model.proposedFillers.count) 个语气词 · 可省 \(String(format: "%.1f", savings))s")
                    .font(.caption).foregroundStyle(.blue)
                Button("全部接受") { model.acceptAllFillers() }
                    .help("接受全部语气词建议（⌘Z 可整体撤销）")
            } else if model.lastFillerRunFound == 0 {
                Text("未发现语气词").font(.caption).foregroundStyle(.secondary)
            }

            Divider().frame(height: 16)

            // AI 字幕纠错（LLM，异步；结果需审阅确认）
            if model.correctionRunning {
                ProgressView().controlSize(.small)
                Text("纠错中…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("AI 纠错") { model.requestTranscriptCorrection() }
                    .help("LLM 逐句纠正同音字、错别字、专有名词（只上传文字，结果需审阅）")
            }
            if model.showCorrectionReview {
                Button("\(model.correctionDiffs.count) 处修正 · 审阅") { model.showCorrectionReview = true }
                    .popover(isPresented: $model.showCorrectionReview) { CorrectionReviewPanel() }
                    .foregroundStyle(.green)
            }

            Divider().frame(height: 16)

            // AI 抖音文案（标题 + 配文 + 标签，结果显示在右侧边栏）
            if model.socialCopyRunning {
                ProgressView().controlSize(.small)
                Button("取消") { /* 暂不支持取消 */ }
                    .disabled(true)
            } else {
                Button("抖音文案") { model.requestSocialCopy() }
                    .help("AI 分析字幕生成标题、配文和标签（只上传文字稿，结果在右侧边栏）")
            }
            if model.socialCopyResult != nil {
                Button("查看文案") { model.showSocialPanel = true }
                    .foregroundStyle(.pink)
            }

            Divider().frame(height: 16)

            // 识别废话（LLM，异步可取消；建议永不自动接受）
            if model.verbosityRunning {
                ProgressView().controlSize(.small)
                Button("取消") { model.cancelVerbosityAnalysis() }
            } else {
                Button("识别废话") { model.requestVerbosityAnalysis() }
                    .help("LLM 通读文字稿找可整句删除的废话（只上传文字，需配置 LLM）")
            }
            if !model.proposedVerbosity.isEmpty {
                Button("\(model.proposedVerbosity.count) 处废话 · 审阅") { showVerbosityPanel = true }
                    .popover(isPresented: $showVerbosityPanel) { VerbosityReviewPanel() }
                    .foregroundStyle(.purple)
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
        .sheet(isPresented: $model.showVerbosityTopicPrompt) { VerbosityTopicSheet() }
        .alert("识别废话失败", isPresented: Binding(
            get: { model.verbosityError != nil },
            set: { if !$0 { model.verbosityError = nil } }
        )) {
            Button("好") { model.verbosityError = nil }
        } message: {
            Text(model.verbosityError ?? "")
        }
    }
}

/// 发起废话识别前的可选主题输入（提升离题判定）
struct VerbosityTopicSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("识别废话").font(.headline)
            Text("LLM 通读文字稿，找出重复表达、口误重来、离题、凑字的句子。\n只上传文字稿；建议需逐条审阅，永不自动接受。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("视频主题（可选，提升离题判定）", text: $model.verbosityTopic)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { model.showVerbosityTopicPrompt = false }
                Button("开始识别") {
                    model.showVerbosityTopicPrompt = false
                    model.runVerbosityAnalysis()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// 废话审阅面板：按类分组 + 低置信（<0.5）折叠 + 按类批量接受。
/// 没有「全部接受」——verbosity 永不自动接受（D-M3-2）。
struct VerbosityReviewPanel: View {
    @EnvironmentObject var model: AppModel

    private var highConfidence: [EditSuggestion] {
        model.proposedVerbosity.filter { ($0.confidence ?? 0) >= 0.5 }
    }

    private var lowConfidence: [EditSuggestion] {
        model.proposedVerbosity.filter { ($0.confidence ?? 0) < 0.5 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("废话建议 · 逐条或按类接受").font(.headline)
                ForEach(EditSuggestion.VerbosityCategory.allCases, id: \.self) { category in
                    let items = highConfidence.filter { $0.category == category }
                    if !items.isEmpty {
                        HStack {
                            Text(verbosityLabel(category)).font(.subheadline).bold()
                            Spacer()
                            Button("接受这 \(items.count) 条") {
                                model.acceptVerbosity(category: category)
                            }
                            .controlSize(.small)
                            .help("批量接受本类建议（⌘Z 一步整体撤销）")
                        }
                        ForEach(items) { row($0) }
                    }
                }
                if !lowConfidence.isEmpty {
                    DisclosureGroup("低置信（\(lowConfidence.count) 条）") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(lowConfidence) { row($0) }
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(14)
        }
        .frame(width: 380, height: 340)
    }

    private func row(_ s: EditSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.detail ?? "").font(.caption)
            HStack(spacing: 6) {
                Text(String(format: "剪 %.1fs · 置信 %.0f%%",
                            s.cut.duration.seconds, (s.confidence ?? 0) * 100))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("跳听") { model.audition(suggestionID: s.id) }.controlSize(.small)
                Button("拒绝") { model.reject(suggestionID: s.id) }.controlSize(.small)
                Button("剪掉") { model.accept(suggestionID: s.id) }.controlSize(.small)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.08)))
    }
}

/// 建议审阅泡：跳听 / 接受 / 拒绝（cut-quality skill 审阅交互），按 kind 出文案
struct SuggestionReviewPopover: View {
    @EnvironmentObject var model: AppModel
    let suggestion: EditSuggestion

    private var savedText: String { String(format: "%.1f", suggestion.cut.duration.seconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch suggestion.kind {
            case .pause:
                Label("停顿 \(String(format: "%.1f", suggestion.originalGap.duration.seconds)) 秒 · 建议剪掉 \(savedText) 秒",
                      systemImage: "waveform.badge.minus")
                    .font(.callout)
                Text("保留自然停顿，切点带词边界保护")
                    .font(.caption).foregroundStyle(.secondary)
            case .filler:
                Label("语气词「\(suggestion.detail ?? "")」 · 建议剪掉 \(savedText) 秒",
                      systemImage: "bubble.left")
                    .font(.callout)
                Text("删词后两侧停顿合并，不留双倍空洞；字幕同步剔词")
                    .font(.caption).foregroundStyle(.secondary)
            case .verbosity:
                Label("\(suggestion.category.map(verbosityLabel) ?? "废话") · 建议整句剪除 \(savedText) 秒",
                      systemImage: "text.badge.minus")
                    .font(.callout)
                Text(suggestion.detail ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                if let confidence = suggestion.confidence {
                    Text("置信度 \(Int(confidence * 100))%")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
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

/// AI 纠错审阅面板：逐条展示原文 vs 修正，确认后写入（走 undo）
struct CorrectionReviewPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("AI 字幕纠错 · \(model.correctionDiffs.count) 处建议修正").font(.headline)
                Text("逐条比对，确认后写入字幕（⌘Z 可撤销）")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(model.correctionDiffs.indices, id: \.self) { idx in
                    let diff = model.correctionDiffs[idx]
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.badge.minus")
                                .foregroundStyle(.red).font(.caption)
                            Text(diff.original)
                                .font(.caption).strikethrough().foregroundStyle(.red)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "text.badge.plus")
                                .foregroundStyle(.green).font(.caption)
                            Text(diff.corrected)
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.background.secondary.opacity(0.5)))
                }

                HStack {
                    Button("全部应用") {
                        model.applyCorrections(model.correctionDiffs)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("取消") { model.correctionDiffs = []; model.showCorrectionReview = false }
                }
            }
            .padding(14)
        }
        .frame(width: 400, height: 380)
    }
}
