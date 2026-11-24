import Foundation
import PrismExtensionKit

/// Formats reminder due dates and timestamps in Prism's language while
/// preserving the user's region and 24-hour clock preference when languages align.
struct ReminderDates {
    let now: Date
    let calendar: Calendar
    let locale: Locale

    private let timeOnly: DateFormatter
    private let monthDay: DateFormatter
    private let fullDate: DateFormatter
    private let fullDateTime: DateFormatter
    private let relative: RelativeDateTimeFormatter

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

        relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.calendar = calendar
        relative.unitsStyle = .short
    }

    func accessoryLabel(for dueDate: ReminderDueDate, showExactTime: Bool) -> String {
        let date = dueDate.date(in: calendar)
        if dueDate.isAllDay {
            return dayLabel(for: date)
        }
        if !showExactTime {
            let delta = abs(date.timeIntervalSince(now))
            if delta < 24 * 3600 {
                return relative.localizedString(for: date, relativeTo: now)
            }
        }
        let time = timeOnly.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "\(localized("Today")) \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "\(localized("Tomorrow")) \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(localized("Yesterday")) \(time)"
        }
        return "\(dayLabel(for: date)) \(time)"
    }

    func completionAccessoryLabel(for date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeOnly.string(from: date)
        }
        return dayLabel(for: date)
    }

    func detailLabel(for dueDate: ReminderDueDate) -> String {
        let date = dueDate.date(in: calendar)
        if dueDate.isAllDay {
            let formatted = fullDate.string(from: date)
            if calendar.isDate(date, inSameDayAs: now) {
                return "\(localized("Today")) (\(formatted))"
            }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(date, inSameDayAs: tomorrow) {
                return "\(localized("Tomorrow")) (\(formatted))"
            }
            return formatted
        }
        return fullDateTime.string(from: date)
    }

    func detailTimestampLabel(for date: Date) -> String {
        fullDateTime.string(from: date)
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

    // MARK: - Preset Due Dates

    func todayAllDay() -> ReminderDueDate {
        allDay(from: now)
    }

    func tomorrowAllDay() -> ReminderDueDate {
        let target = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return allDay(from: target)
    }

    /// Upcoming Saturday (if today is Saturday, chooses next Saturday).
    func thisWeekendAllDay() -> ReminderDueDate {
        let start = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: start) // 1 = Sun ... 7 = Sat
        let daysUntilSaturday = weekday == 7 ? 7 : (7 - weekday)
        let target = calendar.date(byAdding: .day, value: daysUntilSaturday, to: start) ?? start
        return allDay(from: target)
    }

    /// Upcoming Monday (if today is Monday, chooses next Monday).
    func nextWeekAllDay() -> ReminderDueDate {
        let start = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: start) // 1 = Sun, 2 = Mon ... 7 = Sat
        let offset = (9 - weekday) % 7
        let daysUntilMonday = offset == 0 ? 7 : offset
        let target = calendar.date(byAdding: .day, value: daysUntilMonday, to: start) ?? start
        return allDay(from: target)
    }

    func inOneHour() -> ReminderDueDate {
        .timed(now.addingTimeInterval(3600))
    }

    private func allDay(from date: Date) -> ReminderDueDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return .allDay(year: parts.year ?? 2001, month: parts.month ?? 1, day: parts.day ?? 1)
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
