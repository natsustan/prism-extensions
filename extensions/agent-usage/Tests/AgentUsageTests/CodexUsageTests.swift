import Foundation
import Testing
@testable import AgentUsage

/// Fixtures are synthetic: the shapes mirror the live endpoints, the numbers and
/// accounts do not come from any real login.
@Suite("Codex usage mapping")
struct CodexUsageMapperTests {
    private static let credentials = CodexCredentials(
        accessToken: "test-access-token",
        accountID: "acct-test"
    )

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func usageBody(
        planType: String = "prolite",
        primary: String = """
            {"used_percent": 98, "limit_window_seconds": 604800, "reset_after_seconds": 316376, "reset_at": 1789805682}
            """,
        secondary: String = "null",
        additional: String = "[]",
        credits: String = """
            {"has_credits": false, "unlimited": false, "balance": "796"}
            """,
        resetCredits: String = "{\"available_count\": 2}"
    ) -> Data {
        Data("""
        {
          "plan_type": "\(planType)",
          "email": "person@example.com",
          "rate_limit": {"allowed": true, "primary_window": \(primary), "secondary_window": \(secondary)},
          "code_review_rate_limit": null,
          "additional_rate_limits": \(additional),
          "credits": \(credits),
          "rate_limit_reset_credits": \(resetCredits)
        }
        """.utf8)
    }

    @Test("additional limits keep unique identities across repeated names and slug collisions")
    func additionalLimitIdentities() throws {
        let names = ["Foo Bar", "Foo Bar", "Foo-Bar", "Foo Bar"]
        let additional = names.map { name in
            """
            {"limit_name":"\(name)", "rate_limit": {
                "primary_window":{"used_percent":10,"limit_window_seconds":604800},
                "secondary_window":{"used_percent":20,"limit_window_seconds":604800}
            }}
            """
        }.joined(separator: ",")
        let data = Self.usageBody(additional: "[\(additional)]")
        let report = try CodexUsageMapper.report(
            from: data, resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)
        #expect(report.metrics.filter { $0.section == .perModel }.count == 8)
        #expect(Set(report.metrics.map(\.id)).count == report.metrics.count)
        let repeated = try CodexUsageMapper.report(
            from: data, resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)
        #expect(report.metrics.map(\.id) == repeated.metrics.map(\.id))
    }

    @Test("non-finite and out-of-range credit balances reject the primary response",
          arguments: ["\"1e999\"", "\"NaN\"", "1e100", "9223372036854775808"])
    func invalidBalances(balance: String) {
        #expect(throws: AgentUsageClientError.invalidResponse) {
            try CodexUsageMapper.report(
                from: Self.usageBody(credits: "{\"balance\":\(balance)}"),
                resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)
        }
    }

    @Test("oversized reset counts reject primary data but optional counts fall back")
    func invalidResetCounts() throws {
        #expect(throws: AgentUsageClientError.invalidResponse) {
            try CodexUsageMapper.report(
                from: Self.usageBody(resetCredits: "{\"available_count\":1e100}"),
                resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)
        }
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(resetCredits: "{\"available_count\":3}"),
            resetCredits: Data("{\"available_count\":1e100}".utf8),
            credentials: Self.credentials, fetchedAt: Self.now)
        #expect(report.metrics.first { $0.id == "reset-credits" }?.value == .text("3 available"))
        #expect(CodexUsageMapper.resetCreditsMetrics(
            body: .init(availableCount: .infinity, credits: nil), dedicated: nil, now: Self.now).isEmpty)
    }

    @Test("credit formatting does not trap at floating-point integer boundaries")
    func creditBoundaries() {
        for balance in [Double.infinity, -.infinity, .nan, Double(Int.max), Double.greatestFiniteMagnitude] {
            #expect(CodexUsageMapper.creditText(balance: balance) == "—")
        }
        #expect(CodexUsageMapper.creditText(balance: Double(Int.max).nextDown) != "—")
        #expect(CodexUsageMapper.creditText(balance: -1) == "0")
    }

    @Test("weekly-only accounts report one weekly window with its plan and reset time")
    func weeklyOnly() throws {
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(), resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)

        #expect(report.providerID == .codex)
        #expect(report.plan == "Pro 5x")
        #expect(report.accountLabel == "person@example.com")
        #expect(report.metrics.map(\.id) == ["weekly", "credits", "reset-credits"])
        #expect(report.metrics[0].title == "Weekly Limit")

        guard case let .progress(used, limit, format, resetsAt, windowSeconds) = report.metrics[0].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 98)
        #expect(limit == 100)
        #expect(format == .percent)
        #expect(resetsAt == Date(timeIntervalSince1970: 1_789_805_682))
        #expect(windowSeconds == 604_800)
    }

    @Test("windows are classified by declared length, not by slot")
    func windowClassification() {
        #expect(CodexUsageMapper.windowKind(seconds: 18_000, slot: .primary) == .session)
        #expect(CodexUsageMapper.windowKind(seconds: 604_800, slot: .secondary) == .weekly)
        #expect(CodexUsageMapper.windowKind(seconds: 3_600, slot: .primary) == .other(seconds: 3_600))
        // An account that omits the length still gets the slot's conventional label.
        #expect(CodexUsageMapper.windowKind(seconds: nil, slot: .primary) == .session)
        #expect(CodexUsageMapper.windowKind(seconds: nil, slot: .secondary) == .weekly)
    }

    @Test("a five-hour session window and an unknown window both render")
    func mixedWindows() throws {
        let primary = """
            {"used_percent": 10, "limit_window_seconds": 18000, "reset_at": 1789507306}
            """
        let secondary = """
            {"used_percent": 55, "limit_window_seconds": 3600, "reset_at": 1789507306}
            """
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(primary: primary, secondary: secondary),
            resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)

        #expect(report.metrics.prefix(2).map(\.id) == ["session", "window-3600"])
        #expect(report.metrics.prefix(2).map(\.title) == ["5h Limit", "1h Limit"])
    }

    @Test("additional model limits get their own rows, first window under the limit name")
    func additionalLimits() throws {
        let additional = """
            [{"limit_name": "GPT-Test-Spark", "metered_feature": "spark", "rate_limit": {
                "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_at": 1789507306},
                "secondary_window": {"used_percent": 12, "limit_window_seconds": 604800, "reset_at": 1790000000}}}]
            """
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(additional: additional),
            resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)

        let limitMetrics = report.metrics.filter { $0.id.hasPrefix("limit-") }
        #expect(limitMetrics.map(\.id) == ["limit-gpt-test-spark-session", "limit-gpt-test-spark-weekly"])
        #expect(limitMetrics.map(\.title) == ["GPT-Test-Spark", "GPT-Test-Spark — Weekly Limit"])
    }

    @Test("the detail pane's groups follow the payload, not the metric ids")
    func sections() throws {
        let primary = """
            {"used_percent": 10, "limit_window_seconds": 18000, "reset_at": 1789507306}
            """
        let additional = """
            [{"limit_name": "GPT-Test-Spark", "metered_feature": "spark", "rate_limit": {
                "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_at": 1789507306},
                "secondary_window": {"used_percent": 12, "limit_window_seconds": 604800, "reset_at": 1790000000}}}]
            """
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(primary: primary, additional: additional),
            resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)

        #expect(report.showsSectionHeaders)
        #expect(report.groups.map(\.section) == [.limits, .perModel, .creditsAndResets])
        #expect(report.groups.map { $0.metrics.map(\.id) } == [
            ["session"],
            ["limit-gpt-test-spark-session", "limit-gpt-test-spark-weekly"],
            ["credits", "reset-credits"],
        ])
    }

    @Test("a short report stays a flat list instead of growing headings")
    func shortReportStaysFlat() throws {
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(), resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)

        // Weekly, credits, reset credits: three rows over three headings would
        // read worse than three rows.
        #expect(report.metrics.count == 3)
        #expect(report.groups.map(\.section) == [.limits, .creditsAndResets])
        #expect(!report.showsSectionHeaders)
    }

    @Test("the fourth row is what turns grouping on")
    func groupingThreshold() throws {
        // Weekly, one model window, credits, reset credits: four rows is the
        // first count that earns headings, so pin the boundary from below here
        // and from above in `shortReportStaysFlat`.
        let additional = """
            [{"limit_name": "GPT-Test-Spark", "rate_limit": {
                "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_at": 1789507306}}}]
            """
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(additional: additional),
            resetCredits: nil, credentials: Self.credentials, fetchedAt: Self.now)

        #expect(report.metrics.count == 4)
        #expect(report.showsSectionHeaders)
    }

    @Test("credits are priced at the Codex CLI's 4¢ per credit")
    func credits() {
        #expect(CodexUsageMapper.creditText(balance: 796) == "796 · $31.84")
        #expect(CodexUsageMapper.creditText(balance: 0) == "0")
        #expect(CodexUsageMapper.creditText(balance: 12.9) == "12 · $0.48")
    }

    @Test("an exhausted balance reads as a plain zero")
    func emptyCredits() throws {
        let credits = """
            {"has_credits": false, "unlimited": false, "balance": "0"}
            """
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(credits: credits), resetCredits: nil,
            credentials: Self.credentials, fetchedAt: Self.now)
        let metric = report.metrics.first { $0.id == "credits" }
        #expect(metric?.title == "Credits")
        #expect(metric?.value == .text("0"))
    }

    @Test("unlimited accounts are labeled rather than priced")
    func unlimitedCredits() throws {
        let credits = """
            {"has_credits": true, "unlimited": true, "balance": "0"}
            """
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(credits: credits), resetCredits: nil,
            credentials: Self.credentials, fetchedAt: Self.now)
        guard case let .badge(text) = report.metrics.first(where: { $0.id == "credits" })?.value else {
            Issue.record("expected a badge")
            return
        }
        #expect(text == "Unlimited")
    }

    @Test("reset credits prefer the dedicated endpoint and fall back to the usage body")
    func resetCredits() throws {
        let dedicated = Data("""
        {"available_count": 2, "credits": [
          {"status": "available", "expires_at": "2026-08-01T00:00:00Z"},
          {"status": "available", "expires_at": "2026-08-02T00:00:00Z"},
          {"status": "consumed", "expires_at": "2026-08-03T00:00:00Z"}]}
        """.utf8)

        let preferred = try CodexUsageMapper.report(
            from: Self.usageBody(), resetCredits: dedicated,
            credentials: Self.credentials, fetchedAt: Self.now)
        #expect(preferred.metrics.first { $0.id == "reset-credits" }?.value == .text("2 available"))
        // Each still-available credit gets a dated row; a spent one does not.
        #expect(preferred.metrics.filter { $0.id.hasPrefix("reset-credit-") }.map(\.title)
            == ["Manual Reset 1 Expires", "Manual Reset 2 Expires"])
        #expect(preferred.metrics.first { $0.id == "reset-credit-1" }?.value
            == .date(Date(timeIntervalSince1970: 1_785_542_400)))

        let fallback = try CodexUsageMapper.report(
            from: Self.usageBody(), resetCredits: nil,
            credentials: Self.credentials, fetchedAt: Self.now)
        #expect(fallback.metrics.first { $0.id == "reset-credits" }?.value == .text("2 available"))
    }

    @Test("a zero reset-credit count drops the row instead of showing 0")
    func noResetCredits() throws {
        let report = try CodexUsageMapper.report(
            from: Self.usageBody(resetCredits: "{\"available_count\": 0}"), resetCredits: nil,
            credentials: Self.credentials, fetchedAt: Self.now)
        #expect(!report.metrics.contains { $0.id == "reset-credits" })
    }

    @Test("an unparseable payload is reported as an unexpected response")
    func malformedPayload() {
        #expect(throws: AgentUsageClientError.invalidResponse) {
            try CodexUsageMapper.report(
                from: Data("not json".utf8), resetCredits: nil,
                credentials: Self.credentials, fetchedAt: Self.now)
        }
    }

    @Test("plan names map to what the Codex CLI shows")
    func planNames() {
        #expect(CodexUsageMapper.planName("prolite") == "Pro 5x")
        #expect(CodexUsageMapper.planName("pro") == "Pro 20x")
        #expect(CodexUsageMapper.planName("self_serve_business_prolite") == "Business Premium")
        #expect(CodexUsageMapper.planName("team") == "Team")
        #expect(CodexUsageMapper.planName("") == nil)
    }
}

@Suite("Codex usage client")
struct CodexUsageClientTests {
    private static let credentials = CodexCredentials(
        accessToken: "test-access-token",
        accountID: "acct-test"
    )

    @Test("a rejected token surfaces as unauthorized so the provider can explain it")
    func unauthorized() async {
        let client = CodexUsageClient(client: StubHTTPClient(status: 401))
        await #expect(throws: AgentUsageClientError.unauthorized) {
            try await client.fetchUsage(credentials: Self.credentials)
        }
    }

    @Test("server errors keep their status")
    func serverError() async {
        let client = CodexUsageClient(client: StubHTTPClient(status: 503))
        await #expect(throws: AgentUsageClientError.http(503)) {
            try await client.fetchUsage(credentials: Self.credentials)
        }
    }

    @Test("the account id and bearer token are sent as headers")
    func headers() async throws {
        let captured = HeaderRecorder()
        let client = CodexUsageClient(client: StubHTTPClient(handler: { request in
            captured.record(request.headers)
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }))
        _ = try await client.fetchUsage(credentials: Self.credentials)
        let headers = captured.headers
        #expect(headers["Authorization"] == "Bearer test-access-token")
        #expect(headers["ChatGPT-Account-ID"] == "acct-test")
    }

    @Test("the provider explains a missing login instead of showing raw status codes")
    func providerFailures() {
        #expect(CodexAgentUsageProvider.failure(from: AgentUsageClientError.unauthorized)
            .message.contains("codex login"))
        #expect(CodexAgentUsageProvider.failure(from: AgentUsageClientError.transport)
            .message.contains("Could not reach Codex"))
        #expect(CodexAgentUsageProvider.failure(from: AgentUsageClientError.invalidResponse)
            == .invalidResponse("Codex returned an unexpected response."))
    }
}

/// Captures request headers across the `@Sendable` client closure.
final class HeaderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    var headers: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        stored = headers
    }
}

@MainActor
@Suite("Codex provider deadline")
struct CodexProviderDeadlineTests {
    @Test("late primary quota survives slow or skipped optional reset credits", arguments: [0.5, 2.6])
    func optionalCreditsDeadline(primaryDelay: Double) async throws {
        let file = try TemporaryCredentialFile(relativePath: "auth.json", contents:
            #"{"tokens":{"access_token":"test-token"}}"#)
        defer { file.remove() }
        let client = SlowCodexResetCreditsClient(primaryDelay: primaryDelay)
        let provider = CodexAgentUsageProvider(
            authStore: CodexAuthStore(environment: ["CODEX_HOME": file.directory.path]), client: client)
        let defaults = UserDefaults(suiteName: "com.spike.prism.tests.codex.deadline.\(UUID().uuidString)")!
        let controller = AgentUsageController(
            providers: [provider], preferences: AgentUsagePreferencesStore())
        AgentUsageTiming.$current.withValue(.testing) { controller.refresh(force: true) }
        await controller.waitForPendingRefresh()
        let row = try #require(controller.row(for: .codex))
        #expect(row.failure == nil)
        #expect(!row.metrics.isEmpty)
        #expect(row.fetchedAt != nil)
        #expect(await client.state.fetchCount == (primaryDelay < 2 ? 2 : 1))
    }
}

private struct SlowCodexResetCreditsClient: AgentUsageHTTPClient {
    let primaryDelay: Double
    let state = StubProviderState()

    func send(_ request: AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse {
        _ = await state.next(from: [])
        if request.url == CodexUsageClient.usageURL {
            try await Task.sleep(for: .seconds(primaryDelay))
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":604800}}}"#.utf8))
        }
        try await Task.sleep(for: .seconds(4))
        return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
    }
}
