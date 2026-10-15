import Foundation
import Testing
@testable import AgentUsage

@Suite("Grok usage mapping")
struct GrokUsageMapperTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func credentials(email: String? = "person@example.com") -> GrokCredentials {
        GrokCredentials(
            accessToken: "test-token",
            refreshToken: "test-refresh",
            expiresAt: now.addingTimeInterval(3_600),
            clientID: "client-test",
            entryKey: "https://auth.x.ai::client-test",
            issuerURL: URL(string: "https://auth.x.ai"),
            principalType: nil,
            principalID: nil,
            email: email,
            displayName: "Test Person",
            teamID: nil,
            loginMethod: "SuperGrok"
        )
    }

    /// proto-JSON: an absent zero field is a real zero, so callers build the
    /// payload without it.
    private static func creditsJSON(
        periodType: String = "USAGE_PERIOD_TYPE_WEEKLY",
        percent: String? = "99.0",
        cap: String? = #"{"val": 2500}"#
    ) -> Data {
        Data("""
        {
          "config": {
            \(percent.map { "\"creditUsagePercent\": \($0)," } ?? "")
            "currentPeriod": {
              "type": "\(periodType)",
              "start": "2026-07-03T04:01:09.238389+00:00",
              "end": "2026-07-10T04:01:09.238389+00:00"
            }\(cap.map { ",\n    \"onDemandCap\": \($0)" } ?? ""),
            "isUnifiedBillingUser": true
          }
        }
        """.utf8)
    }

    @Test("oversized caps are rejected before integer formatting", arguments: ["1e100", "9223372036854775808"])
    func oversizedCap(value: String) {
        #expect(throws: AgentUsageClientError.invalidResponse) {
            try GrokUsageMapper.decodeCreditsConfig(Self.creditsJSON(cap: "{\"val\":\(value)}"))
        }
    }

    @Test("the shared weekly pool maps to one weekly meter with its reset time")
    func weeklyPool() throws {
        let config = try GrokUsageMapper.decodeCreditsConfig(Self.creditsJSON())
        #expect(config.periodType == GrokUsageMapper.weeklyPeriodType)
        #expect(config.usedPercent == 99)
        #expect(config.windowSeconds == 7 * 86_400)

        let report = GrokUsageMapper.report(
            config: config, credentials: Self.credentials(), plan: "SuperGrok", fetchedAt: Self.now)
        #expect(report.providerID == .grok)
        #expect(report.accountLabel == "person@example.com")
        #expect(report.plan == "SuperGrok")
        #expect(report.metrics.map(\.id) == ["weekly", "pay-as-you-go"])
        // Two rows: the detail pane keeps them flat rather than heading each.
        #expect(report.groups.map(\.section) == [.limits, .creditsAndResets])
        #expect(!report.showsSectionHeaders)
        guard case let .progress(used, limit, format, resetsAt, windowSeconds) = report.metrics[0].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 99)
        #expect(limit == 100)
        #expect(format == .percent)
        #expect(resetsAt == AgentUsageISO8601.date(from: "2026-07-10T04:01:09.238389+00:00"))
        #expect(windowSeconds == 7 * 86_400)
    }

    @Test("an account still on the old monthly billing reports no weekly number")
    func monthlyAccount() throws {
        let config = try GrokUsageMapper.decodeCreditsConfig(
            Self.creditsJSON(periodType: "USAGE_PERIOD_TYPE_MONTHLY"))
        let report = GrokUsageMapper.report(
            config: config, credentials: Self.credentials(), plan: nil, fetchedAt: Self.now)
        #expect(report.metrics.first?.value == .badge("No data"))
        #expect(report.metrics.first?.title == "Weekly Limit")
    }

    @Test("a missing percent is a real zero, a non-numeric one is schema drift")
    func percentHandling() throws {
        let absent = try GrokUsageMapper.decodeCreditsConfig(Self.creditsJSON(percent: nil))
        #expect(absent.usedPercent == 0)

        #expect(throws: AgentUsageClientError.invalidResponse) {
            try GrokUsageMapper.decodeCreditsConfig(Self.creditsJSON(percent: "\"99\""))
        }
    }

    @Test("the pay-as-you-go row is a cap badge or a Disabled badge")
    func payAsYouGo() throws {
        let capped = try GrokUsageMapper.decodeCreditsConfig(Self.creditsJSON())
        #expect(capped.onDemandCap == 2500)
        let cappedReport = GrokUsageMapper.report(
            config: capped, credentials: Self.credentials(), plan: nil, fetchedAt: Self.now)
        #expect(cappedReport.metrics.last?.value == .badge("2500 cap"))

        // proto-JSON drops a zero cap entirely.
        let disabled = try GrokUsageMapper.decodeCreditsConfig(Self.creditsJSON(cap: nil))
        #expect(disabled.onDemandCap == 0)
        let disabledReport = GrokUsageMapper.report(
            config: disabled, credentials: Self.credentials(), plan: nil, fetchedAt: Self.now)
        #expect(disabledReport.metrics.last?.value == .badge("Disabled"))
    }

    @Test("a period that does not move forward is rejected")
    func backwardsPeriod() {
        let body = Data("""
        {"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
          "start": "2026-07-10T04:01:09Z", "end": "2026-07-03T04:01:09Z"}}}
        """.utf8)
        #expect(throws: AgentUsageClientError.invalidResponse) {
            try GrokUsageMapper.decodeCreditsConfig(body)
        }
    }

    @Test("plan names come from the settings payload")
    func planName() {
        let body = Data(#"{"subscription_tier_display": "SuperGrok", "other": 1}"#.utf8)
        #expect(GrokUsageMapper.planName(fromSettings: body) == "SuperGrok")
        #expect(GrokUsageMapper.planName(fromSettings: Data("{}".utf8)) == nil)
        #expect(GrokUsageMapper.planName(fromSettings: Data("[]".utf8)) == nil)
    }

    @Test("a bare payload with no config is rejected")
    func missingConfig() {
        #expect(throws: AgentUsageClientError.invalidResponse) {
            try GrokUsageMapper.decodeCreditsConfig(Data("{}".utf8))
        }
    }
}

@Suite("Grok usage client")
struct GrokUsageClientTests {
    @Test("a rejected token surfaces as unauthorized")
    func unauthorized() async {
        let client = GrokUsageClient(client: StubHTTPClient(status: 401))
        await #expect(throws: AgentUsageClientError.unauthorized) {
            try await client.fetchCredits(accessToken: "test-token")
        }
    }

    @Test("the CLI's token header is sent alongside the bearer token")
    func headers() async throws {
        let captured = HeaderRecorder()
        let client = GrokUsageClient(client: StubHTTPClient(handler: { request in
            captured.record(request.headers)
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }))
        _ = try await client.fetchCredits(accessToken: "test-token")
        #expect(captured.headers["Authorization"] == "Bearer test-token")
        #expect(captured.headers["X-XAI-Token-Auth"] == "xai-grok-cli")
    }

    @Test("refresh discovers the token endpoint and sends the CLI's OIDC fields")
    func refresh() async throws {
        let requests = GrokRequestRecorder()
        let client = GrokUsageClient(client: StubHTTPClient { request in
            requests.record(request)
            if request.method == "GET" {
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"token_endpoint":"https://auth.x.ai/oauth2/token"}"#.utf8))
            }
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        })
        let response = try await client.refresh(credentials: Self.credentials)

        #expect(response.accessToken == "new-token")
        #expect(response.refreshToken == "new-refresh")
        #expect(requests.requests.map(\.url.absoluteString) == [
            "https://auth.x.ai/.well-known/openid-configuration",
            "https://auth.x.ai/oauth2/token",
        ])
        let tokenRequest = try #require(requests.requests.last)
        #expect(tokenRequest.method == "POST")
        #expect(String(decoding: try #require(tokenRequest.body), as: UTF8.self) ==
            "client_id=client-test&grant_type=refresh_token&principal_id=person-1&principal_type=user&refresh_token=test-refresh")
    }

    @Test("an invalid refresh grant surfaces as unauthorized")
    func invalidGrant() async {
        let client = GrokUsageClient(client: Self.refreshClient(
            status: 400, body: #"{"error":"invalid_grant"}"#))

        await #expect(throws: AgentUsageClientError.unauthorized) {
            try await client.refresh(credentials: Self.credentials)
        }
    }

    @Test("an unrecognized refresh error retains its HTTP status")
    func unrecognizedRefreshError() async {
        let client = GrokUsageClient(client: Self.refreshClient(
            status: 400, body: #"{"error":"temporarily_unavailable"}"#))

        await #expect(throws: AgentUsageClientError.http(400)) {
            try await client.refresh(credentials: Self.credentials)
        }
    }

    private static func refreshClient(status: Int, body: String) -> StubHTTPClient {
        StubHTTPClient { request in
            if request.method == "GET" {
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"token_endpoint":"https://auth.x.ai/oauth2/token"}"#.utf8))
            }
            return AgentUsageHTTPResponse(
                statusCode: status, headers: [:], body: Data(body.utf8))
        }
    }

    private static let credentials = GrokCredentials(
        accessToken: "test-token",
        refreshToken: "test-refresh",
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
        clientID: "client-test",
        entryKey: "https://auth.x.ai::client-test",
        issuerURL: URL(string: "https://auth.x.ai"),
        principalType: "user",
        principalID: "person-1",
        email: nil,
        displayName: nil,
        teamID: nil,
        loginMethod: nil
    )
}

private final class GrokRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentUsageHTTPRequest] = []

    var requests: [AgentUsageHTTPRequest] {
        lock.withLock { stored }
    }

    func record(_ request: AgentUsageHTTPRequest) {
        lock.withLock { stored.append(request) }
    }
}

@MainActor
@Suite("Grok provider deadline")
struct GrokProviderDeadlineTests {
    @Test("slow optional settings cannot discard decoded credits")
    func optionalSettingsDeadline() async throws {
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {"https://auth.x.ai::test-client": {
            "key": "test-token", "refresh_token": "test-refresh",
            "expires_at": "2030-01-01T00:00:00Z"
        }}
        """)
        defer { file.remove() }
        let defaults = UserDefaults(suiteName: "com.spike.prism.tests.grok.deadline.\(UUID().uuidString)")!
        let controller = AgentUsageController(
            providers: [GrokAgentUsageProvider(
                authStore: GrokAuthStore(authFilePath: file.url),
                client: SlowGrokSettingsClient())],
            preferences: AgentUsagePreferencesStore())

        AgentUsageTiming.$current.withValue(.testing) { controller.refresh(force: true) }
        await controller.waitForPendingRefresh()

        let row = try #require(controller.row(for: .grok))
        #expect(row.failure == nil)
        #expect(!row.metrics.isEmpty)
        #expect(row.fetchedAt != nil)
    }
}

private struct SlowGrokSettingsClient: AgentUsageHTTPClient {
    func send(_ request: AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse {
        let body: String
        if request.url == GrokUsageClient.settingsURL {
            try await Task.sleep(for: .seconds(2.5))
            body = #"{"subscription_tier_display":"SuperGrok"}"#
        } else {
            try await Task.sleep(for: .seconds(1))
            body = #"{"config":{"creditUsagePercent":42,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-03T04:01:09Z","end":"2026-07-10T04:01:09Z"}}}"#
        }
        return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

@Suite("Grok credential renewal")
struct GrokCredentialRenewalTests {
    @Test("an expired token is renewed and rotated credentials are persisted")
    func renewsExpiredToken() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = """
        {"https://auth.x.ai::test": {
            "key":"saved-token", "refresh_token":"shared-refresh", "expires_at":"2020-01-01T00:00:00Z"
        }}
        """
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: original)
        defer { file.remove() }
        let provider = GrokAgentUsageProvider(
            authStore: GrokAuthStore(authFilePath: file.url, now: { now }),
            client: StubHTTPClient { request in
                if request.url.absoluteString.hasSuffix("/.well-known/openid-configuration") {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                        #"{"token_endpoint":"https://auth.x.ai/oauth2/token"}"#.utf8))
                }
                if request.url.absoluteString == "https://auth.x.ai/oauth2/token" {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                        #"{"access_token":"renewed-token","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8))
                }
                #expect(request.headers["Authorization"] == "Bearer renewed-token")
                if request.url == GrokUsageClient.creditsURL {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"config":{"creditUsagePercent":42,"currentPeriod":{
                        "type":"USAGE_PERIOD_TYPE_WEEKLY",
                        "start":"2026-07-03T04:01:09Z","end":"2026-07-10T04:01:09Z"}}}
                    """.utf8))
                }
                #expect(request.url == GrokUsageClient.settingsURL)
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }, now: { now })

        let report = try await provider.fetchUsage().get()
        #expect(!report.metrics.isEmpty)
        let stored = try #require(file.text())
        #expect(stored.contains("renewed-token"))
        #expect(stored.contains("rotated-refresh"))
        #expect(!stored.contains("saved-token"))
        #expect(Set(try FileManager.default.contentsOfDirectory(
            atPath: file.url.deletingLastPathComponent().path)) == ["auth.json", "auth.json.lock"])
        let lockText = try String(contentsOf: file.url.appendingPathExtension("lock"), encoding: .utf8)
        #expect(lockText.split(separator: ":").count == 2)
    }

    @Test("a rejected token adopts credentials concurrently renewed by the CLI")
    func adoptsCLIUpdate() async throws {
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {"https://accounts.x.ai/sign-in":{"key":"old-token"}}
        """)
        defer { file.remove() }
        let updated = #"{"https://auth.x.ai::test":{"key":"cli-token","refresh_token":"cli-refresh"}}"#
        let requests = GrokRequestRecorder()
        let provider = GrokAgentUsageProvider(
            authStore: GrokAuthStore(authFilePath: file.url),
            client: StubHTTPClient { request in
                requests.record(request)
                if request.url == GrokUsageClient.creditsURL,
                   request.headers["Authorization"] == "Bearer old-token"
                {
                    try updated.write(to: file.url, atomically: true, encoding: .utf8)
                    return AgentUsageHTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                if request.url == GrokUsageClient.creditsURL {
                    #expect(request.headers["Authorization"] == "Bearer cli-token")
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"config":{"creditUsagePercent":42,"currentPeriod":{
                        "type":"USAGE_PERIOD_TYPE_WEEKLY",
                        "start":"2026-07-03T04:01:09Z","end":"2026-07-10T04:01:09Z"}}}
                    """.utf8))
                }
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            })

        let report = try await provider.fetchUsage().get()

        #expect(!report.metrics.isEmpty)
        #expect(file.text() == updated)
        #expect(!requests.requests.contains { $0.method == "POST" })
    }

    @Test("a transient refresh failure is not reported as an expired login")
    func preservesRefreshFailure() async throws {
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {"https://auth.x.ai::test":{"key":"old-token","refresh_token":"old-refresh"}}
        """)
        defer { file.remove() }
        let provider = GrokAgentUsageProvider(
            authStore: GrokAuthStore(authFilePath: file.url),
            client: StubHTTPClient { request in
                if request.url == GrokUsageClient.creditsURL {
                    return AgentUsageHTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                #expect(request.url.absoluteString.hasSuffix("/.well-known/openid-configuration"))
                return AgentUsageHTTPResponse(statusCode: 503, headers: [:], body: Data())
            })

        let result = await provider.fetchUsage()

        #expect(result == .failure(.network(
            "Grok usage request failed (HTTP 503). Try again in a moment.")))
    }
}
