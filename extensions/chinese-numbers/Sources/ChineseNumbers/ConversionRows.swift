import PrismExtensionKit

/// Rows for one conversion. Return pastes into the app Prism was opened
/// over; Copy follows for an older Prism, which drops the paste action.
enum ConversionRows {
    typealias ItemID = ChineseNumbers.ItemID
    typealias ActionID = ChineseNumbers.ActionID

    static func items(for number: ArabicNumber) -> [ExtensionListItem] {
        [
            item(ItemID.lowercase, ChineseNumberFormatter.lowercase(number), caption: localized("小写")),
            item(ItemID.uppercase, ChineseNumberFormatter.uppercase(number), caption: localized("大写")),
            item(ItemID.amount, ChineseNumberFormatter.amount(number), caption: localized("金额大写")),
        ]
    }

    static func items(forChinese number: ArabicNumber) -> [ExtensionListItem] {
        [item(ItemID.arabic, number.digits, caption: localized("阿拉伯数字"))]
    }

    private static func item(_ id: String, _ text: String, caption: String) -> ExtensionListItem {
        ExtensionListItem(
            id: id,
            title: text,
            subtitle: caption,
            actions: [
                ExtensionAction(id: ActionID.paste, title: localized("Paste"), kind: .paste(text: text)),
                ExtensionAction(
                    id: ActionID.copy, title: localized("Copy"), kind: .copy(text: text),
                    shortcut: ExtensionShortcut("cmd+shift+c")
                ),
            ]
        )
    }
}
