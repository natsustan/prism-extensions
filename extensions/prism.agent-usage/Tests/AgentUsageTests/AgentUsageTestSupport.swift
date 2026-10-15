import Foundation
import Testing
@testable import AgentUsage

/// No test may touch the network or the user's real
/// credential files, so both seams are stubbed here.

/// Counts fetches and hands out scripted outcomes in order.
actor StubProviderState {
    private(set) var fetchCount = 0
    private var index = 0

    func next(
        from outcomes: [Result<AgentUsageReport, AgentUsageFailure>]
    ) -> Result<AgentUsageReport, AgentUsageFailure>? {
        fetchCount += 1
        guard index < outcomes.count else { return nil }
        defer { index += 1 }
        return outcomes[index]
    }
}

struct StubAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID
    let displayName: String
    var icon: AgentUsageProviderIcon = .symbol("circle", tint: "gray")
    var hasLocalCredentialsValue = true
    /// Used when `outcomes` runs out, so one-off scripts stay terse.
    var outcome: Result<AgentUsageReport, AgentUsageFailure> = .success(.fixture())
    /// Per-fetch script, consumed in order.
    var outcomes: [Result<AgentUsageReport, AgentUsageFailure>] = []
    var delay: Duration = .zero

    // Internal (not private) so the synthesized memberwise initializer stays
    // reachable from the tests that build this stub.
    let state = StubProviderState()

    func hasLocalCredentials() -> Bool { hasLocalCredentialsValue }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        let scripted = await state.next(from: outcomes)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return scripted ?? outcome
    }

    func fetchCount() async -> Int { await state.fetchCount }
}

extension AgentUsageReport {
    static func fixture(
        provider: AgentUsageProviderID = .codex,
        providerName: String = "Codex",
        plan: String? = "Pro 5x",
        accountLabel: String? = "person@example.com",
        usedPercent: Double = 42,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AgentUsageReport {
        AgentUsageReport(
            providerID: provider,
            providerName: providerName,
            plan: plan,
            accountLabel: accountLabel,
            metrics: [AgentUsageMetric(
                id: "weekly",
                title: "Weekly",
                section: .limits,
                value: .progress(
                    used: usedPercent,
                    limit: 100,
                    format: .percent,
                    resetsAt: fetchedAt.addingTimeInterval(86_400),
                    windowSeconds: 604_800
                )
            )],
            fetchedAt: fetchedAt
        )
    }
}

/// Scripted HTTP transport for the provider clients.
struct StubHTTPClient: AgentUsageHTTPClient {
    var handler: @Sendable (AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse

    init(handler: @escaping @Sendable (AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse) {
        self.handler = handler
    }

    init(status: Int, body: String = "") {
        self.handler = { _ in AgentUsageHTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8)) }
    }

    static func json(_ body: String, status: Int = 200) -> StubHTTPClient {
        StubHTTPClient(handler: { _ in
            AgentUsageHTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
        })
    }

    func send(_ request: AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse {
        try await handler(request)
    }
}

/// Captures the request a stubbed client received across the `@Sendable`
/// handler closure.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentUsageHTTPRequest] = []

    var requests: [AgentUsageHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var lastRequest: AgentUsageHTTPRequest? { requests.last }

    func record(_ request: AgentUsageHTTPRequest) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(request)
    }
}

/// A lock-guarded flag for asserting a code path ran inside a `@Sendable`
/// closure.
final class FlagRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flagged = true
    }
}

/// Mutable clock so throttle and refresh-window behavior is deterministic.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current += interval
    }
}

/// A throwaway auth file in the test process's temp directory.
struct TemporaryCredentialFile {
    let directory: URL
    let url: URL

    init(relativePath: String, contents: String? = nil) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism-agent-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(
                (relativePath as NSString).deletingLastPathComponent, isDirectory: true),
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent(relativePath)
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func text() -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A one-shot event with a bounded, cancellation-aware wait for async assertions.
struct AgentUsageTestEvent: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func signal() {
        continuation.yield(())
        continuation.finish()
    }

    func wait() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

/// Deliberately ignores cancellation until released, to verify that a replacement
/// refresh cannot overlap a provider that is still unwinding its old request.
actor AgentUsageTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

struct ControlledAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID
    var displayName: String { id.rawValue }
    let icon: AgentUsageProviderIcon = .symbol("circle", tint: "gray")
    let started = AgentUsageTestEvent()
    let cancelled = AgentUsageTestEvent()
    let gate = AgentUsageTestGate()
    let state = StubProviderState()

    func hasLocalCredentials() -> Bool { true }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        _ = await state.next(from: [])
        return await withTaskCancellationHandler {
            started.signal()
            await gate.wait()
            return .success(.fixture(provider: id, providerName: displayName))
        } onCancel: {
            cancelled.signal()
        }
    }
}

extension AgentUsageTiming {
    /// Short deadlines with a wide enrichment window, so timing tests run in
    /// a few seconds and stay far from either edge: enrichment must finish
    /// by 2 s, the refresh by 4 s.
    static let testing = AgentUsageTiming(refreshDeadline: .seconds(4), enrichmentMargin: .seconds(2))
}
