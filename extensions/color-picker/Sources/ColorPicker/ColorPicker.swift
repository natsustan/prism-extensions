import Foundation
import PrismExtensionKit

/// Picks colors from the screen, keeps them, and writes them out in the
/// formats people paste into code and design tools. Pick Color is
/// `interactive`, so Prism closes the launcher before the loupe appears.
@main
struct ColorPicker: PrismExtension {
    enum CommandID {
        static let pick = "pick-color"
        static let colors = "colors"
        static let convert = "convert-color"
    }

    enum ActionID {
        /// Followed by a `ColorFormat` raw value.
        static let copyPrefix = "copy-"
        static let copyName = "copy-name"
        static let favorite = "favorite"
        static let unfavorite = "unfavorite"
        static let delete = "delete"
        static let clearRecent = "clear-recent"
        static let save = "save"
    }

    enum FilterID {
        static let favorites = "favorites"
    }

    enum PreferenceID {
        static let formats = "formats"
    }

    let sampler: any ColorSampling
    let clipboard: any Clipboard
    let now: @Sendable () -> Date

    init() {
        self.init(sampler: ScreenColorSampler(), clipboard: SystemClipboard(), now: { Date() })
    }

    init(sampler: any ColorSampling, clipboard: any Clipboard, now: @escaping @Sendable () -> Date) {
        self.sampler = sampler
        self.clipboard = clipboard
        self.now = now
    }

    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        guard command == CommandID.pick else {
            throw PrismExtensionError("Color Picker has no command “\(command)”.")
        }
        guard let color = await sampler.sample() else { return .done }
        var saved = await SavedColors.load(from: context)
        saved.add(color, at: now())
        try await saved.save(to: context)
        let text = Self.formats(context).on[0].string(for: color)
        await clipboard.copy(text)
        await context.listChanged(CommandID.colors)
        return .hud(message: "Copied \(text)")
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        switch command {
        case CommandID.colors:
            return await savedColors(filter: filter, context: context)
        case CommandID.convert:
            return convert(query, formats: Self.formats(context))
        default:
            throw PrismExtensionError("Color Picker has no list “\(command)”.")
        }
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        var saved = await SavedColors.load(from: context)
        switch action {
        case ActionID.favorite, ActionID.unfavorite:
            saved.setFavorite(action == ActionID.favorite, id: item)
        case ActionID.delete:
            saved.remove(id: item)
        case ActionID.clearRecent:
            saved.removeRecent()
        case ActionID.save:
            guard let color = ColorRows.convertedColor(itemID: item) else {
                throw PrismExtensionError("This color can’t be saved.")
            }
            saved.add(color, at: now())
            try await saved.save(to: context)
            await context.listChanged(CommandID.colors)
            return ExtensionActionResult(.keepOpen(message: "Saved \(color.hex) to Colors."))
        default:
            throw PrismExtensionError("Color Picker has no action “\(action)”.")
        }
        try await saved.save(to: context)
        return .reload()
    }

    func preferenceItems(_ preference: String, context: PrismContext) async throws -> [ExtensionPreferenceItem] {
        guard preference == PreferenceID.formats else { return [] }
        return Self.formatItems
    }

    // MARK: - Lists

    private func savedColors(filter: String?, context: PrismContext) async -> ExtensionList {
        let saved = await SavedColors.load(from: context)
        let showsFavorites = filter == FilterID.favorites
        let colors = showsFavorites ? saved.favorites : saved.favorites + saved.colors.filter { !$0.isFavorite }
        let formats = Self.formats(context).on
        return ExtensionList(
            items: colors.map { ColorRows.savedItem($0, formats: formats) },
            searchPlaceholder: "Search colors…",
            filters: [ExtensionListFilter(id: FilterID.favorites, title: "Favorites", symbol: "star")],
            emptyMessage: showsFavorites
                ? ExtensionListMessage(
                    title: "No Favorites", message: "Add a color to Favorites with ⌘⇧F.", symbol: "star"
                )
                : ExtensionListMessage(
                    title: "No Colors", message: "Colors you pick with Pick Color appear here.", symbol: "eyedropper"
                ),
            showsDetail: true
        )
    }

    private func convert(_ query: String, formats: (on: [ColorFormat], all: [ColorFormat])) -> ExtensionList {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = [ExtensionListItem]()
        if let color = ColorParser.parse(query) {
            items = ColorRows.formatItems(for: color, input: query, formats: formats.all)
        }
        items += ColorNames.search(query).prefix(50).map { ColorRows.namedItem($0, formats: formats.on) }
        return ExtensionList(
            items: items,
            filtering: .extension,
            searchPlaceholder: "#FF6363, rgb(255 99 99), coral…",
            emptyMessage: query.isEmpty
                ? ExtensionListMessage(
                    title: "Type a Color",
                    message: "HEX, RGB, HSL, OKLCH, Display P3, or a CSS color name.",
                    symbol: "paintpalette"
                )
                : ExtensionListMessage(title: "Not a Color", message: "Try #FF6363, rgb(255 99 99), or coral.", symbol: "questionmark")
        )
    }

    // MARK: - Formats

    static let formatItems = ColorFormat.allCases.map { format in
        ExtensionPreferenceItem(id: format.rawValue, title: format.title, isOn: format.isOnByDefault)
    }

    /// The formats that are on, in the user's order, and every format with
    /// those first. Pick Color copies the first that is on; with every
    /// format off, that is HEX.
    static func formats(_ context: PrismContext) -> (on: [ColorFormat], all: [ColorFormat]) {
        let entries = context.preferences.orderedList(PreferenceID.formats).resolved(with: formatItems)
        let on = entries.filter(\.isOn).compactMap { ColorFormat(rawValue: $0.id) }
        let off = entries.filter { !$0.isOn }.compactMap { ColorFormat(rawValue: $0.id) }
        return (on.isEmpty ? [.hex] : on, on + off)
    }
}
