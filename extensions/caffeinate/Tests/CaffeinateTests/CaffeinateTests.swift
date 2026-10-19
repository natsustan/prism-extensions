import Foundation
import PrismExtensionTesting
import Synchronization
import Testing
@testable import Caffeinate

/// Stands in for the system's caffeinate processes. A start shows up on the
/// check after `startsAfterChecks` more checks, the way Prism's task launch
/// lands a moment after the request.
private final class FakeProcesses: CaffeinateProcesses {
    private struct State {
        var running = false
        var checks = 0
        var startsAtCheck: Int?
        var stops = 0
        var stopError: (any Error)?
    }

    private let state = Mutex(State())

    init(running: Bool = false) {
        state.withLock { $0.running = running }
    }

    /// The next start becomes visible after this many more checks.
    func startSoon(afterChecks checks: Int = 2) {
        state.withLock { $0.startsAtCheck = $0.checks + checks }
    }

    func failStops(_ error: any Error) {
        state.withLock { $0.stopError = error }
    }

    var stops: Int { state.withLock { $0.stops } }

    func isRunning() -> Bool {
        state.withLock { state in
            state.checks += 1
            if let start = state.startsAtCheck, state.checks >= start {
                state.running = true
                state.startsAtCheck = nil
            }
            return state.running
        }
    }

    func stopAll() throws {
        try state.withLock { state in
            state.stops += 1
            if let error = state.stopError { throw error }
            state.running = false
        }
    }
}

@Suite("Caffeinate")
struct CaffeinateTests {
    private func host(
        _ processes: FakeProcesses, preventDiskSleep: Bool = false
    ) async throws -> PrismTestHost {
        try await PrismTestHost(
            Caffeinate(processes: processes, startTimeout: .milliseconds(300), pollInterval: .milliseconds(5)),
            extensionID: "prism.caffeinate",
            preferences: ["preventDiskSleep": .bool(preventDiskSleep)]
        )
    }

    @Test("Caffeinate asks Prism to start the task, with -m when the disk should stay awake too")
    func start() async throws {
        let processes = FakeProcesses()
        processes.startSoon()
        let prism = try await host(processes)
        #expect(try await prism.run("caffeinate") == .completed(message: "Caffeinate is on.", restoreFocus: true))
        #expect(await prism.startedTasks == [.init(taskID: "caffeinate", arguments: ["-d", "-i"])])

        let disk = FakeProcesses()
        disk.startSoon()
        let diskPrism = try await host(disk, preventDiskSleep: true)
        _ = try await diskPrism.run("caffeinate")
        #expect(await diskPrism.startedTasks.first?.arguments == ["-d", "-i", "-m"])
    }

    @Test("a start that never shows up fails instead of claiming success")
    func startTimesOut() async throws {
        let prism = try await host(FakeProcesses())
        #expect(try await prism.run("caffeinate") == .failed(message: "Caffeinate did not start."))
    }

    @Test("already running: Caffeinate starts nothing; Decaffeinate stops every process")
    func alreadyRunning() async throws {
        let processes = FakeProcesses(running: true)
        let prism = try await host(processes)
        #expect(try await prism.run("caffeinate") == .completed(message: "Caffeinate is already on.", restoreFocus: true))
        #expect(await prism.startedTasks.isEmpty)

        #expect(try await prism.run("decaffeinate") == .completed(message: "Caffeinate is off.", restoreFocus: true))
        #expect(processes.stops == 1)
        #expect(try await prism.run("decaffeinate") == .completed(message: "Caffeinate is already off.", restoreFocus: true))
    }

    @Test("Toggle starts when off and stops when on")
    func toggle() async throws {
        let processes = FakeProcesses()
        // Toggle checks once to choose, and start checks again before asking.
        processes.startSoon(afterChecks: 3)
        let prism = try await host(processes)
        #expect(try await prism.run("toggle-caffeinate") == .completed(message: "Caffeinate is on.", restoreFocus: true))
        #expect(try await prism.run("toggle-caffeinate") == .completed(message: "Caffeinate is off.", restoreFocus: true))
        #expect(processes.stops == 1)
    }

    @Test("a stop the system refuses is reported")
    func stopFails() async throws {
        let processes = FakeProcesses(running: true)
        processes.failStops(POSIXError(.EPERM))
        let prism = try await host(processes)
        guard case let .failed(message) = try await prism.run("decaffeinate") else {
            Issue.record("A refused stop fails")
            return
        }
        #expect(message.hasPrefix("Could not stop caffeinate"))
    }

    @Test("the status row and the widget read the system's state")
    func statusAndWidget() async throws {
        let processes = FakeProcesses(running: true)
        let prism = try await host(processes)
        #expect(try await prism.status("caffeinate-status")?.text == "Caffeinated")
        guard case let .toggleCard(card) = try await prism.widget("toggle") else {
            Issue.record("The widget is a toggle card")
            return
        }
        #expect(card.isOn && card.status == "On" && card.toggleCommandID == "toggle-caffeinate")

        _ = try await prism.run("decaffeinate")
        #expect(try await prism.status("caffeinate-status")?.text == "Decaffeinated")
        #expect(try await prism.run("caffeinate-status") == .keepOpen(message: "Caffeinate is off."))
    }

    @Test("the system inspector finds nothing for an executable no one runs")
    func inspector() {
        let inspector = ProcessInspector(executableURL: URL(fileURLWithPath: "/usr/bin/true-not-running-\(UUID())"))
        #expect(inspector.matchingProcesses().isEmpty)
    }
}
