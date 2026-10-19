import Foundation
import Testing
@testable import AgentUsage

@Suite("Amp auth store")
struct AmpAuthStoreTests {
    @Test("reads the ampcode.com apiKey entry from secrets.json")
    func readsSecretsFile() throws {
        let file = try TemporaryCredentialFile(relativePath: "secrets.json", contents: """
        {"apiKey@https://ampcode.com/": "amp-test-key", "other": "ignored"}
        """)
        defer { file.remove() }

        let store = AmpAuthStore(secretsFileURL: file.url, environment: [:])
        #expect(try store.loadCredentials().apiKey == "amp-test-key")
    }

    @Test("credentials for other hosts are ignored, preserving the environment fallback")
    func ignoresOtherHosts() throws {
        let file = try TemporaryCredentialFile(relativePath: "secrets.json", contents: """
        {"apiKey@https://amp.example.internal/": "self-hosted-key"}
        """)
        defer { file.remove() }

        var store = AmpAuthStore(secretsFileURL: file.url, environment: [:])
        #expect(throws: AmpAuthError.notLoggedIn) { try store.loadCredentials() }
        store.environment = ["AMP_API_KEY": "env-key"]
        #expect(try store.loadCredentials().apiKey == "env-key")
    }

    @Test("AMP_API_KEY is the fallback when no secrets file exists")
    func environmentFallback() throws {
        let missing = try TemporaryCredentialFile(relativePath: "absent/secrets.json")
        defer { missing.remove() }

        let store = AmpAuthStore(
            secretsFileURL: missing.url,
            environment: ["AMP_API_KEY": "  env-key  "])
        #expect(try store.loadCredentials().apiKey == "env-key")
    }

    @Test("no file and no env var is not logged in")
    func notLoggedIn() throws {
        let missing = try TemporaryCredentialFile(relativePath: "absent/secrets.json")
        defer { missing.remove() }

        let store = AmpAuthStore(secretsFileURL: missing.url, environment: [:])
        #expect(throws: AmpAuthError.notLoggedIn) { try store.loadCredentials() }
    }
}

@Suite("Amp usage mapping")
struct AmpUsageMapperTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func envelope(_ displayText: String) -> Data {
        let escaped = displayText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Data("""
        {"ok": true, "result": {"displayText": "\(escaped)"}}
        """.utf8)
    }

    @Test("free-tier dollars become a used-percent meter with a refill ETA")
    func freeTierDollars() throws {
        let report = try AmpUsageMapper.report(from: Self.envelope("""
        Signed in as person@example.com
        Amp Free: $4.20/$10 remaining (replenishes +$0.42/hour)
        """), fetchedAt: Self.now)

        #expect(report.plan == "Free")
        #expect(report.accountLabel == "person@example.com")
        let free = try #require(report.metrics.first)
        guard case let .progress(used, limit, format, resetsAt, _) = free.value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(abs(used - 58) < 0.000_001)
        #expect(limit == 100)
        #expect(format == .percent)
        // $5.80 used at +$0.42/hour refills in ~13.8 hours.
        #expect(resetsAt == Self.now.addingTimeInterval(5.8 / 0.42 * 3_600))
    }

    @Test("markdown-bold labels still parse")
    func markdownLabels() throws {
        let report = try AmpUsageMapper.report(from: Self.envelope("""
        **Signed in as** person@example.com
        **Amp Free:** 42% remaining today (resets daily)
        """), fetchedAt: Self.now)

        let free = try #require(report.metrics.first)
        guard case let .progress(used, _, _, _, _) = free.value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 58)
    }

    @Test("subscription percentages split the two usage meters")
    func subscriptionPercentages() throws {
        let report = try AmpUsageMapper.report(from: Self.envelope("""
        Amp Pro Subscription: 32% other usage and 97% orb usage remaining - resets upon renewal in 5 days
        """), fetchedAt: Self.now)

        #expect(report.plan == "Pro")
        #expect(report.metrics.count == 2)
        guard case let .progress(used, _, _, resetsAt, _) = report.metrics[0].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 68)
        #expect(resetsAt == Self.now.addingTimeInterval(5 * 86_400))
        guard case let .progress(orbUsed, _, _, _, _) = report.metrics[1].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(orbUsed == 3)
        #expect(report.metrics[1].section == .perModel)
    }

    @Test("the tier dollar form parses with orb hours")
    func tierDollars() throws {
        let report = try AmpUsageMapper.report(from: Self.envelope("""
        Amp Pro Tier: agent usage $50 of $100 remaining (orb usage 12h of 100h a1.small orb hours remaining) resets upon renewal in 10 days
        """), fetchedAt: Self.now)

        #expect(report.plan == "Pro")
        #expect(report.metrics.count == 2)
        guard case let .progress(used, _, _, _, _) = report.metrics[0].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 50)
        guard case let .progress(orbUsed, _, _, _, _) = report.metrics[1].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(orbUsed == 88)
    }

    @Test("individual credits and workspace balances are text rows")
    func creditsAndWorkspaces() throws {
        let report = try AmpUsageMapper.report(from: Self.envelope("""
        Individual credits: $25.00 remaining
        Workspace acme: $130.50 remaining
        """), fetchedAt: Self.now)

        #expect(report.plan == "Credits")
        #expect(report.metrics.count == 2)
        #expect(report.metrics[0].value == .text("$25.00"))
        #expect(report.metrics[1].title == "Workspace acme")
        #expect(report.metrics[1].value == .text("$130.50"))
    }

    @Test("workspace rows keep distinct identities when names share a slug")
    func collidingWorkspaceNames() throws {
        let report = try AmpUsageMapper.report(from: Self.envelope("""
        Workspace foo bar: $10.00 remaining
        Workspace foo-bar: $20.00 remaining
        Workspace foo bar: $30.00 remaining
        """), fetchedAt: Self.now)

        #expect(report.metrics.map(\.title) == [
            "Workspace foo bar", "Workspace foo-bar", "Workspace foo bar",
        ])
        #expect(Set(report.metrics.map(\.id)).count == 3)
    }

    @Test("the credits line's daily Amp Free balance meters usage against $5")
    func inlineFreeBalance() throws {
        // The shape observed from a live `userDisplayBalanceInfo` reply.
        let report = try AmpUsageMapper.report(from: Self.envelope("""
        Signed in as person@example.com (orgname)
        Individual credits: $19.01 remaining (includes $4.98 Amp Free remaining today; resets daily) (set up auto-reload to avoid running out) - https://ampcode.com/settings
        """), fetchedAt: Self.now)

        #expect(report.accountLabel == "person@example.com · orgname")
        #expect(report.metrics.count == 2)
        #expect(report.metrics[0].id == "free")
        #expect(report.primaryMetric?.id == "free")
        guard case let .progress(used, limit, format, resetsAt, windowSeconds) = report.metrics[0].value else {
            Issue.record("expected a daily progress metric")
            return
        }
        #expect(abs(used - 0.02) < 0.000_001)
        #expect(limit == 5)
        #expect(format == .currency)
        #expect(resetsAt == nil)
        #expect(windowSeconds == 86_400)
        #expect(AgentUsageFormat.meterPercent(used: used, limit: limit, showsRemaining: false) == "<1%")
        #expect(AgentUsageFormat.meterPercent(used: used, limit: limit, showsRemaining: true) == "100%")
        #expect(report.metrics[1].value == .text("$19.01"))

        let halfUsed = try AmpUsageMapper.report(from: Self.envelope(
            "Individual credits: $12.50 remaining (includes $2.50 Amp Free remaining today; resets daily)"
        ), fetchedAt: Self.now)
        guard let primary = halfUsed.primaryMetric,
              case let .progress(halfUsedDollars, dailyLimit, _, _, _) = primary.value else {
            Issue.record("expected a daily progress metric")
            return
        }
        #expect(AgentUsageFormat.meterPercent(
            used: halfUsedDollars, limit: dailyLimit, showsRemaining: false) == "50%")
    }

    @Test("an auth-required envelope is an auth rejection")
    func authRejected() {
        let body = Data(#"{"ok": false, "error": {"code": "auth-required", "message": "bad key"}}"#.utf8)
        #expect(throws: AmpUsageError.authRejected) {
            try AmpUsageMapper.report(from: body, fetchedAt: Self.now)
        }
    }

    @Test("an ok response with no parseable lines is invalid")
    func unrecognizedText() {
        let body = Self.envelope("Signed in as person@example.com")
        #expect(throws: AmpUsageError.invalidResponse) {
            try AmpUsageMapper.report(from: body, fetchedAt: Self.now)
        }
    }
}

@Suite("Amp provider")
struct AmpAgentUsageProviderTests {
    @Test("a 401 surfaces as expired auth")
    func unauthorized() async throws {
        let file = try TemporaryCredentialFile(relativePath: "secrets.json", contents: """
        {"apiKey@https://ampcode.com/": "amp-test-key"}
        """)
        defer { file.remove() }

        var provider = AmpAgentUsageProvider()
        provider.authStore = AmpAuthStore(secretsFileURL: file.url, environment: [:])
        provider.client = StubHTTPClient(status: 401)

        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure == .authExpired("Amp rejected the saved API key. Run `amp login` to refresh it."))
    }

    @Test("the request posts the JSON-RPC method with a bearer token")
    func requestShape() async throws {
        let file = try TemporaryCredentialFile(relativePath: "secrets.json", contents: """
        {"apiKey@https://ampcode.com/": "amp-test-key"}
        """)
        defer { file.remove() }

        let captured = RequestRecorder()
        var provider = AmpAgentUsageProvider()
        provider.authStore = AmpAuthStore(secretsFileURL: file.url, environment: [:])
        provider.client = StubHTTPClient { request in
            captured.record(request)
            return AgentUsageHTTPResponse(
                statusCode: 200, headers: [:],
                body: Data(#"{"ok": true, "result": {"displayText": "Amp Free: 42% remaining today"}}"#.utf8))
        }

        let result = await provider.fetchUsage()
        guard case .success = result else {
            Issue.record("expected success")
            return
        }
        let request = try #require(captured.lastRequest)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://ampcode.com/api/internal")
        #expect(request.headers["Authorization"] == "Bearer amp-test-key")
        let body = try JSONSerialization.jsonObject(with: #require(request.body)) as? [String: Any]
        #expect(body?["method"] as? String == "userDisplayBalanceInfo")
    }
}
