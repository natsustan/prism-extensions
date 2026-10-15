import Foundation
import Testing
@testable import AgentUsage

/// Fixtures are synthetic: the shapes mirror the live endpoints, the numbers and
/// accounts do not come from any real login.
@Suite("Claude usage mapping")
struct ClaudeUsageMapperTests {
    private static let credentials = ClaudeCredentials(
        accessToken: "test-access-token",
        expiresAt: nil,
        scopes: ["user:inference", "user:profile"],
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_20x"
    )

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func usageBody(
        sevenDaySonnet: String = "null",
        limits: String = "[]",
        extraUsage: String = #"{"is_enabled": false, "monthly_limit": null, "used_credits": null}"#
    ) -> Data {
        Data("""
        {
          "five_hour": {"utilization": 61.0, "resets_at": "2026-10-10T16:19:59.584480+00:00"},
          "seven_day": {"utilization": 8.0, "resets_at": "2026-10-14T01:59:59+00:00"},
          "seven_day_opus": null,
          "seven_day_sonnet": \(sevenDaySonnet),
          "iguana_necktie": {"utilization": 99.0, "resets_at": null},
          "extra_usage": \(extraUsage),
          "limits": \(limits)
        }
        """.utf8)
    }

    @Test("account windows map to the 5h and weekly meters with their reset times")
    func accountWindows() throws {
        let report = try ClaudeUsageMapper.report(
            from: Self.usageBody(), profile: nil, credentials: Self.credentials, fetchedAt: Self.now)

        #expect(report.providerID == .claude)
        #expect(report.plan == "Max 20x")
        #expect(report.primaryMetric?.id == "session")
        #expect(report.metrics.map(\.id) == ["session", "weekly", "extra-usage"])
        guard case let .progress(used, limit, format, resetsAt, windowSeconds) = report.metrics[0].value else {
            Issue.record("expected a progress meter")
            return
        }
        #expect(used == 61)
        #expect(limit == 100)
        #expect(format == .percent)
        #expect(resetsAt == AgentUsageISO8601.date(from: "2026-10-10T16:19:59.584480+00:00"))
        #expect(windowSeconds == ClaudeUsageMapper.sessionWindowSeconds)
        #expect(report.metrics[2].value == .badge("Off"))
    }

    @Test("per-model weekly windows come from both shapes, one row per model")
    func scopedWeeklyWindows() throws {
        let limits = """
            [{"kind": "weekly_all", "group": "weekly", "percent": 8, "scope": null},
             {"kind": "weekly_scoped", "group": "weekly", "percent": 40,
              "resets_at": "2026-10-14T01:59:59+00:00",
              "scope": {"model": {"id": "x", "display_name": "Sonnet"}}},
             {"kind": "weekly_scoped", "group": "weekly", "percent": 12,
              "scope": {"model": {"id": "y", "display_name": "Fable"}}}]
            """
        let report = try ClaudeUsageMapper.report(
            from: Self.usageBody(
                sevenDaySonnet: #"{"utilization": 39, "resets_at": null}"#, limits: limits),
            profile: nil,
            credentials: Self.credentials,
            fetchedAt: Self.now
        )
        let perModel = report.metrics.filter { $0.section == .perModel }
        #expect(perModel.map(\.title) == ["Sonnet Weekly", "Fable Weekly"])
        guard case let .progress(used, _, _, _, _) = perModel[0].value else {
            Issue.record("expected a progress meter")
            return
        }
        #expect(used == 40)
        #expect(Set(report.metrics.map(\.id)).count == report.metrics.count)
    }

    @Test("the flat Fable weekly window maps its quota and reset time")
    func flatFableWindow() throws {
        let report = try ClaudeUsageMapper.report(
            from: Data("""
                {"seven_day_overage_included": {
                    "utilization": 83, "resets_at": "2026-10-14T01:59:59+00:00"
                }}
                """.utf8),
            profile: nil, credentials: Self.credentials, fetchedAt: Self.now)
        let metric = try #require(report.metrics.first)
        #expect(report.metrics.count == 1)
        #expect(metric.id == "weekly-fable-5")
        #expect(metric.title == "Fable 5 Weekly")
        #expect(metric.section == .perModel)
        #expect(metric.value == .progress(
            used: 83, limit: 100, format: .percent,
            resetsAt: AgentUsageISO8601.date(from: "2026-10-14T01:59:59+00:00"),
            windowSeconds: ClaudeUsageMapper.weeklyWindowSeconds))
    }

    @Test("generic Fable limits take precedence over the flat fallback", arguments: [
        "Fable", "Fable 5", "fAbLe 5",
    ])
    func genericFableWins(name: String) throws {
        let report = try ClaudeUsageMapper.report(
            from: Data("""
                {"seven_day_overage_included": {"utilization": 83, "resets_at": null},
                 "limits": [{"kind": "weekly_scoped", "percent": 12,
                             "scope": {"model": {"display_name": "\(name)"}}}]}
                """.utf8),
            profile: nil, credentials: Self.credentials, fetchedAt: Self.now)
        let metric = try #require(report.metrics.first)
        #expect(report.metrics.count == 1)
        #expect(metric.title == "\(name) Weekly")
        #expect(metric.value == .progress(
            used: 12, limit: 100, format: .percent,
            resetsAt: nil, windowSeconds: ClaudeUsageMapper.weeklyWindowSeconds))
    }

    @Test("an absent or unusable flat Fable window adds no metric", arguments: [
        "{}", #"{"seven_day_overage_included": null}"#,
        #"{"seven_day_overage_included": {}}"#,
    ])
    func absentFableWindow(body: String) throws {
        let root = try #require(AgentUsageParse.jsonObject(Data(body.utf8)))
        #expect(ClaudeUsageMapper.scopedWeeklyMetrics(root).isEmpty)
    }

    @Test("the limits array supplies the 5h and weekly meters ahead of the flat windows")
    func limitsArrayWindows() throws {
        let limits = """
            [{"kind": "session", "group": "session", "percent": 72,
              "resets_at": "2026-10-10T18:00:00+00:00", "scope": null},
             {"kind": "weekly_all", "group": "weekly", "percent": 15,
              "resets_at": "2026-10-14T01:59:59+00:00", "scope": null}]
            """
        let report = try ClaudeUsageMapper.report(
            from: Self.usageBody(limits: limits), profile: nil, credentials: Self.credentials, fetchedAt: Self.now)
        #expect(report.metrics.map(\.id) == ["session", "weekly", "extra-usage"])
        #expect(report.metrics[0].value == .progress(
            used: 72, limit: 100, format: .percent,
            resetsAt: AgentUsageISO8601.date(from: "2026-10-10T18:00:00+00:00"),
            windowSeconds: ClaudeUsageMapper.sessionWindowSeconds))
        #expect(report.metrics[1].value == .progress(
            used: 15, limit: 100, format: .percent,
            resetsAt: AgentUsageISO8601.date(from: "2026-10-14T01:59:59+00:00"),
            windowSeconds: ClaudeUsageMapper.weeklyWindowSeconds))

        let limitsOnly = Data("""
            {"limits": [{"kind": "session", "group": "session", "percent": 30, "resets_at": null},
                        {"kind": "weekly_all", "group": "weekly", "percent": 4, "resets_at": null}]}
            """.utf8)
        let limitsOnlyReport = try ClaudeUsageMapper.report(
            from: limitsOnly, profile: nil, credentials: Self.credentials, fetchedAt: Self.now)
        #expect(limitsOnlyReport.metrics.map(\.id) == ["session", "weekly"])
    }

    @Test("an object without any quota rows is rejected so stale data is kept", arguments: [
        "{}",
        #"{"type": "error", "error": {"type": "permission_error", "message": "denied"}}"#,
        #"{"extra_usage": {"is_enabled": false}, "limits": []}"#,
    ])
    func noQuotaRows(body: String) {
        #expect(throws: AgentUsageClientError.invalidResponse) {
            try ClaudeUsageMapper.report(
                from: Data(body.utf8), profile: nil, credentials: Self.credentials, fetchedAt: Self.now)
        }
    }

    @Test("the profile's organization tier names the plan ahead of the cached credential")
    func profilePlan() throws {
        let stale = ClaudeCredentials(
            accessToken: "t", expiresAt: nil, scopes: nil,
            subscriptionType: "max", rateLimitTier: "default_claude_max_5x")
        let profile = Data("""
            {"account": {"email": "person@example.com"},
             "organization": {"organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x"}}
            """.utf8)
        let report = try ClaudeUsageMapper.report(
            from: Self.usageBody(), profile: profile, credentials: stale, fetchedAt: Self.now)
        #expect(report.plan == "Max 20x")

        let unknownOrganization = Data(#"{"organization": {"organization_type": "something_new"}}"#.utf8)
        let fallback = try ClaudeUsageMapper.report(
            from: Self.usageBody(), profile: unknownOrganization, credentials: stale, fetchedAt: Self.now)
        #expect(fallback.plan == "Max 5x")

        let tierless = Data(#"{"organization": {"organization_type": "claude_max"}}"#.utf8)
        let credentialTier = try ClaudeUsageMapper.report(
            from: Self.usageBody(), profile: tierless, credentials: stale, fetchedAt: Self.now)
        #expect(credentialTier.plan == "Max 5x")
    }

    @Test("enabled extra usage reads minor units as dollars against the monthly cap")
    func extraUsage() throws {
        let report = try ClaudeUsageMapper.report(
            from: Self.usageBody(extraUsage: """
                {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1234,
                 "currency": "USD", "decimal_places": 2}
                """),
            profile: nil,
            credentials: Self.credentials,
            fetchedAt: Self.now
        )
        let metric = try #require(report.metrics.first { $0.id == "extra-usage" })
        #expect(metric.section == .creditsAndResets)
        #expect(metric.value == .progress(
            used: 12.34, limit: 50, format: .currency, resetsAt: nil, windowSeconds: nil))
    }

    @Test("the profile email labels the account; a malformed body is rejected")
    func profileAndInvalidBody() throws {
        let profile = Data(#"{"account": {"email": "person@example.com"}}"#.utf8)
        let report = try ClaudeUsageMapper.report(
            from: Self.usageBody(), profile: profile, credentials: Self.credentials, fetchedAt: Self.now)
        #expect(report.accountLabel == "person@example.com")

        #expect(throws: AgentUsageClientError.invalidResponse) {
            try ClaudeUsageMapper.report(
                from: Data("[]".utf8), profile: nil, credentials: Self.credentials, fetchedAt: Self.now)
        }
    }

    @Test("plan names", arguments: [
        ("pro", nil, "Pro"),
        ("max", "default_claude_max_5x", "Max 5x"),
        ("max", "default_claude_ai", "Max"),
        ("team", nil, "Team"),
    ] as [(String, String?, String)])
    func planNames(subscription: String, tier: String?, expected: String) {
        #expect(ClaudeUsageMapper.planName(subscriptionType: subscription, rateLimitTier: tier) == expected)
    }
}

@Suite("Claude credentials")
struct ClaudeAuthStoreTests {
    private static let record = """
        {"claudeAiOauth": {"accessToken": "keychain-token", "refreshToken": "r",
         "expiresAt": 1700000000000, "scopes": ["user:inference", "user:profile"],
         "subscriptionType": "pro", "rateLimitTier": "default_claude_ai"}}
        """

    @Test("the Keychain item wins over the credentials file")
    func keychainFirst() async throws {
        let file = try TemporaryCredentialFile(
            relativePath: ".credentials.json",
            contents: #"{"claudeAiOauth":{"accessToken":"file-token"}}"#)
        defer { file.remove() }
        let store = ClaudeAuthStore(
            environment: ["CLAUDE_CONFIG_DIR": file.directory.path],
            readKeychainSecret: { _ in Data(Self.record.utf8) },
            keychainItemExists: { _ in true })

        let credentials = try await store.loadCredentials()
        #expect(credentials.accessToken == "keychain-token")
        #expect(credentials.subscriptionType == "pro")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(credentials.canReadUsage)
    }

    @Test("without a Keychain item the config directory's file is used")
    func fileFallback() async throws {
        let file = try TemporaryCredentialFile(
            relativePath: ".credentials.json",
            contents: #"{"claudeAiOauth":{"accessToken":"file-token"}}"#)
        defer { file.remove() }
        let store = ClaudeAuthStore(
            environment: ["CLAUDE_CONFIG_DIR": file.directory.path],
            readKeychainSecret: { _ in nil },
            keychainItemExists: { _ in false })

        #expect(store.hasCredentials())
        #expect(try await store.loadCredentials().accessToken == "file-token")
    }

    @Test("a custom config directory selects a hashed Keychain service")
    func keychainServiceName() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(ClaudeAuthStore(environment: [:], homeDirectory: home).keychainServiceName
            == "Claude Code-credentials")
        let custom = ClaudeAuthStore(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude"], homeDirectory: home)
        #expect(custom.keychainServiceName == "Claude Code-credentials-21493821")
    }

    @Test("the secure-storage override selects the Keychain service and credentials directory")
    func secureStorageOverride() {
        let home = URL(fileURLWithPath: "/Users/test")
        let secure = ClaudeAuthStore(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/secure"],
            homeDirectory: home)
        #expect(secure.keychainServiceName == "Claude Code-credentials-7f494bd1")
        #expect(secure.credentialsFileURL.path == "/tmp/secure/.credentials.json")

        let empty = ClaudeAuthStore(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""],
            homeDirectory: home)
        #expect(empty.keychainServiceName == "Claude Code-credentials")
        #expect(empty.credentialsFileURL.path == "/Users/test/.claude/.credentials.json")
    }

    @Test("the Keychain hash uses the NFC form of the directory, like Claude Code")
    func keychainServiceNormalization() {
        let decomposed = ClaudeAuthStore(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cafe\u{0301}"])
        let composed = ClaudeAuthStore(environment: ["CLAUDE_CONFIG_DIR": "/tmp/caf\u{00E9}"])
        #expect(decomposed.keychainServiceName == composed.keychainServiceName)
    }

    @Test("a cancelled Keychain lookup is not mistaken for a missing item")
    func cancelledKeychainLookup() async throws {
        let file = try TemporaryCredentialFile(
            relativePath: ".credentials.json",
            contents: #"{"claudeAiOauth":{"accessToken":"file-token"}}"#)
        defer { file.remove() }
        let store = ClaudeAuthStore(
            environment: ["CLAUDE_CONFIG_DIR": file.directory.path],
            readKeychainSecret: { _ in
                try? await Task.sleep(for: .seconds(60))
                return nil
            },
            keychainItemExists: { _ in true })

        let task = Task { try await store.loadCredentials() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("cancelling the security tool lookup terminates the subprocess")
    func securityToolCancellation() async {
        let lookup = SecurityToolLookup(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let started = ContinuousClock.now
        let task = Task {
            await withTaskCancellationHandler(
                operation: { await lookup.run() },
                onCancel: { lookup.cancel() })
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("no Keychain item and no file means not signed in")
    func notLoggedIn() async {
        let store = ClaudeAuthStore(
            environment: ["CLAUDE_CONFIG_DIR": "/nonexistent/prism-claude-tests"],
            readKeychainSecret: { _ in nil },
            keychainItemExists: { _ in false })
        #expect(!store.hasCredentials())
        await #expect(throws: ClaudeAuthError.notLoggedIn) { try await store.loadCredentials() }
    }
}

@Suite("Claude usage provider")
struct ClaudeAgentUsageProviderTests {
    private static func provider(
        record: String = #"{"claudeAiOauth":{"accessToken":"saved-token","scopes":["user:profile"]}}"#,
        client: any AgentUsageHTTPClient
    ) -> ClaudeAgentUsageProvider {
        ClaudeAgentUsageProvider(
            authStore: ClaudeAuthStore(
                environment: ["CLAUDE_CONFIG_DIR": "/nonexistent/prism-claude-tests"],
                readKeychainSecret: { _ in Data(record.utf8) },
                keychainItemExists: { _ in true }),
            client: client)
    }

    @Test("sends the bearer token and OAuth beta header to the usage endpoint")
    func requestShape() async throws {
        let recorder = RequestRecorder()
        let client = StubHTTPClient { request in
            recorder.record(request)
            let body = request.url == ClaudeUsageClient.usageURL
                ? #"{"five_hour": {"utilization": 10, "resets_at": null}}"#
                : #"{"account": {"email": "person@example.com"}}"#
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }

        let report = try await Self.provider(client: client).fetchUsage().get()
        let usageRequest = try #require(recorder.requests.first)
        #expect(usageRequest.url == ClaudeUsageClient.usageURL)
        #expect(usageRequest.headers["Authorization"] == "Bearer saved-token")
        #expect(usageRequest.headers["anthropic-beta"] == ClaudeUsageClient.betaHeader)
        #expect(report.accountLabel == "person@example.com")
        #expect(report.metrics.map(\.id) == ["session"])
    }

    @Test("a rejected token asks for `claude`; rate limiting reads as retryable")
    func failures() async {
        let unauthorized = await Self.provider(client: StubHTTPClient(status: 401)).fetchUsage()
        #expect(unauthorized.failureValue?.shortStatusText == "Sign In")
        #expect(unauthorized.failureValue?.message.contains("`claude`") == true)

        let limited = await Self.provider(client: StubHTTPClient(status: 429)).fetchUsage()
        #expect(limited.failureValue?.message.contains("rate limiting") == true)
    }

    @Test("an inference-only token never reaches the network")
    func inferenceOnlyToken() async {
        let flag = FlagRecorder()
        let client = StubHTTPClient { _ in
            flag.set()
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let result = await Self.provider(
            record: #"{"claudeAiOauth":{"accessToken":"t","scopes":["user:inference"]}}"#,
            client: client
        ).fetchUsage()
        #expect(result.failureValue?.isMissingCredentials == true)
        #expect(!flag.isSet)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}
