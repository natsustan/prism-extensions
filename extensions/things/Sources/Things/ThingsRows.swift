import Foundation
import PrismExtensionKit

/// Builds Prism list rows, filters, actions, and empty states for Things.
enum ThingsRows {
    static var myTodosPlaceholder: String {
        localized("Search to-dos, projects, tags, or type to add…")
    }

    static var quickAddPlaceholder: String {
        localized("Buy milk tomorrow @Errands #home // Oat milk")
    }

    static var appNotInstalledItem: ExtensionListItem {
        ExtensionListItem(
            id: Things.appNotInstalledItemID,
            title: localized("Things 3 Is Not Installed"),
            subtitle: localized("Install Things 3 from the Mac App Store to browse and add to-dos."),
            icon: ExtensionIcon(symbol: "exclamationmark.triangle", tint: "orange"),
            actions: [
                ExtensionAction(
                    id: Things.ActionID.openAppStore,
                    title: localized("Open Things Website"),
                    symbol: "safari",
                    kind: .open(url: ThingsURLs.websiteURL)
                ),
            ]
        )
    }

    static var appNotRunningItem: ExtensionListItem {
        ExtensionListItem(
            id: Things.appNotRunningItemID,
            title: localized("Things 3 Is Not Running"),
            subtitle: localized("Press Return to open Things so Prism can load your to-dos."),
            icon: ExtensionIcon(symbol: "play.circle", tint: "blue"),
            actions: [
                ExtensionAction(
                    id: Things.ActionID.launchThings,
                    title: localized("Open Things"),
                    symbol: "arrow.up.forward.app"
                ),
            ]
        )
    }

    static var allowAccessItem: ExtensionListItem {
        ExtensionListItem(
            id: Things.allowAccessItemID,
            title: localized("Allow Prism to Control Things"),
            subtitle: localized("Press Return and allow Automation access when macOS asks."),
            icon: ExtensionIcon(symbol: "lock.shield", tint: "blue"),
            actions: [
                ExtensionAction(
                    id: Things.ActionID.allowAccess,
                    title: localized("Allow Access"),
                    symbol: "checkmark.shield"
                ),
            ]
        )
    }

    static var openAutomationSettingsItem: ExtensionListItem {
        ExtensionListItem(
            id: Things.automationSettingsItemID,
            title: localized("Allow Prism to Control Things"),
            subtitle: localized("Open System Settings → Privacy & Security → Automation and enable Things."),
            icon: ExtensionIcon(symbol: "lock.shield", tint: "orange"),
            actions: [
                ExtensionAction(
                    id: Things.ActionID.openAutomationSettings,
                    title: localized("Open Automation Settings"),
                    symbol: "gearshape",
                    kind: .open(url: ThingsURLs.automationSettingsURL)
                ),
            ]
        )
    }

    // MARK: - Filters

    static func filters(containers: [ThingsContainer]) -> [ExtensionListFilter] {
        var result: [ExtensionListFilter] = [
            ExtensionListFilter(id: ThingsFilter.allID, title: localized("All Active"), symbol: "tray.full"),
            ExtensionListFilter(id: ThingsFilter.todayID, title: localized("Today"), symbol: "star"),
            ExtensionListFilter(id: ThingsFilter.inboxID, title: localized("Inbox"), symbol: "tray"),
            ExtensionListFilter(id: ThingsFilter.upcomingID, title: localized("Upcoming"), symbol: "calendar"),
            ExtensionListFilter(id: ThingsFilter.anytimeID, title: localized("Anytime"), symbol: "square.stack"),
            ExtensionListFilter(id: ThingsFilter.somedayID, title: localized("Someday"), symbol: "archivebox"),
            ExtensionListFilter(id: ThingsFilter.logbookID, title: localized("Logbook"), symbol: "checkmark.circle"),
        ]
        for container in containers where container.kind == .project {
            result.append(
                ExtensionListFilter(
                    id: ThingsFilter.projectPrefix + container.id,
                    title: container.title,
                    symbol: "circle.dotted"
                )
            )
        }
        for container in containers where container.kind == .area {
            result.append(
                ExtensionListFilter(
                    id: ThingsFilter.areaPrefix + container.id,
                    title: container.title,
                    symbol: "cube"
                )
            )
        }
        return result
    }

    // MARK: - To-Do Row

    static func item(
        for todo: ThingsTodo,
        filter: ThingsFilter,
        containers: [ThingsContainer],
        dates: ThingsDates
    ) -> ExtensionListItem {
        let subtitle = rowSubtitle(for: todo)
        let accessories = rowAccessories(for: todo, filter: filter, dates: dates)
        let section = sectionTitle(for: todo, filter: filter)

        return ExtensionListItem(
            id: todo.id,
            title: todo.title,
            subtitle: subtitle,
            icon: rowIcon(for: todo, dates: dates),
            accessories: accessories,
            section: section,
            actions: rowActions(for: todo, containers: containers)
        )
    }

    private static func rowIcon(for todo: ThingsTodo, dates: ThingsDates) -> ExtensionIcon {
        switch todo.status {
        case .completed:
            return ExtensionIcon(symbol: "checkmark.circle.fill", tint: "blue", style: .glyph)
        case .canceled:
            return ExtensionIcon(symbol: "xmark.circle.fill", tint: "gray", style: .glyph)
        case .open:
            if todo.isOverdue(now: dates.now, calendar: dates.calendar) {
                return ExtensionIcon(symbol: "circle", tint: "red", style: .glyph)
            }
            if todo.bucket == .today {
                return ExtensionIcon(symbol: "star.fill", tint: "gold", style: .glyph)
            }
            return ExtensionIcon(symbol: "circle", tint: "blue", style: .glyph)
        }
    }

    private static func rowSubtitle(for todo: ThingsTodo) -> String? {
        let firstNoteLine = todo.notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let firstNoteLine {
            return firstNoteLine
        }
        return nil
    }

    private static func rowAccessories(
        for todo: ThingsTodo,
        filter: ThingsFilter,
        dates: ThingsDates
    ) -> [ExtensionListAccessory] {
        var accessories: [ExtensionListAccessory] = []

        if !todo.isOpen {
            if let doneDate = todo.completionDate ?? todo.cancellationDate {
                accessories.append(
                    ExtensionListAccessory(
                        text: dates.completionAccessoryLabel(for: doneDate),
                        symbol: todo.status == .canceled ? "xmark" : "checkmark",
                        tint: "gray"
                    )
                )
            }
        } else {
            if let dueDate = todo.dueDate {
                let overdue = todo.isOverdue(now: dates.now, calendar: dates.calendar)
                accessories.append(
                    ExtensionListAccessory(
                        text: dates.dayLabel(for: dueDate),
                        symbol: "flag.fill",
                        tint: overdue ? "red" : "orange",
                        help: localized("Deadline: \(dates.detailDateLabel(for: dueDate))")
                    )
                )
            } else if todo.bucket == .upcoming, let act = todo.activationDate {
                accessories.append(
                    ExtensionListAccessory(
                        text: dates.dayLabel(for: act),
                        symbol: "calendar",
                        tint: "red"
                    )
                )
            }
        }

        if let parent = todo.parentTitle, !isShowingSameContainer(todo: todo, filter: filter) {
            accessories.append(
                ExtensionListAccessory(
                    text: parent,
                    tint: "blue",
                    style: .tag
                )
            )
        }

        if let firstTag = todo.tags.first {
            let label = todo.tags.count > 1 ? "#\(firstTag) +\(todo.tags.count - 1)" : "#\(firstTag)"
            accessories.append(
                ExtensionListAccessory(
                    text: label,
                    tint: "gray",
                    help: todo.tags.map { "#\($0)" }.joined(separator: ", ")
                )
            )
        }

        return accessories
    }

    private static func isShowingSameContainer(todo: ThingsTodo, filter: ThingsFilter) -> Bool {
        switch filter {
        case let .project(id): todo.projectID == id
        case let .area(id): todo.projectID == nil && todo.areaID == id
        default: false
        }
    }

    private static func sectionTitle(for todo: ThingsTodo, filter: ThingsFilter) -> String? {
        guard filter == .all || filter.preferredContainerID != nil else { return nil }
        switch todo.bucket {
        case .today: return localized("Today")
        case .inbox: return localized("Inbox")
        case .upcoming: return localized("Upcoming")
        case .anytime: return localized("Anytime")
        case .someday: return localized("Someday")
        case .logbook: return localized("Logbook")
        }
    }

    private static func rowActions(for todo: ThingsTodo, containers: [ThingsContainer]) -> [ExtensionAction] {
        var actions: [ExtensionAction] = []

        // Primary action (Return): Complete or Reopen
        if todo.isOpen {
            actions.append(
                ExtensionAction(
                    id: Things.ActionID.complete,
                    title: localized("Complete To-Do"),
                    symbol: "checkmark.circle"
                )
            )
        } else {
            actions.append(
                ExtensionAction(
                    id: Things.ActionID.reopen,
                    title: localized("Mark as Incomplete"),
                    symbol: "arrow.uturn.backward.circle"
                )
            )
        }

        actions.append(
            ExtensionAction(
                id: Things.ActionID.open,
                title: localized("Open in Things"),
                symbol: "arrow.up.forward.app",
                kind: .open(url: ThingsURLs.showURL(id: todo.id)),
                shortcut: ExtensionShortcut("cmd+shift+o")
            )
        )

        if todo.isOpen {
            actions.append(
                ExtensionAction(
                    id: Things.ActionID.cancel,
                    title: localized("Cancel To-Do"),
                    symbol: "xmark.circle",
                    shortcut: ExtensionShortcut("cmd+shift+x")
                )
            )

            // Schedule submenu
            actions.append(
                ExtensionAction(
                    id: Things.ActionID.scheduleMenu,
                    title: localized("When…"),
                    symbol: "calendar",
                    shortcut: ExtensionShortcut("cmd+shift+s"),
                    actions: [
                        ExtensionAction(id: Things.ActionID.scheduleToday, title: localized("Today"), symbol: "star"),
                        ExtensionAction(id: Things.ActionID.scheduleTomorrow, title: localized("Tomorrow"), symbol: "sunrise"),
                        ExtensionAction(id: Things.ActionID.scheduleWeekend, title: localized("This Weekend"), symbol: "sun.max"),
                        ExtensionAction(id: Things.ActionID.scheduleNextWeek, title: localized("Next Week"), symbol: "calendar.badge.plus"),
                        ExtensionAction(id: Things.ActionID.scheduleAnytime, title: localized("Anytime"), symbol: "square.stack"),
                        ExtensionAction(id: Things.ActionID.scheduleSomeday, title: localized("Someday"), symbol: "archivebox"),
                    ]
                )
            )

            // Deadline submenu
            var deadlineActions: [ExtensionAction] = [
                ExtensionAction(id: Things.ActionID.deadlineToday, title: localized("Today"), symbol: "flag"),
                ExtensionAction(id: Things.ActionID.deadlineTomorrow, title: localized("Tomorrow"), symbol: "flag"),
                ExtensionAction(id: Things.ActionID.deadlineWeekend, title: localized("This Weekend"), symbol: "flag"),
                ExtensionAction(id: Things.ActionID.deadlineNextWeek, title: localized("Next Week"), symbol: "flag"),
            ]
            if todo.dueDate != nil {
                deadlineActions.append(
                    ExtensionAction(id: Things.ActionID.deadlineClear, title: localized("Remove Deadline"), symbol: "xmark.circle")
                )
            }
            actions.append(
                ExtensionAction(
                    id: Things.ActionID.deadlineMenu,
                    title: localized("Deadline…"),
                    symbol: "flag",
                    shortcut: ExtensionShortcut("cmd+shift+d"),
                    actions: deadlineActions
                )
            )

            // Move submenu
            var moveActions: [ExtensionAction] = [
                ExtensionAction(id: Things.ActionID.moveInbox, title: localized("Inbox"), symbol: "tray"),
            ]
            for container in containers where container.kind == .project && container.id != todo.projectID {
                moveActions.append(
                    ExtensionAction(
                        id: Things.ActionID.moveProjectPrefix + container.id,
                        title: container.title,
                        symbol: "circle.dotted"
                    )
                )
            }
            for container in containers where container.kind == .area && container.id != todo.areaID {
                moveActions.append(
                    ExtensionAction(
                        id: Things.ActionID.moveAreaPrefix + container.id,
                        title: container.title,
                        symbol: "cube"
                    )
                )
            }
            actions.append(
                ExtensionAction(
                    id: Things.ActionID.moveMenu,
                    title: localized("Move to…"),
                    symbol: "folder",
                    shortcut: ExtensionShortcut("cmd+shift+m"),
                    actions: moveActions
                )
            )
        }

        if let url = todo.primaryURL {
            actions.append(
                ExtensionAction(
                    id: Things.ActionID.openAttachedURL,
                    title: localized("Open Link"),
                    symbol: "link",
                    kind: .open(url: url),
                    shortcut: ExtensionShortcut("cmd+shift+l")
                )
            )
        }

        var copyActions: [ExtensionAction] = [
            ExtensionAction(
                id: Things.ActionID.copyTitle,
                title: localized("Copy Title"),
                symbol: "doc.on.doc",
                kind: .copy(text: todo.title),
                shortcut: ExtensionShortcut("cmd+shift+t")
            ),
        ]
        if !todo.notes.isEmpty {
            copyActions.append(
                ExtensionAction(
                    id: Things.ActionID.copyNotes,
                    title: localized("Copy Notes"),
                    symbol: "note.text",
                    kind: .copy(text: todo.notes),
                    shortcut: ExtensionShortcut("cmd+shift+n")
                )
            )
        }
        copyActions.append(
            ExtensionAction(
                id: Things.ActionID.copyLink,
                title: localized("Copy Things Link"),
                symbol: "link",
                kind: .copy(text: ThingsURLs.show(id: todo.id)),
                shortcut: ExtensionShortcut("cmd+shift+c")
            )
        )
        actions.append(
            ExtensionAction(
                id: Things.ActionID.copyMenu,
                title: localized("Copy…"),
                symbol: "doc.on.doc",
                actions: copyActions
            )
        )

        actions.append(
            ExtensionAction(
                id: Things.ActionID.delete,
                title: localized("Move to Trash"),
                symbol: "trash",
                style: .destructive,
                confirmationMessage: localized("Move “\(todo.title)” to Things Trash?")
            )
        )

        return actions
    }

    // MARK: - Quick Add Row

    static func createItem(
        itemID: String,
        draft: ThingsDraft,
        containers: [ThingsContainer],
        dates: ThingsDates,
        isQuickAddCommand: Bool
    ) -> ExtensionListItem {
        var accessories: [ExtensionListAccessory] = []
        if let when = draft.when {
            accessories.append(
                ExtensionListAccessory(
                    text: dates.whenLabel(for: when),
                    symbol: when == .today || when == .evening ? "star.fill" : "calendar",
                    tint: when == .today || when == .evening ? "gold" : "blue"
                )
            )
        }
        if let deadline = draft.deadline {
            accessories.append(
                ExtensionListAccessory(
                    text: dates.dayLabel(for: deadline),
                    symbol: "flag.fill",
                    tint: "orange",
                    help: localized("Deadline: \(dates.detailDateLabel(for: deadline))")
                )
            )
        }
        if let listTitle = draft.listTitle, !listTitle.isEmpty {
            accessories.append(
                ExtensionListAccessory(text: listTitle, tint: "blue", style: .tag)
            )
        } else {
            accessories.append(
                ExtensionListAccessory(text: localized("Inbox"), tint: "gray", style: .tag)
            )
        }
        for tag in draft.tags.prefix(2) {
            accessories.append(ExtensionListAccessory(text: "#\(tag)", tint: "gray"))
        }

        let subtitle: String?
        if !draft.notes.isEmpty {
            subtitle = draft.notes
        } else if isQuickAddCommand {
            subtitle = localized("Press Return to add to Things")
        } else {
            subtitle = localized("No matching to-dos — press Return to add")
        }

        var actions: [ExtensionAction] = [
            ExtensionAction(
                id: Things.ActionID.create,
                title: localized("Add To-Do"),
                symbol: "plus.circle.fill"
            ),
            ExtensionAction(
                id: Things.ActionID.createAndOpen,
                title: localized("Add and Open in Things"),
                symbol: "arrow.up.forward.app",
                shortcut: ExtensionShortcut("cmd+shift+o")
            ),
            ExtensionAction(
                id: Things.ActionID.createWhenMenu,
                title: localized("Add with Schedule…"),
                symbol: "calendar",
                shortcut: ExtensionShortcut("cmd+shift+s"),
                actions: [
                    ExtensionAction(id: Things.ActionID.createWhenToday, title: localized("Today"), symbol: "star"),
                    ExtensionAction(id: Things.ActionID.createWhenEvening, title: localized("This Evening"), symbol: "moon.stars"),
                    ExtensionAction(id: Things.ActionID.createWhenTomorrow, title: localized("Tomorrow"), symbol: "sunrise"),
                    ExtensionAction(id: Things.ActionID.createWhenSomeday, title: localized("Someday"), symbol: "archivebox"),
                ]
            ),
        ]

        if !containers.isEmpty {
            let listActions = containers.map { container in
                ExtensionAction(
                    id: Things.ActionID.createInContainerPrefix + container.id,
                    title: container.title,
                    symbol: container.kind == .project ? "circle.dotted" : "cube"
                )
            }
            actions.append(
                ExtensionAction(
                    id: Things.ActionID.createInContainerMenu,
                    title: localized("Add to Project or Area…"),
                    symbol: "folder",
                    shortcut: ExtensionShortcut("cmd+shift+m"),
                    actions: listActions
                )
            )
        }

        return ExtensionListItem(
            id: itemID,
            title: localized("Add “\(draft.title)”"),
            subtitle: subtitle,
            icon: ExtensionIcon(symbol: "plus.circle.fill", tint: "blue"),
            accessories: accessories,
            actions: actions
        )
    }

    // MARK: - Empty States

    static func emptyMessage(for filter: ThingsFilter, hasQuery: Bool) -> ExtensionListMessage {
        if hasQuery {
            return ExtensionListMessage(
                title: localized("No Matching To-Dos"),
                message: localized("Try a different search or filter."),
                symbol: "magnifyingglass"
            )
        }
        switch filter {
        case .today:
            return ExtensionListMessage(
                title: localized("Nothing for Today"),
                message: localized("Enjoy your day, or type to add a new to-do."),
                symbol: "star"
            )
        case .inbox:
            return ExtensionListMessage(
                title: localized("Inbox Is Empty"),
                message: localized("Type to add a new to-do right away."),
                symbol: "tray"
            )
        case .logbook:
            return ExtensionListMessage(
                title: localized("No Completed To-Dos"),
                message: localized("Completed and canceled to-dos appear here."),
                symbol: "checkmark.circle"
            )
        default:
            return ExtensionListMessage(
                title: localized("No To-Dos"),
                message: localized("Type to add a new to-do to Things."),
                symbol: "checkmark.circle"
            )
        }
    }

    static var quickAddEmptyMessage: ExtensionListMessage {
        ExtensionListMessage(
            title: localized("Quick Add To-Do"),
            message: localized("Try “Buy milk tomorrow @Errands #home // Oat milk” or “周五 交报告 截止:周六”."),
            symbol: "plus.circle"
        )
    }
}
