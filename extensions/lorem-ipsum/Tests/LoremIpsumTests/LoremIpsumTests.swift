import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import LoremIpsum

actor FakeClipboard: Clipboard {
    private(set) var copied: [String] = []

    func copy(_ text: String) { copied.append(text) }
}

/// Every new seed is the same, so text after a paste is known but differs from seed 0's.
let nextSeed: UInt64 = 42

func makeHost(
    clipboard: FakeClipboard = FakeClipboard(),
    preferences: [String: ExtensionValue] = [:],
    state: [String: ExtensionValue] = [:]
) async throws -> PrismTestHost {
    try await PrismTestHost(
        LoremIpsum(clipboard: clipboard, makeSeed: { nextSeed }),
        extensionID: "prism.lorem-ipsum",
        preferences: preferences,
        state: state
    )
}

@Suite("Lorem Ipsum")
struct LoremIpsumTests {
    typealias CommandID = LoremIpsum.CommandID
    typealias ActionID = LoremIpsum.ActionID
    typealias StateKey = LoremIpsum.StateKey

    // MARK: - Generate Lorem Ipsum

    @Test("an empty search offers one Latin paragraph, sentence, and word")
    func emptyQuery() async throws {
        let prism = try await makeHost()
        let list = try await prism.list(CommandID.generate)

        #expect(list.items.map(\.id) == ["la-paragraphs-1", "la-sentences-1", "la-words-1"])
        #expect(list.items.map(\.title) == ["1 Paragraph", "1 Sentence", "1 Word"])
        #expect(list.filtering == .extension)
        #expect(list.showsDetail == true)
        #expect(list.items.allSatisfy { $0.subtitle == nil })
        #expect(list.items[2].accessories.first?.text == "5 characters")
        #expect(list.filters.map(\.id) == ["la", "zh", "ja", "ko", "de", "fr"])
        #expect(list.filters.map(\.title) == ["Latin", "中文", "日本語", "한국어", "Deutsch", "Français"])
    }

    @Test("a number sets the count for every kind")
    func count() async throws {
        let prism = try await makeHost()
        let list = try await prism.list(CommandID.generate, query: " 12 ")

        #expect(list.items.map(\.title) == ["12 Paragraphs", "12 Sentences", "12 Words"])
    }

    @Test("a word after the number narrows the list to that kind", arguments: [
        ("5 w", ["la-words-5"]),
        ("5words", ["la-words-5"]),
        ("3 Paragraphs", ["la-paragraphs-3"]),
        ("sent", ["la-sentences-1"]),
        ("3 段", ["la-paragraphs-3"]),
        ("50字", ["la-words-50"]),
        ("2 단어", ["la-words-2"]),
        ("1,000 w", ["la-words-1000"]),
    ])
    func narrows(query: String, ids: [String]) async throws {
        let prism = try await makeHost()
        #expect(try await prism.list(CommandID.generate, query: query).items.map(\.id) == ids)
    }

    @Test("a count past 1,000 or below 1 explains the limit", arguments: ["1001", "0", "99999999999999999999"])
    func outOfRange(query: String) async throws {
        let prism = try await makeHost()
        let list = try await prism.list(CommandID.generate, query: query)

        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "Try Another Number")
        #expect(list.emptyMessage?.message == "Type a number from 1 to 1,000.")
        #expect(list.filters.count == LoremLanguage.allCases.count)
    }

    @Test("text that names no kind asks for a number")
    func unknownKind() async throws {
        let prism = try await makeHost()
        let list = try await prism.list(CommandID.generate, query: "five")

        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "Type a Number")
    }

    @Test("the detail pane shows the row's text with its counts")
    func detail() async throws {
        let prism = try await makeHost()
        let row = try await prism.list(CommandID.generate, query: "3 p").items[0]
        let detail = try await prism.detail(row.id, in: CommandID.generate)
        let markdown = try #require(detail.markdown)

        #expect(markdown.hasPrefix("Lorem ipsum dolor sit amet, consectetur adipiscing elit. "))
        #expect(markdown.components(separatedBy: "\n\n").count == 3)
        #expect(detail.metadata.map(\.label) == ["Words", "Characters"])
        #expect(detail.metadata[0].value == "\(LoremIpsum.wordCount(markdown))")
        #expect(row.accessories.first?.text == "\(LoremIpsum.formatted(markdown.count)) characters")
    }

    @Test("Return pastes, ⌘⇧C copies, and ⌘R regenerates")
    func actions() async throws {
        let prism = try await makeHost()
        let row = try await prism.list(CommandID.generate, query: "1 p").items[0]

        #expect(row.actions.map(\.id) == [ActionID.paste, ActionID.copy, ActionID.regenerate])
        #expect(row.actions.map(\.shortcut) == [nil, ExtensionShortcut("cmd+shift+c"), ExtensionShortcut("cmd+r")])
    }

    @Test("Return has Prism paste the text the detail showed, then draws new text")
    func pastes() async throws {
        let clipboard = FakeClipboard()
        let prism = try await makeHost(clipboard: clipboard)
        let shown = try #require(try await prism.detail("la-sentences-4", in: CommandID.generate).markdown)

        let result = try await prism.perform(ActionID.paste, on: "la-sentences-4", in: CommandID.generate)

        #expect(result == ExtensionActionResult(.paste(text: shown), reload: true))
        #expect(await clipboard.copied.isEmpty)
        #expect(await prism.state[StateKey.seed] == .number(Double(nextSeed)))
        #expect(try await prism.detail("la-sentences-4", in: CommandID.generate).markdown != shown)
    }

    @Test("⌘⇧C copies the text and confirms it")
    func copies() async throws {
        let clipboard = FakeClipboard()
        let prism = try await makeHost(clipboard: clipboard)
        let shown = try await prism.detail("la-sentences-4", in: CommandID.generate).markdown

        let result = try await prism.perform(ActionID.copy, on: "la-sentences-4", in: CommandID.generate)

        #expect(result == ExtensionActionResult(.hud(message: "Copied 4 sentences"), reload: true))
        #expect(await clipboard.copied == [shown])
        #expect(await prism.state[StateKey.seed] == .number(Double(nextSeed)))
    }

    @Test("the same seed gives the same text after Prism restarts the extension")
    func stableAcrossRestarts() async throws {
        let prism = try await makeHost(state: [StateKey.seed: .number(7)])
        let before = try await prism.detail("la-paragraphs-2", in: CommandID.generate)

        try await prism.restart()

        #expect(try await prism.detail("la-paragraphs-2", in: CommandID.generate) == before)
    }

    @Test("⌘R regenerates the list without pasting")
    func regenerates() async throws {
        let clipboard = FakeClipboard()
        let prism = try await makeHost(clipboard: clipboard)
        let before = try await prism.detail("la-words-20", in: CommandID.generate)

        #expect(try await prism.perform(ActionID.regenerate, on: "la-words-20", in: CommandID.generate) == .reload())

        #expect(try await prism.detail("la-words-20", in: CommandID.generate) != before)
        #expect(await clipboard.copied.isEmpty)
    }

    @Test("with Start with “Lorem ipsum” off, the classic opening isn't forced")
    func withoutOpening() async throws {
        let prism = try await makeHost(preferences: [LoremIpsum.PreferenceID.startsWithLorem: .bool(false)])
        for kind in LoremKind.allCases {
            let text = try #require(try await prism.detail("la-\(kind.rawValue)-8", in: CommandID.generate).markdown)
            #expect(!text.lowercased().hasPrefix("lorem ipsum dolor sit amet"))
        }
    }

    @Test("an action on a row that can't exist fails plainly", arguments: [
        "la-words-0", "la-words-1001", "la-lines-3", "xx-words-3", "words-3", "la-words",
    ])
    func unknownRow(item: String) async throws {
        let clipboard = FakeClipboard()
        let prism = try await makeHost(clipboard: clipboard)

        let result = try await prism.perform(ActionID.copy, on: item, in: CommandID.generate)

        #expect(result == ExtensionActionResult(.failed(message: "Lorem Ipsum has no row “\(item)”.")))
        #expect(await clipboard.copied.isEmpty)
    }

    // MARK: - Languages

    @Test("a language picked with ⌘P is kept, and the list reopens in it")
    func picksLanguage() async throws {
        let prism = try await makeHost()

        let picked = try await prism.list(CommandID.generate, filter: "zh")
        #expect(picked.items.map(\.id) == ["zh-paragraphs-1", "zh-sentences-1", "zh-words-1"])
        #expect(picked.items[2].title == "1 Character")
        #expect(await prism.state[StateKey.language] == .string("zh"))

        let reopened = try await prism.list(CommandID.generate)
        #expect(reopened.items.map(\.id) == picked.items.map(\.id))
        #expect(reopened.filters.map(\.id) == ["zh", "la", "ja", "ko", "de", "fr"])
    }

    @Test("a filter Lorem Ipsum doesn't know keeps the saved language")
    func unknownFilter() async throws {
        let prism = try await makeHost(state: [StateKey.language: .string("ko")])

        #expect(try await prism.list(CommandID.generate, filter: "xx").items.first?.id == "ko-paragraphs-1")
        #expect(await prism.state[StateKey.language] == .string("ko"))
    }

    @Test("in Chinese, a word is a character, and the detail counts only characters")
    func chineseCharacters() async throws {
        let clipboard = FakeClipboard()
        let prism = try await makeHost(clipboard: clipboard, state: [StateKey.language: .string("zh")])
        let row = try await prism.list(CommandID.generate, query: "50字").items[0]
        let detail = try await prism.detail(row.id, in: CommandID.generate)
        let markdown = try #require(detail.markdown)

        #expect(row.title == "50 Characters")
        #expect(markdown.count == 50)
        #expect(!markdown.contains(" ") && !markdown.contains("。") && !markdown.contains("，"))
        #expect(detail.metadata.map(\.label) == ["Characters"])
        #expect(
            try await prism.perform(ActionID.copy, on: row.id, in: CommandID.generate)
                == ExtensionActionResult(.hud(message: "Copied 50 characters"), reload: true)
        )
    }

    @Test("Start with “Lorem ipsum” only opens Latin text")
    func openingIsLatin() async throws {
        let prism = try await makeHost(state: [StateKey.language: .string("de")])
        let paragraph = try #require(try await prism.detail("de-paragraphs-1", in: CommandID.generate).markdown)

        #expect(!paragraph.lowercased().hasPrefix("lorem ipsum"))
    }
}

@Suite("Lorem generator")
struct LoremGeneratorTests {
    static func text(_ language: LoremLanguage, _ kind: LoremKind, _ count: Int, seed: UInt64) -> String {
        LoremGenerator.text(
            LoremRequest(language: language, kind: kind, count: count), seed: seed, startsWithLorem: language == .latin
        )
    }

    @Test("Latin sentences have 4 to 16 words, a capital, and a full stop")
    func sentences() {
        for seed in UInt64(0)..<50 {
            let text = LoremGenerator.text(
                LoremRequest(language: .latin, kind: .sentences, count: 20), seed: seed, startsWithLorem: false
            )
            let sentences = text.split(separator: ". ").map { $0.hasSuffix(".") ? $0.dropLast() : $0 }
            #expect(sentences.count == 20)
            for sentence in sentences {
                #expect(LoremLanguage.latin.sentenceLengths.contains(sentence.split(separator: " ").count))
                #expect(sentence.first?.isUppercase == true)
                #expect(!sentence.hasSuffix(","))
            }
            #expect(text.hasSuffix("."))
        }
    }

    @Test("paragraphs have 4 to 8 sentences, separated by a blank line", arguments: LoremLanguage.allCases)
    func paragraphs(language: LoremLanguage) {
        for seed in UInt64(0)..<20 {
            let text = Self.text(language, .paragraphs, 5, seed: seed)
            let paragraphs = text.components(separatedBy: "\n\n")
            #expect(paragraphs.count == 5)
            for paragraph in paragraphs {
                let sentences = paragraph.components(separatedBy: language.period).count - 1
                #expect(LoremGenerator.paragraphLengths.contains(sentences))
                #expect(paragraph.hasSuffix(language.period))
            }
            #expect(!text.contains("  "))
            #expect(text == text.trimmingCharacters(in: .whitespacesAndNewlines))
            if language.countsCharacters {
                #expect(!text.contains(" "))
            }
        }
    }

    @Test("words are exactly as many as asked, without punctuation", arguments: LoremLanguage.allCases)
    func words(language: LoremLanguage) {
        for count in [1, 3, 8, 9, 1_000] {
            let text = Self.text(language, .words, count, seed: 3)
            if language.countsCharacters {
                #expect(text.count == count)
            } else {
                #expect(text.split(separator: " ").count == count)
            }
            #expect(!text.contains { ".,。，、".contains($0) })
        }
    }

    @Test("Latin words are lowercase and open with “lorem ipsum”")
    func latinWords() {
        for count in [1, 3, 8, 9, 1_000] {
            let words = Self.text(.latin, .words, count, seed: 3).split(separator: " ")
            #expect(words.allSatisfy { $0.allSatisfy(\.isLowercase) })
            #expect(Array(words.prefix(min(count, 8))).map(String.init) == Array(LoremGenerator.opening.prefix(count)))
        }
    }

    @Test("Japanese and Korean sentences end with a verb", arguments: [LoremLanguage.japanese, .korean])
    func endings(language: LoremLanguage) {
        let text = Self.text(language, .sentences, 30, seed: 5)
        let sentences = text.components(separatedBy: language.period).dropLast()
        #expect(sentences.count == 30)
        for sentence in sentences {
            #expect(language.endings.contains { sentence.hasSuffix($0) })
        }
    }

    @Test("Chinese sentences are one to three clauses, each opening with a word, not a particle")
    func chineseClauses() {
        let sentences = Self.text(.chinese, .sentences, 50, seed: 2).components(separatedBy: "。").dropLast()
        #expect(sentences.count == 50)
        for sentence in sentences {
            let clauses = sentence.components(separatedBy: "，")
            #expect((1...3).contains(clauses.count))
            #expect(clauses.allSatisfy { $0.count >= 6 && !$0.hasPrefix("的") && !$0.hasPrefix("在") })
        }
    }

    @Test("rows with different languages, kinds, or counts get different text from one seed")
    func rowsDiffer() {
        let three = Self.text(.latin, .sentences, 3, seed: 9)
        #expect(!Self.text(.latin, .sentences, 4, seed: 9).hasPrefix(three))
        #expect(three == Self.text(.latin, .sentences, 3, seed: 9))
        #expect(Self.text(.german, .words, 5, seed: 9) != Self.text(.french, .words, 5, seed: 9))
    }
}
