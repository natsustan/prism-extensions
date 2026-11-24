import Foundation
import PrismExtensionKit

/// Text in Prism's language, which can differ from macOS's: the lookup goes
/// through `prismLocalized`, not plain `.module`. Translations live in
/// `Localizable.xcstrings`; the English is the text written here.
func localized(_ text: String.LocalizationValue) -> String {
    String(localized: text, bundle: .module.prismLocalized)
}
