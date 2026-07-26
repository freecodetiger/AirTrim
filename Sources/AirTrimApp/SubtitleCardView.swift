import AirTrimCore
import CoreMedia
import SwiftUI

/// 左栏字幕卡片列表：选中/当前句/编辑/结构操作三方联动（选中态是 UI 状态，非剪辑状态）
struct SubtitleCardListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(model.sentences.enumerated()), id: \.element.words.lowerBound) { index, sentence in
                        SubtitleCard(index: index, sentence: sentence)
                            .id(sentence.words.lowerBound)
                    }
                }
                .padding(10)
            }
            .onChange(of: model.currentSentenceStart) { _, start in
                guard model.isPlaying, let start else { return }
                withAnimation { proxy.scrollTo(start, anchor: .center) }
            }
            .onChange(of: model.selectedSentenceStart) { _, start in
                guard let start else { return }
                withAnimation { proxy.scrollTo(start, anchor: .center) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SubtitleCard: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let sentence: TranscriptSentence
    @State private var draft = ""
    @State private var showSplitPicker = false
    @FocusState private var focused: Bool

    private var range: (start: CMTime, end: CMTime)? {
        model.transcript?.sentenceRange(sentence)
    }

    private var isCurrent: Bool { model.currentSentenceStart == sentence.words.lowerBound }
    private var isSelected: Bool { model.selectedSentenceStart == sentence.words.lowerBound }
    private var edited: Bool {
        model.session.current.patch.textOverrides[sentence.words.lowerBound] != nil
    }

    var body: some View {
        let currentText = model.sentenceText(sentence)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(timeLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .onTapGesture { model.seek(to: sentence) }
                    .help("跳转到句首")
                if let range {
                    Text(String(format: "%.1fs", CMTimeSubtract(range.end, range.start).seconds))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if edited {
                    BadgeView(text: "已改", color: .accentColor)
                }
                if currentText.count > 32 {
                    BadgeView(text: "超长", color: .orange)
                        .help("超过一条字幕 32 字上限，导出时会折成多条——考虑拆句")
                }
                Spacer()
                Button {
                    model.playSentence(sentence)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("试听整句（句尾自动停）")
                Menu {
                    Button("拆分此句…") { showSplitPicker = true }
                        .disabled(sentence.words.count < 2)
                    Button("与上一句合并") { model.mergeWithPrevious(sentence) }
                        .disabled(sentence.words.lowerBound == 0)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .onAppear { draft = currentText }
                .onChange(of: currentText) { _, new in
                    if !focused { draft = new }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { model.updateSentence(sentence, text: draft) }
                }
                .onSubmit { model.updateSentence(sentence, text: draft) }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.10)
                                : Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                              lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedSentenceStart = sentence.words.lowerBound
        }
        .contextMenu {
            Button("拆分此句…") { showSplitPicker = true }
                .disabled(sentence.words.count < 2)
            Button("与上一句合并") { model.mergeWithPrevious(sentence) }
                .disabled(sentence.words.lowerBound == 0)
        }
        .popover(isPresented: $showSplitPicker) {
            SplitPicker(sentence: sentence)
        }
    }

    private var timeLabel: String {
        guard let range else { return "--:--" }
        let s = Int(range.start.seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct BadgeView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

/// 拆句选择器：点某个词 = 从该词前断开
struct SplitPicker: View {
    @EnvironmentObject var model: AppModel
    let sentence: TranscriptSentence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("点击要作为新句开头的词").font(.caption).foregroundStyle(.secondary)
            let words = model.transcript.map { Array($0.words[sentence.words]) } ?? []
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 4)], spacing: 4) {
                ForEach(Array(words.enumerated().dropFirst()), id: \.offset) { offset, w in
                    Button(w.text) {
                        model.splitSentence(before: sentence.words.lowerBound + offset)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}
