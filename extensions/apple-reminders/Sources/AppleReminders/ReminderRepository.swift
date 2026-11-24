import EventKit
import Foundation
import Synchronization

enum ReminderAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
}

enum ReminderRepositoryError: Error, Equatable {
    case accessDenied
    case notFound
    case listNotFound
    case failed(String)

    var userMessage: String {
        switch self {
        case .accessDenied:
            localized("Allow Prism to access Reminders in System Settings → Privacy & Security → Reminders.")
        case .notFound:
            localized("This reminder no longer exists in Reminders.")
        case .listNotFound:
            localized("The selected reminder list no longer exists.")
        case let .failed(detail):
            detail.isEmpty
                ? localized("Couldn’t update Apple Reminders.")
                : localized("Couldn’t update Apple Reminders: \(detail)")
        }
    }
}

/// EventKit read/write boundary. Abstracted behind a protocol so tests run
/// deterministically without touching the real Reminders store or TCC.
protocol ReminderRepository: Sendable {
    func authorizationStatus() -> ReminderAuthorizationStatus
    func requestFullAccess() async throws -> Bool
    func fetchLists() async throws -> [ReminderList]
    func fetchSnapshot(completed: Bool) async throws -> ReminderSnapshot
    func setCompleted(id: String, completed: Bool) async throws
    func setPriority(id: String, priority: ReminderPriority) async throws
    func setDueDate(id: String, dueDate: ReminderDueDate?, calendar: Calendar) async throws
    func move(id: String, toListID: String) async throws
    func delete(id: String) async throws
    func create(_ draft: ReminderDraft, calendar: Calendar) async throws -> String?
}

/// Native EventKit repository. Lazily instantiates `EKEventStore` only once
/// access is granted or explicitly requested, so opening the extension before
/// permission is granted (or running `smoke`) never triggers a TCC dialog.
final class EventKitReminderRepository: ReminderRepository, @unchecked Sendable {
    private let store = Mutex<EKEventStore?>(nil)

    func authorizationStatus() -> ReminderAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        case .denied, .restricted, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore().requestFullAccessToReminders()
    }

    func fetchLists() async throws -> [ReminderList] {
        let store = try authorizedStore(reset: true)
        return Self.mapLists(from: store)
    }

    func fetchSnapshot(completed: Bool) async throws -> ReminderSnapshot {
        try Task.checkCancellation()
        let store = try authorizedStore(reset: true)
        let lists = Self.mapLists(from: store)
        let calendars = store.calendars(for: .reminder)
        let predicate = completed
            ? store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: calendars)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)

        let reminders = await fetchMappedReminders(matching: predicate, in: store)
        try Task.checkCancellation()
        return ReminderSnapshot(reminders: reminders, lists: lists)
    }

    func setCompleted(id: String, completed: Bool) async throws {
        try updateReminder(id: id) { $0.isCompleted = completed }
    }

    func setPriority(id: String, priority: ReminderPriority) async throws {
        try updateReminder(id: id) { $0.priority = priority.eventKitValue }
    }

    func setDueDate(id: String, dueDate: ReminderDueDate?, calendar: Calendar) async throws {
        try updateReminder(id: id) { reminder in
            Self.removeTimeBasedAlarms(from: reminder)
            if let dueDate {
                reminder.dueDateComponents = dueDate.dateComponents(in: calendar)
                if case let .timed(date) = dueDate {
                    reminder.addAlarm(EKAlarm(absoluteDate: date))
                }
            } else {
                reminder.dueDateComponents = nil
            }
        }
    }

    func move(id: String, toListID: String) async throws {
        let store = try authorizedStore(reset: false)
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderRepositoryError.notFound
        }
        guard let target = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == toListID }) else {
            throw ReminderRepositoryError.listNotFound
        }
        reminder.calendar = target
        try save(reminder, in: store)
    }

    func delete(id: String) async throws {
        let store = try authorizedStore(reset: false)
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderRepositoryError.notFound
        }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw ReminderRepositoryError.failed(error.localizedDescription)
        }
    }

    func create(_ draft: ReminderDraft, calendar: Calendar) async throws -> String? {
        let store = try authorizedStore(reset: false)
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.combinedNotes
        reminder.priority = draft.priority.eventKitValue

        if let listID = draft.listID {
            guard let target = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listID }) else {
                throw ReminderRepositoryError.listNotFound
            }
            reminder.calendar = target
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        if let dueDate = draft.dueDate {
            reminder.dueDateComponents = dueDate.dateComponents(in: calendar)
            if case let .timed(date) = dueDate {
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
        }

        try save(reminder, in: store)
        return reminder.calendarItemIdentifier
    }

    // MARK: - Helpers

    private func authorizedStore(reset: Bool) throws -> EKEventStore {
        guard authorizationStatus() == .fullAccess else {
            throw ReminderRepositoryError.accessDenied
        }
        let store = eventStore()
        if reset {
            store.reset()
        }
        return store
    }

    private func eventStore() -> EKEventStore {
        store.withLock { existing in
            if let existing { return existing }
            let created = EKEventStore()
            existing = created
            return created
        }
    }

    private func updateReminder(id: String, _ mutate: (EKReminder) -> Void) throws {
        let store = try authorizedStore(reset: false)
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderRepositoryError.notFound
        }
        mutate(reminder)
        try save(reminder, in: store)
    }

    private func save(_ reminder: EKReminder, in store: EKEventStore) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderRepositoryError.failed(error.localizedDescription)
        }
    }

    private func fetchMappedReminders(matching predicate: NSPredicate, in store: EKEventStore) async -> [Reminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).map { Self.mapReminder($0) }
                continuation.resume(returning: mapped)
            }
        }
    }

    private static func removeTimeBasedAlarms(from reminder: EKReminder) {
        for alarm in reminder.alarms ?? [] where alarm.structuredLocation == nil {
            reminder.removeAlarm(alarm)
        }
    }

    // MARK: - Mapping

    private static func mapLists(from store: EKEventStore) -> [ReminderList] {
        store.calendars(for: .reminder)
            .map { calendar in
                ReminderList(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    account: calendar.source?.title,
                    isReadOnly: !calendar.allowsContentModifications
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id < rhs.id
            }
    }

    private static func mapReminder(_ item: EKReminder) -> Reminder {
        let notes = item.notes
        let tags = notes.map(extractInlineTags(from:)) ?? []

        var attachedURLs = [URL]()
        if let url = item.url, isSafeOpenableURL(url) {
            attachedURLs.append(url)
        }
        if let notes {
            for url in extractURLs(from: notes) where !attachedURLs.contains(url) {
                attachedURLs.append(url)
            }
        }

        let dueDate: ReminderDueDate? = item.dueDateComponents.flatMap { components in
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = components.timeZone ?? .autoupdatingCurrent
            let sourceCalendar = components.calendar ?? gregorian
            if components.hour != nil, components.minute != nil,
               let date = sourceCalendar.date(from: components) {
                return .timed(date)
            }
            if sourceCalendar.identifier != .gregorian, let date = sourceCalendar.date(from: components) {
                let normalized = gregorian.dateComponents([.year, .month, .day], from: date)
                if let year = normalized.year, let month = normalized.month, let day = normalized.day {
                    return .allDay(year: year, month: month, day: day)
                }
            }
            if let year = components.year, let month = components.month, let day = components.day {
                return .allDay(year: year, month: month, day: day)
            }
            return nil
        }

        let recurrence: ReminderRecurrence? = item.recurrenceRules?.first.flatMap { rule in
            let frequency: ReminderRecurrence.Frequency? = switch rule.frequency {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            @unknown default: nil
            }
            guard let frequency else { return nil }
            return ReminderRecurrence(frequency: frequency, interval: max(rule.interval, 1))
        }

        let location: ReminderLocation? = (item.alarms ?? []).compactMap { alarm -> ReminderLocation? in
            guard let structured = alarm.structuredLocation, let title = structured.title, !title.isEmpty else {
                return nil
            }
            let proximity: ReminderLocation.Proximity = switch alarm.proximity {
            case .enter: .enter
            case .leave: .leave
            case .none: .none
            @unknown default: .none
            }
            return ReminderLocation(title: title, proximity: proximity)
        }.first

        return Reminder(
            id: item.calendarItemIdentifier,
            title: item.title ?? "",
            notes: notes,
            listID: item.calendar?.calendarIdentifier,
            listTitle: item.calendar?.title ?? "",
            account: item.calendar?.source?.title,
            isCompleted: item.isCompleted,
            completionDate: item.completionDate,
            createdAt: item.creationDate,
            modifiedAt: item.lastModifiedDate,
            dueDate: dueDate,
            priority: ReminderPriority(applePriority: item.priority),
            tags: tags,
            attachedURLs: attachedURLs,
            recurrence: recurrence,
            location: location
        )
    }

    static func extractInlineTags(from notes: String) -> [String] {
        let pattern = #"(?:^|\s)#([^\s#,.;:!?()\[\]{}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        var tags = [String]()
        for match in regex.matches(in: notes, range: range) {
            guard match.numberOfRanges > 1,
                  let tagRange = Range(match.range(at: 1), in: notes)
            else { continue }
            let tag = String(notes[tagRange])
            if !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                tags.append(tag)
            }
        }
        return tags
    }

    static func extractURLs(from notes: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        var urls = [URL]()
        for match in detector.matches(in: notes, range: range) {
            guard let url = match.url, isSafeOpenableURL(url), !urls.contains(url) else { continue }
            urls.append(url)
        }
        return urls
    }

    private static func isSafeOpenableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !["javascript", "vbscript", "data", "blob"].contains(scheme)
    }
}
