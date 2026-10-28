import Foundation

/// What a row generates. The raw value is part of the row’s item ID.
enum LoremKind: String, CaseIterable, Sendable {
    case paragraphs
    case sentences
    case words

    /// What a query may start with to pick this kind: English, and the
    /// Chinese, Japanese, and Korean nouns, so `3 段` or `50字` work.
    var terms: [String] {
        switch self {
        case .paragraphs: ["paragraphs", "段落", "문단"]
        case .sentences: ["sentences", "句子", "文", "문장"]
        case .words: ["words", "characters", "字", "词", "文字", "単語", "단어"]
        }
    }

    func title(count: Int, in language: LoremLanguage) -> String {
        let noun = switch self {
        case .paragraphs: count == 1 ? "Paragraph" : "Paragraphs"
        case .sentences: count == 1 ? "Sentence" : "Sentences"
        case .words where language.countsCharacters: count == 1 ? "Character" : "Characters"
        case .words: count == 1 ? "Word" : "Words"
        }
        return "\(count) \(noun)"
    }

    /// The HUD after copying: “Copied 3 paragraphs”.
    func copiedMessage(count: Int, in language: LoremLanguage) -> String {
        "Copied \(title(count: count, in: language).lowercased())"
    }

    var symbol: String {
        switch self {
        case .paragraphs: "text.alignleft"
        case .sentences: "text.quote"
        case .words: "textformat.abc"
        }
    }

    var seedSalt: UInt64 {
        switch self {
        case .paragraphs: 1
        case .sentences: 2
        case .words: 3
        }
    }
}

/// A row of the list: a language, a kind, and how many. Its ID carries all
/// three, because `detail.load` and `action.perform` name only the item.
struct LoremRequest: Hashable, Sendable {
    static let maximumCount = 1_000

    let language: LoremLanguage
    let kind: LoremKind
    let count: Int

    var id: String { "\(language.rawValue)-\(kind.rawValue)-\(count)" }

    init(language: LoremLanguage, kind: LoremKind, count: Int) {
        self.language = language
        self.kind = kind
        self.count = count
    }

    init?(id: String) {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let language = LoremLanguage(rawValue: String(parts[0])),
              let kind = LoremKind(rawValue: String(parts[1])),
              let count = Int(parts[2]),
              (1...Self.maximumCount).contains(count)
        else { return nil }
        self.init(language: language, kind: kind, count: count)
    }
}

/// What the user typed: an optional count, then optionally the start of a
/// kind, such as `5`, `5 w`, `3 paragraphs`, `words`, or `50字`.
enum LoremQuery: Equatable, Sendable {
    case rows(count: Int, kinds: [LoremKind])
    case countOutOfRange
    case unknownKind

    init(_ query: String) {
        var rest = Substring(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        // Thousands separators are allowed, as the limit is written “1,000”.
        let digits = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ",") }
        var count = 1
        if !digits.isEmpty {
            guard let value = Int(digits.filter(\.isNumber)), (1...LoremRequest.maximumCount).contains(value) else {
                self = .countOutOfRange
                return
            }
            count = value
            rest = rest.dropFirst(digits.count)
        }
        let term = rest.trimmingCharacters(in: .whitespaces)
        let kinds = LoremKind.allCases.filter { kind in
            term.isEmpty || kind.terms.contains { $0.hasPrefix(term) }
        }
        self = kinds.isEmpty ? .unknownKind : .rows(count: count, kinds: kinds)
    }
}
