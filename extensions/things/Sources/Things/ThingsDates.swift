import Foundation
import PrismExtensionKit

/// Formats Things dates and timestamps in Prism's language while preserving
/// the user's region and clock preference when languages align.
struct ThingsDates {
    let now: Date
    let calendar: Calendar
    let locale: Locale

    private let timeOnly: DateFormatter
    private let monthDay: DateFormatter
    private let fullDate: DateFormatter
    private let fullDateTime: DateFormatter

    init(now: Date, calendar: Calendar, locale: Locale) {
        self.now = now
        self.calendar = calendar
        self.locale = locale

        timeOnly = DateFormatter()
        timeOnly.dateStyle = .none
        timeOnly.timeStyle = .short

        monthDay = DateFormatter()
        monthDay.setLocalizedDateFormatFromTemplate("MMMd")

        fullDate = DateFormatter()
        fullDate.dateStyle = .medium
        fullDate.timeStyle = .none

        fullDateTime = DateFormatter()
        fullDateTime.dateStyle = .medium
        fullDateTime.timeStyle = .short

        for formatter in [timeOnly, monthDay, fullDate, fullDateTime] {
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
        }
    }

    func dayLabel(for thingsDate: ThingsDate) -> String {
        dayLabel(for: thingsDate.date(in: calendar))
    }

    func dayLabel(for date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return localized("Today")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return localized("Tomorrow")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return localized("Yesterday")
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDay.string(from: date)
        }
        return fullDate.string(from: date)
    }

    func detailDateLabel(for thingsDate: ThingsDate) -> String {
        let date = thingsDate.date(in: calendar)
        let formatted = fullDate.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "\(localized("Today")) (\(formatted))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "\(localized("Tomorrow")) (\(formatted))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(localized("Yesterday")) (\(formatted))"
        }
        return formatted
    }

    func whenLabel(for when: ThingsWhen) -> String {
        switch when {
        case .today:
            return localized("Today")
        case .evening:
            return localized("This Evening")
        case .tomorrow:
            return localized("Tomorrow")
        case .anytime:
            return localized("Anytime")
        case .someday:
            return localized("Someday")
        case let .date(thingsDate):
            return dayLabel(for: thingsDate)
        case let .dateTime(thingsDate, hour, minute):
            let gregorian = ThingsDate.gregorianCalendar(for: calendar)
            let parts = DateComponents(year: thingsDate.year, month: thingsDate.month, day: thingsDate.day, hour: hour, minute: minute)
            let date = gregorian.date(from: parts) ?? thingsDate.date(in: calendar)
            return "\(dayLabel(for: thingsDate)) \(timeOnly.string(from: date))"
        }
    }

    func completionAccessoryLabel(for date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeOnly.string(from: date)
        }
        return dayLabel(for: date)
    }

    // MARK: - Preset Dates

    func today() -> ThingsDate {
        ThingsDate.today(now: now, calendar: calendar)
    }

    func tomorrow() -> ThingsDate {
        let target = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return ThingsDate.today(now: target, calendar: calendar)
    }

    /// Upcoming Saturday (if today is Saturday, chooses next Saturday).
    func thisWeekend() -> ThingsDate {
        let start = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: start)
        let daysUntilSaturday = weekday == 7 ? 7 : (7 - weekday)
        let target = calendar.date(byAdding: .day, value: daysUntilSaturday, to: start) ?? start
        return ThingsDate.today(now: target, calendar: calendar)
    }

    /// Upcoming Monday (if today is Monday, chooses next Monday).
    func nextWeek() -> ThingsDate {
        let start = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: start)
        let offset = (9 - weekday) % 7
        let daysUntilMonday = offset == 0 ? 7 : offset
        let target = calendar.date(byAdding: .day, value: daysUntilMonday, to: start) ?? start
        return ThingsDate.today(now: target, calendar: calendar)
    }

    /// The Mac's own locale when it matches Prism's language; otherwise Prism's
    /// language with the Mac's region.
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
