import PrismExtensionKit

/// Rows for one conversion. Return pastes into the app Prism was opened
/// over; Copy follows for an older Prism, which drops the paste action.
enum ConversionRows {
    typealias ItemID = ChineseNumbers.ItemID
    typealias ActionID = ChineseNumbers.ActionID

    static func items(for number: ArabicNumber) -> [ExtensionListItem] {
        [
            item(ItemID.lowercase, ChineseNumberFormatter.lowercase(number), caption: String(localized: "小写", bundle: .module.prismLocalized)),
            item(ItemID.uppercase, ChineseNumberFormatter.uppercase(number), caption: String(localized: "大写", bundle: .module.prismLocalized)),
            item(ItemID.amount, ChineseNumberFormatter.amount(number), caption: String(localized: "金额大写", bundle: .module.prismLocalized)),
        ]
    }

    static func items(forChinese number: ArabicNumber) -> [ExtensionListItem] {
        [item(ItemID.arabic, number.digits, caption: String(localized: "阿拉伯数字", bundle: .module.prismLocalized))]
    }

    private static func item(_ id: String, _ text: String, caption: String) -> ExtensionListItem {
        ExtensionListItem(
            id: id,
            title: text,
            subtitle: caption,
            actions: [
                ExtensionAction(id: ActionID.paste, title: String(localized: "Paste", bundle: .module.prismLocalized), kind: .paste(text: text)),
                ExtensionAction(
                    id: ActionID.copy, title: String(localized: "Copy", bundle: .module.prismLocalized), kind: .copy(text: text),
                    shortcut: ExtensionShortcut("cmd+shift+c")
                ),
            ]
        )
    }
}
