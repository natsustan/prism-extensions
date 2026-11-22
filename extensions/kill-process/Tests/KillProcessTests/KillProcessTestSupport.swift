import Darwin
import Foundation
import Synchronization
@testable import KillProcess

let me: uid_t = 501
let root: uid_t = 0
let startSeconds = 1_700_000_000

/// A Mac played in memory: running processes, bundle metadata,
/// signals sent, and Finder/app launches.
final class FakeProcesses: ProcessSystem, Sendable {
    private struct State {
        var records: [ProcessRecord] = []
        var missingFiles: Set<String> = []
        var ignoresTerminate: Set<pid_t> = []
        var refusesSignals: Set<pid_t> = []
        var failOpen = false
        var failReveal = false
        var signals: [Sent] = []
        var opened: [String] = []
        var revealed: [String] = []
    }

    struct Sent: Equatable {
        let pid: pid_t
        let signal: Int32
    }

    let currentUserID = me
    let currentPID: pid_t
    let bundleIdentifiers: [String: String]
    private let state = Mutex(State())

    init(currentPID: pid_t = 99_999, bundleIdentifiers: [String: String] = [:]) {
        self.currentPID = currentPID
        self.bundleIdentifiers = bundleIdentifiers
    }

    var signals: [Sent] { locked { $0.signals } }
    var opened: [String] { locked { $0.opened } }
    var revealed: [String] { locked { $0.revealed } }

    func add(_ record: ProcessRecord) {
        locked { state in
            state.records.removeAll { $0.pid == record.pid }
            state.records.append(record)
        }
    }

    func quit(_ pid: pid_t) {
        locked { $0.records.removeAll { $0.pid == pid } }
    }

    func markMissingFile(_ path: String) {
        locked { _ = $0.missingFiles.insert(path) }
    }

    func ignoreTerminate(_ pid: pid_t) {
        locked { _ = $0.ignoresTerminate.insert(pid) }
    }

    func refuseSignals(_ pid: pid_t) {
        locked { _ = $0.refusesSignals.insert(pid) }
    }

    func setFailOpen(_ value: Bool) {
        locked { $0.failOpen = value }
    }

    func setFailReveal(_ value: Bool) {
        locked { $0.failReveal = value }
    }

    // MARK: - ProcessSystem

    func snapshot() async throws -> [ProcessRecord] {
        locked { $0.records }
    }

    func process(_ pid: pid_t) -> KernelProcessInfo? {
        locked { state in
            guard let record = state.records.first(where: { $0.pid == pid }) else { return nil }
            return KernelProcessInfo(
                identity: record.identity,
                parentPID: record.parentPID,
                userID: record.userID,
                shortName: record.shortName,
                path: record.path
            )
        }
    }

    func send(_ signal: Int32, to process: ProcessIdentity) throws(SignalError) {
        let failure: SignalError? = locked { state in
            guard let index = state.records.firstIndex(where: { $0.pid == process.pid }),
                  state.records[index].identity == process else {
                return .gone
            }
            guard !state.refusesSignals.contains(process.pid) else {
                return .notPermitted
            }
            state.signals.append(Sent(pid: process.pid, signal: signal))
            if signal == SIGKILL || !state.ignoresTerminate.contains(process.pid) {
                state.records.remove(at: index)
            }
            return nil
        }
        if let failure { throw failure }
    }

    func isRunning(_ process: ProcessIdentity) -> Bool {
        locked { $0.records.first(where: { $0.pid == process.pid })?.identity == process }
    }

    func fileExists(at path: String) -> Bool {
        locked { !$0.missingFiles.contains(path) }
    }

    func open(_ path: String) async throws {
        let shouldFail = locked { state -> Bool in
            if state.failOpen { return true }
            state.opened.append(path)
            return false
        }
        if shouldFail { throw CommandRunner.Failure() }
    }

    func reveal(_ path: String) async throws {
        let shouldFail = locked { state -> Bool in
            if state.failReveal { return true }
            state.revealed.append(path)
            return false
        }
        if shouldFail { throw CommandRunner.Failure() }
    }

    func bundleIdentifier(ofAppAt path: String) -> String? {
        bundleIdentifiers[path]
    }

    private func locked<Value: Sendable>(_ body: (inout sending State) -> sending Value) -> Value {
        state.withLock(body)
    }
}

extension ProcessRecord {
    static func fake(
        _ pid: pid_t,
        _ name: String,
        user: uid_t = me,
        parent: pid_t = 1,
        path: String? = nil,
        comm: String? = nil,
        cpu: Double = 0.0,
        memoryMB: UInt64 = 32,
        startedAt seconds: Int = startSeconds
    ) -> ProcessRecord {
        let resolvedPath = path ?? "/usr/local/bin/\(name)"
        return ProcessRecord(
            identity: ProcessIdentity(pid: pid, startSeconds: seconds, startMicroseconds: 250_000),
            parentPID: parent,
            userID: user,
            shortName: String(name.prefix(16)),
            path: resolvedPath,
            comm: comm ?? resolvedPath,
            cpu: cpu,
            memoryBytes: memoryMB * 1024 * 1024
        )
    }
}

extension KillProcess {
    init(fake: FakeProcesses) {
        self.init(
            system: fake,
            exitTimeout: .milliseconds(100),
            restartExitTimeout: .milliseconds(100),
            pollInterval: .milliseconds(5)
        )
    }
}
