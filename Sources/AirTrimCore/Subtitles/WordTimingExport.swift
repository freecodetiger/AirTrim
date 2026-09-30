import CoreMedia
import Foundation

/// 词级时间轴导出：`Transcript` + `EditList` → **成片轴**的词级 JSON。
///
/// 消费者是 hyperframes 动画工作流（`/embedded-captions`、`/talking-head-recut`），
/// 即"拿最终成片去加字幕/动画"的 Agent。故时间戳必须落在**导出的成片**那条轴上，
/// 且形状要能被它直接吃下（字段名照它 `packages/cli/src/whisper/normalize.ts` 的 `Word`）。
///
/// 成片轴与导出的 MP4 逐样本对齐：`PreviewComposer` 把 keep 段首尾相接、不插填充不重叠
/// （`PreviewComposer.swift`），切点淡化只是段内音量 ramp，不动时间轴。
public enum WordTimingExport {
    /// 单个词。字段名与 hyperframes 的 `Word` 接口对齐。
    public struct Word: Codable, Equatable, Sendable {
        /// `w0`、`w1`…稳定引用键（caption 覆盖与 `--preserve-cues` 靠它）
        public let id: String
        public let text: String
        /// 秒（3 位小数），绝对于成片 t=0。**毫秒会被 hyperframes 主动拒绝**
        /// （`transcribe.cjs` 用 `end < 36000` 判"这是秒还是毫秒"）。
        public let start: Double
        public let end: Double
        /// 恒为 `"word"`：hyperframes 的 `check-timing.cjs` 按 `type == "word"` 过滤，
        /// 缺了它这些词对它的时间闸门不可见。
        public let type: String

        public init(id: String, text: String, start: Double, end: Double, type: String = "word") {
            self.id = id
            self.text = text
            self.start = start
            self.end = end
            self.type = type
        }
    }

    /// wrapper 形状（不是裸数组）：只有它能让 `/embedded-captions` 完全跳过 WhisperX
    /// 重转写——裸数组会被它判成"不是词级"而重新转写。`languageCode` 非空是硬条件。
    public struct Document: Codable, Equatable, Sendable {
        /// 已导出词拼接（CJK 不加空格，与转写的分词习惯一致）
        public let text: String
        public let languageCode: String
        /// 出处标记：让 Agent 知道这不是 Whisper 产物，不必再"转录后先校一遍"
        public let engine: String
        public let words: [Word]

        enum CodingKeys: String, CodingKey {
            case text
            case languageCode = "language_code"
            case engine
            case words
        }

        public init(text: String, languageCode: String, engine: String, words: [Word]) {
            self.text = text
            self.languageCode = languageCode
            self.engine = engine
            self.words = words
        }
    }

    /// `engine` 字段的值
    public static let engineName = "airtrim"

    /// 成片轴的词序列。
    ///
    /// 规则与字幕口径保持一致（复用 `Subtitles.isCutOut`，不另立一套）：
    /// 1. **完全落入**切口的词剔除；只被 padding 擦边的词保留——宁可多留字（cut-quality skill）。
    /// 2. 其余词按 `EditList` 重定时到成片轴。
    /// 3. 映射后零长/倒置的词丢弃：hyperframes 的 `interpolateZeroDuration()` 会静默改写
    ///    零长词，宁可不给，别给它一份会被改的数。
    /// 4. `end` 夹到成片时长，`start` 越界的词丢弃。
    public static func words(transcript: Transcript, edits: EditList = EditList()) -> [Word] {
        // 成片时长取 outputTime(sourceDuration) 而非 outputDuration(sourceDuration)：
        // 后者用未夹取的 cuts 前缀和，在"切口越过源片尾"时会比实际合成短
        // （keepSegments 夹了、outputTime 也自洽，只有它也偏）。
        let outputDuration = edits.outputTime(forSource: transcript.sourceDuration)
        var out: [Word] = []
        for w in transcript.words {
            if Subtitles.isCutOut(w, in: edits) { continue }
            let clampedEnd = CMTimeMinimum(edits.outputTime(forSource: w.end), outputDuration)
            let start = milliseconds(edits.outputTime(forSource: w.start))
            let end = milliseconds(clampedEnd)
            guard end > start else { continue }
            out.append(Word(id: "w\(out.count)", text: w.text, start: start, end: end))
        }
        return out
    }

    /// - Parameter languageCode: 缺省 `"zh"`。
    ///   ponytail: `Transcript` 里没有 language 字段，全项目唯一来源是
    ///   `AirTrimApp/AppModel.swift` 转写调用点的 `language: "zh"` 字面量。将来真支持多语种
    ///   转写时，把语言码存进 `Transcript` 并一路传到这里，别继续默认。
    public static func document(transcript: Transcript, edits: EditList = EditList(),
                                languageCode: String = "zh") -> Document {
        let words = words(transcript: transcript, edits: edits)
        return Document(text: words.map(\.text).joined(),
                        languageCode: languageCode, engine: engineName, words: words)
    }

    /// 序列化。`.sortedKeys` 保证字节稳定（同 `SpikeJSON.encode` 的约定），便于 Agent 比对。
    public static func json(_ document: Document) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Document 全是 String/Double，编码不会抛；真抛了给空对象比崩好
        return (try? encoder.encode(document)) ?? Data("{}".utf8)
    }

    /// 秒取到毫秒（3 位小数）——hyperframes 导入时同样 `round3`，且它的一致性闸门是 80ms，
    /// 取整误差 ≤0.5ms 远在门内。这是单向派生的交换格式，不产生第二份权威时间戳：
    /// `Transcript`/`EditList` 里仍是 CMTime。
    static func milliseconds(_ t: CMTime) -> Double {
        (t.seconds * 1000).rounded() / 1000
    }
}
