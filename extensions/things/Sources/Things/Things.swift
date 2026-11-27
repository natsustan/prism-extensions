import AppKit
import PrismExtensionKit

/// Searches, completes, organizes, and quick-adds Things 3 to-dos from Prism's
/// launcher using Things' official AppleScript and URL scheme interfaces.
@main
struct Things: PrismExtension {
    enum CommandID {
        static let myTodos = "my-todos"
        static let quickAdd = "quick-add"
    }

    enum ActionID {
        static let complete = "complete"
        static let reopen = "reopen"
        static let cancel = "cancel"
        static let open = "open"
        static let scheduleMenu = "schedule-menu"
        static let scheduleToday = "schedule-today"
        static let scheduleTomorrow = "schedule-tomorrow"
        static let scheduleWeekend = "schedule-weekend"
        static let scheduleNextWeek = "schedule-next-week"
        static let scheduleAnytime = "schedule-anytime"
        static let scheduleSomeday = "schedule-someday"
        static let deadlineMenu = "deadline-menu"
        static let deadlineToday = "deadline-today"
        static let deadlineTomorrow = "deadline-tomorrow"
        static let deadlineWeekend = "deadline-weekend"
        static let deadlineNextWeek = "deadline-next-week"
        static let deadlineClear = "deadline-clear"
        static let moveMenu = "move-menu"
        static let moveInbox = "move-inbox"
        static let moveProjectPrefix = "move-project:"
        static let moveAreaPrefix = "move-area:"
        static let openAttachedURL = "open-attached-url"
        static let copyMenu = "copy-menu"
        static let copyTitle = "copy-title"
        static let copyNotes = "copy-notes"
        static let copyLink = "copy-link"
        static let delete = "delete"
        static let create = "create"
        static let createAndOpen = "create-and-open"
        static let createWhenMenu = "create-when-menu"
        static let createWhenToday = "create-when-today"
        static let createWhenEvening = "create-when-evening"
        static let createWhenTomorrow = "create-when-tomorrow"
        static let createWhenSomeday = "create-when-someday"
        static let createInContainerMenu = "create-in-container-menu"
        static let createInContainerPrefix = "create-in-container:"
        static let allowAccess = "allow-access"
        static let launchThings = "launch-things"
        static let openAutomationSettings = "open-automation-settings"
        static let openAppStore = "open-app-store"
    }

    static let appNotInstalledItemID = "app-not-installed"
    static let appNotRunningItemID = "app-not-running"
    static let allowAccessItemID = "allow-access"
    static let automationSettingsItemID = "open-automation-settings"
    static let createItemPrefix = "create:"
    static let createInContainerItemPrefix = "create-in:"
    static let resultLimit = 100

    let repository: any ThingsRepository
    let pinyinCache = PinyinCache()
    let library = ThingsLibrary()
    let openURL: @Sendable (URL, Bool) async throws -> Void
    let now: @Sendable () -> Date
    let calendar: Calendar

    init() {
        self.init(
            repository: AppleScriptThingsRepository(),
            openURL: Self.openWithWorkspace
        )
    }

    init(
        repository: any ThingsRepository,
        openURL: @escaping @Sendable (URL, Bool) async throws -> Void,
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
        case CommandID.myTodos:
            return try await listMyTodos(query: query, filter: filter, context: context)
        case CommandID.quickAdd:
            return try await listQuickAdd(query: query)
        default:
            throw PrismExtensionError(localized("Things has no list “\(command)”."))
        }
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        if action == ActionID.allowAccess {
            let status = await repository.requestAutomationAccess()
            library.invalidate()
            switch status {
            case .authorized:
                return .reload(message: localized("Things Access Granted"))
            case .notRunning:
                return .reload(message: localized("Open Things and try again."))
            default:
                return .reload(message: localized("Things access was not granted."))
            }
        }

        if action == ActionID.launchThings {
            try await openURL(ThingsURLs.showURL(id: "today"), false)
            library.invalidate()
            return .reload(message: localized("Opened Things"))
        }

        if item.hasPrefix(Self.createItemPrefix) || item.hasPrefix(Self.createInContainerItemPrefix) {
            return try await performCreate(action: action, item: item, command: command, context: context)
        }

        switch action {
        case ActionID.complete:
            return try await mutate(message: localized("Completed To-Do")) {
                try await repository.setStatus(id: item, status: .completed)
            }

        case ActionID.reopen:
            return try await mutate(message: localized("Marked as Incomplete")) {
                try await repository.setStatus(id: item, status: .open)
            }

        case ActionID.cancel:
            return try await mutate(message: localized("Canceled To-Do")) {
                try await repository.setStatus(id: item, status: .canceled)
            }

        case ActionID.scheduleToday:
            return try await mutate(message: localized("Scheduled for Today")) {
                try await repository.move(id: item, to: .list(ThingsBucket.today.appleScriptListID))
            }

        case ActionID.scheduleTomorrow:
            let date = makeDates(now: now()).tomorrow()
            return try await mutate(message: localized("Scheduled for Tomorrow")) {
                try await repository.schedule(id: item, for: date)
            }

        case ActionID.scheduleWeekend:
            let date = makeDates(now: now()).thisWeekend()
            return try await mutate(message: localized("Scheduled for This Weekend")) {
                try await repository.schedule(id: item, for: date)
            }

        case ActionID.scheduleNextWeek:
            let date = makeDates(now: now()).nextWeek()
            return try await mutate(message: localized("Scheduled for Next Week")) {
                try await repository.schedule(id: item, for: date)
            }

        case ActionID.scheduleAnytime:
            return try await mutate(message: localized("Moved to Anytime")) {
                try await repository.move(id: item, to: .list(ThingsBucket.anytime.appleScriptListID))
            }

        case ActionID.scheduleSomeday:
            return try await mutate(message: localized("Moved to Someday")) {
                try await repository.move(id: item, to: .list(ThingsBucket.someday.appleScriptListID))
            }

        case ActionID.deadlineToday:
            let date = makeDates(now: now()).today()
            return try await mutate(message: localized("Deadline Set to Today")) {
                try await repository.setDeadline(id: item, deadline: date)
            }

        case ActionID.deadlineTomorrow:
            let date = makeDates(now: now()).tomorrow()
            return try await mutate(message: localized("Deadline Set to Tomorrow")) {
                try await repository.setDeadline(id: item, deadline: date)
            }

        case ActionID.deadlineWeekend:
            let date = makeDates(now: now()).thisWeekend()
            return try await mutate(message: localized("Deadline Set to This Weekend")) {
                try await repository.setDeadline(id: item, deadline: date)
            }

        case ActionID.deadlineNextWeek:
            let date = makeDates(now: now()).nextWeek()
            return try await mutate(message: localized("Deadline Set to Next Week")) {
                try await repository.setDeadline(id: item, deadline: date)
            }

        case ActionID.deadlineClear:
            return try await mutate(message: localized("Removed Deadline")) {
                try await repository.setDeadline(id: item, deadline: nil)
            }

        case ActionID.moveInbox:
            return try await mutate(message: localized("Moved to Inbox")) {
                try await repository.move(id: item, to: .list(ThingsBucket.inbox.appleScriptListID))
            }

        case let actionID where actionID.hasPrefix(ActionID.moveProjectPrefix):
            let projectID = String(actionID.dropFirst(ActionID.moveProjectPrefix.count))
            return try await mutate(message: localized("Moved To-Do")) {
                try await repository.move(id: item, to: .project(projectID))
            }

        case let actionID where actionID.hasPrefix(ActionID.moveAreaPrefix):
            let areaID = String(actionID.dropFirst(ActionID.moveAreaPrefix.count))
            return try await mutate(message: localized("Moved To-Do")) {
                try await repository.move(id: item, to: .area(areaID))
            }

        case ActionID.delete:
            return try await mutate(message: localized("Moved to Trash")) {
                try await repository.delete(id: item)
            }

        default:
            throw PrismExtensionError(localized("Things has no action “\(action)”."))
        }
    }

    // MARK: - Lists

    private func listMyTodos(query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard repository.isInstalled() else {
            return myTodosList(items: [ThingsRows.appNotInstalledItem], filters: ThingsRows.filters(containers: []))
        }

        switch repository.authorizationStatus() {
        case .notRunning:
            return myTodosList(items: [ThingsRows.appNotRunningItem], filters: ThingsRows.filters(containers: []))
        case .notDetermined:
            return myTodosList(items: [ThingsRows.allowAccessItem], filters: ThingsRows.filters(containers: []))
        case .denied:
            return myTodosList(items: [ThingsRows.openAutomationSettingsItem], filters: ThingsRows.filters(containers: []))
        case .authorized:
            break
        }

        let activeFilter = ThingsFilter(filterID: filter)
        let loadedAt = now()

        let data: ThingsLibrary.CachedData
        do {
            data = try await library.load(
                logbook: activeFilter.loadsLogbook,
                forceRefresh: query.isEmpty,
                now: loadedAt,
                from: repository,
                pinyin: pinyinCache,
                directory: context.dataDirectory
            )
        } catch ThingsRepositoryError.appNotInstalled {
            return myTodosList(items: [ThingsRows.appNotInstalledItem], filters: ThingsRows.filters(containers: []))
        } catch ThingsRepositoryError.appNotRunning {
            return myTodosList(items: [ThingsRows.appNotRunningItem], filters: ThingsRows.filters(containers: []))
        } catch ThingsRepositoryError.automationDenied {
            return myTodosList(items: [ThingsRows.openAutomationSettingsItem], filters: ThingsRows.filters(containers: []))
        }

        let dates = makeDates(now: loadedAt)
        let filters = ThingsRows.filters(containers: data.containers)
        let search = ThingsSearch(query: query)
        let results = search.results(
            in: data.todos,
            filter: activeFilter,
            now: loadedAt,
            calendar: calendar,
            limit: Self.resultLimit
        )

        if results.isEmpty, !search.words.isEmpty, activeFilter != .logbook {
            let defaultWhen: ThingsWhen? = switch activeFilter {
            case .today: .today
            case .anytime: .anytime
            case .someday: .someday
            default: nil
            }
            if let draft = QuickAddParser.parse(
                query,
                containers: data.containers,
                preferredContainerID: activeFilter.preferredContainerID,
                defaultWhen: defaultWhen,
                now: loadedAt,
                calendar: calendar
            ) {
                let item = ThingsRows.createItem(
                    itemID: Self.encodeCreateItemID(
                        query: query,
                        preferredContainerID: activeFilter.preferredContainerID,
                        defaultWhen: defaultWhen
                    ),
                    draft: draft,
                    containers: data.containers,
                    dates: dates,
                    isQuickAddCommand: false
                )
                return myTodosList(items: [item], filters: filters, fetchedAt: data.loadedAt, error: data.staleError)
            }
        }

        return myTodosList(
            items: results.map {
                ThingsRows.item(
                    for: $0,
                    filter: activeFilter,
                    containers: data.containers,
                    dates: dates
                )
            },
            filters: filters,
            emptyMessage: ThingsRows.emptyMessage(for: activeFilter, hasQuery: !search.words.isEmpty),
            fetchedAt: data.loadedAt,
            error: data.staleError
        )
    }

    private func myTodosList(
        items: [ExtensionListItem],
        filters: [ExtensionListFilter],
        emptyMessage: ExtensionListMessage? = nil,
        fetchedAt: Date? = nil,
        error: String? = nil
    ) -> ExtensionList {
        ExtensionList(
            items: items,
            filtering: .extension,
            searchPlaceholder: ThingsRows.myTodosPlaceholder,
            filters: filters,
            emptyMessage: emptyMessage,
            showsDetail: false,
            fetchedAt: fetchedAt,
            error: error
        )
    }

    private func listQuickAdd(query: String) async throws -> ExtensionList {
        guard repository.isInstalled() else {
            return ExtensionList(
                items: [ThingsRows.appNotInstalledItem],
                filtering: .extension,
                searchPlaceholder: ThingsRows.quickAddPlaceholder,
                showsDetail: false
            )
        }

        let loadedAt = now()
        let containers = try await loadContainersIgnoringErrors(forceRefresh: query.isEmpty, now: loadedAt)
        let dates = makeDates(now: loadedAt)

        guard let draft = QuickAddParser.parse(
            query,
            containers: containers,
            now: loadedAt,
            calendar: calendar
        ) else {
            return ExtensionList(
                items: [],
                filtering: .extension,
                searchPlaceholder: ThingsRows.quickAddPlaceholder,
                emptyMessage: ThingsRows.quickAddEmptyMessage,
                showsDetail: false,
                fetchedAt: loadedAt
            )
        }

        let item = ThingsRows.createItem(
            itemID: Self.encodeCreateItemID(query: query, preferredContainerID: nil),
            draft: draft,
            containers: containers,
            dates: dates,
            isQuickAddCommand: true
        )
        return ExtensionList(
            items: [item],
            filtering: .extension,
            searchPlaceholder: ThingsRows.quickAddPlaceholder,
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
        guard repository.isInstalled() else {
            return ExtensionActionResult(.failed(message: ThingsRepositoryError.appNotInstalled.userMessage))
        }

        let (rawQuery, preferredContainerID, defaultWhen) = Self.decodeCreateItemID(item)
        let currentNow = now()
        let containers = try await loadContainersIgnoringErrors(forceRefresh: false, now: currentNow)

        guard var draft = QuickAddParser.parse(
            rawQuery,
            containers: containers,
            preferredContainerID: preferredContainerID,
            defaultWhen: defaultWhen,
            now: currentNow,
            calendar: calendar
        ) else {
            return ExtensionActionResult(.failed(message: localized("Couldn’t add an empty to-do.")))
        }

        var reveal = false
        switch action {
        case ActionID.create:
            break
        case ActionID.createAndOpen:
            reveal = true
        case ActionID.createWhenToday:
            draft.when = .today
        case ActionID.createWhenEvening:
            draft.when = .evening
        case ActionID.createWhenTomorrow:
            draft.when = .tomorrow
        case ActionID.createWhenSomeday:
            draft.when = .someday
        case let actionID where actionID.hasPrefix(ActionID.createInContainerPrefix):
            let containerID = String(actionID.dropFirst(ActionID.createInContainerPrefix.count))
            draft.listID = containerID
            draft.listTitle = containers.first { $0.id == containerID }?.title
        default:
            throw PrismExtensionError(localized("Things has no action “\(action)”."))
        }

        guard let url = ThingsURLs.add(draft, reveal: reveal) else {
            return ExtensionActionResult(.failed(message: localized("Couldn’t build the Things URL for this to-do.")))
        }

        try await openURL(url, reveal)
        library.invalidate()
        await context.listChanged(CommandID.myTodos)

        if reveal {
            return .done
        }
        if command == CommandID.quickAdd {
            return ExtensionActionResult(.hud(message: localized("Added “\(draft.title)”")))
        }
        return .reload(message: localized("Added “\(draft.title)”"))
    }

    private func mutate(
        message: String,
        operation: () async throws -> Void
    ) async throws -> ExtensionActionResult {
        do {
            try await operation()
        } catch let error as ThingsRepositoryError {
            return ExtensionActionResult(.failed(message: error.userMessage))
        }
        library.invalidate()
        return .reload(message: message)
    }

    private func loadContainersIgnoringErrors(forceRefresh: Bool, now: Date) async throws -> [ThingsContainer] {
        guard repository.authorizationStatus() == .authorized else {
            return []
        }
        do {
            return try await library.containers(forceRefresh: forceRefresh, now: now, from: repository)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func makeDates(now: Date) -> ThingsDates {
        ThingsDates(now: now, calendar: calendar, locale: ThingsDates.locale(prismLanguage: PrismLocalization.language))
    }

    static func encodeCreateItemID(
        query: String,
        preferredContainerID: String? = nil,
        defaultWhen: ThingsWhen? = nil
    ) -> String {
        let containerPart = preferredContainerID ?? ""
        let whenPart = defaultWhen?.urlParameterValue ?? ""
        if !containerPart.isEmpty || !whenPart.isEmpty {
            return "\(createInContainerItemPrefix)\(containerPart)|\(whenPart):\(query)"
        }
        return createItemPrefix + query
    }

    static func decodeCreateItemID(_ item: String) -> (query: String, preferredContainerID: String?, defaultWhen: ThingsWhen?) {
        if item.hasPrefix(createInContainerItemPrefix) {
            let rest = item.dropFirst(createInContainerItemPrefix.count)
            if let colon = rest.firstIndex(of: ":") {
                let header = rest[..<colon]
                let query = String(rest[rest.index(after: colon)...])
                let parts = header.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let containerID = parts.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
                let when = parts.count > 1 ? ThingsWhen(presetCode: String(parts[1])) : nil
                return (query, containerID, when)
            }
        }
        if item.hasPrefix(createItemPrefix) {
            return (String(item.dropFirst(createItemPrefix.count)), nil, nil)
        }
        return (item, nil, nil)
    }

    private static func openWithWorkspace(_ url: URL, activate: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        let app = try await NSWorkspace.shared.open(url, configuration: configuration)
        if activate {
            app.activate()
        }
    }
}
