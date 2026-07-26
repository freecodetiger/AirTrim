import Foundation
import WhisperKit

/// 强制逐 token 切词的 tokenizer 包装器。
///
/// 绕过 WhisperKit 上游 bug：`splitToWordTokens` 对无空格语言有特判，但语言检测
/// 用 `NLLanguageRecognizer`，中文返回 "zh-Hans"/"zh-Hant"，与白名单字面量 "zh"
/// 不相等，导致中文误走英文式按空格分词（整句粘成单"词"→ 触发 1.4s 截断）。
/// 本包装器复刻其 private `splitTokensOnUnicode` 算法（按 UTF-8 解码完整性分组，
/// 与日语等命中特判语言的行为一致），其余全部委托原 tokenizer。
public final class ZhWordSplitTokenizer: WhisperTokenizer {
    private let base: any WhisperTokenizer

    public init(wrapping base: any WhisperTokenizer) {
        self.base = base
    }

    public func encode(text: String) -> [Int] { base.encode(text: text) }
    public func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    public func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    public func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    public var specialTokens: SpecialTokens { base.specialTokens }
    public var allLanguageTokens: Set<Int> { base.allLanguageTokens }

    public func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedFull = base.decode(tokens: tokenIds)
        let replacement = "\u{fffd}"

        var words: [String] = []
        var wordTokens: [[Int]] = []
        var current: [Int] = []
        for token in tokenIds {
            current.append(token)
            let decoded = base.decode(tokens: current)
            // 字节级 BPE 可能把一个汉字拆成多个 token，中间态解码出 U+FFFD；
            // 只有解码完整（或原文本身含 U+FFFD）时才落一个"词"
            var replacementIsInFullString = false
            if let range = decoded.range(of: replacement) {
                replacementIsInFullString = decodedFull[range] == replacement
            }
            if !decoded.contains(replacement) || replacementIsInFullString {
                words.append(decoded)
                wordTokens.append(current)
                current = []
            }
        }
        return (words, wordTokens)
    }
}
