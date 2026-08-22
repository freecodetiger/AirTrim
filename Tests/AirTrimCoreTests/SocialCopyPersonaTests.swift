import Testing
@testable import AirTrimCore

/// 人设模板（SocialCopyPersona）与 prompt 组合（SocialCopywriter）的契约测试。
/// 硬性要求：人设块只定义表达方式，不含任务级指令；字段与 md 各节一一对应。
@Suite("社交文案人设")
struct SocialCopyPersonaTests {

    @Test func allHasSixUniquePersonas() {
        let ids = SocialCopyPersona.all.map(\.id)
        #expect(ids.count == 6)
        #expect(Set(ids).count == 6, "id 必须唯一")
        #expect(SocialCopyPersona.all.allSatisfy { !$0.displayName.isEmpty && !$0.description.isEmpty })
    }

    @Test func promptBlockContainsAllSections() {
        let sections = ["受众画像", "内容价值类型", "标题钩子", "文案语气",
                        "标签方向", "抖音平台锚点", "红线", "语感判据"]
        for persona in SocialCopyPersona.all {
            let block = persona.promptBlock
            for section in sections {
                #expect(block.contains(section), "\(persona.id) 缺少「\(section)」")
            }
            // 语感判据与红线是 persona 特有内容，必须出现
            #expect(block.contains(persona.tasteCheck))
            #expect(block.contains(persona.redLines))
        }
    }

    @Test func promptBlockHasNoTaskLevelDirectives() {
        // 人设块不得重复任务流程 / 输出格式（那属于 taskPrompt）
        for persona in SocialCopyPersona.all {
            let block = persona.promptBlock
            #expect(!block.contains("你的任务是"))
            #expect(!block.contains("请按以下格式输出"))
            #expect(!block.contains("【标题方案】"))
            #expect(!block.contains("50-150"))
        }
    }

    @Test func generalUsesSelfContainedFullPrompt() {
        let prompt = SocialCopywriter.systemPrompt(for: .general)
        // fullPrompt 生效：自包含，不走 taskPrompt + promptBlock
        #expect(SocialCopyPersona.general.fullPrompt != nil)
        #expect(prompt == SocialCopyPersona.general.fullPrompt)
        // 新 prompt 锚点
        #expect(prompt.contains("方向一：真实记录型"))
        #expect(prompt.contains("不要输出你的分析过程"))
        // 不含共享 taskPrompt 的任务级指令/旧输出格式
        #expect(!prompt.contains("【标题方案】"))
        #expect(!prompt.contains("共 3 个标题方案"))
        #expect(!prompt.contains("最终推荐"))
    }

    @Test func systemPromptComposesTaskAndPersona() {
        let prompt = SocialCopywriter.systemPrompt(for: .techGrowth)
        // taskPrompt 锚点：输出契约 + 精简数量
        #expect(prompt.contains("【标题方案】"))
        #expect(prompt.contains("共 3 个标题方案"))
        #expect(prompt.contains("每类 3 个"))
        // persona 锚点：人设块内容
        #expect(prompt.contains("技术成长派"))
        #expect(prompt.contains("程序员成长，最后拼的不是会多少框架"))  // 标题钩子范例
        #expect(prompt.contains("语感判据"))
    }

    @Test func differentPersonasYieldDifferentPrompts() {
        let beauty = SocialCopywriter.systemPrompt(for: .beauty)
        let fitness = SocialCopywriter.systemPrompt(for: .fitness)
        #expect(beauty != fitness)
        #expect(!beauty.contains("训练"))
        #expect(!fitness.contains("底妆"))
    }
}
