import Foundation

/// AI 社交媒体文案生成：标题 + 视频配文 + 标签。
/// 只上传有效句子文字稿（已剪辑掉的内容不参与分析）。
/// system prompt = 共享 taskPrompt + 人设块（SocialCopyPersona），见 `systemPrompt(for:)`。
public struct SocialCopywriter: Sendable {
    public let client: OpenAIChatClient

    public init(client: OpenAIChatClient) {
        self.client = client
    }

    /// 共享任务 prompt：任务流程 + 输出格式契约 + 全局约束。不随人设变。
    static let taskPrompt = """
    你是一名内容运营专家。你的任务是：根据我提供的一段口播字幕文字稿，生成适合发布到抖音的视频标题、发布文案和标签。

    你的目标不是简单总结内容，而是把这段内容转化成更容易传播、更容易引发目标受众共鸣的短视频文案。你的人设、受众、标题钩子、文案语气、标签方向与红线要求，由下方人设指令块给出——严格遵守，不要越出该赛道的表达方式。

    ---

    ## 一、内容分析

    先分析这段口播：

    1. 视频核心观点：用一句话总结作者真正想表达的东西。
    2. 结合人设指令块判断：目标用户是谁、内容属于哪类价值。

    ---

    ## 二、生成标题

    从人设指令块「标题钩子」给出的类型中，挑选最合适的 3 种，每类各出 1 个，共 3 个标题方案。

    要求：
    - 标题控制在 15-25 字
    - 不制造虚假焦虑
    - 不使用低质量标题党
    - 保持该赛道人的可信感

    ---

    ## 三、生成抖音发布文案

    按人设指令块「文案语气」的每个角度各出 1 个方案，共 3 个版本。

    要求：
    - 长度 50-150 字
    - 避免空泛鸡汤
    - 保留该赛道的理性表达
    - 可以加入“你怎么看？”“评论区聊聊你的经历”等互动引导

    ---

    ## 四、生成标签

    按人设指令块「标签方向」生成三类标签，每类 3 个：
    - 精准标签：适合精准推荐给目标人群
    - 泛流量标签：扩大推荐范围
    - 身份标签：针对目标人群

    ---

    ## 五、推荐最终发布方案

    从所有结果中选择【最佳标题】【最佳发布文案】【最佳标签组合】，并解释为什么这个组合最适合抖音传播。

    分析：
    - 用户为什么会停留
    - 为什么可能点赞收藏
    - 为什么可能评论互动

    ---

    输出格式：

    ================

    【内容定位】

    xxx

    【标题方案】

    1. [类型]
    标题

    ...

    【发布文案】

    方案1：
    xxx

    ...

    【标签】

    精准：
    xxx

    流量：
    xxx

    身份：
    xxx

    【最终推荐】

    标题：
    xxx

    文案：
    xxx

    标签：
    xxx

    推荐理由：
    xxx

    ================

    注意：
    人设指令块中「红线」是绝对禁止项，违反即整篇不合格。以「语感判据」为最终自检标准：生成后对照判据检查一遍，不像就重写。
    """

    /// 由人设渲染完整 system prompt：自包含 fullPrompt 优先，否则共享任务 + 人设块。
    static func systemPrompt(for persona: SocialCopyPersona) -> String {
        if let full = persona.fullPrompt { return full }
        return taskPrompt + "\n\n" + persona.promptBlock
    }

    /// 生成社交媒体文案。text 应为剪辑后保留的有效字幕文本。
    public func generate(from text: String,
                         persona: SocialCopyPersona) async throws -> String {
        try await client.complete(system: Self.systemPrompt(for: persona), user: text)
    }
}
