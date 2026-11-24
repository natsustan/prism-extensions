import Foundation
import PrismExtensionKit

/// Formats dates for list rows and the detail pane: the time for a note
/// changed today, then Yesterday, then the short date. Follows System
/// Settings › General › Language & Region when it matches Prism's language.
struct NoteDates {
    private let today: DateFormatter
    private let earlier: DateFormatter
    private let detail: DateFormatter
    private let now: Date
    private let yesterday: Date?
    private let calendar: Calendar

    init(now: Date, calendar: Calendar, locale: Locale) {
        self.now = now
        self.calendar = calendar
        yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        today = DateFormatter()
        today.dateStyle = .none
        today.timeStyle = .short
        earlier = DateFormatter()
        earlier.dateStyle = .short
        earlier.timeStyle = .none
        detail = DateFormatter()
        detail.dateStyle = .medium
        detail.timeStyle = .short
        for formatter in [today, earlier, detail] {
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
        }
    }

    func label(for date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return today.string(from: date) }
        if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
            return localized("Yesterday")
        }
        return earlier.string(from: date)
    }

    func detailLabel(for date: Date) -> String {
        detail.string(from: date)
    }

    /// The Mac's own locale, which carries the 24-hour setting and custom
    /// formats, when it speaks Prism's language; otherwise Prism's language
    /// with the Mac's region, so dates read like the text around them.
    static func locale(prismLanguage: String?, system: Locale = .autoupdatingCurrent) -> Locale {
        guard let prismLanguage else { return system }
        func key(_ language: Locale.Language) -> (String?, String?) {
            let full = Locale.Language(identifier: language.maximalIdentifier)
            return (full.languageCode?.identifier, full.script?.identifier)
        }
        return key(system.language) == key(Locale.Language(identifier: prismLanguage))
            ? system
            : PrismLocalization.locale(for: prismLanguage)
    }
}
