import PrismExtensionKit

/// Converts between Arabic and Chinese numbers as the user types: digits
/// become lowercase, uppercase, and amount-in-words rows; Chinese numerals
/// become digits. Everything is worked out from the query, so the
/// extension keeps no state.
@main
struct ChineseNumbers: PrismExtension {
    enum CommandID {
        static let convert = "convert"
    }

    enum ItemID {
        static let lowercase = "lowercase"
        static let uppercase = "uppercase"
        static let amount = "amount"
        static let arabic = "arabic"
    }

    enum ActionID {
        static let paste = "paste"
        static let copy = "copy"
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.convert else {
            throw PrismExtensionError(String(localized: "Chinese Numbers has no list “\(command)”.", bundle: .module.prismLocalized))
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Self.list(empty: String(localized: "Type a Number", bundle: .module.prismLocalized), String(localized: "Digits such as 12345.67, or Chinese such as 一万二千.", bundle: .module.prismLocalized), symbol: "textformat.123")
        }
        do {
            return Self.list(ConversionRows.items(for: try ArabicNumber(parsing: query)))
        } catch .tooLarge {
            return Self.list(
                empty: String(localized: "Number Too Large", bundle: .module.prismLocalized), String(localized: "Chinese Numbers goes up to 16 digits before the point.", bundle: .module.prismLocalized),
                symbol: "exclamationmark.triangle"
            )
        } catch {
            if let number = ChineseNumberParser.parse(query) {
                return Self.list(ConversionRows.items(forChinese: number))
            }
            return Self.list(empty: String(localized: "Not a Number", bundle: .module.prismLocalized), String(localized: "Try 12345.67, 一万二千, or 壹佰元伍角.", bundle: .module.prismLocalized), symbol: "questionmark")
        }
    }

    private static func list(_ items: [ExtensionListItem]) -> ExtensionList {
        ExtensionList(items: items, filtering: .extension, searchPlaceholder: placeholder)
    }

    private static func list(empty title: String, _ message: String, symbol: String) -> ExtensionList {
        ExtensionList(
            items: [], filtering: .extension, searchPlaceholder: placeholder,
            emptyMessage: ExtensionListMessage(title: title, message: message, symbol: symbol)
        )
    }

    private static var placeholder: String { String(localized: "12345.67 or 一万二千…", bundle: .module.prismLocalized) }
}
