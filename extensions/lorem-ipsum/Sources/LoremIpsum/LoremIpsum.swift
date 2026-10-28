import Foundation
import PrismExtensionKit

/// Placeholder text: type how many paragraphs, sentences, or words, pick a
/// language with ⌘P, and paste them. The text comes from a seed kept in
/// Prism, so the row, its detail pane, and what is pasted agree; using the
/// text draws a new seed.
@main
struct LoremIpsum: PrismExtension {
    enum CommandID {
        static let generate = "generate"
    }

    enum ActionID {
        static let paste = "paste"
        static let copy = "copy"
        static let regenerate = "regenerate"
    }

    enum PreferenceID {
        static let startsWithLorem = "startsWithLorem"
    }

    enum StateKey {
        static let seed = "seed"
        static let language = "language"
    }

    let clipboard: any Clipboard
    let makeSeed: @Sendable () -> UInt64

    init() {
        self.init(clipboard: SystemClipboard(), makeSeed: { UInt64.random(in: 0...UInt64.max) })
    }

    init(clipboard: any Clipboard, makeSeed: @escaping @Sendable () -> UInt64) {
        self.clipboard = clipboard
        self.makeSeed = makeSeed
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.generate else {
            throw PrismExtensionError("Lorem Ipsum has no list “\(command)”.")
        }
        let language = await Self.language(choosing: filter, context: context)
        // Prism shows the first filter as chosen until the user picks one,
        // so the language last picked goes first.
        let filters = ([language] + LoremLanguage.allCases.filter { $0 != language }).map {
            ExtensionListFilter(id: $0.rawValue, title: $0.title)
        }
        let placeholder = "How many? Try 3, 5 w, or 20 sentences…"
        switch LoremQuery(query) {
        case let .rows(count, kinds):
            let seed = await Self.seed(context)
            let startsWithLorem = Self.startsWithLorem(context)
            return ExtensionList(
                items: kinds.map { kind in
                    let request = LoremRequest(language: language, kind: kind, count: count)
                    return Self.item(request, text: Self.text(request, seed: seed, startsWithLorem: startsWithLorem))
                },
                filtering: .extension,
                searchPlaceholder: placeholder,
                filters: filters,
                showsDetail: true
            )
        case .countOutOfRange:
            return ExtensionList(
                items: [], filtering: .extension, searchPlaceholder: placeholder, filters: filters,
                emptyMessage: ExtensionListMessage(
                    title: "Try Another Number", message: "Type a number from 1 to 1,000.", symbol: "number"
                )
            )
        case .unknownKind:
            return ExtensionList(
                items: [], filtering: .extension, searchPlaceholder: placeholder, filters: filters,
                emptyMessage: ExtensionListMessage(
                    title: "Type a Number",
                    message: "Add paragraphs, sentences, or words after it, such as “5 words”.",
                    symbol: "text.alignleft"
                )
            )
        }
    }

    func detail(command: String, item: String, context: PrismContext) async throws -> ExtensionDetail {
        let request = try Self.request(item)
        let text = Self.text(request, seed: await Self.seed(context), startsWithLorem: Self.startsWithLorem(context))
        // A word count means nothing in Chinese or Japanese, which don't space words.
        let words = request.language.countsCharacters
            ? [] : [ExtensionMetadataRow(label: "Words", value: Self.formatted(Self.wordCount(text)))]
        return ExtensionDetail(
            markdown: text,
            metadata: words + [ExtensionMetadataRow(label: "Characters", value: Self.formatted(text.count))]
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        let request = try Self.request(item)
        switch action {
        case ActionID.paste, ActionID.copy:
            // The seed changes, so a launcher left open (a paste that fell
            // back to copying) shows the text Return would use next.
            return ExtensionActionResult(
                await use(request, pasting: action == ActionID.paste, context: context), reload: true
            )
        case ActionID.regenerate:
            await rotateSeed(context)
            return .reload()
        default:
            throw PrismExtensionError("Lorem Ipsum has no action “\(action)”.")
        }
    }

    // MARK: - Pasting and copying

    /// Has Prism paste the text the row shows, or copies it, then draws a new
    /// seed so the next text is different, as each run of a generator should be.
    private func use(_ request: LoremRequest, pasting: Bool, context: PrismContext) async -> ExtensionCommandResult {
        let text = Self.text(request, seed: await Self.seed(context), startsWithLorem: Self.startsWithLorem(context))
        await rotateSeed(context)
        guard !pasting else { return .paste(text: text) }
        await clipboard.copy(text)
        return .hud(message: request.kind.copiedMessage(count: request.count, in: request.language))
    }

    /// State numbers are doubles, so the seed keeps to the 53 bits a double holds exactly.
    private func rotateSeed(_ context: PrismContext) async {
        let seed = makeSeed() & (1 << 53 - 1)
        await context.setState(.number(Double(seed)), for: StateKey.seed)
    }

    private static func seed(_ context: PrismContext) async -> UInt64 {
        guard let value = await context.state(StateKey.seed)?.numberValue, value >= 0, value < 0x1p53 else {
            return 0
        }
        return UInt64(value)
    }

    // MARK: - Language

    /// The language picked with ⌘P, kept so the list reopens in it.
    private static func language(choosing filter: String?, context: PrismContext) async -> LoremLanguage {
        let saved = await language(context)
        guard let picked = filter.flatMap(LoremLanguage.init(rawValue:)) else { return saved }
        if picked != saved {
            await context.setState(.string(picked.rawValue), for: StateKey.language)
        }
        return picked
    }

    private static func language(_ context: PrismContext) async -> LoremLanguage {
        await context.state(StateKey.language)?.stringValue.flatMap(LoremLanguage.init(rawValue:)) ?? .latin
    }

    // MARK: - Rows

    static func text(_ request: LoremRequest, seed: UInt64, startsWithLorem: Bool) -> String {
        LoremGenerator.text(request, seed: seed, startsWithLorem: startsWithLorem)
    }

    /// Return pastes, as Prism's own Clipboard History does; ⌘⇧C copies.
    static func item(_ request: LoremRequest, text: String) -> ExtensionListItem {
        ExtensionListItem(
            id: request.id,
            title: request.kind.title(count: request.count, in: request.language),
            icon: ExtensionIcon(symbol: request.kind.symbol, tint: "gray"),
            accessories: [ExtensionListAccessory(text: "\(formatted(text.count)) characters")],
            actions: [
                ExtensionAction(id: ActionID.paste, title: "Paste to Active App", symbol: "doc.on.clipboard"),
                ExtensionAction(
                    id: ActionID.copy, title: "Copy to Clipboard", symbol: "doc.on.doc",
                    shortcut: ExtensionShortcut("cmd+shift+c")
                ),
                ExtensionAction(
                    id: ActionID.regenerate, title: "Regenerate", symbol: "arrow.clockwise",
                    shortcut: ExtensionShortcut("cmd+r")
                ),
            ]
        )
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func formatted(_ number: Int) -> String {
        number.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func request(_ item: String) throws -> LoremRequest {
        guard let request = LoremRequest(id: item) else {
            throw PrismExtensionError("Lorem Ipsum has no row “\(item)”.")
        }
        return request
    }

    private static func startsWithLorem(_ context: PrismContext) -> Bool {
        context.preferences.bool(PreferenceID.startsWithLorem, default: true)
    }
}
