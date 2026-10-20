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
        guard command == CommandID.openPorts else {
            throw PrismExtensionError("Port Manager has no list “\(command)”.")
        }
        let names = PortNames(context.preferences.string(PreferenceID.portNames))
        let (listeners, scan) = await listeningProcesses()
        try Task.checkCancellation()

        // A filter keeps the processes with a port that reaches that far, and
        // shows only those ports.
        let exposure = Self.exposure(for: filter)
        let shown = exposure.map { exposure in
            listeners.compactMap { $0.only(exposure) }.sorted(by: ListeningProcess.byLowestPort)
        } ?? listeners
        let currentUserID = system.currentUserID
        return ExtensionList(
            items: shown.map {
                PortRows.item(
                    for: $0, names: names, currentUserID: currentUserID,
                    bundleIdentifier: system.bundleIdentifier(ofAppAt:)
                )
            },
            searchPlaceholder: "Search by port, process, or address",
            filters: PortRows.filters,
            emptyMessage: PortRows.emptyMessage(for: exposure),
            error: scan.isCurrentUserOnly
                ? "Only your own processes are shown, because the system’s list of sockets couldn’t be read."
                : nil
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard command == CommandID.openPorts else {
            throw PrismExtensionError("Port Manager has no list “\(command)”.")
        }
        // The row may be minutes old: its ID names the process by PID and
        // start time, so act only if that same process still listens.
        guard let listener = await listeningProcesses().listeners.first(where: { $0.id == item }) else {
            return .reload(message: "That process is no longer listening.")
        }
        switch action {
        case ActionID.kill:
            return try await stop(listener.process, with: SIGTERM)
        case ActionID.forceKill:
            return try await stop(listener.process, with: SIGKILL)
        case ActionID.killParent:
            return try await stop(listener.parent, with: SIGTERM)
        case ActionID.showInFinder:
            return await reveal(listener.process)
        case ActionID.showParentInFinder:
            return await reveal(listener.parent)
        case ActionID.browserMenu, ActionID.finderMenu, ActionID.copyMenu:
            // A Prism without submenus runs the submenu itself.
            return ExtensionActionResult(.failed(message: "Update Prism to open this menu."))
        default:
            throw PrismExtensionError("Port Manager can’t do “\(action)”.")
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

    private func listeningProcesses() async -> (listeners: [ListeningProcess], scan: SocketScan) {
        let scan = await system.listeningSockets()
        return (ListeningProcess.group(scan.sockets, processes: system.process), scan)
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
