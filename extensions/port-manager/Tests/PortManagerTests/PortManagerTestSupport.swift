import Darwin
import Foundation
@testable import PortManager

let me: uid_t = 501
let root: uid_t = 0

/// A Mac played in memory: its sockets and processes, and the signals and
/// Finder requests it received. A signalled process quits unless it ignores
/// that signal.
final class FakePorts: PortSystem, @unchecked Sendable {
    private struct State {
        var sockets: [SocketListener] = []
        var processes: [pid_t: RunningProcess] = [:]
        var isCurrentUserOnly = false
        var ignoresTerminate: Set<pid_t> = []
        var refusesSignals: Set<pid_t> = []
        var signals: [Sent] = []
        var revealed: [String] = []
    }

    struct Sent: Equatable {
        let pid: pid_t
        let signal: Int32
    }

    let currentUserID = me
    let bundleIdentifiers: [String: String]
    private let lock = NSLock()
    private var state = State()

    init(bundleIdentifiers: [String: String] = [:]) {
        self.bundleIdentifiers = bundleIdentifiers
    }

    var signals: [Sent] { locked { $0.signals } }
    var revealed: [String] { locked { $0.revealed } }

    /// A process listening at each `host:port` given.
    func listen(_ process: RunningProcess, at addresses: (String, Int)..., listedName: String? = nil) {
        locked {
            $0.processes[process.pid] = process
            $0.sockets += addresses.map { SocketListener(pid: process.pid, host: $0.0, port: $0.1, processName: listedName) }
        }
    }

    /// A process with no sockets, such as a server's parent.
    func run(_ process: RunningProcess) {
        locked { $0.processes[process.pid] = process }
    }

    func quit(_ pid: pid_t) {
        locked {
            $0.processes[pid] = nil
            $0.sockets.removeAll { $0.pid == pid }
        }
    }

    func ignoreTerminate(_ pid: pid_t) { locked { _ = $0.ignoresTerminate.insert(pid) } }
    func refuseSignals(_ pid: pid_t) { locked { _ = $0.refusesSignals.insert(pid) } }
    func showOnlyCurrentUser() { locked { $0.isCurrentUserOnly = true } }

    // MARK: - PortSystem

    func listeningSockets() async -> SocketScan {
        locked { SocketScan(sockets: $0.sockets, isCurrentUserOnly: $0.isCurrentUserOnly) }
    }

    func process(_ pid: pid_t) -> RunningProcess? {
        locked { $0.processes[pid] }
    }

    func send(_ signal: Int32, to process: ProcessIdentity) throws(SignalError) {
        let failure: SignalError? = locked { state in
            guard state.processes[process.pid]?.identity == process else { return .gone }
            guard !state.refusesSignals.contains(process.pid) else { return .notPermitted }
            state.signals.append(Sent(pid: process.pid, signal: signal))
            if signal == SIGKILL || !state.ignoresTerminate.contains(process.pid) {
                state.processes[process.pid] = nil
                state.sockets.removeAll { $0.pid == process.pid }
            }
            return nil
        }
        if let failure { throw failure }
    }

    func isRunning(_ process: ProcessIdentity) -> Bool {
        self.process(process.pid)?.identity == process
    }

    func reveal(_ path: String) async throws {
        locked { $0.revealed.append(path) }
    }

    func bundleIdentifier(ofAppAt path: String) -> String? {
        bundleIdentifiers[path]
    }

    private func locked<Value>(_ body: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

/// 2023-11-14 22:13:20 UTC.
let startSeconds = 1_700_000_000

extension RunningProcess {
    static func fake(
        _ pid: pid_t, _ name: String, user: uid_t = me, parent: pid_t = 1, path: String? = nil,
        arguments: [String]? = nil, startedAt seconds: Int = startSeconds
    ) -> RunningProcess {
        RunningProcess(
            identity: ProcessIdentity(pid: pid, startSeconds: seconds, startMicroseconds: 250_000),
            parentPID: parent,
            userID: user,
            userName: user == root ? "root" : "jane",
            shortName: String(name.prefix(16)),
            path: path ?? "/usr/local/bin/\(name)",
            arguments: user == me ? arguments ?? [path ?? "/usr/local/bin/\(name)"] : nil
        )
    }
}

extension PortManager {
    /// Signals take effect at once in the fake, so a short wait is enough.
    init(fake: FakePorts) {
        self.init(system: fake, exitTimeout: .milliseconds(100), pollInterval: .milliseconds(5))
    }
}
