import Foundation
import PrismExtensionKit

/// Formats last-opened dates: the time for today, “Yesterday”, then a short
/// date, following Prism's language while preserving macOS's region and
/// 24-hour clock preference when both share the same language.
struct ProjectDates {
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

    func label(for date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return today.string(from: date)
        }
        if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
            return localized("Yesterday")
        }
        return earlier.string(from: date)
    }

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
