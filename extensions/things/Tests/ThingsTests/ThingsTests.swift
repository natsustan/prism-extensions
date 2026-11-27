import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Synchronization
import Testing
@testable import Things

// MARK: - Fake Repository & URL Opener

final class FakeThingsRepository: ThingsRepository {
    struct State {
        var installed = true
        var authStatus: ThingsAuthorizationStatus = .authorized
        var requestedAuthResult: ThingsAuthorizationStatus = .authorized
        var activeError: ThingsRepositoryError?
        var logbookError: ThingsRepositoryError?
        var mutationError: ThingsRepositoryError?
        var activeTodos: [ThingsTodo] = []
        var logbookTodos: [ThingsTodo] = []
        var containers: [ThingsContainer] = []
        var recordedCalls: [String] = []
    }

    private let state = Mutex(State())

    init(
        installed: Bool = true,
        authStatus: ThingsAuthorizationStatus = .authorized,
        activeTodos: [ThingsTodo] = [],
        logbookTodos: [ThingsTodo] = [],
        containers: [ThingsContainer] = []
    ) {
        state.withLock {
            $0.installed = installed
            $0.authStatus = authStatus
            $0.activeTodos = activeTodos
            $0.logbookTodos = logbookTodos
            $0.containers = containers
        }
    }

    var calls: [String] { state.withLock(\.recordedCalls) }

    func setActiveError(_ error: ThingsRepositoryError?) {
        state.withLock { $0.activeError = error }
    }

    func setMutationError(_ error: ThingsRepositoryError?) {
        state.withLock { $0.mutationError = error }
    }

    func isInstalled() -> Bool {
        state.withLock(\.installed)
    }

    func authorizationStatus() -> ThingsAuthorizationStatus {
        state.withLock(\.authStatus)
    }

    func requestAutomationAccess() async -> ThingsAuthorizationStatus {
        state.withLock { state in
            state.recordedCalls.append("requestAutomationAccess")
            state.authStatus = state.requestedAuthResult
            return state.authStatus
        }
    }

    func fetchActive() async throws -> ThingsSnapshot {
        try state.withLock { state in
            state.recordedCalls.append("fetchActive")
            if let error = state.activeError { throw error }
            return ThingsSnapshot(todos: state.activeTodos, containers: state.containers)
        }
    }

    func fetchLogbook(limit: Int) async throws -> ThingsSnapshot {
        try state.withLock { state in
            state.recordedCalls.append("fetchLogbook:\(limit)")
            if let error = state.logbookError { throw error }
            return ThingsSnapshot(todos: Array(state.logbookTodos.prefix(limit)), containers: state.containers)
        }
    }

    func fetchContainers() async throws -> [ThingsContainer] {
        try state.withLock { state in
            state.recordedCalls.append("fetchContainers")
            if let error = state.activeError { throw error }
            return state.containers
        }
    }

    func setStatus(id: String, status: ThingsStatus) async throws {
        try state.withLock { state in
            if let error = state.mutationError { throw error }
            state.recordedCalls.append("setStatus:\(id):\(status.rawValue)")
            if let idx = state.activeTodos.firstIndex(where: { $0.id == id }) {
                let todo = state.activeTodos.remove(at: idx)
                if status != .open {
                    state.logbookTodos.insert(
                        ThingsTodo(
                            id: todo.id,
                            title: todo.title,
                            notes: todo.notes,
                            status: status,
                            bucket: .logbook,
                            dueDate: todo.dueDate,
                            activationDate: todo.activationDate,
                            completionDate: status == .completed ? Date(timeIntervalSince1970: 1_760_000_000) : nil,
                            cancellationDate: status == .canceled ? Date(timeIntervalSince1970: 1_760_000_000) : nil,
                            projectID: todo.projectID,
                            projectTitle: todo.projectTitle,
                            areaID: todo.areaID,
                            areaTitle: todo.areaTitle,
                            tags: todo.tags
                        ),
                        at: 0
                    )
                }
            } else if let idx = state.logbookTodos.firstIndex(where: { $0.id == id }), status == .open {
                let todo = state.logbookTodos.remove(at: idx)
                state.activeTodos.insert(
                    ThingsTodo(
                        id: todo.id,
                        title: todo.title,
                        notes: todo.notes,
                        status: .open,
                        bucket: .today,
                        dueDate: todo.dueDate,
                        activationDate: todo.activationDate,
                        completionDate: nil,
                        cancellationDate: nil,
                        projectID: todo.projectID,
                        projectTitle: todo.projectTitle,
                        areaID: todo.areaID,
                        areaTitle: todo.areaTitle,
                        tags: todo.tags
                    ),
                    at: 0
                )
            }
        }
    }

    func move(id: String, to target: ThingsMoveTarget) async throws {
        try state.withLock { state in
            if let error = state.mutationError { throw error }
            state.recordedCalls.append("move:\(target.scriptKind):\(id):\(target.targetID)")
        }
    }

    func schedule(id: String, for date: ThingsDate) async throws {
        try state.withLock { state in
            if let error = state.mutationError { throw error }
            state.recordedCalls.append("schedule:\(id):\(date.isoString)")
        }
    }

    func setDeadline(id: String, deadline: ThingsDate?) async throws {
        try state.withLock { state in
            if let error = state.mutationError { throw error }
            state.recordedCalls.append("deadline:\(id):\(deadline?.isoString ?? "nil")")
        }
    }

    func delete(id: String) async throws {
        try state.withLock { state in
            if let error = state.mutationError { throw error }
            state.recordedCalls.append("delete:\(id)")
            state.activeTodos.removeAll { $0.id == id }
        }
    }
}

final class OpenedURLRecorder: Sendable {
    private let entries = Mutex<[(URL, Bool)]>([])

    var opened: [(URL, Bool)] { entries.withLock { $0 } }

    func record(_ url: URL, activate: Bool) {
        entries.withLock { $0.append((url, activate)) }
    }
}

// MARK: - Fixtures

private func makeUTCCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

/// Fixed Wednesday, 2026-04-08 10:00:00 UTC.
private let fixedNow = Date(timeIntervalSince1970: 1_775_642_400)

private func sampleContainers() -> [ThingsContainer] {
    [
        ThingsContainer(id: "area-work", title: "Work", kind: .area, areaID: nil, areaTitle: nil),
        ThingsContainer(id: "proj-launch", title: "Launch", kind: .project, areaID: "area-work", areaTitle: "Work"),
        ThingsContainer(id: "proj-errands", title: "Errands", kind: .project, areaID: nil, areaTitle: nil),
    ]
}

private func sampleTodos() -> [ThingsTodo] {
    [
        ThingsTodo(
            id: "todo-1",
            title: "Ship Things extension",
            notes: "Review PR at https://github.com/prismformac/prism-extensions",
            status: .open,
            bucket: .today,
            dueDate: ThingsDate(year: 2026, month: 4, day: 8),
            activationDate: ThingsDate(year: 2026, month: 4, day: 8),
            completionDate: nil,
            cancellationDate: nil,
            projectID: "proj-launch",
            projectTitle: "Launch",
            areaID: "area-work",
            areaTitle: "Work",
            tags: ["prism", "dev"]
        ),
        ThingsTodo(
            id: "todo-2",
            title: "买牛奶",
            notes: "燕麦奶",
            status: .open,
            bucket: .inbox,
            dueDate: ThingsDate(year: 2026, month: 4, day: 7), // Overdue
            activationDate: nil,
            completionDate: nil,
            cancellationDate: nil,
            projectID: nil,
            projectTitle: nil,
            areaID: nil,
            areaTitle: nil,
            tags: ["home"]
        ),
        ThingsTodo(
            id: "todo-3",
            title: "Plan summer trip",
            notes: "",
            status: .open,
            bucket: .someday,
            dueDate: nil,
            activationDate: nil,
            completionDate: nil,
            cancellationDate: nil,
            projectID: nil,
            projectTitle: nil,
            areaID: nil,
            areaTitle: nil,
            tags: []
        ),
    ]
}

private func makeHost(
    repo: FakeThingsRepository,
    urlRecorder: OpenedURLRecorder = OpenedURLRecorder(),
    language: String? = nil
) async throws -> PrismTestHost {
    let ext = Things(
        repository: repo,
        openURL: { url, activate in urlRecorder.record(url, activate: activate) },
        now: { fixedNow },
        calendar: makeUTCCalendar()
    )
    return try await PrismTestHost(ext, extensionID: "prism.things", language: language)
}

// MARK: - Tests

@Suite("Things")
struct ThingsTests {
    @Test("Shows not-installed row when Things 3 is missing")
    func notInstalled() async throws {
        let repo = FakeThingsRepository(installed: false)
        let host = try await makeHost(repo: repo)

        let list = try await host.list(Things.CommandID.myTodos)
        #expect(list.items.count == 1)
        #expect(list.items[0].id == Things.appNotInstalledItemID)
        #expect(list.items[0].title == "Things 3 Is Not Installed")
    }

    @Test("Shows not-running row and launches Things when Things 3 is closed")
    func notRunning() async throws {
        let repo = FakeThingsRepository(authStatus: .notRunning)
        let recorder = OpenedURLRecorder()
        let host = try await makeHost(repo: repo, urlRecorder: recorder)

        let list = try await host.list(Things.CommandID.myTodos)
        #expect(list.items.count == 1)
        #expect(list.items[0].id == Things.appNotRunningItemID)
        #expect(list.items[0].actions.first?.id == Things.ActionID.launchThings)

        let res = try await host.perform(Things.ActionID.launchThings, on: Things.appNotRunningItemID, in: Things.CommandID.myTodos)
        #expect(res.reload == true)
        #expect(recorder.opened.first?.0.absoluteString == "things:///show?id=today")
    }

    @Test("Prompts for Automation access when not yet determined")
    func notDeterminedAutomation() async throws {
        let repo = FakeThingsRepository(authStatus: .notDetermined, activeTodos: sampleTodos(), containers: sampleContainers())
        let host = try await makeHost(repo: repo)

        let prompt = try await host.list(Things.CommandID.myTodos)
        #expect(prompt.items.count == 1)
        #expect(prompt.items[0].id == Things.allowAccessItemID)

        let grant = try await host.perform(Things.ActionID.allowAccess, on: Things.allowAccessItemID, in: Things.CommandID.myTodos)
        #expect(grant.reload == true)
        #expect(repo.calls.contains("requestAutomationAccess"))

        let list = try await host.list(Things.CommandID.myTodos)
        #expect(list.items.count == 3)
    }

    @Test("Shows automation settings row when Apple Events permission is denied")
    func automationDenied() async throws {
        let repo = FakeThingsRepository()
        repo.setActiveError(.automationDenied)
        let host = try await makeHost(repo: repo)

        let list = try await host.list(Things.CommandID.myTodos)
        #expect(list.items.count == 1)
        #expect(list.items[0].id == Things.automationSettingsItemID)
        #expect(list.items[0].actions.first?.kind == .open(url: ThingsURLs.automationSettingsURL))
    }

    @Test("Lists active to-dos grouped by bucket with filters and actions")
    func listsActiveTodos() async throws {
        let repo = FakeThingsRepository(activeTodos: sampleTodos(), containers: sampleContainers())
        let host = try await makeHost(repo: repo)

        let list = try await host.list(Things.CommandID.myTodos)
        #expect(list.items.map(\.id) == ["todo-1", "todo-2", "todo-3"])
        #expect(list.items[0].section == "Today")
        #expect(list.items[1].section == "Inbox")
        #expect(list.items[2].section == "Someday")

        // Return action is Complete To-Do
        #expect(list.items[0].actions.first?.id == Things.ActionID.complete)
        // Attached URL from notes is surfaced as Open Link
        #expect(list.items[0].actions.contains { $0.id == Things.ActionID.openAttachedURL })

        // Filters include built-in views plus projects and areas
        let filterIDs = list.filters.map(\.id)
        #expect(filterIDs.contains(ThingsFilter.todayID))
        #expect(filterIDs.contains(ThingsFilter.logbookID))
        #expect(filterIDs.contains(ThingsFilter.projectPrefix + "proj-launch"))
        #expect(filterIDs.contains(ThingsFilter.areaPrefix + "area-work"))
    }

    @Test("Searches by title, tags, project, and Chinese pinyin")
    func searchAndPinyin() async throws {
        let repo = FakeThingsRepository(activeTodos: sampleTodos(), containers: sampleContainers())
        let host = try await makeHost(repo: repo)

        let pinyinFull = try await host.list(Things.CommandID.myTodos, query: "mainiunai")
        #expect(pinyinFull.items.map(\.id) == ["todo-2"])

        let pinyinInitials = try await host.list(Things.CommandID.myTodos, query: "mnn")
        #expect(pinyinInitials.items.map(\.id) == ["todo-2"])

        let byTag = try await host.list(Things.CommandID.myTodos, query: "#prism")
        #expect(byTag.items.map(\.id) == ["todo-1"])

        let byProject = try await host.list(Things.CommandID.myTodos, query: "launch")
        #expect(byProject.items.map(\.id) == ["todo-1"])
    }

    @Test("Filters by Today, Project, and Logbook")
    func filters() async throws {
        let completedTodo = ThingsTodo(
            id: "done-1",
            title: "File taxes",
            notes: "",
            status: .completed,
            bucket: .logbook,
            dueDate: nil,
            activationDate: nil,
            completionDate: fixedNow,
            cancellationDate: nil,
            projectID: nil,
            projectTitle: nil,
            areaID: nil,
            areaTitle: nil,
            tags: []
        )
        let repo = FakeThingsRepository(
            activeTodos: sampleTodos(),
            logbookTodos: [completedTodo],
            containers: sampleContainers()
        )
        let host = try await makeHost(repo: repo)

        let today = try await host.list(Things.CommandID.myTodos, filter: ThingsFilter.todayID)
        #expect(today.items.map(\.id) == ["todo-1"])

        let project = try await host.list(Things.CommandID.myTodos, filter: ThingsFilter.projectPrefix + "proj-launch")
        #expect(project.items.map(\.id) == ["todo-1"])

        let logbook = try await host.list(Things.CommandID.myTodos, filter: ThingsFilter.logbookID)
        #expect(logbook.items.map(\.id) == ["done-1"])
        #expect(logbook.items[0].actions.first?.id == Things.ActionID.reopen)
    }

    @Test("Completes, reopens, cancels, schedules, sets deadline, moves, and trashes to-dos")
    func mutations() async throws {
        let repo = FakeThingsRepository(activeTodos: sampleTodos(), containers: sampleContainers())
        let host = try await makeHost(repo: repo)

        let completeRes = try await host.perform(Things.ActionID.complete, on: "todo-1", in: Things.CommandID.myTodos)
        #expect(completeRes.reload == true)
        #expect(repo.calls.contains("setStatus:todo-1:completed"))

        let reopenRes = try await host.perform(Things.ActionID.reopen, on: "todo-1", in: Things.CommandID.myTodos)
        #expect(reopenRes.reload == true)
        #expect(repo.calls.contains("setStatus:todo-1:open"))

        _ = try await host.perform(Things.ActionID.cancel, on: "todo-2", in: Things.CommandID.myTodos)
        #expect(repo.calls.contains("setStatus:todo-2:canceled"))

        _ = try await host.perform(Things.ActionID.scheduleTomorrow, on: "todo-3", in: Things.CommandID.myTodos)
        #expect(repo.calls.contains("schedule:todo-3:2026-04-09"))

        _ = try await host.perform(Things.ActionID.deadlineNextWeek, on: "todo-3", in: Things.CommandID.myTodos)
        #expect(repo.calls.contains("deadline:todo-3:2026-04-13"))

        _ = try await host.perform(Things.ActionID.deadlineClear, on: "todo-3", in: Things.CommandID.myTodos)
        #expect(repo.calls.contains("deadline:todo-3:nil"))

        _ = try await host.perform(Things.ActionID.moveProjectPrefix + "proj-launch", on: "todo-3", in: Things.CommandID.myTodos)
        #expect(repo.calls.contains("move:project:todo-3:proj-launch"))

        _ = try await host.perform(Things.ActionID.delete, on: "todo-3", in: Things.CommandID.myTodos)
        #expect(repo.calls.contains("delete:todo-3"))
    }

    @Test("Quick Add parses English and Chinese syntax and opens things:///add URL")
    func quickAdd() async throws {
        let repo = FakeThingsRepository(containers: sampleContainers())
        let recorder = OpenedURLRecorder()
        let host = try await makeHost(repo: repo, urlRecorder: recorder)

        let empty = try await host.list(Things.CommandID.quickAdd, query: "")
        #expect(empty.items.isEmpty)
        #expect(empty.emptyMessage?.title == "Quick Add To-Do")

        let query = "Buy milk tomorrow 9am due:friday @Errands #home // Oat milk"
        let preview = try await host.list(Things.CommandID.quickAdd, query: query)
        #expect(preview.items.count == 1)
        #expect(preview.items[0].title == "Add “Buy milk”")
        #expect(preview.items[0].subtitle == "Oat milk")

        let result = try await host.perform(Things.ActionID.create, on: preview.items[0].id, in: Things.CommandID.quickAdd)
        #expect(result.result == .hud(message: "Added “Buy milk”"))
        #expect(await host.changedLists.contains(Things.CommandID.myTodos))

        let opened = try #require(recorder.opened.first)
        #expect(opened.1 == false) // background add
        let components = try #require(URLComponents(url: opened.0, resolvingAgainstBaseURL: false))
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(params["title"] == "Buy milk")
        #expect(params["notes"] == "Oat milk")
        #expect(params["when"] == "2026-04-09@09:00")
        #expect(params["deadline"] == "2026-04-10")
        #expect(params["list-id"] == "proj-errands")
        #expect(params["tags"] == "home")
        #expect(params["reveal"] == "false")
    }

    @Test("Quick Add parses Chinese schedules, times, and deadlines")
    func quickAddChinese() {
        let draft = QuickAddParser.parse(
            "明天 下午3点半 交报告 截止:周五 @Launch #工作 // 发给团队",
            containers: sampleContainers(),
            now: fixedNow,
            calendar: makeUTCCalendar()
        )
        #expect(draft?.title == "交报告")
        #expect(draft?.notes == "发给团队")
        #expect(draft?.when == .dateTime(ThingsDate(year: 2026, month: 4, day: 9), hour: 15, minute: 30))
        #expect(draft?.deadline == ThingsDate(year: 2026, month: 4, day: 10))
        #expect(draft?.listID == "proj-launch")
        #expect(draft?.tags == ["工作"])
    }

    @Test("Quick Add preserves URLs in title and ignores invalid calendar dates")
    func quickAddEdgeCases() {
        let urlDraft = QuickAddParser.parse(
            "Read https://culturedcode.com/things/ // Check release notes",
            containers: [],
            now: fixedNow,
            calendar: makeUTCCalendar()
        )
        #expect(urlDraft?.title == "Read https://culturedcode.com/things/")
        #expect(urlDraft?.notes == "Check release notes")

        let invalidDateDraft = QuickAddParser.parse(
            "Check 2026-02-31 report",
            containers: [],
            now: fixedNow,
            calendar: makeUTCCalendar()
        )
        #expect(invalidDateDraft?.title == "Check 2026-02-31 report")
        #expect(invalidDateDraft?.when == nil)

        let standaloneAmPm = QuickAddParser.parse(
            "I am working on pm notes",
            containers: [],
            now: fixedNow,
            calendar: makeUTCCalendar()
        )
        #expect(standaloneAmPm?.title == "I am working on pm notes")
        #expect(standaloneAmPm?.when == nil)
    }

    @Test("Inline Quick Add in Today filter preserves when=today on perform")
    func todayFilterInlineCreatePreservesWhen() async throws {
        let repo = FakeThingsRepository(activeTodos: sampleTodos(), containers: sampleContainers())
        let recorder = OpenedURLRecorder()
        let host = try await makeHost(repo: repo, urlRecorder: recorder)

        let list = try await host.list(
            Things.CommandID.myTodos,
            query: "Buy espresso beans",
            filter: ThingsFilter.todayID
        )
        #expect(list.items.count == 1)
        _ = try await host.perform(Things.ActionID.create, on: list.items[0].id, in: Things.CommandID.myTodos)
        let opened = try #require(recorder.opened.first)
        #expect(opened.0.absoluteString.contains("when=today"))
    }

    @Test("Offers inline Quick Add fallback when My To-Dos has no matches")
    func noMatchFallbackCreatesTodo() async throws {
        let repo = FakeThingsRepository(activeTodos: sampleTodos(), containers: sampleContainers())
        let recorder = OpenedURLRecorder()
        let host = try await makeHost(repo: repo, urlRecorder: recorder)

        let list = try await host.list(
            Things.CommandID.myTodos,
            query: "Book dentist tomorrow",
            filter: ThingsFilter.projectPrefix + "proj-errands"
        )
        #expect(list.items.count == 1)
        #expect(list.items[0].title == "Add “Book dentist”")

        _ = try await host.perform(Things.ActionID.createAndOpen, on: list.items[0].id, in: Things.CommandID.myTodos)
        let opened = try #require(recorder.opened.first)
        #expect(opened.1 == true) // reveal=true activates Things
        let urlString = opened.0.absoluteString
        #expect(urlString.contains("list-id=proj-errands"))
        #expect(urlString.contains("reveal=true"))
    }

    @Test("Decodes JXA snapshot JSON and maps AppleScript errors")
    func decodesSnapshotAndErrors() throws {
        let json = #"""
        {
          "containers": [
            { "id": "p1", "title": "Launch", "kind": "project", "areaID": "a1", "areaTitle": "Work" }
          ],
          "todos": [
            {
              "id": "t1",
              "title": "Write tests",
              "notes": "Cover JXA decoding",
              "status": "open",
              "bucket": "today",
              "dueDate": { "year": 2026, "month": 4, "day": 10 },
              "activationDate": { "year": 2026, "month": 4, "day": 8 },
              "completionDate": null,
              "cancellationDate": null,
              "projectID": "p1",
              "projectTitle": "Launch",
              "areaID": "a1",
              "areaTitle": "Work",
              "tags": ["dev"]
            }
          ]
        }
        """#
        let snapshot = try AppleScriptThingsRepository.decodeSnapshot(Data(json.utf8))
        #expect(snapshot.containers.count == 1)
        #expect(snapshot.todos.count == 1)
        #expect(snapshot.todos[0].title == "Write tests")
        #expect(snapshot.todos[0].dueDate == ThingsDate(year: 2026, month: 4, day: 10))
        #expect(snapshot.todos[0].tags == ["dev"])

        #expect(AppleScriptThingsRepository.mapError(stderr: "execution error: Not authorized to send Apple events to Things3. (-1743)") == .automationDenied)
        #expect(AppleScriptThingsRepository.mapError(stderr: "execution error: Application isn't running. (-600)") == .appNotRunning)
        #expect(AppleScriptThingsRepository.mapError(stderr: "Error -1728: Can't get object.") == .notFound)
        #expect(AppleScriptThingsRepository.mapError(stderr: "Error -10814: Application can't be found.") == .appNotInstalled)
    }

    @Test("Localizes runtime UI strings into Simplified Chinese")
    func localizedZhHans() async throws {
        let repo = FakeThingsRepository(activeTodos: sampleTodos(), containers: sampleContainers())
        let host = try await makeHost(repo: repo, language: "zh-Hans")

        let list = try await host.list(Things.CommandID.myTodos)
        #expect(list.items[0].section == "今天")
        #expect(list.items[0].actions.first?.title == "完成待办")
        #expect(list.filters.first?.title == "全部待办")
    }
}
