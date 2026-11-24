import Foundation
import PrismExtensionKit

/// Maps reminders, lists, filters, quick-add previews, and access prompts into
/// clean single-column Prism list items and actions.
enum ReminderRows {
    typealias ActionID = AppleReminders.ActionID

    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
    )!

    static var myRemindersPlaceholder: String {
        localized("Search reminders…")
    }

    static var quickAddPlaceholder: String {
        localized("Buy milk tomorrow 9am ! #List")
    }

    static func filters(lists: [ReminderList]) -> [ExtensionListFilter] {
        var result = [
            ExtensionListFilter(id: ReminderFilter.allID, title: localized("All"), symbol: "tray"),
            ExtensionListFilter(id: ReminderFilter.todayID, title: localized("Today"), symbol: "calendar"),
            ExtensionListFilter(id: ReminderFilter.overdueID, title: localized("Overdue"), symbol: "exclamationmark.circle"),
            ExtensionListFilter(id: ReminderFilter.scheduledID, title: localized("Scheduled"), symbol: "calendar.badge.clock"),
            ExtensionListFilter(id: ReminderFilter.completedID, title: localized("Completed"), symbol: "checkmark.circle"),
        ]
        for list in lists {
            result.append(ExtensionListFilter(
                id: ReminderFilter.listPrefix + list.id,
                title: list.title,
                symbol: "list.bullet"
            ))
        }
        return result
    }

    static func emptyMessage(for filter: ReminderFilter, hasQuery: Bool) -> ExtensionListMessage {
        if hasQuery {
            return ExtensionListMessage(title: localized("No Matching Reminders"), symbol: "magnifyingglass")
        }
        switch filter {
        case .all:
            return ExtensionListMessage(
                title: localized("No Reminders"),
                message: localized("Reminders you add in Apple Reminders appear here."),
                symbol: "checklist"
            )
        case .today:
            return ExtensionListMessage(
                title: localized("Nothing Due Today"),
                message: localized("You’re all caught up for today."),
                symbol: "checkmark.circle"
            )
        case .overdue:
            return ExtensionListMessage(
                title: localized("No Overdue Reminders"),
                message: localized("None of your reminders are past due."),
                symbol: "checkmark.circle"
            )
        case .scheduled:
            return ExtensionListMessage(
                title: localized("No Scheduled Reminders"),
                message: localized("Reminders with a due date appear here."),
                symbol: "calendar"
            )
        case .completed:
            return ExtensionListMessage(
                title: localized("No Completed Reminders"),
                message: localized("Completed reminders appear here."),
                symbol: "checkmark.circle"
            )
        case .list:
            return ExtensionListMessage(
                title: localized("No Reminders in This List"),
                message: localized("Type to create a new reminder in this list."),
                symbol: "list.bullet"
            )
        }
    }

    static func quickAddEmptyMessage(defaultListTitle: String?) -> ExtensionListMessage {
        let targetNote: String
        if let defaultListTitle, !defaultListTitle.isEmpty {
            targetNote = localized("Type a reminder to add to “\(defaultListTitle)”. Supports dates (tomorrow 9am, 明天 9点), priority (! / !! / !!!), #List, #tags, and // notes.")
        } else {
            targetNote = localized("Type a reminder to create it. Supports dates (tomorrow 9am, 明天 9点), priority (! / !! / !!!), #List, #tags, and // notes.")
        }
        return ExtensionListMessage(
            title: localized("Quick Add Reminder"),
            message: targetNote,
            symbol: "plus.circle"
        )
    }

    // MARK: - Reminder Item

    static func item(
        for reminder: Reminder,
        filter: ReminderFilter,
        lists: [ReminderList],
        dates: ReminderDates,
        showExactTime: Bool
    ) -> ExtensionListItem {
        let title = oneLine(reminder.title) ?? localized("Untitled Reminder")
        let isSingleList: Bool = if case .list = filter { true } else { false }
        let isOverdue = !reminder.isCompleted
            && (reminder.dueDate?.isOverdue(now: dates.now, calendar: dates.calendar) ?? false)

        let icon = reminder.isCompleted
            ? ExtensionIcon(symbol: "checkmark.circle.fill", tint: "green", style: .glyph)
            : ExtensionIcon(symbol: "circle", tint: "gray", style: .glyph)

        return ExtensionListItem(
            id: reminder.id,
            title: title,
            subtitle: reminder.notes.flatMap(oneLine),
            icon: icon,
            accessories: accessories(
                for: reminder,
                isSingleList: isSingleList,
                isOverdue: isOverdue,
                dates: dates,
                showExactTime: showExactTime
            ),
            section: sectionTitle(for: reminder, filter: filter, dates: dates),
            actions: actions(for: reminder, title: title, lists: lists)
        )
    }

    static func accessories(
        for reminder: Reminder,
        isSingleList: Bool,
        isOverdue: Bool,
        dates: ReminderDates,
        showExactTime: Bool
    ) -> [ExtensionListAccessory] {
        var items = [ExtensionListAccessory]()

        if reminder.isCompleted, let completionDate = reminder.completionDate {
            items.append(ExtensionListAccessory(
                text: dates.completionAccessoryLabel(for: completionDate),
                symbol: "checkmark.circle",
                tint: "green",
                help: localized("Completed \(dates.detailTimestampLabel(for: completionDate))")
            ))
        } else if let due = reminder.dueDate {
            let label = dates.accessoryLabel(for: due, showExactTime: showExactTime)
            let help = reminder.recurrence.map {
                "\(dates.detailLabel(for: due)) · \($0.localizedSummary)"
            } ?? dates.detailLabel(for: due)
            items.append(ExtensionListAccessory(
                text: label,
                symbol: "calendar",
                tint: isOverdue ? "red" : nil,
                help: help
            ))
        }

        if let recurrence = reminder.recurrence {
            items.append(ExtensionListAccessory(
                symbol: "repeat",
                help: recurrence.localizedSummary
            ))
        }

        if let location = reminder.location {
            items.append(ExtensionListAccessory(
                text: location.title,
                symbol: "mappin.and.ellipse",
                help: location.localizedSummary
            ))
        }

        if let badge = reminder.priority.badgeText {
            items.append(ExtensionListAccessory(
                text: badge,
                tint: reminder.priority.tint,
                help: localized("Priority: \(reminder.priority.localizedName)")
            ))
        }

        if let firstTag = reminder.tags.first {
            let allTags = reminder.tags.map { "#\($0)" }.joined(separator: " ")
            items.append(ExtensionListAccessory(
                text: "#\(firstTag)",
                help: allTags
            ))
        }

        if !isSingleList, !reminder.listTitle.isEmpty {
            items.append(ExtensionListAccessory(
                text: reminder.listTitle
            ))
        }

        return items
    }

    static func sectionTitle(
        for reminder: Reminder,
        filter: ReminderFilter,
        dates: ReminderDates
    ) -> String? {
        switch filter {
        case .overdue, .completed:
            return nil
        case .today:
            guard let due = reminder.dueDate else { return localized("Today") }
            return due.isOverdue(now: dates.now, calendar: dates.calendar)
                ? localized("Overdue")
                : localized("Today")
        case .scheduled:
            guard let due = reminder.dueDate else { return localized("Later") }
            if due.isOverdue(now: dates.now, calendar: dates.calendar) { return localized("Overdue") }
            if due.isToday(now: dates.now, calendar: dates.calendar) { return localized("Today") }
            if due.isTomorrow(now: dates.now, calendar: dates.calendar) { return localized("Tomorrow") }
            if due.isWithinNextSevenDays(now: dates.now, calendar: dates.calendar) { return localized("Upcoming") }
            return localized("Later")
        case .all, .list:
            guard let due = reminder.dueDate else { return localized("No Due Date") }
            if due.isOverdue(now: dates.now, calendar: dates.calendar) { return localized("Overdue") }
            if due.isToday(now: dates.now, calendar: dates.calendar) { return localized("Today") }
            return localized("Scheduled")
        }
    }

    static func actions(
        for reminder: Reminder,
        title: String,
        lists: [ReminderList]
    ) -> [ExtensionAction] {
        var result = [ExtensionAction]()

        // 1. Primary (Return): Complete / Mark as Incomplete
        if reminder.isCompleted {
            result.append(ExtensionAction(
                id: ActionID.uncomplete,
                title: localized("Mark as Incomplete"),
                symbol: "circle"
            ))
        } else {
            result.append(ExtensionAction(
                id: ActionID.complete,
                title: localized("Complete Reminder"),
                symbol: "checkmark.circle"
            ))
        }

        // 2. Open in Reminders (handled directly by Prism so Reminders comes to the foreground)
        if let openURL = reminder.openURL {
            result.append(ExtensionAction(
                id: ActionID.open,
                title: localized("Open in Reminders"),
                symbol: "arrow.up.forward.app",
                kind: .open(url: openURL),
                shortcut: ExtensionShortcut("cmd+shift+o")
            ))
        }

        // 3. Set Due Date submenu
        var dueActions = [
            ExtensionAction(id: ActionID.dueToday, title: localized("Today"), symbol: "sun.max"),
            ExtensionAction(id: ActionID.dueTomorrow, title: localized("Tomorrow"), symbol: "sunrise"),
            ExtensionAction(id: ActionID.dueWeekend, title: localized("This Weekend"), symbol: "calendar"),
            ExtensionAction(id: ActionID.dueNextWeek, title: localized("Next Week"), symbol: "calendar.badge.plus"),
            ExtensionAction(id: ActionID.dueInOneHour, title: localized("In 1 Hour"), symbol: "clock"),
        ]
        if reminder.dueDate != nil {
            dueActions.append(ExtensionAction(
                id: ActionID.dueClear,
                title: localized("Remove Due Date"),
                symbol: "calendar.badge.minus"
            ))
        }
        result.append(ExtensionAction(
            id: ActionID.dueMenu,
            title: localized("Set Due Date…"),
            symbol: "calendar",
            shortcut: ExtensionShortcut("cmd+shift+d"),
            actions: dueActions
        ))

        // 4. Set Priority submenu
        let priorityActions = [
            ExtensionAction(id: ActionID.priorityHigh, title: localized("High (!!!)"), symbol: "exclamationmark.3"),
            ExtensionAction(id: ActionID.priorityMedium, title: localized("Medium (!!)"), symbol: "exclamationmark.2"),
            ExtensionAction(id: ActionID.priorityLow, title: localized("Low (!)"), symbol: "exclamationmark"),
            ExtensionAction(id: ActionID.priorityNone, title: localized("None"), symbol: "minus.circle"),
        ]
        result.append(ExtensionAction(
            id: ActionID.priorityMenu,
            title: localized("Set Priority…"),
            symbol: "exclamationmark.circle",
            actions: priorityActions
        ))

        // 5. Move to List submenu
        let destinationLists = lists.filter { !$0.isReadOnly && $0.id != reminder.listID }
        if !destinationLists.isEmpty {
            let moveActions = destinationLists.map { list in
                ExtensionAction(
                    id: ActionID.movePrefix + list.id,
                    title: list.title,
                    symbol: "list.bullet"
                )
            }
            result.append(ExtensionAction(
                id: ActionID.moveMenu,
                title: localized("Move to List…"),
                symbol: "folder",
                shortcut: ExtensionShortcut("cmd+shift+m"),
                actions: moveActions
            ))
        }

        // 6. Open attached URL(s)
        if reminder.attachedURLs.count == 1, let url = reminder.attachedURLs.first {
            result.append(ExtensionAction(
                id: ActionID.openAttachedURL,
                title: localized("Open Attached Link"),
                symbol: "safari",
                kind: .open(url: url),
                shortcut: ExtensionShortcut("cmd+shift+l")
            ))
        } else if reminder.attachedURLs.count > 1 {
            let linkActions = reminder.attachedURLs.enumerated().map { index, url in
                ExtensionAction(
                    id: "\(ActionID.openAttachedURL)-\(index)",
                    title: url.host() ?? url.absoluteString,
                    symbol: "safari",
                    kind: .open(url: url)
                )
            }
            result.append(ExtensionAction(
                id: ActionID.openAttachedURLMenu,
                title: localized("Open Attached Link…"),
                symbol: "safari",
                shortcut: ExtensionShortcut("cmd+shift+l"),
                actions: linkActions
            ))
        }

        // 7. Copy submenu
        var copyActions = [
            ExtensionAction(
                id: ActionID.copyTitle,
                title: localized("Copy Title"),
                symbol: "doc.on.doc",
                kind: .copy(text: reminder.title),
                shortcut: ExtensionShortcut("cmd+shift+t")
            ),
        ]
        if let notes = reminder.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copyActions.append(ExtensionAction(
                id: ActionID.copyNotes,
                title: localized("Copy Notes"),
                symbol: "note.text",
                kind: .copy(text: notes),
                shortcut: ExtensionShortcut("cmd+shift+n")
            ))
        }
        if let link = reminder.openURL?.absoluteString {
            copyActions.append(ExtensionAction(
                id: ActionID.copyLink,
                title: localized("Copy Reminder Link"),
                symbol: "link",
                kind: .copy(text: link),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ))
        }
        result.append(ExtensionAction(
            id: ActionID.copyMenu,
            title: localized("Copy…"),
            symbol: "doc.on.doc",
            actions: copyActions
        ))

        // 8. Delete Reminder
        result.append(ExtensionAction(
            id: ActionID.delete,
            title: localized("Delete Reminder"),
            symbol: "trash",
            style: .destructive,
            confirmationMessage: localized("Delete “\(title)” from Apple Reminders?")
        ))

        return result
    }

    // MARK: - Create / Quick Add Preview

    static func createItem(
        itemID: String,
        draft: ReminderDraft,
        lists: [ReminderList],
        dates: ReminderDates,
        showExactTime: Bool,
        isQuickAddCommand: Bool
    ) -> ExtensionListItem {
        let subtitle: String = if let notes = draft.notes.flatMap(oneLine) {
            notes
        } else if isQuickAddCommand {
            localized("Press Return to create in Reminders")
        } else {
            localized("No matching reminders — press Return to create in Reminders")
        }

        var accessories = [ExtensionListAccessory]()
        if let due = draft.dueDate {
            accessories.append(ExtensionListAccessory(
                text: dates.accessoryLabel(for: due, showExactTime: showExactTime),
                symbol: "calendar",
                help: dates.detailLabel(for: due)
            ))
        }
        if let badge = draft.priority.badgeText {
            accessories.append(ExtensionListAccessory(
                text: badge,
                tint: draft.priority.tint,
                help: localized("Priority: \(draft.priority.localizedName)")
            ))
        }
        if let firstTag = draft.tags.first {
            let allTags = draft.tags.map { "#\($0)" }.joined(separator: " ")
            accessories.append(ExtensionListAccessory(
                text: "#\(firstTag)",
                help: allTags
            ))
        }
        let targetListTitle = draft.listTitle ?? localized("Default List")
        accessories.append(ExtensionListAccessory(
            text: targetListTitle
        ))

        var actions = [
            ExtensionAction(
                id: ActionID.create,
                title: localized("Create Reminder"),
                symbol: "plus.circle"
            ),
            ExtensionAction(
                id: ActionID.createAndOpen,
                title: localized("Create and Open in Reminders"),
                symbol: "arrow.up.forward.app",
                shortcut: ExtensionShortcut("cmd+shift+o")
            ),
        ]

        let writableLists = lists.filter { !$0.isReadOnly }
        if !writableLists.isEmpty {
            actions.append(ExtensionAction(
                id: ActionID.createInListMenu,
                title: localized("Create in List…"),
                symbol: "folder",
                shortcut: ExtensionShortcut("cmd+shift+m"),
                actions: writableLists.map { list in
                    ExtensionAction(
                        id: ActionID.createInListPrefix + list.id,
                        title: list.title,
                        symbol: "list.bullet"
                    )
                }
            ))
        }

        if isQuickAddCommand {
            actions.append(ExtensionAction(
                id: ActionID.createPriorityMenu,
                title: localized("Create with Priority…"),
                symbol: "exclamationmark.circle",
                actions: [
                    ExtensionAction(id: ActionID.createPriorityHigh, title: localized("High (!!!)"), symbol: "exclamationmark.3"),
                    ExtensionAction(id: ActionID.createPriorityMedium, title: localized("Medium (!!)"), symbol: "exclamationmark.2"),
                    ExtensionAction(id: ActionID.createPriorityLow, title: localized("Low (!)"), symbol: "exclamationmark"),
                    ExtensionAction(id: ActionID.createPriorityNone, title: localized("None"), symbol: "minus.circle"),
                ]
            ))
        }

        return ExtensionListItem(
            id: itemID,
            title: localized("Create “\(draft.title)”"),
            subtitle: subtitle,
            icon: ExtensionIcon(symbol: "plus.circle", tint: "gray", style: .glyph),
            accessories: accessories,
            actions: actions
        )
    }

    // MARK: - Access Prompts

    static var allowAccessItem: ExtensionListItem {
        ExtensionListItem(
            id: AppleReminders.allowAccessItemID,
            title: localized("Allow Access to Your Reminders"),
            subtitle: localized("Press Return to allow Prism to access Apple Reminders"),
            icon: ExtensionIcon(symbol: "lock.open", tint: "gray"),
            actions: [ExtensionAction(
                id: ActionID.allowAccess,
                title: localized("Allow Reminders Access"),
                symbol: "lock.open"
            )]
        )
    }

    static var openPrivacySettingsItem: ExtensionListItem {
        ExtensionListItem(
            id: AppleReminders.privacySettingsItemID,
            title: localized("Reminders Access Is Turned Off"),
            subtitle: localized("Turn on Prism in System Settings → Privacy & Security → Reminders"),
            icon: ExtensionIcon(symbol: "hand.raised", tint: "gray"),
            actions: [ExtensionAction(
                id: ActionID.openPrivacySettings,
                title: localized("Open Privacy Settings"),
                symbol: "hand.raised",
                kind: .open(url: privacySettingsURL)
            )]
        )
    }

    static func oneLine(_ text: String) -> String? {
        let line = QuickAddParser.collapseWhitespace(text)
        return line.isEmpty ? nil : line
    }
}
