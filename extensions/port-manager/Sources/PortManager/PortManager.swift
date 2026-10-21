import Darwin
import Foundation
import PrismExtensionKit

/// The TCP ports programs listen on, with the process behind each, and a way
/// to stop it. Every load reads the system afresh, so nothing is kept; an
/// action reads it again and acts only on the process the row showed.
@main
struct PortManager: PrismExtension {
    enum CommandID {
        static let openPorts = "open-ports"
    }

    enum FilterID {
        static let all = "all"
        static let localhost = "localhost"
        static let network = "network"
        static let interface = "interface"
    }

    enum ActionID {
        static let kill = "kill"
        static let forceKill = "force-kill"
        static let killParent = "kill-parent"
        static let openInBrowser = "open-in-browser"
        static let showInFinder = "show-in-finder"
        static let showParentInFinder = "show-parent-in-finder"
        static let copyPID = "copy-pid"
        static let copyPath = "copy-path"
        static let copyCommandLine = "copy-command-line"
        static let copyKillCommand = "copy-kill-command"
        // Submenus.
        static let browserMenu = "browser"
        static let finderMenu = "finder"
        static let copyMenu = "copy"
    }

    enum PreferenceID {
        static let portNames = "portNames"
    }

    let system: any PortSystem
    /// How long a signalled process gets to quit before it is reported as
    /// still running.
    let exitTimeout: Duration
    let pollInterval: Duration

    init() {
        self.init(system: SystemPorts())
    }

    init(system: any PortSystem, exitTimeout: Duration = .seconds(2), pollInterval: Duration = .milliseconds(50)) {
        self.system = system
        self.exitTimeout = exitTimeout
        self.pollInterval = pollInterval
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        try Self.check(command)
        let names = PortNames(context.preferences.string(PreferenceID.portNames))
        let listeners = await listeningProcesses()
        try Task.checkCancellation()

        // A filter keeps the processes with a port that reaches that far, and
        // shows only those ports beside them. Actions and the detail still
        // cover every port, since a kill closes them all.
        let exposure = Self.exposure(for: filter)
        let shown: [(process: ListeningProcess, ports: [ListeningPort])] = exposure.map { exposure in
            listeners.map { ($0, $0.ports(reaching: exposure)) }.filter { !$0.ports.isEmpty }
                .sorted(by: ListeningProcess.byLowestPort)
        } ?? listeners.map { ($0, $0.ports) }
        let currentUserID = system.currentUserID
        return ExtensionList(
            items: shown.map {
                PortRows.item(
                    for: $0.process, showing: $0.ports, names: names, currentUserID: currentUserID,
                    bundleIdentifier: system.bundleIdentifier(ofAppAt:)
                )
            },
            searchPlaceholder: "Search by port, process, or address",
            filters: PortRows.filters,
            emptyMessage: PortRows.emptyMessage(for: exposure)
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        try Self.check(command)
        let act: (ListeningProcess) async throws -> ExtensionActionResult
        switch action {
        case ActionID.kill: act = { try await stop($0.process, with: SIGTERM) }
        case ActionID.forceKill: act = { try await stop($0.process, with: SIGKILL) }
        case ActionID.killParent: act = { try await stop($0.parent, with: SIGTERM) }
        case ActionID.showInFinder: act = { await reveal($0.process) }
        case ActionID.showParentInFinder: act = { await reveal($0.parent) }
        case ActionID.browserMenu, ActionID.finderMenu, ActionID.copyMenu:
            // A Prism without submenus runs the submenu itself.
            return ExtensionActionResult(.failed(message: "Update Prism to open this menu."))
        default:
            throw PrismExtensionError("Port Manager can’t do “\(action)”.")
        }
        // The row may be minutes old: its ID names the process by PID and
        // start time, so act only if that same process still listens.
        guard let listener = await listeningProcess(item) else {
            return .reload(message: "That process is no longer listening.")
        }
        return try await act(listener)
    }

    private static func check(_ command: String) throws {
        guard command == CommandID.openPorts else {
            throw PrismExtensionError("Port Manager has no list “\(command)”.")
        }
    }

    /// Selects the program in Finder: its app bundle when it is an app's
    /// program, otherwise the executable.
    private func reveal(_ process: RunningProcess?) async -> ExtensionActionResult {
        guard let path = process.flatMap({ $0.bundlePath ?? $0.path }) else {
            return ExtensionActionResult(.failed(message: "The program’s location can’t be read."))
        }
        do {
            try await system.reveal(path)
        } catch {
            return ExtensionActionResult(.failed(message: "Finder couldn’t show “\(URL(fileURLWithPath: path).lastPathComponent)”."))
        }
        return .done
    }

    // MARK: - Reading and stopping

    private func listeningProcesses() async -> [ListeningProcess] {
        ListeningProcess.group(await system.listeningSockets(), processes: system.process)
    }

    /// The row with this ID, reading only its PID's process.
    private func listeningProcess(_ id: String) async -> ListeningProcess? {
        guard let pid = pid_t(id.prefix { $0 != "@" }) else { return nil }
        let sockets = await system.listeningSockets().filter { $0.pid == pid }
        return ListeningProcess.group(sockets, processes: system.process).first { $0.id == id }
    }

    static func exposure(for filter: String?) -> Exposure? {
        switch filter {
        case FilterID.localhost: .localhost
        case FilterID.network: .network
        case FilterID.interface: .interface
        default: nil
        }
    }

    /// Sends the signal and waits for the process to quit, since a delivered
    /// signal can still be caught or ignored.
    private func stop(_ process: RunningProcess?, with signal: Int32) async throws -> ExtensionActionResult {
        guard let process else { return .reload(message: "The process already quit.") }
        let name = "“\(process.name)”"
        do {
            try system.send(signal, to: process.identity)
        } catch .gone {
            return .reload(message: "\(name) already quit.")
        } catch .notPermitted {
            return ExtensionActionResult(.failed(message: "You don’t have permission to kill \(name)."), reload: true)
        } catch let .failed(code) {
            return ExtensionActionResult(.failed(message: "Couldn’t kill \(name): \(String(cString: strerror(code)))."), reload: true)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: exitTimeout)
        while system.isRunning(process.identity) {
            guard clock.now < deadline else {
                return .reload(message: signal == SIGKILL
                    ? "\(name) is still running."
                    : "\(name) is still running. Force Kill (⌘⇧⌫) stops it at once.")
            }
            try await Task.sleep(for: pollInterval)
        }
        return .reload(message: "Killed \(name).")
    }
}
