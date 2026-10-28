/// Chinese placeholder text built from clause patterns. Words drawn at random
/// don't read as Chinese, because particles and conjunctions land anywhere;
/// a few fixed shapes give text like “遥远的灯光渐渐亮起，微风轻轻吹过湖面。”
enum ChineseLorem {
    static func sentence(using random: inout some RandomNumberGenerator) -> String {
        let count = [1, 2, 2, 3].randomElement(using: &random) ?? 2
        let clauses = (0..<count).map { index in
            let clause = clause(using: &random)
            guard index > 0, Bool.random(using: &random) else { return clause }
            return pick(connectives, &random) + clause
        }
        return clauses.joined(separator: "，") + "。"
    }

    static func clause(using random: inout some RandomNumberGenerator) -> String {
        switch Int.random(in: 0..<5, using: &random) {
        case 0:
            let subject = pick(nouns, &random)
            return subject + pick(adverbs, &random) + pick(transitiveVerbs, &random) + pick(nouns, &random, not: subject)
        case 1:
            return pick(adjectives, &random) + "的" + pick(nouns, &random) + pick(adverbs, &random)
                + pick(intransitiveVerbs, &random)
        case 2:
            return pick(nouns, &random) + "在" + pick(places, &random) + pick(intransitiveVerbs, &random)
        case 3:
            return pick(adverbs, &random) + pick(transitiveVerbs, &random) + pick(adjectives, &random) + "的"
                + pick(nouns, &random)
        default:
            let subject = pick(nouns, &random)
            return pick(times, &random) + subject + pick(transitiveVerbs, &random) + pick(nouns, &random, not: subject)
        }
    }

    static let nouns = [
        "微风", "阳光", "河流", "城市", "街道", "灯光", "云朵", "树林", "小路", "湖面", "草地", "星光",
        "月色", "海浪", "花园", "故事", "声音", "记忆", "季节", "日子", "人们", "孩子", "山谷",
        "雨水", "时光", "文字", "书页", "天空", "窗台", "旧信", "钟声", "影子", "落叶",
    ]

    static let adjectives = [
        "遥远", "安静", "温暖", "柔和", "明亮", "清新", "熟悉", "陌生", "简单", "美好", "古老", "细小",
        "漫长", "淡淡",
    ]

    static let adverbs = [
        "轻轻", "静静", "渐渐", "慢慢", "悄悄", "依然", "总是", "已经", "仿佛", "似乎", "默默",
    ]

    static let transitiveVerbs = [
        "穿过", "照亮", "走过", "留下", "带走", "等待", "想起", "看见", "听见", "吹过", "掠过", "填满",
        "唤醒", "记住",
    ]

    static let intransitiveVerbs = [
        "亮起", "散去", "落下", "远去", "醒来", "沉默", "流淌", "消失", "回来", "停留", "展开", "闪烁",
    ]

    static let places = ["窗外", "街角", "湖边", "山间", "林中", "远方", "路上", "桥下", "屋顶", "海边"]

    static let times = ["清晨", "黄昏", "夜里", "午后", "那天", "后来", "此刻", "雨后"]

    static let connectives = ["于是", "然后", "但是", "只是", "也许"]

    private static func pick(
        _ words: [String], _ random: inout some RandomNumberGenerator, not excluded: String? = nil
    ) -> String {
        while true {
            let word = words[Int.random(in: 0..<words.count, using: &random)]
            if word != excluded { return word }
        }
    }
}
