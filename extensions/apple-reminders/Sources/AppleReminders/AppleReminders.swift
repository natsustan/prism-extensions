import AppKit
import PrismExtensionKit

/// Searches, organizes, completes, and quick-adds Apple Reminders from Prism's
/// launcher through EventKit (`EventKitReminderRepository`).
@main
struct AppleReminders: PrismExtension {
    enum CommandID {
        static let myReminders = "my-reminders"
        static let quickAdd = "quick-add"
    }

    enum PreferenceID {
        static let showExactDueTime = "showExactDueTime"
        static let defaultList = "defaultList"
    }

    enum ActionID {
        static let complete = "complete"
        static let uncomplete = "uncomplete"
        static let open = "open"
        static let dueMenu = "due-menu"
        static let dueToday = "due-today"
        static let dueTomorrow = "due-tomorrow"
        static let dueWeekend = "due-weekend"
        static let dueNextWeek = "due-next-week"
        static let dueInOneHour = "due-in-one-hour"
        static let dueClear = "due-clear"
        static let priorityMenu = "priority-menu"
        static let priorityHigh = "priority-high"
        static let priorityMedium = "priority-medium"
        static let priorityLow = "priority-low"
        static let priorityNone = "priority-none"
        static let moveMenu = "move-menu"
        static let movePrefix = "move:"
        static let openAttachedURL = "open-attached-url"
        static let openAttachedURLMenu = "open-attached-url-menu"
        static let copyMenu = "copy-menu"
        static let copyTitle = "copy-title"
        static let copyNotes = "copy-notes"
        static let copyLink = "copy-link"
        static let delete = "delete"
        static let create = "create"
        static let createAndOpen = "create-and-open"
        static let createInListMenu = "create-in-list-menu"
        static let createInListPrefix = "create-in-list:"
        static let createPriorityMenu = "create-priority-menu"
        static let createPriorityHigh = "create-priority-high"
        static let createPriorityMedium = "create-priority-medium"
        static let createPriorityLow = "create-priority-low"
        static let createPriorityNone = "create-priority-none"
        static let allowAccess = "allow-access"
        static let openPrivacySettings = "open-privacy-settings"
    }

    static let allowAccessItemID = "allow-access"
    static let privacySettingsItemID = "open-privacy-settings"
    static let createItemPrefix = "create:"
    static let createInListItemPrefix = "create-in:"
    static let resultLimit = 100

    let repository: any ReminderRepository
    let pinyinCache = PinyinCache()
    let library = ReminderLibrary()
    let openURL: @Sendable (URL) async throws -> Void
    let now: @Sendable () -> Date
    let calendar: Calendar

    init() {
        self.init(
            repository: EventKitReminderRepository(),
            openURL: Self.openWithWorkspace
        )
    }

    init(
        repository: any ReminderRepository,
        openURL: @escaping @Sendable (URL) async throws -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.repository = repository
        self.openURL = openURL
        self.now = now
        self.calendar = calendar
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        switch command {
        case CommandID.myReminders:
            return try await listMyReminders(query: query, filter: filter, context: context)
        case CommandID.quickAdd:
            return try await listQuickAdd(query: query, context: context)
        default:
            throw PrismExtensionError(localized("Apple Reminders has no list “\(command)”."))
        }
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        if action == ActionID.allowAccess {
            let granted = try await repository.requestFullAccess()
            library.invalidate()
            return granted
                ? .reload(message: localized("Reminders Access Granted"))
                : .reload(message: localized("Reminders access was not granted."))
        }

        if item.hasPrefix(Self.createItemPrefix) || item.hasPrefix(Self.createInListItemPrefix) {
            return try await performCreate(action: action, item: item, command: command, context: context)
        }

        switch action {
        case ActionID.complete:
            return try await mutate(message: localized("Completed Reminder")) {
                try await repository.setCompleted(id: item, completed: true)
            }

        case ActionID.uncomplete:
            return try await mutate(message: localized("Marked as Incomplete")) {
                try await repository.setCompleted(id: item, completed: false)
            }

        case ActionID.dueToday:
            return try await updateDueDate(id: item, to: makeDates(now: now()).todayAllDay(), message: localized("Due Date Set to Today"))

        case ActionID.dueTomorrow:
            return try await updateDueDate(id: item, to: makeDates(now: now()).tomorrowAllDay(), message: localized("Due Date Set to Tomorrow"))

        case ActionID.dueWeekend:
            return try await updateDueDate(id: item, to: makeDates(now: now()).thisWeekendAllDay(), message: localized("Due Date Set to This Weekend"))

        case ActionID.dueNextWeek:
            return try await updateDueDate(id: item, to: makeDates(now: now()).nextWeekAllDay(), message: localized("Due Date Set to Next Week"))

        case ActionID.dueInOneHour:
            return try await updateDueDate(id: item, to: makeDates(now: now()).inOneHour(), message: localized("Due Date Set to In 1 Hour"))

        case ActionID.dueClear:
            return try await updateDueDate(id: item, to: nil, message: localized("Removed Due Date"))

        case ActionID.priorityHigh:
            return try await updatePriority(id: item, to: .high, message: localized("Priority Set to High"))

        case ActionID.priorityMedium:
            return try await updatePriority(id: item, to: .medium, message: localized("Priority Set to Medium"))

        case ActionID.priorityLow:
            return try await updatePriority(id: item, to: .low, message: localized("Priority Set to Low"))

        case ActionID.priorityNone:
            return try await updatePriority(id: item, to: .none, message: localized("Removed Priority"))

        case let actionID where actionID.hasPrefix(ActionID.movePrefix):
            let listID = String(actionID.dropFirst(ActionID.movePrefix.count))
            return try await mutate(message: localized("Moved Reminder")) {
                try await repository.move(id: item, toListID: listID)
            }

        case ActionID.delete:
            return try await mutate(message: localized("Deleted Reminder")) {
                try await repository.delete(id: item)
            }

        default:
            throw PrismExtensionError(localized("Apple Reminders has no action “\(action)”."))
        }
    }

    // MARK: - List Implementations

    private func listMyReminders(query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        let activeFilter = ReminderFilter(filterID: filter)

        switch repository.authorizationStatus() {
        case .notDetermined:
            return myRemindersList(items: [ReminderRows.allowAccessItem], filters: ReminderRows.filters(lists: []))
        case .denied:
            return myRemindersList(items: [ReminderRows.openPrivacySettingsItem], filters: ReminderRows.filters(lists: []))
        case .fullAccess:
            break
        }

        let data: ReminderLibrary.CachedData
        do {
            data = try await library.load(
                completed: activeFilter.loadsCompleted,
                forceRefresh: query.isEmpty,
                from: repository,
                pinyin: pinyinCache,
                directory: context.dataDirectory
            )
        } catch ReminderRepositoryError.accessDenied {
            return myRemindersList(items: [ReminderRows.openPrivacySettingsItem], filters: ReminderRows.filters(lists: []))
        }

        let loadedAt = now()
        let showExactTime = context.preferences.bool(PreferenceID.showExactDueTime)
        let dates = makeDates(now: loadedAt)
        let filters = ReminderRows.filters(lists: data.lists)
        let search = ReminderSearch(query: query)
        let results = search.results(
            in: data.reminders,
            filter: activeFilter,
            now: loadedAt,
            calendar: calendar,
            limit: Self.resultLimit
        )

        if results.isEmpty, !search.words.isEmpty, activeFilter != .completed {
            let preferredListID: String? = if case let .list(id) = activeFilter { id } else { nil }
            let defaultListName = context.preferences.string(PreferenceID.defaultList)
            if let draft = QuickAddParser.parse(
                query,
                lists: data.lists,
                defaultListName: defaultListName,
                preferredListID: preferredListID,
                now: loadedAt,
                calendar: calendar
            ) {
                let item = ReminderRows.createItem(
                    itemID: Self.encodeCreateItemID(query: query, preferredListID: preferredListID),
                    draft: draft,
                    lists: data.lists,
                    dates: dates,
                    showExactTime: showExactTime,
                    isQuickAddCommand: false
                )
                return myRemindersList(items: [item], filters: filters, fetchedAt: loadedAt)
            }
        }

        return myRemindersList(
            items: results.map {
                ReminderRows.item(
                    for: $0,
                    filter: activeFilter,
                    lists: data.lists,
                    dates: dates,
                    showExactTime: showExactTime
                )
            },
            filters: filters,
            emptyMessage: ReminderRows.emptyMessage(for: activeFilter, hasQuery: !search.words.isEmpty),
            fetchedAt: loadedAt
        )
    }

    private func myRemindersList(
        items: [ExtensionListItem],
        filters: [ExtensionListFilter],
        emptyMessage: ExtensionListMessage? = nil,
        fetchedAt: Date? = nil
    ) -> ExtensionList {
        ExtensionList(
            items: items,
            filtering: .extension,
            searchPlaceholder: ReminderRows.myRemindersPlaceholder,
            filters: filters,
            emptyMessage: emptyMessage,
            showsDetail: false,
            fetchedAt: fetchedAt
        )
    }

    private func listQuickAdd(query: String, context: PrismContext) async throws -> ExtensionList {
        let lists: [ReminderList]
        switch repository.authorizationStatus() {
        case .denied:
            return ExtensionList(
                items: [ReminderRows.openPrivacySettingsItem],
                filtering: .extension,
                searchPlaceholder: ReminderRows.quickAddPlaceholder,
                showsDetail: false
            )
        case .notDetermined:
            lists = []
        case .fullAccess:
            lists = try await loadListsIgnoringErrors(forceRefresh: query.isEmpty)
        }

        let loadedAt = now()
        let dates = makeDates(now: loadedAt)
        let showExactTime = context.preferences.bool(PreferenceID.showExactDueTime)
        let defaultListName = context.preferences.string(PreferenceID.defaultList)

        guard let draft = QuickAddParser.parse(
            query,
            lists: lists,
            defaultListName: defaultListName,
            now: loadedAt,
            calendar: calendar
        ) else {
            let trimmedDefault = defaultListName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ExtensionList(
                items: [],
                filtering: .extension,
                searchPlaceholder: ReminderRows.quickAddPlaceholder,
                emptyMessage: ReminderRows.quickAddEmptyMessage(
                    defaultListTitle: trimmedDefault.isEmpty ? nil : trimmedDefault
                ),
                showsDetail: false,
                fetchedAt: loadedAt
            )
        }

        let item = ReminderRows.createItem(
            itemID: Self.encodeCreateItemID(query: query, preferredListID: nil),
            draft: draft,
            lists: lists,
            dates: dates,
            showExactTime: showExactTime,
            isQuickAddCommand: true
        )
        return ExtensionList(
            items: [item],
            filtering: .extension,
            searchPlaceholder: ReminderRows.quickAddPlaceholder,
            showsDetail: false,
            fetchedAt: loadedAt
        )
    }

    // MARK: - Create & Mutation Helpers

    private func performCreate(
        action: String,
        item: String,
        command: String,
        context: PrismContext
    ) async throws -> ExtensionActionResult {
        switch repository.authorizationStatus() {
        case .denied:
            return ExtensionActionResult(.failed(message: ReminderRepositoryError.accessDenied.userMessage))
        case .notDetermined:
            let granted = try await repository.requestFullAccess()
            guard granted else {
                return ExtensionActionResult(.failed(message: ReminderRepositoryError.accessDenied.userMessage))
            }
        case .fullAccess:
            break
        }

        let (rawQuery, preferredListID) = Self.decodeCreateItemID(item)
        let lists = try await loadListsIgnoringErrors(forceRefresh: false)

        guard var draft = QuickAddParser.parse(
            rawQuery,
            lists: lists,
            defaultListName: context.preferences.string(PreferenceID.defaultList),
            preferredListID: preferredListID,
            now: now(),
            calendar: calendar
        ) else {
            return ExtensionActionResult(.failed(message: localized("Couldn’t create an empty reminder.")))
        }

        var openAfterCreate = false
        switch action {
        case ActionID.create:
            break
        case ActionID.createAndOpen:
            openAfterCreate = true
        case ActionID.createPriorityHigh:
            draft.priority = .high
        case ActionID.createPriorityMedium:
            draft.priority = .medium
        case ActionID.createPriorityLow:
            draft.priority = .low
        case ActionID.createPriorityNone:
            draft.priority = .none
        case let actionID where actionID.hasPrefix(ActionID.createInListPrefix):
            let listID = String(actionID.dropFirst(ActionID.createInListPrefix.count))
            draft.listID = listID
            draft.listTitle = lists.first { $0.id == listID }?.title
        default:
            throw PrismExtensionError(localized("Apple Reminders has no action “\(action)”."))
        }

        let createdID: String?
        do {
            createdID = try await repository.create(draft, calendar: calendar)
        } catch let error as ReminderRepositoryError {
            return ExtensionActionResult(.failed(message: error.userMessage))
        }

        library.invalidate()
        await context.listChanged(CommandID.myReminders)

        if openAfterCreate,
           let createdID,
           !createdID.isEmpty,
           let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(createdID)") {
            try await openURL(url)
            return .done
        }

        if command == CommandID.quickAdd {
            return ExtensionActionResult(.hud(message: localized("Created “\(draft.title)”")))
        }
        return .reload(message: localized("Created “\(draft.title)”"))
    }

    private func updateDueDate(id: String, to dueDate: ReminderDueDate?, message: String) async throws -> ExtensionActionResult {
        try await mutate(message: message) {
            try await repository.setDueDate(id: id, dueDate: dueDate, calendar: calendar)
        }
    }

    private func updatePriority(id: String, to priority: ReminderPriority, message: String) async throws -> ExtensionActionResult {
        try await mutate(message: message) {
            try await repository.setPriority(id: id, priority: priority)
        }
    }

    private func mutate(
        message: String,
        operation: () async throws -> Void
    ) async throws -> ExtensionActionResult {
        do {
            try await operation()
        } catch let error as ReminderRepositoryError {
            return ExtensionActionResult(.failed(message: error.userMessage))
        }
        library.invalidate()
        return .reload(message: message)
    }

    private func loadListsIgnoringErrors(forceRefresh: Bool) async throws -> [ReminderList] {
        do {
            return try await library.lists(forceRefresh: forceRefresh, from: repository)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func makeDates(now: Date) -> ReminderDates {
        ReminderDates(now: now, calendar: calendar, locale: ReminderDates.locale(prismLanguage: PrismLocalization.language))
    }

    static func encodeCreateItemID(query: String, preferredListID: String?) -> String {
        if let preferredListID, !preferredListID.isEmpty {
            return "\(createInListItemPrefix)\(preferredListID):\(query)"
        }
        return createItemPrefix + query
    }

    static func decodeCreateItemID(_ item: String) -> (query: String, preferredListID: String?) {
        if item.hasPrefix(createInListItemPrefix) {
            let rest = item.dropFirst(createInListItemPrefix.count)
            if let colon = rest.firstIndex(of: ":") {
                let listID = String(rest[..<colon])
                let query = String(rest[rest.index(after: colon)...])
                return (query, listID.isEmpty ? nil : listID)
            }
        }
        if item.hasPrefix(createItemPrefix) {
            return (String(item.dropFirst(createItemPrefix.count)), nil)
        }
        return (item, nil)
    }

    private static func openWithWorkspace(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.open(url, configuration: configuration)
        app.activate()
    }
}
