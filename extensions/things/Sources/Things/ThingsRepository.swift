import AppKit
import ApplicationServices
import Foundation
import Synchronization

struct ThingsSnapshot: Sendable, Equatable {
    let todos: [ThingsTodo]
    let containers: [ThingsContainer]
}

protocol ThingsRepository: Sendable {
    func isInstalled() -> Bool
    func authorizationStatus() -> ThingsAuthorizationStatus
    func requestAutomationAccess() async -> ThingsAuthorizationStatus
    func fetchActive() async throws -> ThingsSnapshot
    func fetchLogbook(limit: Int) async throws -> ThingsSnapshot
    func fetchContainers() async throws -> [ThingsContainer]
    func setStatus(id: String, status: ThingsStatus) async throws
    func move(id: String, to target: ThingsMoveTarget) async throws
    func schedule(id: String, for date: ThingsDate) async throws
    func setDeadline(id: String, deadline: ThingsDate?) async throws
    func delete(id: String) async throws
}

/// Talks to Things 3 exclusively through its official AppleScript interface
/// (`osascript -l JavaScript`), avoiding direct reads of Things' internal SQLite files.
struct AppleScriptThingsRepository: ThingsRepository {
    static let defaultTimeoutSeconds: Double = 12

    func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ThingsURLs.bundleIdentifier) != nil
    }

    func authorizationStatus() -> ThingsAuthorizationStatus {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: ThingsURLs.bundleIdentifier).isEmpty else {
            return .notRunning
        }
        return Self.checkAutomationPermission(askUserIfNeeded: false)
    }

    func requestAutomationAccess() async -> ThingsAuthorizationStatus {
        await Task.detached {
            Self.checkAutomationPermission(askUserIfNeeded: true)
        }.value
    }

    private static func checkAutomationPermission(askUserIfNeeded: Bool) -> ThingsAuthorizationStatus {
        var desc = AEAddressDesc()
        let status: OSStatus = ThingsURLs.bundleIdentifier.withCString { cstr in
            let created = AECreateDesc(typeApplicationBundleID, cstr, strlen(cstr), &desc)
            guard created == noErr else { return OSStatus(created) }
            defer { AEDisposeDesc(&desc) }
            return AEDeterminePermissionToAutomateTarget(&desc, typeWildCard, typeWildCard, askUserIfNeeded)
        }
        switch status {
        case noErr:
            return .authorized
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(procNotFound):
            return .notRunning
        default:
            return .notDetermined
        }
    }

    func fetchActive() async throws -> ThingsSnapshot {
        let data = try await runJXA(Self.fetchActiveScript, arguments: [])
        return try Self.decodeSnapshot(data)
    }

    func fetchLogbook(limit: Int) async throws -> ThingsSnapshot {
        let data = try await runJXA(Self.fetchLogbookScript, arguments: [String(max(1, limit))])
        return try Self.decodeSnapshot(data)
    }

    func fetchContainers() async throws -> [ThingsContainer] {
        let data = try await runJXA(Self.fetchContainersScript, arguments: [])
        return try Self.decodeContainers(data)
    }

    func setStatus(id: String, status: ThingsStatus) async throws {
        _ = try await runJXA(Self.setStatusScript, arguments: [id, status.rawValue])
    }

    func move(id: String, to target: ThingsMoveTarget) async throws {
        _ = try await runJXA(Self.moveScript, arguments: [id, target.scriptKind, target.targetID])
    }

    func schedule(id: String, for date: ThingsDate) async throws {
        _ = try await runJXA(
            Self.scheduleScript,
            arguments: [id, String(date.year), String(date.month), String(date.day)]
        )
    }

    func setDeadline(id: String, deadline: ThingsDate?) async throws {
        if let deadline {
            _ = try await runJXA(
                Self.setDeadlineScript,
                arguments: [id, String(deadline.year), String(deadline.month), String(deadline.day)]
            )
        } else {
            _ = try await runJXA(Self.clearDeadlineScript, arguments: [id])
        }
    }

    func delete(id: String) async throws {
        _ = try await runJXA(Self.deleteScript, arguments: [id])
    }

    // MARK: - Process Execution

    private func runJXA(_ script: String, arguments: [String]) async throws -> Data {
        guard isInstalled() else {
            throw ThingsRepositoryError.appNotInstalled
        }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stdout/stderr continuously so large JSON payloads never fill
        // the OS pipe buffer and deadlock `osascript`.
        let stdoutBuffer = Mutex(Data())
        let stderrBuffer = Mutex(Data())
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stdoutBuffer.withLock { $0.append(chunk) }
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrBuffer.withLock { $0.append(chunk) }
            }
        }

        let state = Mutex<CheckedContinuation<Data, Error>?>(nil)
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(Self.defaultTimeoutSeconds))
            if process.isRunning {
                process.terminate()
            }
            if let continuation = state.withLock({ cont -> CheckedContinuation<Data, Error>? in
                defer { cont = nil }
                return cont
            }) {
                continuation.resume(throwing: ThingsRepositoryError.scriptFailed(
                    localized("Things took too long to respond.")
                ))
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0 = continuation }

                process.terminationHandler = { proc in
                    timeoutTask.cancel()
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    let tailOut = stdoutHandle.readDataToEndOfFile()
                    let tailErr = stderrHandle.readDataToEndOfFile()
                    let outData = stdoutBuffer.withLock { data -> Data in
                        data.append(tailOut)
                        return data
                    }
                    let errData = stderrBuffer.withLock { data -> Data in
                        data.append(tailErr)
                        return data
                    }
                    guard let cont = state.withLock({ pending -> CheckedContinuation<Data, Error>? in
                        defer { pending = nil }
                        return pending
                    }) else { return }

                    if proc.terminationStatus == 0 {
                        cont.resume(returning: outData)
                    } else {
                        let stderr = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        cont.resume(throwing: Self.mapError(stderr: stderr))
                    }
                }

                do {
                    try process.run()
                } catch {
                    timeoutTask.cancel()
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    if let cont = state.withLock({ pending -> CheckedContinuation<Data, Error>? in
                        defer { pending = nil }
                        return pending
                    }) {
                        cont.resume(throwing: ThingsRepositoryError.scriptFailed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            timeoutTask.cancel()
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            if let cont = state.withLock({ pending -> CheckedContinuation<Data, Error>? in
                defer { pending = nil }
                return pending
            }) {
                cont.resume(throwing: CancellationError())
            }
        }
    }

    static func mapError(stderr: String) -> ThingsRepositoryError {
        let lower = stderr.lowercased()
        if stderr.contains("-1743") || lower.contains("not authorized to send apple events") || lower.contains("not permitted") {
            return .automationDenied
        }
        if stderr.contains("-600") || lower.contains("application isn't running") {
            return .appNotRunning
        }
        if stderr.contains("-1728") || lower.contains("can't get") || lower.contains("object is not found") {
            return .notFound
        }
        if stderr.contains("-10814") || lower.contains("application can't be found") {
            return .appNotInstalled
        }
        return .scriptFailed(stderr)
    }

    // MARK: - JSON Decoding

    private struct RawDate: Decodable {
        let year: Int
        let month: Int
        let day: Int

        var thingsDate: ThingsDate {
            ThingsDate(year: year, month: month, day: day)
        }
    }

    private struct RawContainer: Decodable {
        let id: String
        let title: String
        let kind: String
        let areaID: String?
        let areaTitle: String?
    }

    private struct RawTodo: Decodable {
        let id: String
        let title: String
        let notes: String?
        let status: String
        let bucket: String
        let dueDate: RawDate?
        let activationDate: RawDate?
        let completionDate: Double?
        let cancellationDate: Double?
        let projectID: String?
        let projectTitle: String?
        let areaID: String?
        let areaTitle: String?
        let tags: [String]?
    }

    private struct RawSnapshot: Decodable {
        let todos: [RawTodo]
        let containers: [RawContainer]
    }

    static func decodeSnapshot(_ data: Data) throws -> ThingsSnapshot {
        let raw: RawSnapshot
        do {
            raw = try JSONDecoder().decode(RawSnapshot.self, from: data)
        } catch {
            throw ThingsRepositoryError.scriptFailed(
                localized("Couldn’t read the response from Things.")
            )
        }
        let containers = raw.containers.compactMap(mapContainer)
        let todos = raw.todos.map { item in
            ThingsTodo(
                id: item.id,
                title: item.title,
                notes: item.notes ?? "",
                status: ThingsStatus(rawValue: item.status) ?? .open,
                bucket: ThingsBucket(rawValue: item.bucket) ?? .anytime,
                dueDate: item.dueDate?.thingsDate,
                activationDate: item.activationDate?.thingsDate,
                completionDate: item.completionDate.map { Date(timeIntervalSince1970: $0) },
                cancellationDate: item.cancellationDate.map { Date(timeIntervalSince1970: $0) },
                projectID: item.projectID,
                projectTitle: item.projectTitle,
                areaID: item.areaID,
                areaTitle: item.areaTitle,
                tags: item.tags ?? []
            )
        }
        return ThingsSnapshot(todos: todos, containers: containers)
    }

    static func decodeContainers(_ data: Data) throws -> [ThingsContainer] {
        do {
            let raw = try JSONDecoder().decode([RawContainer].self, from: data)
            return raw.compactMap(mapContainer)
        } catch {
            throw ThingsRepositoryError.scriptFailed(
                localized("Couldn’t read the response from Things.")
            )
        }
    }

    private static func mapContainer(_ raw: RawContainer) -> ThingsContainer? {
        guard let kind = ThingsContainer.Kind(rawValue: raw.kind) else { return nil }
        return ThingsContainer(
            id: raw.id,
            title: raw.title,
            kind: kind,
            areaID: raw.areaID,
            areaTitle: raw.areaTitle
        )
    }

    // MARK: - JXA Scripts

    /// Shared JS helpers for reading areas, projects, and bulk-extracting to-do properties.
    private static let commonHelpersJS = #"""
    function toDayObj(d) {
        if (!d) return null;
        return { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() };
    }
    function toEpoch(d) {
        if (!d) return null;
        return d.getTime() / 1000.0;
    }
    function parseTags(raw) {
        if (!raw) return [];
        return String(raw).split(",").map(function(s) { return s.trim(); }).filter(function(s) { return s.length > 0; });
    }
    function collectContainers(app) {
        var containers = [];
        var areaTitleByID = {};
        var projectTitleByID = {};
        var projectAreaIDByID = {};
        var projectIDSet = {};
        var todoProjectID = {};
        var todoAreaID = {};

        var areas = app.areas();
        for (var i = 0; i < areas.length; i++) {
            var a = areas[i];
            var aid = a.id();
            var atitle = a.name() || "";
            areaTitleByID[aid] = atitle;
            containers.push({ id: aid, title: atitle, kind: "area", areaID: null, areaTitle: null });
            try {
                var aTodoIDs = a.toDos.id();
                for (var k = 0; k < aTodoIDs.length; k++) {
                    todoAreaID[aTodoIDs[k]] = aid;
                }
            } catch (e) {}
        }

        var projects = app.projects();
        for (var j = 0; j < projects.length; j++) {
            var p = projects[j];
            var pid = p.id();
            projectIDSet[pid] = true;
            var pstatus = "";
            try { pstatus = p.status(); } catch (e) {}
            if (pstatus !== "open") continue;
            var ptitle = p.name() || "";
            var paid = null;
            var patitle = null;
            try {
                var pa = p.area();
                if (pa) {
                    paid = pa.id();
                    patitle = areaTitleByID[paid] || pa.name() || null;
                }
            } catch (e) {}
            projectTitleByID[pid] = ptitle;
            if (paid) projectAreaIDByID[pid] = paid;
            containers.push({ id: pid, title: ptitle, kind: "project", areaID: paid, areaTitle: patitle });
            try {
                var pTodoIDs = p.toDos.id();
                for (var m = 0; m < pTodoIDs.length; m++) {
                    todoProjectID[pTodoIDs[m]] = pid;
                }
            } catch (e) {}
        }

        return {
            containers: containers,
            areaTitleByID: areaTitleByID,
            projectTitleByID: projectTitleByID,
            projectAreaIDByID: projectAreaIDByID,
            projectIDSet: projectIDSet,
            todoProjectID: todoProjectID,
            todoAreaID: todoAreaID
        };
    }
    function extractFromList(listObj, bucketName, meta, seen, maxCount) {
        var results = [];
        var ids = [];
        try { ids = listObj.toDos.id(); } catch (e) { return results; }
        if (!ids || ids.length === 0) return results;
        var names = listObj.toDos.name();
        var notes = listObj.toDos.notes();
        var statuses = listObj.toDos.status();
        var dueDates = listObj.toDos.dueDate();
        var actDates = listObj.toDos.activationDate();
        var compDates = listObj.toDos.completionDate();
        var cancDates = listObj.toDos.cancellationDate();
        var tagNames = listObj.toDos.tagNames();

        var count = maxCount > 0 ? Math.min(ids.length, maxCount) : ids.length;
        for (var i = 0; i < count; i++) {
            var id = ids[i];
            if (!id || seen[id] || meta.projectIDSet[id]) continue;
            seen[id] = true;
            var pid = meta.todoProjectID[id] || null;
            var aid = (pid && meta.projectAreaIDByID[pid]) ? meta.projectAreaIDByID[pid] : (meta.todoAreaID[id] || null);
            results.push({
                id: id,
                title: names[i] || "",
                notes: notes[i] || "",
                status: statuses[i] || "open",
                bucket: bucketName,
                dueDate: toDayObj(dueDates[i]),
                activationDate: toDayObj(actDates[i]),
                completionDate: toEpoch(compDates[i]),
                cancellationDate: toEpoch(cancDates[i]),
                projectID: pid,
                projectTitle: pid ? (meta.projectTitleByID[pid] || null) : null,
                areaID: aid,
                areaTitle: aid ? (meta.areaTitleByID[aid] || null) : null,
                tags: parseTags(tagNames[i])
            });
        }
        return results;
    }
    """#

    private static let fetchActiveScript = commonHelpersJS + #"""
    function run() {
        var app = Application("com.culturedcode.ThingsMac");
        var meta = collectContainers(app);
        var seen = {};
        var todos = [];
        var sources = [
            { id: "TMTodayListSource", bucket: "today" },
            { id: "TMInboxListSource", bucket: "inbox" },
            { id: "TMCalendarListSource", bucket: "upcoming" },
            { id: "TMNextListSource", bucket: "anytime" },
            { id: "TMSomedayListSource", bucket: "someday" }
        ];
        for (var i = 0; i < sources.length; i++) {
            try {
                var listObj = app.lists.byId(sources[i].id);
                var batch = extractFromList(listObj, sources[i].bucket, meta, seen, 0);
                for (var j = 0; j < batch.length; j++) {
                    todos.push(batch[j]);
                }
            } catch (e) {}
        }
        return JSON.stringify({ todos: todos, containers: meta.containers });
    }
    """#

    private static let fetchLogbookScript = commonHelpersJS + #"""
    function run(argv) {
        var limit = parseInt(argv[0], 10) || 150;
        var app = Application("com.culturedcode.ThingsMac");
        var meta = collectContainers(app);
        var seen = {};
        var listObj = app.lists.byId("TMLogbookListSource");
        var todos = extractFromList(listObj, "logbook", meta, seen, limit);
        return JSON.stringify({ todos: todos, containers: meta.containers });
    }
    """#

    private static let fetchContainersScript = commonHelpersJS + #"""
    function run() {
        var app = Application("com.culturedcode.ThingsMac");
        var meta = collectContainers(app);
        return JSON.stringify(meta.containers);
    }
    """#

    private static let setStatusScript = #"""
    function run(argv) {
        var app = Application("com.culturedcode.ThingsMac");
        var todo = app.toDos.byId(argv[0]);
        todo.status = argv[1];
        return "ok";
    }
    """#

    private static let moveScript = #"""
    function run(argv) {
        var app = Application("com.culturedcode.ThingsMac");
        var todo = app.toDos.byId(argv[0]);
        var kind = argv[1];
        var targetID = argv[2];
        var target = kind === "project" ? app.projects.byId(targetID)
            : (kind === "area" ? app.areas.byId(targetID) : app.lists.byId(targetID));
        app.move(todo, { to: target });
        return "ok";
    }
    """#

    private static let scheduleScript = #"""
    function run(argv) {
        var app = Application("com.culturedcode.ThingsMac");
        var todo = app.toDos.byId(argv[0]);
        var year = parseInt(argv[1], 10);
        var month = parseInt(argv[2], 10);
        var day = parseInt(argv[3], 10);
        app.schedule(todo, { for: new Date(year, month - 1, day) });
        return "ok";
    }
    """#

    private static let setDeadlineScript = #"""
    function run(argv) {
        var app = Application("com.culturedcode.ThingsMac");
        var todo = app.toDos.byId(argv[0]);
        var year = parseInt(argv[1], 10);
        var month = parseInt(argv[2], 10);
        var day = parseInt(argv[3], 10);
        todo.dueDate = new Date(year, month - 1, day);
        return "ok";
    }
    """#

    private static let clearDeadlineScript = #"""
    function run(argv) {
        var app = Application("com.culturedcode.ThingsMac");
        var todo = app.toDos.byId(argv[0]);
        todo.dueDate = null;
        return "ok";
    }
    """#

    private static let deleteScript = #"""
    function run(argv) {
        var app = Application("com.culturedcode.ThingsMac");
        var todo = app.toDos.byId(argv[0]);
        app.delete(todo);
        return "ok";
    }
    """#
}
