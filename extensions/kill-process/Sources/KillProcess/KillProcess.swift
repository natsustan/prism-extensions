import Darwin
import Foundation
import PrismExtensionKit

/// Running processes sorted by CPU or memory usage, with safe kill, force
/// kill, restart, kill-all, and app-grouping controls.
@main
struct KillProcess: PrismExtension {
    enum CommandID {
        static let killProcess = "kill-process"
    }

    enum FilterID {
        static let cpu = "cpu"
        static let memory = "memory"
    }

    enum ActionID {
        static let kill = "kill"
        static let forceKill = "force-kill"
        static let restart = "restart"
        static let forceRestart = "force-restart"
        static let killAll = "kill-all"
        static let forceKillAll = "force-kill-all"
        static let showInFinder = "show-in-finder"
        static let copyPID = "copy-pid"
        static let copyPath = "copy-path"
        static let copyKillCommand = "copy-kill-command"
        static let copyForceKillCommand = "copy-force-kill-command"
        static let copyMenu = "copy"
        static let toggleAppGrouping = "toggle-app-grouping"
    }

    enum PreferenceID {
        static let closeAfterKill = "closeAfterKill"
    }

    enum StateKey {
        static let appGrouping = "appGrouping"
    }

    let system: any ProcessSystem
    let exitTimeout: Duration
    let restartExitTimeout: Duration
    let pollInterval: Duration

    init() {
        self.init(system: SystemProcesses())
    }

    init(
        system: any ProcessSystem,
        exitTimeout: Duration = .seconds(2),
        restartExitTimeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.system = system
        self.exitTimeout = exitTimeout
        self.restartExitTimeout = restartExitTimeout
        self.pollInterval = pollInterval
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        try Self.check(command)
        let sort = ProcessSort(filter: filter)
        let groupApps = await context.state(StateKey.appGrouping)?.boolValue ?? true

        let records = try await system.snapshot()
        try Task.checkCancellation()

        let currentUserID = system.currentUserID
        let entries = ProcessGrouping.entries(
            from: records,
            sort: sort,
            groupApps: groupApps,
            currentUserID: currentUserID
        )
        let sameNameOwnCounts = Dictionary(
            records
                .filter { $0.isKillable(by: currentUserID, excludingPID: system.currentPID) }
                .map { ($0.name, 1) },
            uniquingKeysWith: +
        )

        let rowContext = ProcessRows.RowContext(groupApps: groupApps)
        var fileExistsCache: [String: Bool] = [:]
        var bundleIDCache: [String: String?] = [:]
        let fileExists: (String) -> Bool = { path in
            if let cached = fileExistsCache[path] { return cached }
            let exists = system.fileExists(at: path)
            fileExistsCache[path] = exists
            return exists
        }
        let bundleIdentifier: (String) -> String? = { path in
            if let cached = bundleIDCache[path] { return cached }
            let identifier = system.bundleIdentifier(ofAppAt: path)
            bundleIDCache[path] = identifier
            return identifier
        }

        return ExtensionList(
            items: entries.map {
                ProcessRows.item(
                    for: $0,
                    sameNameOwnCounts: sameNameOwnCounts,
                    rowContext: rowContext,
                    currentUserID: currentUserID,
                    fileExists: fileExists,
                    bundleIdentifier: bundleIdentifier
                )
            },
            filtering: .prism,
            searchPlaceholder: localized("Filter by name…"),
            filters: ProcessRows.filters,
            emptyMessage: ProcessRows.emptyMessage,
            showsDetail: false
        )
    }

    func perform(
        action: String,
        item: String,
        command: String,
        context: PrismContext
    ) async throws -> ExtensionActionResult {
        try Self.check(command)

        if action == ActionID.toggleAppGrouping {
            let current = await context.state(StateKey.appGrouping)?.boolValue ?? true
            let next = !current
            await context.setState(.bool(next), for: StateKey.appGrouping)
            return .reload(message: next ? localized("Grouped app processes.") : localized("Showing individual processes."))
        }
        if action == ActionID.copyMenu {
            return ExtensionActionResult(.failed(message: localized("Update Prism to open this menu.")))
        }

        guard let parsed = ProcessGrouping.ParsedItemID(rawValue: item) else {
            return .reload(message: localized("That process already quit."))
        }

        switch action {
        case ActionID.showInFinder:
            return await reveal(parsed)
        case ActionID.kill:
            return try await killEntry(parsed, signal: SIGTERM, context: context)
        case ActionID.forceKill:
            return try await killEntry(parsed, signal: SIGKILL, context: context)
        case ActionID.restart:
            return try await restartEntry(parsed, signal: SIGTERM, context: context)
        case ActionID.forceRestart:
            return try await restartEntry(parsed, signal: SIGKILL, context: context)
        case ActionID.killAll:
            return try await killAll(matching: parsed.identity, signal: SIGTERM, context: context)
        case ActionID.forceKillAll:
            return try await killAll(matching: parsed.identity, signal: SIGKILL, context: context)
        default:
            throw PrismExtensionError(localized("Kill Process can’t do “\(action)”."))
        }
    }

    // MARK: - Helpers

    private static func check(_ command: String) throws {
        guard command == CommandID.killProcess else {
            throw PrismExtensionError(localized("Kill Process has no list “\(command)”."))
        }
    }

    private func reveal(_ parsed: ProcessGrouping.ParsedItemID) async -> ExtensionActionResult {
        guard let info = system.process(parsed.identity.pid), info.identity == parsed.identity else {
            return .reload(message: localized("That process already quit."))
        }
        guard let path = ProcessRecord.revealPath(for: info.path, aggregated: parsed.isAggregated) else {
            return ExtensionActionResult(.failed(message: localized("The program’s location can’t be read.")))
        }
        do {
            try await system.reveal(path)
        } catch {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return ExtensionActionResult(.failed(message: localized("Finder couldn’t show “\(name)”.")))
        }
        return .done
    }

    private func finishSuccess(_ message: String, context: PrismContext) -> ExtensionActionResult {
        let closeAfterKill = context.preferences.bool(PreferenceID.closeAfterKill, default: false)
        return closeAfterKill
            ? ExtensionActionResult(.hud(message: message), reload: true)
            : .reload(message: message)
    }

    private func killEntry(
        _ parsed: ProcessGrouping.ParsedItemID,
        signal: Int32,
        context: PrismContext
    ) async throws -> ExtensionActionResult {
        let records = try await system.snapshot()
        guard let resolved = ProcessGrouping.targetIdentities(
            for: parsed,
            in: records,
            currentUserID: system.currentUserID,
            excludingPID: system.currentPID
        ) else {
            return .reload(message: localized("That process already quit."))
        }

        let title = parsed.isAggregated
            ? (resolved.main.appName ?? resolved.main.name)
            : resolved.main.name
        let result = try await sendAndWait(
            targets: resolved.targets,
            signal: signal,
            timeout: exitTimeout
        )

        switch result {
        case let .failed(failure):
            return signalFailureResult(failure, title: title, goneMessage: localized("“\(title)” already quit."))
        case .timedOut:
            return .reload(
                message: signal == SIGKILL
                    ? localized("“\(title)” is still running.")
                    : localized("“\(title)” is still running. Force Kill (⇧⌘⌫) stops it at once.")
            )
        case .stopped:
            return finishSuccess(localized("Killed “\(title)”."), context: context)
        }
    }

    private func restartEntry(
        _ parsed: ProcessGrouping.ParsedItemID,
        signal: Int32,
        context: PrismContext
    ) async throws -> ExtensionActionResult {
        let records = try await system.snapshot()
        guard let resolved = ProcessGrouping.targetIdentities(
            for: parsed,
            in: records,
            currentUserID: system.currentUserID,
            excludingPID: system.currentPID
        ) else {
            return .reload(message: localized("That process already quit."))
        }

        guard let launchPath = resolved.main.restartLaunchPath else {
            return ExtensionActionResult(.failed(message: localized("The app or its bundle can’t be restarted.")))
        }
        guard system.fileExists(at: launchPath) else {
            return ExtensionActionResult(.failed(message: localized("The app’s bundle no longer exists.")), reload: true)
        }

        let title = parsed.isAggregated
            ? (resolved.main.appName ?? resolved.main.name)
            : resolved.main.name
        let result = try await sendAndWait(
            targets: resolved.targets,
            signal: signal,
            timeout: restartExitTimeout
        )

        switch result {
        case let .failed(failure):
            return signalFailureResult(failure, title: title, goneMessage: localized("That process already quit."))
        case .timedOut:
            return .reload(
                message: signal == SIGKILL
                    ? localized("“\(title)” is still running.")
                    : localized("“\(title)” didn’t quit in time. Try Force Restart (⌥⇧⌘R).")
            )
        case .stopped:
            do {
                try await system.open(launchPath)
            } catch {
                return ExtensionActionResult(.failed(message: localized("Killed “\(title)”, but couldn’t reopen it.")), reload: true)
            }
            return finishSuccess(localized("Restarted “\(title)”."), context: context)
        }
    }

    private func killAll(
        matching identity: ProcessIdentity,
        signal: Int32,
        context: PrismContext
    ) async throws -> ExtensionActionResult {
        let records = try await system.snapshot()
        guard let main = records.first(where: { $0.identity == identity }),
              main.isKillable(by: system.currentUserID, excludingPID: system.currentPID) else {
            return .reload(message: localized("That process already quit."))
        }

        let targets = ProcessGrouping.sameNameOwnProcesses(
            named: main.name,
            in: records,
            currentUserID: system.currentUserID,
            excludingPID: system.currentPID
        )
        guard !targets.isEmpty else {
            return .reload(message: localized("No running “\(main.name)” processes you own were found."))
        }

        let result = try await sendAndWait(
            targets: targets,
            signal: signal,
            timeout: exitTimeout,
            requirePrimary: false
        )

        switch result {
        case let .failed(failure):
            return signalFailureResult(failure, title: main.name, goneMessage: localized("“\(main.name)” already quit."))
        case let .timedOut(remainingCount):
            return .reload(
                message: signal == SIGKILL
                    ? localized("\(String(remainingCount)) “\(main.name)” processes are still running.")
                    : localized("\(String(remainingCount)) “\(main.name)” processes are still running. Force Kill All (⌥⇧⌘⌫) stops them at once.")
            )
        case let .stopped(signalledCount):
            let message = signalledCount == 1
                ? localized("Killed “\(main.name)”.")
                : localized("Killed \(String(signalledCount)) “\(main.name)” processes.")
            return finishSuccess(message, context: context)
        }
    }

    private enum SignalFailure {
        case allGoneBeforeSignal
        case notPermitted
        case code(Int32)
    }

    private enum SignalWaitOutcome {
        case stopped(Int)
        case timedOut(Int)
        case failed(SignalFailure)
    }

    private func signalFailureResult(
        _ failure: SignalFailure,
        title: String,
        goneMessage: String
    ) -> ExtensionActionResult {
        switch failure {
        case .allGoneBeforeSignal:
            return .reload(message: goneMessage)
        case .notPermitted:
            return ExtensionActionResult(.failed(message: localized("You don’t have permission to kill “\(title)”.")), reload: true)
        case let .code(code):
            let reason = String(cString: strerror(code))
            return ExtensionActionResult(.failed(message: localized("Couldn’t kill “\(title)”: \(reason).")), reload: true)
        }
    }

    private func sendAndWait(
        targets: [ProcessRecord],
        signal: Int32,
        timeout: Duration,
        requirePrimary: Bool = true
    ) async throws -> SignalWaitOutcome {
        var signalled: [ProcessIdentity] = []
        var firstError: SignalError?
        for target in targets {
            do {
                try system.send(signal, to: target.identity)
                signalled.append(target.identity)
            } catch .gone {
                continue
            } catch let error {
                if requirePrimary, target.identity == targets.first?.identity {
                    switch error {
                    case .notPermitted: return .failed(.notPermitted)
                    case let .failed(code): return .failed(.code(code))
                    case .gone: break
                    }
                } else if firstError == nil {
                    firstError = error
                }
            }
        }
        if signalled.isEmpty {
            switch firstError {
            case .notPermitted: return .failed(.notPermitted)
            case let .failed(code): return .failed(.code(code))
            case .gone, nil: return .failed(.allGoneBeforeSignal)
            }
        }
        let remaining = try await waitForExit(of: signalled, timeout: timeout)
        return remaining.isEmpty ? .stopped(signalled.count) : .timedOut(remaining.count)
    }

    private func waitForExit(of identities: [ProcessIdentity], timeout: Duration) async throws -> [ProcessIdentity] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var pending = identities
        while true {
            pending = pending.filter { system.isRunning($0) }
            if pending.isEmpty || clock.now >= deadline {
                return pending
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
