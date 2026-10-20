import Foundation
import PrismExtensionKit

/// Maps colors to list rows, details, and actions.
enum ColorRows {
    // MARK: - Saved colors

    static func savedItem(_ saved: SavedColor, formats: [ColorFormat]) -> ExtensionListItem {
        let name = ColorNames.match(for: saved.color)
        var actions = copyActions(for: saved.color, formats: formats)
        actions.append(ExtensionAction(
            id: saved.isFavorite ? ColorPicker.ActionID.unfavorite : ColorPicker.ActionID.favorite,
            title: saved.isFavorite ? "Remove from Favorites" : "Add to Favorites",
            symbol: saved.isFavorite ? "star.slash" : "star",
            shortcut: ExtensionShortcut("cmd+shift+f")
        ))
        actions.append(ExtensionAction(
            id: ColorPicker.ActionID.delete, title: "Delete Color", symbol: "trash",
            style: .destructive, shortcut: ExtensionShortcut("cmd+delete")
        ))
        actions.append(ExtensionAction(
            id: ColorPicker.ActionID.clearRecent, title: "Clear Recent Colors…", symbol: "xmark.bin",
            style: .destructive, shortcut: ExtensionShortcut("cmd+shift+delete"),
            confirmationMessage: "Removes every color that isn’t a favorite."
        ))
        return ExtensionListItem(
            id: saved.id,
            title: formats[0].string(for: saved.color),
            subtitle: name.description,
            icon: .swatch(saved.color.hex),
            accessories: saved.isFavorite ? [ExtensionListAccessory(symbol: "star.fill", tint: "gold", help: "Favorite")] : [],
            keywords: keywords(for: saved.color, name: name),
            section: saved.isFavorite ? "Favorites" : "Recent",
            detail: detail(for: saved.color, name: name, savedAt: saved.savedAt),
            actions: actions
        )
    }

    // MARK: - Converted colors

    /// One row per format, every format, in the user's order. The row ID
    /// carries what was typed, so saving reads the same color again
    /// (`convertedColor(itemID:)`).
    static func formatItems(for color: RGBColor, input: String, formats: [ColorFormat]) -> [ExtensionListItem] {
        let name = ColorNames.match(for: color)
        return formats.map { format in
            let text = format.string(for: color)
            return ExtensionListItem(
                id: "\(format.rawValue):\(input)",
                title: text,
                subtitle: format.title,
                icon: .swatch(color.hex),
                section: name.description,
                actions: [copyAction(format, text: text), saveAction]
            )
        }
    }

    static func namedItem(_ named: ColorNames.Named, formats: [ColorFormat]) -> ExtensionListItem {
        var actions = copyActions(for: named.color, formats: formats)
        actions.append(ExtensionAction(
            id: ColorPicker.ActionID.copyName, title: "Copy Name", symbol: "textformat",
            kind: .copy(text: named.keyword), shortcut: ExtensionShortcut("cmd+shift+n")
        ))
        actions.append(saveAction)
        return ExtensionListItem(
            id: "name:\(named.keyword)",
            title: named.name,
            subtitle: formats[0].string(for: named.color),
            icon: .swatch(named.color.hex),
            section: "Named Colors",
            actions: actions
        )
    }

    /// The color a Convert Color row shows.
    static func convertedColor(itemID: String) -> RGBColor? {
        guard let colon = itemID.firstIndex(of: ":") else { return nil }
        return ColorParser.parse(String(itemID[itemID.index(after: colon)...]))
    }

    // MARK: - Shared

    /// Copy in each format that is on; the first runs on Return.
    static func copyActions(for color: RGBColor, formats: [ColorFormat]) -> [ExtensionAction] {
        formats.map { copyAction($0, text: $0.string(for: color)) }
    }

    private static func copyAction(_ format: ColorFormat, text: String) -> ExtensionAction {
        ExtensionAction(
            id: "\(ColorPicker.ActionID.copyPrefix)\(format.rawValue)", title: "Copy \(format.title)",
            symbol: "doc.on.doc", kind: .copy(text: text)
        )
    }

    private static func detail(for color: RGBColor, name: ColorNames.Match, savedAt: Date) -> ExtensionDetail {
        ExtensionDetail(
            title: color.hex,
            subtitle: name.description,
            icon: .swatch(color.hex),
            sections: [ExtensionDetailSection(
                title: "Formats",
                rows: ColorFormat.allCases.map { ExtensionMetadataRow(label: $0.title, value: $0.string(for: color)) }
            )],
            metadata: [ExtensionMetadataRow(label: "Added", date: savedAt)]
        )
    }

    /// Every format and the name, so typing any of them finds the color.
    private static func keywords(for color: RGBColor, name: ColorNames.Match) -> [String] {
        ColorFormat.allCases.map { $0.string(for: color) } + [name.name]
    }

    private static let saveAction = ExtensionAction(
        id: ColorPicker.ActionID.save, title: "Save to Colors", symbol: "square.and.arrow.down",
        shortcut: ExtensionShortcut("cmd+s")
    )
}
