import Foundation

/// Searches and filters reminders by title, notes, list, tags, priority,
/// location, and Chinese pinyin. Every typed word must match; title matches
/// rank ahead of other matches.
struct ReminderSearch {
    let words: [String]

    init(query: String) {
        words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    static func pinyinSources(of reminder: Reminder) -> [String] {
        [reminder.title, reminder.notes ?? "", reminder.listTitle, reminder.location?.title ?? ""] + reminder.tags
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Filters `entries` for `filter` and `words`, sorts them in display order,
    /// and caps the result to `limit`.
    func results(
        in entries: [SearchableReminder],
        filter: ReminderFilter,
        now: Date,
        calendar: Calendar,
        limit: Int
    ) -> [Reminder] {
        var matched = [(reminder: Reminder, matchRank: Int)]()
        matched.reserveCapacity(min(entries.count, limit))

        for entry in entries {
            guard Self.matchesFilter(entry.reminder, filter: filter, now: now, calendar: calendar) else {
                continue
            }
            guard let rank = rank(of: entry) else { continue }
            matched.append((entry.reminder, rank))
        }

        matched.sort { lhs, rhs in
            if lhs.matchRank != rhs.matchRank {
                return lhs.matchRank < rhs.matchRank
            }
            return Self.sortOrder(lhs.reminder, rhs.reminder, filter: filter, now: now, calendar: calendar)
        }

        return Array(matched.prefix(limit).map(\.reminder))
    }

    func rank(of entry: SearchableReminder) -> Int? {
        guard !words.isEmpty else { return 0 }
        if words.allSatisfy(entry.title.contains) { return 0 }
        return words.allSatisfy(entry.text.contains) ? 1 : nil
    }

    static func matchesFilter(
        _ reminder: Reminder,
        filter: ReminderFilter,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch filter {
        case .completed:
            return reminder.isCompleted
        case .all:
            return !reminder.isCompleted
        case .today:
            guard !reminder.isCompleted, let due = reminder.dueDate else { return false }
            return due.isDueOnOrBeforeToday(now: now, calendar: calendar)
        case .overdue:
            guard !reminder.isCompleted, let due = reminder.dueDate else { return false }
            return due.isOverdue(now: now, calendar: calendar)
        case .scheduled:
            return !reminder.isCompleted && reminder.dueDate != nil
        case let .list(listID):
            return !reminder.isCompleted && reminder.listID == listID
        }
    }

    /// Orders completed reminders by most recently completed first, and active
    /// reminders by due bucket (overdue -> today -> upcoming -> undated), then
    /// earliest due date, higher priority, and most recently created.
    static func sortOrder(
        _ lhs: Reminder,
        _ rhs: Reminder,
        filter: ReminderFilter,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        if filter == .completed {
            let lDate = lhs.completionDate ?? lhs.modifiedAt ?? .distantPast
            let rDate = rhs.completionDate ?? rhs.modifiedAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let lBucket = dueBucket(for: lhs, now: now, calendar: calendar)
        let rBucket = dueBucket(for: rhs, now: now, calendar: calendar)
        if lBucket != rBucket { return lBucket < rBucket }

        if let lDue = lhs.dueDate?.date(in: calendar), let rDue = rhs.dueDate?.date(in: calendar), lDue != rDue {
            return lDue < rDue
        }
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        let lCreated = lhs.createdAt ?? lhs.modifiedAt ?? .distantPast
        let rCreated = rhs.createdAt ?? rhs.modifiedAt ?? .distantPast
        if lCreated != rCreated { return lCreated > rCreated }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    /// 0 = overdue, 1 = today, 2 = upcoming, 3 = no due date.
    static func dueBucket(for reminder: Reminder, now: Date, calendar: Calendar) -> Int {
        guard let due = reminder.dueDate else { return 3 }
        if due.isOverdue(now: now, calendar: calendar) { return 0 }
        if due.isToday(now: now, calendar: calendar) { return 1 }
        return 2
    }
}

/// A reminder with its searchable fields folded once, so typing compares only
/// substrings. Newlines separate fields so a query word cannot span two fields.
struct SearchableReminder: Sendable {
    let reminder: Reminder
    let title: String
    let text: String

    init(_ reminder: Reminder, pinyin: [String: [String]]) {
        self.reminder = reminder
        let titleFields = [reminder.title] + (pinyin[reminder.title] ?? [])
        var fields = titleFields + [
            reminder.notes ?? "",
            reminder.listTitle,
            reminder.account ?? "",
            reminder.location?.title ?? "",
        ]
        fields += reminder.tags.flatMap { ["#\($0)", $0] }
        fields += reminder.priority.searchKeywords
        for source in ReminderSearch.pinyinSources(of: reminder).dropFirst() {
            fields += pinyin[source] ?? []
        }
        title = ReminderSearch.fold(titleFields.joined(separator: "\n"))
        text = ReminderSearch.fold(fields.joined(separator: "\n"))
    }
}
