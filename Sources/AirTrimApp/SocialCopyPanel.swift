import SwiftUI

/// AI 生成社交媒体文案侧边栏：标题 + 配文 + 标签 + 推荐组合。
/// 每个区块带一键复制按钮。
struct SocialCopyPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Label("抖音文案", systemImage: "sparkles").font(.headline)
                Spacer()
                if model.socialCopyRunning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    copyAll()
                } label: {
                    Label("全部复制", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .disabled(model.socialCopyResult == nil)
                Button {
                    model.showSocialPanel = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let error = model.socialCopyError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                    Text("生成失败").font(.headline)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.socialCopyRunning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在分析字幕并生成文案…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = model.socialCopyResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(parseSections(from: result)) { section in
                            sectionView(section)
                        }
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").font(.title).foregroundStyle(.secondary)
                    Text("点击工具栏「抖音文案」生成").font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 300)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Section rendering

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(section.title)
                    .font(.subheadline).bold()
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    copyToPasteboard(section.content)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("复制此段")
            }

            Text(section.content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary.opacity(0.5)))

            Divider().padding(.vertical, 4)
        }
    }

    // MARK: - Parsing

    private struct Section: Identifiable {
        var id: String { title }
        let title: String
        let content: String
    }

    /// 按 --- 和 【】 标题分割 LLM 返回的 markdown
    private func parseSections(from text: String) -> [Section] {
        var sections: [Section] = []
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 找所有 【...】 标题位置
        let pattern = try? NSRegularExpression(pattern: "【(.+?)】", options: [])
        let nsText = cleaned as NSString
        let matches = pattern?.matches(in: cleaned, options: [], range: NSRange(location: 0, length: nsText.length)) ?? []

        for (i, match) in matches.enumerated() {
            let titleRange = match.range(at: 1)
            let title = nsText.substring(with: titleRange)

            let contentStart = match.range.location + match.range.length
            let contentEnd = i + 1 < matches.count
                ? matches[i + 1].range.location
                : nsText.length
            let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)
            var content = nsText.substring(with: contentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n---", with: "")
                .replacingOccurrences(of: "---\n", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-\n "))

            if !content.isEmpty {
                sections.append(Section(title: title, content: content))
            }
        }

        // 如果没找到任何标题，整段作为一个 section
        if sections.isEmpty && !cleaned.isEmpty {
            sections.append(Section(title: "生成结果", content: cleaned))
        }
        return sections
    }

    // MARK: - Copy helpers

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyAll() {
        guard let result = model.socialCopyResult else { return }
        copyToPasteboard(result)
    }

    private func attributedLabel(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage).font(.caption)
    }
}
