import Foundation
import PrismExtensionKit

/// A row's date the way Notes' list writes it: the time for a note changed
/// today, then Yesterday, then the date. Both use the system's short styles,
/// so they follow System Settings › General › Language & Region, including
/// the 24-hour setting and any custom date format.
struct NoteDates {
    private let today: DateFormatter
    private let earlier: DateFormatter
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
        for formatter in [today, earlier] {
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
        }
    }

    /// Days are counted from `now`, not the system clock, so a list built
    /// for a given moment reads the same whenever it is checked. Only
    /// Yesterday is named: relative formatting would add words such as the
    /// Chinese for the day before yesterday, which Notes' list never shows.
    func label(for date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return today.string(from: date) }
        if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
            return localized("Yesterday")
        }
        return earlier.string(from: date)
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
