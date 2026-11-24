import Foundation

/// Apple / EventKit priority levels: 0 = none, 1–4 = high, 5 = medium, 6–9 = low.
enum ReminderPriority: Int, Hashable, Comparable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    init(applePriority: Int) {
        switch applePriority {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    /// Raw value expected by `EKReminder.priority`.
    var eventKitValue: Int {
        switch self {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }

    var badgeText: String? {
        switch self {
        case .none: nil
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }

    var tint: String? {
        switch self {
        case .none: nil
        case .low: "blue"
        case .medium: "orange"
        case .high: "red"
        }
    }

    var localizedName: String {
        switch self {
        case .none: localized("None")
        case .low: localized("Low")
        case .medium: localized("Medium")
        case .high: localized("High")
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .none: []
        case .low: ["low", "!", "低"]
        case .medium: ["medium", "med", "!!", "中"]
        case .high: ["high", "!!!", "高"]
        }
    }

    static func < (lhs: ReminderPriority, rhs: ReminderPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A reminder's due date: either a floating calendar day (all-day) or an exact
/// point in time.
enum ReminderDueDate: Hashable, Sendable {
    case allDay(year: Int, month: Int, day: Int)
    case timed(Date)

    var isAllDay: Bool {
        if case .allDay = self { return true }
        return false
    }

    /// Resolves this due date to a `Date` in `calendar`. All-day reminders land
    /// at start of day in `calendar`.
    func date(in calendar: Calendar) -> Date {
        switch self {
        case let .allDay(year, month, day):
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
        case let .timed(date):
            return date
        }
    }

    func dateComponents(in calendar: Calendar) -> DateComponents {
        switch self {
        case let .allDay(year, month, day):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return components
        case let .timed(date):
            return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        }
    }

    func isOverdue(now: Date, calendar: Calendar) -> Bool {
        let target = date(in: calendar)
        if isAllDay {
            return target < calendar.startOfDay(for: now)
        }
        return target < now
    }

    func isToday(now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(date(in: calendar), inSameDayAs: now)
    }

    func isTomorrow(now: Date, calendar: Calendar) -> Bool {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return calendar.isDate(date(in: calendar), inSameDayAs: tomorrow)
    }

    func isDueOnOrBeforeToday(now: Date, calendar: Calendar) -> Bool {
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return date(in: calendar) < tomorrowStart
    }

    func isWithinNextSevenDays(now: Date, calendar: Calendar) -> Bool {
        let startOfToday = calendar.startOfDay(for: now)
        guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday) else {
            return false
        }
        let target = date(in: calendar)
        return target >= startOfToday && target < nextWeek
    }
}

/// A simplified representation of `EKRecurrenceRule`.
struct ReminderRecurrence: Hashable, Sendable {
    enum Frequency: Int, Hashable, Sendable {
        case daily = 0
        case weekly = 1
        case monthly = 2
        case yearly = 3
    }

    let frequency: Frequency
    let interval: Int

    var localizedSummary: String {
        let step = max(interval, 1)
        switch frequency {
        case .daily:
            return step == 1 ? localized("Every Day") : localized("Every \(step) Days")
        case .weekly:
            return step == 1 ? localized("Every Week") : localized("Every \(step) Weeks")
        case .monthly:
            return step == 1 ? localized("Every Month") : localized("Every \(step) Months")
        case .yearly:
            return step == 1 ? localized("Every Year") : localized("Every \(step) Years")
        }
    }
}

/// Location alarm attached to a reminder (`EKAlarm.structuredLocation`).
struct ReminderLocation: Hashable, Sendable {
    enum Proximity: String, Hashable, Sendable {
        case enter
        case leave
        case none
    }

    let title: String
    let proximity: Proximity

    var localizedSummary: String {
        switch proximity {
        case .enter: localized("Arriving at \(title)")
        case .leave: localized("Leaving \(title)")
        case .none: title
        }
    }
}

/// One Reminders list (`EKCalendar`).
struct ReminderList: Hashable, Sendable {
    let id: String
    let title: String
    let account: String?
    let isReadOnly: Bool
}

/// One reminder loaded from EventKit.
struct Reminder: Hashable, Sendable {
    let id: String
    let title: String
    let notes: String?
    let listID: String?
    let listTitle: String
    let account: String?
    let isCompleted: Bool
    let completionDate: Date?
    let createdAt: Date?
    let modifiedAt: Date?
    let dueDate: ReminderDueDate?
    let priority: ReminderPriority
    /// Inline `#tags` extracted from `notes`, without the leading `#`.
    var tags: [String] = []
    /// Attached URLs (`EKReminder.url` and links inside `notes`).
    var attachedURLs: [URL] = []
    var recurrence: ReminderRecurrence?
    var location: ReminderLocation?

    /// Deep link that opens this reminder in Reminders.
    var openURL: URL? {
        guard !id.isEmpty else { return nil }
        return URL(string: "x-apple-reminderkit://REMCDReminder/\(id)")
    }
}

/// Data for creating a new reminder.
struct ReminderDraft: Hashable, Sendable {
    var title: String
    var notes: String?
    var listID: String?
    var listTitle: String?
    var dueDate: ReminderDueDate?
    var priority: ReminderPriority = .none
    var tags: [String] = []

    /// Final notes body written to EventKit, appending parsed `#tags` when present.
    var combinedNotes: String? {
        let base = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let formattedTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
            .map { "#\($0)" }
            .joined(separator: " ")

        switch (base.isEmpty, formattedTags.isEmpty) {
        case (true, true): return nil
        case (false, true): return base
        case (true, false): return formattedTags
        case (false, false): return "\(base)\n\n\(formattedTags)"
        }
    }
}

/// The active ⌘P filter in My Reminders.
enum ReminderFilter: Hashable, Sendable {
    static let allID = "all"
    static let todayID = "today"
    static let overdueID = "overdue"
    static let scheduledID = "scheduled"
    static let completedID = "completed"
    static let listPrefix = "list:"

    case all
    case today
    case overdue
    case scheduled
    case completed
    case list(String)

    init(filterID: String?) {
        guard let filterID else {
            self = .all
            return
        }
        switch filterID {
        case Self.allID: self = .all
        case Self.todayID: self = .today
        case Self.overdueID: self = .overdue
        case Self.scheduledID: self = .scheduled
        case Self.completedID: self = .completed
        default:
            if filterID.hasPrefix(Self.listPrefix) {
                self = .list(String(filterID.dropFirst(Self.listPrefix.count)))
            } else {
                self = .all
            }
        }
    }

    var loadsCompleted: Bool {
        self == .completed
    }
}

/// Snapshot loaded from EventKit.
struct ReminderSnapshot: Hashable, Sendable {
    let reminders: [Reminder]
    let lists: [ReminderList]
}
