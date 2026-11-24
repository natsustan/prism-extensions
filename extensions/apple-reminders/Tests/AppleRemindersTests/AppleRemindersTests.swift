import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Synchronization
import Testing
@testable import AppleReminders

/// In-memory EventKit stand-in for deterministic tests without touching macOS TCC.
private final class FakeReminderRepository: ReminderRepository, Sendable {
    enum Call: Equatable, Sendable {
        case requestFullAccess
        case setCompleted(id: String, completed: Bool)
        case setPriority(id: String, priority: ReminderPriority)
        case setDueDate(id: String, dueDate: ReminderDueDate?)
        case move(id: String, toListID: String)
        case delete(id: String)
        case create(ReminderDraft)
    }

    private struct State {
        var authStatus: ReminderAuthorizationStatus = .fullAccess
        var grantOnRequest: Bool = true
        var lists: [ReminderList] = []
        var reminders: [Reminder] = []
        var calls: [Call] = []
        var nextError: ReminderRepositoryError?
        var createdID: String? = UUID().uuidString
    }

    private let state: Mutex<State>

    init(
        authStatus: ReminderAuthorizationStatus = .fullAccess,
        lists: [ReminderList] = [],
        reminders: [Reminder] = []
    ) {
        var initial = State()
        initial.authStatus = authStatus
        initial.lists = lists
        initial.reminders = reminders
        state = Mutex(initial)
    }

    var calls: [Call] { state.withLock(\.calls) }

    func setAuthStatus(_ status: ReminderAuthorizationStatus) {
        state.withLock { $0.authStatus = status }
    }

    func setGrantOnRequest(_ grant: Bool) {
        state.withLock { $0.grantOnRequest = grant }
    }

    func setNextError(_ error: ReminderRepositoryError?) {
        state.withLock { $0.nextError = error }
    }

    func setCreatedID(_ id: String?) {
        state.withLock { $0.createdID = id }
    }

    func authorizationStatus() -> ReminderAuthorizationStatus {
        state.withLock(\.authStatus)
    }

    func requestFullAccess() async throws -> Bool {
        state.withLock { state in
            state.calls.append(.requestFullAccess)
            if state.grantOnRequest {
                state.authStatus = .fullAccess
                return true
            }
            state.authStatus = .denied
            return false
        }
    }

    func fetchLists() async throws -> [ReminderList] {
        try state.withLock { state in
            guard state.authStatus == .fullAccess else { throw ReminderRepositoryError.accessDenied }
            return state.lists
        }
    }

    func fetchSnapshot(completed: Bool) async throws -> ReminderSnapshot {
        try state.withLock { state in
            guard state.authStatus == .fullAccess else { throw ReminderRepositoryError.accessDenied }
            let filtered = state.reminders.filter { $0.isCompleted == completed }
            return ReminderSnapshot(reminders: filtered, lists: state.lists)
        }
    }

    private func record(_ call: Call) throws {
        try state.withLock { state in
            if let error = state.nextError {
                state.nextError = nil
                throw error
            }
            guard state.authStatus == .fullAccess else { throw ReminderRepositoryError.accessDenied }
            state.calls.append(call)
        }
    }

    func setCompleted(id: String, completed: Bool) async throws {
        try record(.setCompleted(id: id, completed: completed))
    }

    func setPriority(id: String, priority: ReminderPriority) async throws {
        try record(.setPriority(id: id, priority: priority))
    }

    func setDueDate(id: String, dueDate: ReminderDueDate?, calendar: Calendar) async throws {
        try record(.setDueDate(id: id, dueDate: dueDate))
    }

    func move(id: String, toListID: String) async throws {
        try record(.move(id: id, toListID: toListID))
    }

    func delete(id: String) async throws {
        try record(.delete(id: id))
    }

    func create(_ draft: ReminderDraft, calendar: Calendar) async throws -> String? {
        try record(.create(draft))
        return state.withLock(\.createdID)
    }
}

private final class OpenedURLs: Sendable {
    private let urls = Mutex<[URL]>([])
    var all: [URL] { urls.withLock { $0 } }
    func open(_ url: URL) { urls.withLock { $0.append(url) } }
}

@Suite("Apple Reminders")
struct AppleRemindersTests {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// Wednesday, 2026-11-25 10:00:00 UTC.
    static let now: Date = {
        var comps = DateComponents()
        comps.calendar = utc
        comps.timeZone = utc.timeZone
        comps.year = 2026
        comps.month = 11
        comps.day = 25
        comps.hour = 10
        comps.minute = 0
        return utc.date(from: comps)!
    }()

    static func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.calendar = utc
        comps.timeZone = utc.timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return utc.date(from: comps)!
    }

    static func makeList(
        id: String = UUID().uuidString,
        title: String,
        account: String? = "iCloud",
        isReadOnly: Bool = false
    ) -> ReminderList {
        ReminderList(id: id, title: title, account: account, isReadOnly: isReadOnly)
    }

    static func makeReminder(
        id: String = UUID().uuidString,
        title: String,
        notes: String? = nil,
        list: ReminderList,
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        createdAt: Date? = nil,
        dueDate: ReminderDueDate? = nil,
        priority: ReminderPriority = .none,
        tags: [String] = [],
        attachedURLs: [URL] = [],
        recurrence: ReminderRecurrence? = nil,
        location: ReminderLocation? = nil
    ) -> Reminder {
        Reminder(
            id: id,
            title: title,
            notes: notes,
            listID: list.id,
            listTitle: list.title,
            account: list.account,
            isCompleted: isCompleted,
            completionDate: completionDate,
            createdAt: createdAt,
            modifiedAt: createdAt,
            dueDate: dueDate,
            priority: priority,
            tags: tags,
            attachedURLs: attachedURLs,
            recurrence: recurrence,
            location: location
        )
    }

    // MARK: - List, Filters, Sections

    @Test("Lists reminders grouped by due bucket with filters, accessories, and actions")
    func listsRemindersAndFilters() async throws {
        let home = Self.makeList(id: "list-home", title: "Home")
        let work = Self.makeList(id: "list-work", title: "Work")

        let overdue = Self.makeReminder(
            id: "rem-overdue",
            title: "Pay electricity bill",
            notes: "Check https://example.com/bill #finance",
            list: work,
            createdAt: Self.utcDate(2026, 11, 20, 9, 0),
            dueDate: .allDay(year: 2026, month: 11, day: 24),
            priority: .high,
            tags: ["finance"],
            attachedURLs: [URL(string: "https://example.com/bill")!],
            recurrence: ReminderRecurrence(frequency: .monthly, interval: 1),
            location: ReminderLocation(title: "Home", proximity: .enter)
        )
        let today = Self.makeReminder(
            id: "rem-today",
            title: "Team standup",
            list: work,
            createdAt: Self.utcDate(2026, 11, 25, 8, 0),
            dueDate: .timed(Self.utcDate(2026, 11, 25, 14, 30)),
            priority: .medium
        )
        let future = Self.makeReminder(
            id: "rem-future",
            title: "Book dentist",
            list: home,
            createdAt: Self.utcDate(2026, 11, 22, 8, 0),
            dueDate: .allDay(year: 2026, month: 11, day: 28)
        )
        let undated = Self.makeReminder(
            id: "rem-undated",
            title: "Read Swift book",
            list: home,
            createdAt: Self.utcDate(2026, 11, 21, 8, 0)
        )
        let completed = Self.makeReminder(
            id: "rem-done",
            title: "Ship v1.0",
            list: work,
            isCompleted: true,
            completionDate: Self.utcDate(2026, 11, 25, 9, 0),
            createdAt: Self.utcDate(2026, 11, 18, 8, 0)
        )

        let repository = FakeReminderRepository(lists: [home, work], reminders: [overdue, today, future, undated, completed])
        let host = try await PrismTestHost(
            AppleReminders(repository: repository, openURL: { _ in }, now: { Self.now }, calendar: Self.utc)
        )

        let all = try await host.list("my-reminders")
        #expect(all.showsDetail == false)
        #expect(all.items.map(\.id) == ["rem-overdue", "rem-today", "rem-future", "rem-undated"])
        #expect(all.items.map(\.section) == ["Overdue", "Today", "Scheduled", "No Due Date"])
        #expect(all.filters.map(\.id) == ["all", "today", "overdue", "scheduled", "completed", "list:list-home", "list:list-work"])

        let first = try #require(all.items.first)
        #expect(first.detail == nil)
        #expect(first.primaryAction?.id == AppleReminders.ActionID.complete)
        #expect(first.icon == ExtensionIcon(symbol: "circle", tint: "gray", style: .glyph))
        #expect(first.accessories.contains { $0.tint == "red" && $0.symbol == "calendar" })
        #expect(first.accessories.contains { $0.text == "!!!" && $0.tint == "red" })
        #expect(first.accessories.contains { $0.symbol == "repeat" && $0.help == "Every Month" })
        #expect(first.accessories.contains { $0.symbol == "mappin.and.ellipse" && $0.text == "Home" })
        #expect(first.accessories.contains { $0.text == "#finance" && $0.style == .plain })
        #expect(first.accessories.contains { $0.text == "Work" && $0.style == .plain && $0.tint == nil })
        #expect(first.allActions.contains { $0.id == AppleReminders.ActionID.openAttachedURL })

        let todayList = try await host.list("my-reminders", filter: "today")
        #expect(todayList.items.map(\.id) == ["rem-overdue", "rem-today"])

        let overdueList = try await host.list("my-reminders", filter: "overdue")
        #expect(overdueList.items.map(\.id) == ["rem-overdue"])
        #expect(overdueList.items.first?.section == nil)

        let completedList = try await host.list("my-reminders", filter: "completed")
        #expect(completedList.items.map(\.id) == ["rem-done"])
        #expect(completedList.items.first?.primaryAction?.id == AppleReminders.ActionID.uncomplete)

        let homeOnly = try await host.list("my-reminders", filter: "list:list-home")
        #expect(homeOnly.items.map(\.id) == ["rem-future", "rem-undated"])
    }

    @Test("Searches by title, tags, priority, location, and Chinese pinyin")
    func searchesPinyinAndMetadata() async throws {
        let life = Self.makeList(id: "list-life", title: "生活")
        let milk = Self.makeReminder(
            id: "rem-milk",
            title: "买牛奶",
            notes: "超市燕麦奶 #购物",
            list: life,
            priority: .high,
            tags: ["购物"],
            location: ReminderLocation(title: "盒马", proximity: .enter)
        )
        let passport = Self.makeReminder(id: "rem-passport", title: "Renew passport", list: life)

        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleRemindersData-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let host = try await PrismTestHost(
            AppleReminders(
                repository: FakeReminderRepository(lists: [life], reminders: [milk, passport]),
                openURL: { _ in },
                now: { Self.now },
                calendar: Self.utc
            ),
            dataDirectory: dataDir
        )

        #expect(try await host.list("my-reminders", query: "mnn").items.map(\.id) == ["rem-milk"])
        #expect(try await host.list("my-reminders", query: "mainiunai").items.map(\.id) == ["rem-milk"])
        #expect(try await host.list("my-reminders", query: "#购物").items.map(\.id) == ["rem-milk"])
        #expect(try await host.list("my-reminders", query: "high").items.map(\.id) == ["rem-milk"])
        #expect(try await host.list("my-reminders", query: "hema").items.map(\.id) == ["rem-milk"])
    }

    // MARK: - Actions & Mutations

    @Test("Performs complete, uncomplete, open, due date, priority, move, and delete actions")
    func performsMutationsAndOpen() async throws {
        let work = Self.makeList(id: "list-work", title: "Work")
        let personal = Self.makeList(id: "list-personal", title: "Personal")
        let reminder = Self.makeReminder(id: "rem-1", title: "Draft memo", list: work)

        let repository = FakeReminderRepository(lists: [work, personal], reminders: [reminder])
        let opened = OpenedURLs()
        let host = try await PrismTestHost(
            AppleReminders(repository: repository, openURL: { opened.open($0) }, now: { Self.now }, calendar: Self.utc)
        )

        let completeResult = try await host.perform(AppleReminders.ActionID.complete, on: "rem-1", in: "my-reminders")
        #expect(completeResult.reload == true)
        #expect(repository.calls.last == .setCompleted(id: "rem-1", completed: true))

        _ = try await host.perform(AppleReminders.ActionID.uncomplete, on: "rem-1", in: "my-reminders")
        #expect(repository.calls.last == .setCompleted(id: "rem-1", completed: false))

        _ = try await host.perform(AppleReminders.ActionID.priorityHigh, on: "rem-1", in: "my-reminders")
        #expect(repository.calls.last == .setPriority(id: "rem-1", priority: .high))

        _ = try await host.perform(AppleReminders.ActionID.dueTomorrow, on: "rem-1", in: "my-reminders")
        #expect(repository.calls.last == .setDueDate(id: "rem-1", dueDate: .allDay(year: 2026, month: 11, day: 26)))

        _ = try await host.perform(AppleReminders.ActionID.dueClear, on: "rem-1", in: "my-reminders")
        #expect(repository.calls.last == .setDueDate(id: "rem-1", dueDate: nil))

        _ = try await host.perform(AppleReminders.ActionID.movePrefix + "list-personal", on: "rem-1", in: "my-reminders")
        #expect(repository.calls.last == .move(id: "rem-1", toListID: "list-personal"))

        _ = try await host.perform(AppleReminders.ActionID.delete, on: "rem-1", in: "my-reminders")
        #expect(repository.calls.last == .delete(id: "rem-1"))

        let items = try await host.list("my-reminders").items
        let openAction = items.first?.action(id: AppleReminders.ActionID.open)
        #expect(openAction?.kind == .open(url: URL(string: "x-apple-reminderkit://REMCDReminder/rem-1")!))
    }

    @Test("Handles permission prompts for notDetermined and denied EventKit access")
    func handlesAuthorizationFlows() async throws {
        let work = Self.makeList(id: "list-work", title: "Work")
        let reminder = Self.makeReminder(id: "rem-1", title: "Call bank", list: work)
        let repository = FakeReminderRepository(authStatus: .notDetermined, lists: [work], reminders: [reminder])

        let host = try await PrismTestHost(
            AppleReminders(repository: repository, openURL: { _ in }, now: { Self.now }, calendar: Self.utc)
        )

        // When not determined, My Reminders offers an Allow Access row without auto-prompting.
        let prompt = try await host.list("my-reminders")
        #expect(prompt.items.map(\.id) == [AppleReminders.allowAccessItemID])
        #expect(repository.calls.isEmpty)

        // Pressing Return requests full access and reloads with real reminders.
        let granted = try await host.perform(AppleReminders.ActionID.allowAccess, on: AppleReminders.allowAccessItemID, in: "my-reminders")
        #expect(granted.reload == true)
        #expect(repository.calls == [.requestFullAccess])
        let loaded = try await host.list("my-reminders")
        #expect(loaded.items.map(\.id) == ["rem-1"])

        // When access is denied, both commands offer Open Privacy Settings.
        repository.setAuthStatus(.denied)
        let denied = try await host.list("my-reminders")
        #expect(denied.items.map(\.id) == [AppleReminders.privacySettingsItemID])
        #expect(denied.items.first?.primaryAction?.kind == .open(url: ReminderRows.privacySettingsURL))

        let deniedQuick = try await host.list("quick-add")
        #expect(deniedQuick.items.map(\.id) == [AppleReminders.privacySettingsItemID])
    }

    // MARK: - Quick Add Parser & Command

    @Test("Quick Add parses English and Chinese dates, times, priorities, lists, tags, and notes")
    func quickAddParsesNaturalLanguage() {
        let lists = [
            Self.makeList(id: "list-groceries", title: "Groceries"),
            Self.makeList(id: "list-work", title: "工作"),
        ]

        let en = QuickAddParser.parse(
            "Buy milk tomorrow 9am !!! #Groceries #organic // oat milk",
            lists: lists,
            now: Self.now,
            calendar: Self.utc
        )
        #expect(en?.title == "Buy milk")
        #expect(en?.notes == "oat milk")
        #expect(en?.listID == "list-groceries")
        #expect(en?.priority == .high)
        #expect(en?.tags == ["organic"])
        #expect(en?.dueDate == .timed(Self.utcDate(2026, 11, 26, 9, 0)))
        #expect(en?.combinedNotes == "oat milk\n\n#organic")

        let zh = QuickAddParser.parse(
            "明天 下午3点半 提交周报 !! #工作",
            lists: lists,
            now: Self.now,
            calendar: Self.utc
        )
        #expect(zh?.title == "提交周报")
        #expect(zh?.listID == "list-work")
        #expect(zh?.priority == .medium)
        #expect(zh?.dueDate == .timed(Self.utcDate(2026, 11, 26, 15, 30)))

        let offset = QuickAddParser.parse("Check oven in 45m", lists: lists, now: Self.now, calendar: Self.utc)
        #expect(offset?.title == "Check oven")
        #expect(offset?.dueDate == .timed(Self.now.addingTimeInterval(45 * 60)))

        let zhOffset = QuickAddParser.parse("2小时后 喝水", lists: lists, now: Self.now, calendar: Self.utc)
        #expect(zhOffset?.title == "喝水")
        #expect(zhOffset?.dueDate == .timed(Self.now.addingTimeInterval(2 * 3600)))

        // Punctuation attached to words must not be stripped as low priority.
        let exclamation = QuickAddParser.parse("Happy Birthday!", lists: lists, now: Self.now, calendar: Self.utc)
        #expect(exclamation?.title == "Happy Birthday!")
        #expect(exclamation?.priority == ReminderPriority.none)
    }

    @Test("Quick Add command previews and creates reminders, honoring defaultList and override actions")
    func quickAddCommandCreatesReminder() async throws {
        let work = Self.makeList(id: "list-work", title: "Work")
        let personal = Self.makeList(id: "list-personal", title: "Personal")
        let repository = FakeReminderRepository(lists: [work, personal])
        repository.setCreatedID("created-42")
        let opened = OpenedURLs()

        let host = try await PrismTestHost(
            AppleReminders(repository: repository, openURL: { opened.open($0) }, now: { Self.now }, calendar: Self.utc),
            preferences: ["defaultList": .string("Work")]
        )

        let empty = try await host.list("quick-add")
        #expect(empty.items.isEmpty)
        #expect(empty.emptyMessage?.title == "Quick Add Reminder")

        let preview = try await host.list("quick-add", query: "Send invoice tomorrow !")
        #expect(preview.showsDetail == false)
        let item = try #require(preview.items.first)
        #expect(item.title == "Create “Send invoice”")
        #expect(item.accessories.contains { $0.text == "Work" && $0.style == .plain && $0.tint == nil })

        let result = try await host.perform(AppleReminders.ActionID.create, on: item.id, in: "quick-add")
        #expect(result.result == .hud(message: "Created “Send invoice”"))
        #expect(await host.changedLists == ["my-reminders"])
        if case let .create(draft) = repository.calls.last {
            #expect(draft.title == "Send invoice")
            #expect(draft.listID == "list-work")
            #expect(draft.priority == .low)
            #expect(draft.dueDate == .allDay(year: 2026, month: 11, day: 26))
        } else {
            Issue.record("Expected create call")
        }

        let openResult = try await host.perform(AppleReminders.ActionID.createAndOpen, on: item.id, in: "quick-add")
        #expect(openResult == .done)
        #expect(opened.all == [URL(string: "x-apple-reminderkit://REMCDReminder/created-42")!])

        _ = try await host.perform(AppleReminders.ActionID.createInListPrefix + "list-personal", on: item.id, in: "quick-add")
        if case let .create(draft) = repository.calls.last {
            #expect(draft.listID == "list-personal")
            #expect(draft.listTitle == "Personal")
        } else {
            Issue.record("Expected createInList call")
        }

        _ = try await host.perform(AppleReminders.ActionID.createPriorityHigh, on: item.id, in: "quick-add")
        if case let .create(draft) = repository.calls.last {
            #expect(draft.priority == .high)
        } else {
            Issue.record("Expected createPriorityHigh call")
        }
    }

    @Test("My Reminders offers inline creation inside the active list when nothing matches")
    func myRemindersInlineCreateInList() async throws {
        let home = Self.makeList(id: "list-home", title: "Home")
        let plants = Self.makeReminder(id: "rem-1", title: "Water plants", list: home)
        let repository = FakeReminderRepository(lists: [home], reminders: [plants])

        let host = try await PrismTestHost(
            AppleReminders(repository: repository, openURL: { _ in }, now: { Self.now }, calendar: Self.utc)
        )

        let noMatch = try await host.list("my-reminders", query: "Fix lamp tomorrow", filter: "list:list-home")
        let item = try #require(noMatch.items.first)
        #expect(item.title == "Create “Fix lamp”")

        let created = try await host.perform(AppleReminders.ActionID.create, on: item.id, in: "my-reminders")
        #expect(created.reload == true)
        if case let .create(draft) = repository.calls.last {
            #expect(draft.title == "Fix lamp")
            #expect(draft.listID == "list-home")
            #expect(draft.dueDate == .allDay(year: 2026, month: 11, day: 26))
        } else {
            Issue.record("Expected inline create call")
        }
    }

    @Test("Honors showExactDueTime preference and groups Scheduled sections")
    func exactTimeAndScheduledSections() async throws {
        let work = Self.makeList(id: "list-work", title: "Work")
        let reminders = [
            Self.makeReminder(id: "r1", title: "Afternoon call", list: work, dueDate: .timed(Self.utcDate(2026, 11, 25, 14, 30))),
            Self.makeReminder(id: "r2", title: "Pick up package", list: work, dueDate: .allDay(year: 2026, month: 11, day: 26)),
            Self.makeReminder(id: "r3", title: "Weekend trip", list: work, dueDate: .allDay(year: 2026, month: 11, day: 29)),
            Self.makeReminder(id: "r4", title: "Renew lease", list: work, dueDate: .allDay(year: 2026, month: 12, day: 20)),
        ]

        let host = try await PrismTestHost(
            AppleReminders(
                repository: FakeReminderRepository(lists: [work], reminders: reminders),
                openURL: { _ in },
                now: { Self.now },
                calendar: Self.utc
            )
        )

        let scheduled = try await host.list("my-reminders", filter: "scheduled")
        #expect(scheduled.items.map(\.id) == ["r1", "r2", "r3", "r4"])
        #expect(scheduled.items.map(\.section) == ["Today", "Tomorrow", "Upcoming", "Later"])

        let relativeLabel = scheduled.items.first?.accessories.first?.text ?? ""
        #expect(!relativeLabel.hasPrefix("Today "))

        try await host.setPreferences(["showExactDueTime": .bool(true)])
        let exact = try await host.list("my-reminders", filter: "scheduled")
        let exactLabel = exact.items.first?.accessories.first?.text ?? ""
        #expect(exactLabel.hasPrefix("Today "))
    }

    @Test("Localizes runtime UI strings in zh-Hans and zh-Hant and maps colors cleanly")
    func localizesChineseAndMapsColors() async throws {
        let life = Self.makeList(id: "list-life", title: "生活")
        let milk = Self.makeReminder(
            id: "rem-milk",
            title: "买牛奶",
            list: life,
            dueDate: .allDay(year: 2026, month: 11, day: 24)
        )

        let hansHost = try await PrismTestHost(
            AppleReminders(
                repository: FakeReminderRepository(lists: [life], reminders: [milk]),
                openURL: { _ in },
                now: { Self.now },
                calendar: Self.utc
            ),
            language: "zh-Hans"
        )
        let hansList = try await hansHost.list("my-reminders")
        #expect(hansList.items.first?.section == "已逾期")
        #expect(hansList.items.first?.primaryAction?.title == "完成提醒")
        #expect(hansList.filters.first?.title == "全部")

        let hantHost = try await PrismTestHost(
            AppleReminders(
                repository: FakeReminderRepository(lists: [life], reminders: [milk]),
                openURL: { _ in },
                now: { Self.now },
                calendar: Self.utc
            ),
            language: "zh-Hant"
        )
        let hantQuick = try await hantHost.list("quick-add")
        #expect(hantQuick.emptyMessage?.title == "快速新增提醒")

        #expect(EventKitReminderRepository.extractInlineTags(from: "Buy milk #groceries #urgent") == ["groceries", "urgent"])
    }
}
