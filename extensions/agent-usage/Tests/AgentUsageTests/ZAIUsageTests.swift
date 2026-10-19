import Foundation
import Testing
@testable import AgentUsage

@Suite("Z.ai auth store")
struct ZAIAuthStoreTests {
    @Test("a key saved in Prism wins over the environment and files")
    func storedKeyWins() throws {
        let store = ZAIAuthStore(
            environment: ["ZAI_API_KEY": "env-key"],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"),
            storedKey: { " settings-key " })
        #expect(try store.loadCredentials().apiKey == "settings-key")
    }

    @Test("a blank saved key falls through to the environment")
    func blankStoredKeyFallsThrough() throws {
        let store = ZAIAuthStore(
            environment: ["ZAI_API_KEY": "env-key"],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"),
            storedKey: { "  " })
        #expect(try store.loadCredentials().apiKey == "env-key")
    }

    @Test("a stored-key read error cannot fall through to another credential")
    func storedKeyReadFailureStopsFallback() {
        let store = ZAIAuthStore(
            environment: ["ZAI_API_KEY": "different-account-key"],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"),
            storedKey: { throw ZAISecretReadFailure.unavailable })
        #expect(throws: ZAISecretReadFailure.self) { try store.loadCredentials() }
    }

    @Test("the environment wins over every file source")
    func environmentWins() throws {
        let config = try TemporaryCredentialFile(relativePath: "key.json", contents: """
        {"apiKey": "config-key"}
        """)
        defer { config.remove() }

        let store = ZAIAuthStore(
            environment: ["ZAI_API_KEY": "env-key"],
            configFileURL: config.url,
            claudeSettingsURL: config.directory.appendingPathComponent("absent/settings.json"))
        #expect(try store.loadCredentials().apiKey == "env-key")
    }

    @Test("GLM_API_KEY is the legacy fallback")
    func legacyEnvironmentName() throws {
        let store = ZAIAuthStore(
            environment: ["GLM_API_KEY": "glm-key"],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"))
        #expect(try store.loadCredentials().apiKey == "glm-key")
    }

    @Test("the config file accepts api_key and plain-text forms")
    func configFileShapes() throws {
        let jsonFile = try TemporaryCredentialFile(relativePath: "key.json", contents: """
        {"api_key": "json-key"}
        """)
        defer { jsonFile.remove() }
        var store = ZAIAuthStore(
            environment: [:],
            configFileURL: jsonFile.url,
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"))
        #expect(try store.loadAPIKey() == "json-key")

        let plainFile = try TemporaryCredentialFile(relativePath: "key.json", contents: "plain-key\n")
        defer { plainFile.remove() }
        store = ZAIAuthStore(
            environment: [:],
            configFileURL: plainFile.url,
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"))
        #expect(try store.loadAPIKey() == "plain-key")
    }

    @Test("a Claude settings env block counts only when its base URL is z.ai")
    func claudeSettings() throws {
        let settings = try TemporaryCredentialFile(relativePath: "settings.json", contents: """
        {"env": {"ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic", "ANTHROPIC_AUTH_TOKEN": "claude-key"}}
        """)
        defer { settings.remove() }
        var store = ZAIAuthStore(
            environment: [:],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: settings.url)
        #expect(try store.loadAPIKey() == "claude-key")

        let other = try TemporaryCredentialFile(relativePath: "settings.json", contents: """
        {"env": {"ANTHROPIC_BASE_URL": "https://api.anthropic.com", "ANTHROPIC_AUTH_TOKEN": "real-anthropic-key"}}
        """)
        defer { other.remove() }
        store = ZAIAuthStore(
            environment: [:],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: other.url)
        #expect(try store.loadAPIKey() == nil)
    }

    @Test("Claude's token is accepted only for an HTTPS z.ai host")
    func rejectsUnrelatedClaudeProxy() throws {
        let settings = try TemporaryCredentialFile(relativePath: "settings.json")
        defer { settings.remove() }
        let store = ZAIAuthStore(
            environment: [:],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: settings.url)

        for (baseURL, accepted) in [
            ("https://z.ai/api/anthropic", true),
            ("https://api.z.ai/api/anthropic", true),
            ("https://z.ai.example.com/api/anthropic", false),
            ("https://other.example.com/z.ai", false),
            ("https://z.ai@other.example.com/api", false),
            ("http://api.z.ai/api/anthropic", false),
        ] {
            try """
            {"env": {"ANTHROPIC_BASE_URL": "\(baseURL)", "ANTHROPIC_AUTH_TOKEN": "claude-key"}}
            """.write(to: settings.url, atomically: true, encoding: .utf8)
            #expect(try store.loadAPIKey() == (accepted ? "claude-key" : nil))
        }
    }
}

@Suite("Z.ai usage mapping")
struct ZAIUsageMapperTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("credit limits map to session and weekly meters")
    func mapsQuota() throws {
        let body = Data("""
        {"success": true, "data": {"limits": [
            {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 42.5, "nextResetTime": 1700018000000},
            {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "percentage": 80, "nextResetTime": 1700604800000},
            {"type": "TIME_LIMIT", "currentValue": 12, "usage": 100, "nextResetTime": 1701388800000}
        ]}}
        """.utf8)

        let metrics = try ZAIUsageMapper.mapQuota(body)
        #expect(metrics.count == 3)

        guard case let .progress(session, _, _, sessionReset, sessionWindow) = metrics[0].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(session == 42.5)
        #expect(sessionReset == Date(timeIntervalSince1970: 1_700_018_000))
        #expect(sessionWindow == 18_000)

        guard case let .progress(weekly, _, _, _, weeklyWindow) = metrics[1].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(weekly == 80)
        #expect(weeklyWindow == 604_800)

        guard case let .progress(used, limit, format, _, _) = metrics[2].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 12)
        #expect(limit == 100)
        #expect(format == .count)
    }

    @Test("a present zero percentage is a real measured zero")
    func zeroPercentage() throws {
        let body = Data("""
        {"success": true, "data": {"limits": [
            {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 0, "nextResetTime": 1700018000000}
        ]}}
        """.utf8)
        let metrics = try ZAIUsageMapper.mapQuota(body)
        guard case let .progress(used, _, _, _, _) = try #require(metrics.first).value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 0)
    }

    @Test("a 2xx success:false coding-plan body is detected")
    func noCodingPlan() {
        #expect(ZAIUsageMapper.isNoCodingPlan(Data(
            #"{"success": false, "code": 500, "msg": "no coding plan subscription"}"#.utf8)))
        #expect(!ZAIUsageMapper.isNoCodingPlan(Data(#"{"success": true}"#.utf8)))
        #expect(!ZAIUsageMapper.isNoCodingPlan(Data("not json".utf8)))
    }

    @Test("only unrecognized limit entries is drift, not an empty account")
    func allUnrecognized() {
        let body = Data("""
        {"success": true, "data": {"limits": [{"type": "FUTURE_LIMIT", "unit": 9, "number": 1}]}}
        """.utf8)
        #expect(throws: ZAIUsageError.invalidResponse) {
            try ZAIUsageMapper.mapQuota(body)
        }
    }

    @Test("the plan name comes from the first subscription entry")
    func planName() {
        let body = Data(#"{"data": [{"productName": "GLM Coding Max"}]}"#.utf8)
        #expect(ZAIUsageMapper.planName(from: body) == "GLM Coding Max")
        #expect(ZAIUsageMapper.planName(from: Data("{}".utf8)) == nil)
    }
}

@Suite("Z.ai provider")
struct ZAIAgentUsageProviderTests {
    @Test("the quota response becomes a report while the plan stays optional")
    func successPath() async throws {
        var provider = ZAIAgentUsageProvider()
        provider.authStore = ZAIAuthStore(
            environment: ["ZAI_API_KEY": "zai-key"],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"))
        provider.client = StubHTTPClient { request in
            if request.url.absoluteString.contains("subscription") {
                return AgentUsageHTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"data": [{"productName": "GLM Coding Lite"}]}"#.utf8))
            }
            #expect(request.headers["Authorization"] == "Bearer zai-key")
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
            {"success": true, "data": {"limits": [
                {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 10, "nextResetTime": 1700018000000}
            ]}}
            """.utf8))
        }

        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success")
            return
        }
        #expect(report.plan == "GLM Coding Lite")
        #expect(report.metrics.count == 1)
    }

    @Test("the no-coding-plan body is a configuration failure")
    func noPlan() async throws {
        var provider = ZAIAgentUsageProvider()
        provider.authStore = ZAIAuthStore(
            environment: ["ZAI_API_KEY": "zai-key"],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"))
        provider.client = StubHTTPClient(
            status: 200, body: #"{"success": false, "code": 500, "msg": "no coding plan"}"#)

        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .notConfigured = failure {} else {
            Issue.record("expected notConfigured, got \(failure)")
        }
    }
}

@MainActor
@Suite("Z.ai provider deadline")
struct ZAIProviderDeadlineTests {
    @Test("late quota survives slow or skipped subscription enrichment", arguments: [0.5, 2.6])
    func optionalSubscriptionDeadline(primaryDelay: Double) async throws {
        let recorder = RequestRecorder()
        var provider = ZAIAgentUsageProvider()
        provider.authStore = ZAIAuthStore(
            environment: ["ZAI_API_KEY": "test-key"],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"))
        provider.client = StubHTTPClient { request in
            recorder.record(request)
            if request.url == ZAIUsageClient.quotaURL {
                try await Task.sleep(for: .seconds(primaryDelay))
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":42}]}}"#.utf8))
            }
            try await Task.sleep(for: .seconds(4))
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let suite = "com.spike.prism.tests.zai.deadline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentUsageController(
            providers: [provider], preferences: AgentUsagePreferencesStore())
        AgentUsageTiming.$current.withValue(.testing) { controller.refresh(force: true) }
        await controller.waitForPendingRefresh()

        let row = try #require(controller.row(for: .zai))
        #expect(row.failure == nil)
        #expect(!row.metrics.isEmpty)
        #expect(row.fetchedAt != nil)
        #expect(recorder.requests.count == (primaryDelay < 2 ? 2 : 1))
    }
}

/// Shared by the settings-key tests so the controller and the provider read
/// one in-memory item instead of the login keychain.
private enum ZAISecretReadFailure: Error {
    case unavailable
}

final class InMemoryZAISecretStore: ZAISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var failuresRemaining: Int
    private let readFails: Bool

    init(stored: String? = nil, failuresRemaining: Int = 0, readFails: Bool = false) {
        self.stored = stored
        self.failuresRemaining = failuresRemaining
        self.readFails = readFails
    }

    func apiKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if readFails { throw ZAISecretReadFailure.unavailable }
        return stored
    }

    func setAPIKey(_ value: String) throws {
        let trimmed = value.trimmedCredentialValue.nilIfEmpty
        lock.lock()
        defer { lock.unlock() }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw CocoaError(.fileWriteNoPermission)
        }
        stored = trimmed
    }
}

@MainActor
@Suite("Z.ai settings key")
struct ZAISettingsKeyTests {
    private func makeProvider(
        secrets: InMemoryZAISecretStore, client: any AgentUsageHTTPClient
    ) -> ZAIAgentUsageProvider {
        var provider = ZAIAgentUsageProvider()
        provider.authStore = ZAIAuthStore(
            environment: [:],
            configFileURL: URL(fileURLWithPath: "/nonexistent"),
            claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"),
            storedKey: { try secrets.apiKey() })
        provider.client = client
        return provider
    }

    private func makeController(
        secrets: InMemoryZAISecretStore, client: any AgentUsageHTTPClient
    ) -> AgentUsageController {
        let suite = "com.spike.prism.tests.zai.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return AgentUsageController(
            providers: [makeProvider(secrets: secrets, client: client)],
            preferences: AgentUsagePreferencesStore(),
            zaiSecrets: secrets)
    }

    @Test("a Keychain read failure shows an error without using another account's key")
    func keychainReadFailureStopsRequests() async {
        let secrets = InMemoryZAISecretStore(stored: "settings-key", readFails: true)
        let recorder = RequestRecorder()
        var provider = makeProvider(secrets: secrets, client: StubHTTPClient { request in
            recorder.record(request)
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data())
        })
        provider.authStore.environment = ["ZAI_API_KEY": "different-account-key"]
        let defaults = UserDefaults(suiteName: "com.spike.prism.tests.zai.read.\(UUID().uuidString)")!
        let controller = AgentUsageController(
            providers: [provider],
            preferences: AgentUsagePreferencesStore(),
            zaiSecrets: secrets)

        #expect(controller.isEnabled(.zai))
        #expect(controller.readZAIAPIKey() == nil)
        #expect(controller.zaiAPIKeyReadError != nil)
        #expect(!controller.setZAIAPIKey(""))
        #expect(controller.failedZAIAPIKeyDraft == "")

        controller.refresh(force: true)
        await controller.waitForPendingRefresh()
        #expect(recorder.requests.isEmpty)
        #expect(controller.row(for: .zai)?.failure?.message.contains("Keychain") == true)
    }

    @Test("failed key changes retain the draft and state until a successful retry", arguments: [
        (nil as String?, "new-key"),
        ("old-key", "new-key"),
        ("old-key", ""),
    ])
    func failedKeyChange(scenario: (String?, String)) async throws {
        let (original, draft) = scenario
        let secrets = InMemoryZAISecretStore(stored: original, failuresRemaining: 1)
        let recorder = RequestRecorder()
        let controller = makeController(secrets: secrets, client: StubHTTPClient { request in
            recorder.record(request)
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"success":true,"data":{"limits":[]}}"#.utf8))
        })
        let wasEnabled = controller.isEnabled(.zai)
        let wasConfigured = controller.isConfigured(.zai)

        #expect(!controller.setZAIAPIKey(draft))
        #expect(try secrets.apiKey() == original)
        #expect(controller.failedZAIAPIKeyDraft == draft)
        #expect(controller.zaiAPIKeySaveError != nil)
        #expect(controller.isEnabled(.zai) == wasEnabled)
        #expect(controller.isConfigured(.zai) == wasConfigured)
        #expect(!controller.isRefreshing)
        #expect(recorder.requests.isEmpty)

        #expect(controller.setZAIAPIKey(draft))
        #expect(controller.failedZAIAPIKeyDraft == nil)
        #expect(controller.zaiAPIKeySaveError == nil)
        #expect(controller.readZAIAPIKey() == draft)
        #expect(controller.isConfigured(.zai) == !draft.isEmpty)
        await controller.waitForPendingRefresh()
    }

    @Test("a key already on disk counts as configured before one is saved in Prism")
    func fileKeyCountsAsConfigured() throws {
        let config = try TemporaryCredentialFile(relativePath: "key.json", contents: #"{"apiKey":"disk-key"}"#)
        defer { config.remove() }
        let secrets = InMemoryZAISecretStore()
        var provider = ZAIAgentUsageProvider()
        provider.authStore = ZAIAuthStore(
            environment: [:],
            configFileURL: config.url,
            claudeSettingsURL: config.directory.appendingPathComponent("absent/settings.json"),
            storedKey: { try secrets.apiKey() })
        let suite = "com.spike.prism.tests.zai.filekey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentUsageController(
            providers: [provider],
            preferences: AgentUsagePreferencesStore(),
            zaiSecrets: secrets)
        #expect(controller.readZAIAPIKey()?.isEmpty == true)
        #expect(controller.isConfigured(.zai))
        #expect(controller.isEnabled(.zai))
    }

    @Test("saving a key turns an untouched Z.ai switch on and the fetch uses it")
    func savingAKeyEnablesAndFetches() async throws {
        let secrets = InMemoryZAISecretStore()
        let recorder = RequestRecorder()
        let controller = makeController(secrets: secrets, client: StubHTTPClient { request in
            recorder.record(request)
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":10,"nextResetTime":1700018000000}]}}"#.utf8))
        })
        #expect(!controller.isEnabled(.zai))
        #expect(!controller.isConfigured(.zai))

        controller.setZAIAPIKey("  settings-key  ")
        #expect(try secrets.apiKey() == "settings-key")
        #expect(controller.readZAIAPIKey() == "settings-key")
        #expect(controller.isEnabled(.zai))
        #expect(controller.isConfigured(.zai))
        await controller.waitForPendingRefresh()

        #expect(recorder.requests.first?.headers["Authorization"] == "Bearer settings-key")
        #expect(controller.row(for: .zai)?.failure == nil)
        #expect(controller.row(for: .zai)?.metrics.isEmpty == false)
    }

    @Test("a failed refresh with a replacement key cannot show the previous account's usage")
    func replacingKeyClearsPreviousUsage() async {
        let secrets = InMemoryZAISecretStore(stored: "old-key")
        let controller = makeController(secrets: secrets, client: StubHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer old-key" else {
                return AgentUsageHTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            let body = request.url == ZAIUsageClient.quotaURL
                ? #"{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":10,"nextResetTime":1700018000000}]}}"#
                : #"{"data":[{"productName":"Old plan"}]}"#
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        })

        controller.refresh(force: true)
        await controller.waitForPendingRefresh()
        #expect(controller.row(for: .zai)?.plan == "Old plan")
        #expect(controller.row(for: .zai)?.metrics.isEmpty == false)
        #expect(controller.row(for: .zai)?.fetchedAt != nil)

        #expect(controller.setZAIAPIKey("new-key"))
        #expect(controller.row(for: .zai)?.plan == nil)
        #expect(controller.row(for: .zai)?.metrics.isEmpty == true)
        #expect(controller.row(for: .zai)?.fetchedAt == nil)
        await controller.waitForPendingRefresh()

        #expect(controller.row(for: .zai)?.failure?.shortStatusText == "Sign In")
        #expect(controller.row(for: .zai)?.plan == nil)
        #expect(controller.row(for: .zai)?.metrics.isEmpty == true)
        #expect(controller.row(for: .zai)?.fetchedAt == nil)
    }

    @Test("a request using the old key cannot publish after the key changes")
    func replacingKeyDropsInFlightResult() async {
        let secrets = InMemoryZAISecretStore(stored: "old-key")
        let oldRequestStarted = AgentUsageTestEvent()
        let oldRequestCancelled = AgentUsageTestEvent()
        let oldRequestGate = AgentUsageTestGate()
        let publishedOldUsage = FlagRecorder()
        let recorder = RequestRecorder()
        let controller = makeController(secrets: secrets, client: StubHTTPClient { request in
            recorder.record(request)
            guard request.headers["Authorization"] == "Bearer old-key" else {
                return AgentUsageHTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return await withTaskCancellationHandler {
                oldRequestStarted.signal()
                await oldRequestGate.wait()
                let body = #"{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":10,"nextResetTime":1700018000000}]}}"#
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            } onCancel: {
                oldRequestCancelled.signal()
            }
        })
        controller.onChange = {
            if controller.row(for: .zai)?.fetchedAt != nil { publishedOldUsage.set() }
        }

        controller.refresh(force: true)
        #expect(await oldRequestStarted.wait())
        #expect(controller.setZAIAPIKey("new-key"))
        #expect(await oldRequestCancelled.wait())
        #expect(controller.row(for: .zai)?.fetchedAt == nil)
        await oldRequestGate.open()
        await controller.waitForPendingRefresh()

        #expect(recorder.requests.map { $0.headers["Authorization"] } == [
            "Bearer old-key", "Bearer new-key"
        ])
        #expect(!publishedOldUsage.isSet)
        #expect(controller.row(for: .zai)?.failure?.shortStatusText == "Sign In")
        #expect(controller.row(for: .zai)?.fetchedAt == nil)
        #expect(controller.row(for: .zai)?.metrics.isEmpty == true)
        controller.onChange = nil
    }

    @Test("an explicit off switch stays off when a key is saved")
    func explicitOffStaysOff() throws {
        let secrets = InMemoryZAISecretStore()
        let controller = makeController(secrets: secrets, client: StubHTTPClient(status: 500))
        controller.setEnabled(false, for: .zai)
        controller.setZAIAPIKey("settings-key")
        #expect(!controller.isEnabled(.zai))
        #expect(controller.isConfigured(.zai))
        #expect(try secrets.apiKey() == "settings-key")
        #expect(!controller.isRefreshing)
    }

    @Test("clearing the last key turns an untouched Z.ai switch back off")
    func clearingTheKeyDisables() async throws {
        let secrets = InMemoryZAISecretStore()
        try secrets.setAPIKey("settings-key")
        let controller = makeController(
            secrets: secrets, client: StubHTTPClient(status: 200, body: #"{"success":true,"data":{"limits":[]}}"#))
        #expect(controller.isEnabled(.zai))
        #expect(controller.isConfigured(.zai))

        controller.setZAIAPIKey("   ")
        #expect(controller.readZAIAPIKey()?.isEmpty == true)
        #expect(!controller.isEnabled(.zai))
        #expect(!controller.isConfigured(.zai))
        #expect(!controller.isRefreshing)
    }
}
