import Foundation
import Testing
@testable import AgentUsage

/// A discovery runner whose `ps` output lists nothing — the provider reports
/// "not running".
struct NoLanguageServerRunner: AntigravityProcessRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws
        -> AntigravityProcessResult
    {
        AntigravityProcessResult(exitCode: 0, stdout: "")
    }
}

/// `ps`/`lsof` fixture runner for provider-level tests.
struct StubAntigravityRunner: AntigravityProcessRunning {
    var psOutput: String
    var lsofPorts = "127.0.0.1:54400 (LISTEN)"

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws
        -> AntigravityProcessResult
    {
        if executable == "/bin/ps" {
            return AntigravityProcessResult(exitCode: 0, stdout: psOutput)
        }
        return AntigravityProcessResult(exitCode: 0, stdout: """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        agy     42  user  9u IPv4 0x1        0t0  TCP \(lsofPorts)
        """)
    }
}

@Suite("Antigravity usage mapping", .english)
struct AntigravityUsageMapperTests {
    @Test("the quota summary maps its four pool buckets")
    func quotaSummary() {
        let body = Data("""
        {"groups": [{"buckets": [
            {"bucketId": "gemini-5h", "remainingFraction": 0.75, "resetTime": "2026-07-03T04:00:00Z"},
            {"bucketId": "gemini-weekly", "remainingFraction": 0.5},
            {"bucketId": "3p-5h", "remainingFraction": 0.25},
            {"bucketId": "3p-weekly", "remainingFraction": 1.0}
        ]}]}
        """.utf8)

        let metrics = AntigravityUsageMapper.quotaSummaryMetrics(body)
        #expect(metrics?.map(\.title) == ["Session", "Weekly", "Claude", "Claude Weekly"])
        guard case let .progress(used, _, _, _, _) = metrics?[0].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 25)
        guard case let .progress(claudeUsed, _, _, _, _) = metrics?[2].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(claudeUsed == 75)
    }

    @Test("the LS envelope variant unwraps `response`")
    func quotaSummaryEnvelope() {
        let body = Data("""
        {"response": {"groups": [{"buckets": [
            {"bucketId": "gemini-5h", "remainingFraction": 1.0}
        ]}]}}
        """.utf8)
        let metrics = AntigravityUsageMapper.quotaSummaryMetrics(body)
        #expect(metrics?.count == 1)
        #expect(metrics?.first?.title == "Session")
    }

    @Test("a parsed summary with no usable buckets is authoritative and empty")
    func emptySummary() {
        #expect(AntigravityUsageMapper.quotaSummaryMetrics(Data(#"{"groups": []}"#.utf8)) == [])
        // Not a summary at all → nil lets the caller fall back to legacy endpoints.
        #expect(AntigravityUsageMapper.quotaSummaryMetrics(Data(#"{"models": {}}"#.utf8)) == nil)
        #expect(AntigravityUsageMapper.quotaSummaryMetrics(Data("garbage".utf8)) == nil)
    }

    @Test("unrecognized bucket ids never silently join a pool")
    func unknownBucketDropped() {
        let body = Data("""
        {"groups": [{"buckets": [
            {"bucketId": "gemini-5h", "remainingFraction": 0.5},
            {"bucketId": "future-bucket", "remainingFraction": 0.1}
        ]}]}
        """.utf8)
        let metrics = AntigravityUsageMapper.quotaSummaryMetrics(body)
        #expect(metrics?.count == 1)
        #expect(metrics?.first?.title == "Session")
    }

    @Test("legacy pooling keeps each pool's worst fraction")
    func pooling() {
        let metrics = AntigravityUsageMapper.pooledMetrics([
            AntigravityModelQuota(label: "Gemini 3 Pro (High)", modelID: "gemini-3-pro",
                                  remainingFraction: 0.9, resetTime: nil),
            AntigravityModelQuota(label: "Gemini 3 Flash", modelID: "gemini-3-flash",
                                  remainingFraction: 0.4, resetTime: nil),
            AntigravityModelQuota(label: "Claude Sonnet 4.5", modelID: "claude-sonnet",
                                  remainingFraction: 0.7, resetTime: nil),
            AntigravityModelQuota(label: "GPT-OSS 120B", modelID: "gpt-oss",
                                  remainingFraction: 0.2, resetTime: nil),
            // Blacklisted internal model is dropped entirely.
            AntigravityModelQuota(label: "Ghost", modelID: "MODEL_PLACEHOLDER_M9",
                                  remainingFraction: 0.0, resetTime: nil),
        ])

        #expect(metrics.map(\.title) == ["Session", "Claude"])
        guard case let .progress(sessionUsed, _, _, _, sessionWindow) = metrics[0].value,
              case let .progress(claudeUsed, _, _, _, _) = metrics[1].value
        else {
            Issue.record("expected progress metrics")
            return
        }
        #expect(sessionUsed == 60)
        #expect(claudeUsed == 80)
        #expect(sessionWindow == 18_000)
    }

    @Test("GetUserStatus prefers the Google user tier over the plan name")
    func userStatusPlan() {
        let body = Data("""
        {"userStatus": {
            "userTier": {"name": "Google AI Ultra"},
            "planStatus": {"planInfo": {"planName": "Pro"}},
            "cascadeModelConfigData": {"clientModelConfigs": [
                {"label": "Gemini 3 Pro (High)", "modelOrAlias": {"model": "gemini-3-pro"},
                 "quotaInfo": {"remainingFraction": 0.5}}
            ]}
        }}
        """.utf8)
        let parsed = AntigravityUsageMapper.userStatus(body)
        #expect(parsed?.plan == "Ultra")
        #expect(parsed?.quotas.count == 1)
        #expect(parsed?.quotas.first?.remainingFraction == 0.5)
    }

    @Test("GetUserStatus extracts the account email")
    func userStatusEmail() {
        let body = Data("""
        {"userStatus": {"email": "dev@example.com", "planStatus": {"planInfo": {"planName": "Pro"}}}}
        """.utf8)
        let parsed = AntigravityUsageMapper.userStatus(body)
        #expect(parsed?.email == "dev@example.com")
        #expect(parsed?.plan == "Pro")
    }

    @Test("fetchAvailableModels maps explicit model quotas and ignores tab models")
    func availableModelsMapping() {
        let body = Data("""
        {"models": {
            "gemini-3-flash": {"displayName": "Gemini 3 Flash",
                "quotaInfo": {"remainingFraction": 0.83, "resetTime": "2026-11-24T10:14:03Z"}},
            "gemini-4-hydrogen-sonar": {"quotaInfo": {"remainingFraction": 0.80}},
            "claude-opus-5-5-high": {"displayName": "Claude Opus 5.5 (High)",
                "quotaInfo": {"remainingFraction": 1.0}},
            "tab_flash_lite_preview": {"quotaInfo": {"remainingFraction": 0.1}},
            "missing-quota": {"displayName": "Claude No Quota"}
        }}
        """.utf8)
        let quotas = AntigravityUsageMapper.availableModels(body) ?? []
        let metrics = AntigravityUsageMapper.pooledMetrics(quotas)
        #expect(metrics.map(\.title) == ["Session", "Claude"])
        guard case let .progress(sessionUsed, _, _, _, _) = metrics[0].value,
              case let .progress(claudeUsed, _, _, _, _) = metrics[1].value
        else {
            Issue.record("expected progress metrics")
            return
        }
        #expect(sessionUsed == 20)
        #expect(claudeUsed == 0)
    }

    @Test("merging a partial summary preserves summary buckets and adds missing pools in order")
    func mergePartialSummary() {
        let summary = AntigravityUsageMapper.quotaSummaryMetrics(Data("""
        {"groups": [{"buckets": [
            {"bucketId": "3p-weekly", "remainingFraction": 0.9},
            {"bucketId": "3p-5h", "remainingFraction": 1.0}
        ]}]}
        """.utf8)) ?? []
        let fallback = AntigravityUsageMapper.pooledMetrics([
            AntigravityModelQuota(label: "Gemini 3 Flash", modelID: "gemini-3-flash",
                                  remainingFraction: 0.83, resetTime: nil),
            AntigravityModelQuota(label: "Claude Opus", modelID: "claude-opus",
                                  remainingFraction: 0.5, resetTime: nil),
        ])
        let merged = AntigravityUsageMapper.mergeSummaryMetrics(summary, fallback: fallback)
        #expect(merged.map(\.title) == ["Session", "Claude", "Claude Weekly"])
        guard case let .progress(sessionUsed, _, _, _, _) = merged[0].value,
              case let .progress(claudeUsed, _, _, _, _) = merged[1].value
        else {
            Issue.record("expected progress metrics")
            return
        }
        #expect(sessionUsed == 17)
        // Authoritative summary wins for Claude even though fallback differed.
        #expect(claudeUsed == 0)
    }
}

@Suite("Antigravity language server discovery", .english)
struct AntigravityDiscoveryTests {
    @Test("a language_server process is matched by marker and its flags extracted")
    func matchesProcess() {
        let ps = """
          501 /Applications/Antigravity.app/Contents/MacOS/Antigravity
          502 /path/to/language_server_macos_arm --csrf_token=tok-abc --app_data_dir antigravity --extension_server_port 43300
          503 /other/language_server_macos_arm --csrf_token=tok-other --app_data_dir windsurf
        """
        let options = AntigravityLanguageServerDiscovery.Options(
            processName: "language_server",
            markers: ["antigravity", "antigravity-ide"],
            csrfFlag: "--csrf_token",
            portFlag: "--extension_server_port")
        let candidates = AntigravityLanguageServerDiscovery.rankedCandidates(
            psOutput: ps, options: options)
        #expect(candidates.count == 1)
        #expect(candidates.first?.pid == 502)
        #expect(AntigravityLanguageServerDiscovery.extractFlag(
            command: candidates[0].command, flag: "--csrf_token") == "tok-abc")
        #expect(AntigravityLanguageServerDiscovery.extractFlag(
            command: candidates[0].command, flag: "--extension_server_port") == "43300")
    }

    @Test("lsof output yields deduped ascending ports")
    func parsesPorts() {
        let lsof = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        langua+ 5022 user  123u  IPv6 0x123      0t0  TCP 127.0.0.1:52168 (LISTEN)
        langua+ 5022 user  124u  IPv6 0x124      0t0  TCP 127.0.0.1:52168 (LISTEN)
        langua+ 5022 user  125u  IPv6 0x125      0t0  TCP 127.0.0.1:52200 (LISTEN)
        """
        #expect(AntigravityLanguageServerDiscovery.parseListeningPorts(lsof) == [52168, 52200])
    }

    @Test("the agy CLI matches as a bare or pathed executable")
    func agyExecutable() {
        let ps = """
          700 agy
          701 /Users/x/.local/bin/agy --print hello
          702 /usr/bin/git -C /Users/x/.gemini/antigravity-cli/scratch/ws status
          703 /tmp/notagy/server
        """
        let options = AntigravityLanguageServerDiscovery.Options(
            processName: "agy", markers: [],
            executableMarkers: ["antigravity-cli", "antigravity_cli"],
            csrfFlag: "--csrf_token", csrfOptional: true,
            portFlag: "--extension_server_port")
        let candidates = AntigravityLanguageServerDiscovery.rankedCandidates(
            psOutput: ps, options: options)
        // The git helper runs *inside* a CLI directory but its executable is
        // /usr/bin/git — it must not be mistaken for the server.
        #expect(candidates.map(\.pid) == [700, 701])
    }

    @Test("a language_server under antigravity-cli matches via its executable path")
    func cliBundledLanguageServer() {
        let ps = """
          800 /Users/x/.gemini/antigravity-cli/bin/language_server --app_data_dir /Users/x/.gemini/antigravity-cli
          801 /other/language_server --csrf_token=tok --app_data_dir windsurf
        """
        let options = AntigravityLanguageServerDiscovery.Options(
            processName: "agy", markers: [],
            executableMarkers: ["antigravity-cli", "antigravity_cli"],
            csrfFlag: "--csrf_token", csrfOptional: true,
            portFlag: "--extension_server_port")
        let candidates = AntigravityLanguageServerDiscovery.rankedCandidates(
            psOutput: ps, options: options)
        #expect(candidates.map(\.pid) == [800])
    }

    @Test("a missing csrf flag only skips candidates that require it")
    func csrfOptional() {
        let runner = StubAntigravityRunner(psOutput: " 900 /Users/x/.local/bin/agy\n")
        let discovery = AntigravityLanguageServerDiscovery(processRunner: runner)
        var options = AntigravityLanguageServerDiscovery.Options(
            processName: "agy", markers: [], csrfFlag: "--csrf_token")

        // Token required: the tokenless process is skipped.
        #expect(discovery.discover(options) == nil)

        // The CLI server ignores the token — it gets the stand-in the header
        // carries instead.
        options.csrfOptional = true
        let result = discovery.discover(options)
        #expect(result?.pid == 900)
        #expect(result?.csrf == "cli-dummy-token")
        #expect(result?.ports == [54400])
    }

    @Test("the renamed Gemini desktop app is an app marker")
    func geminiAppMarker() {
        let ps = """
          910 /Applications/Gemini.app/Contents/Resources/language_server --csrf_token=tok --app_data_dir antigravity
        """
        let options = AntigravityLanguageServerDiscovery.Options(
            processName: "language_server",
            markers: [
                "antigravity", "antigravity-ide",
                "antigravity.app", "antigravity ide.app", "gemini.app",
            ],
            csrfFlag: "--csrf_token",
            portFlag: "--extension_server_port")
        let candidates = AntigravityLanguageServerDiscovery.rankedCandidates(
            psOutput: ps, options: options)
        #expect(candidates.map(\.pid) == [910])
    }

    @Test("the extension port carries its own csrf token")
    func extensionCSRF() {
        #expect(AntigravityLanguageServerDiscovery.extractFlag(
            command: "/bin/language_server --csrf_token=main --extension_server_csrf_token ext-tok",
            flag: "--extension_server_csrf_token") == "ext-tok")
    }
}

@Suite("Antigravity provider", .english)
struct AntigravityProviderTests {
    /// A credential path guaranteed not to exist — tests that don't inject one
    /// must never touch the host's real `agy` token file.
    static let missingCredentialURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("prism-tests-\(UUID().uuidString)/token.json")

    static func makeProvider(
        installPresent: Bool = true,
        runner: any AntigravityProcessRunning = NoLanguageServerRunner(),
        ls: StubHTTPClient,
        credentialURL: URL = missingCredentialURL,
        keychainPayload: Data? = nil,
        cloud: StubHTTPClient? = nil,
        oauthClients: [AntigravityOAuthClient] = [
            AntigravityOAuthClient(id: "test-client.apps.googleusercontent.com", secret: "test-secret")
        ]
    ) -> AntigravityAgentUsageProvider {
        var provider = AntigravityAgentUsageProvider()
        provider.installPresence = { installPresent }
        provider.usageClient.loopbackClient = ls
        if let cloud { provider.usageClient.httpClient = cloud }
        provider.authStore = AntigravityAuthStore(
            credentialURL: credentialURL,
            httpClient: cloud ?? StubHTTPClient(status: 500))
        provider.authStore.readKeychainSecret = { _, _ in keychainPayload }
        provider.authStore.keychainItemExists = { _, _ in keychainPayload != nil }
        provider.authStore.oauthClients = { _ in oauthClients }
        provider.discovery = AntigravityLanguageServerDiscovery(processRunner: runner)
        return provider
    }

    static func makeGoKeyringPayload(
        accessToken: String = "keychain-access",
        refreshToken: String? = "keychain-refresh",
        expiry: String = "2099-01-01T00:00:00Z",
        email: String? = "dev@example.com"
    ) -> Data {
        let refresh = refreshToken.map { #""refresh_token": "\#($0)", "# } ?? ""
        let emailField = email.map { #", "id_token_email": "\#($0)""# } ?? ""
        let json = """
        {"token": {"access_token": "\(accessToken)", \(refresh)"expiry": "\(expiry)"}, "auth_method": "consumer"\(emailField)}
        """
        return Data(("go-keyring-base64:" + Data(json.utf8).base64EncodedString()).utf8)
    }

    /// Writes an `agy`-shaped token file into a temp dir and returns its URL.
    static func makeCredentialFile(
        accessToken: String = "file-access",
        refreshToken: String? = "file-refresh",
        expiry: String = "2099-01-01T00:00:00Z"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("token.json")
        let refresh = refreshToken.map { #""refresh_token": "\#($0)", "# } ?? ""
        try """
        {"token": {"access_token": "\(accessToken)", \(refresh)"expiry": "\(expiry)"}}
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The stub LS answers any method 200 by default; tests override per path.
    private static let agyRunner = StubAntigravityRunner(
        psOutput: " 42 /Users/x/.local/bin/agy\n")

    @Test("a running agy CLI answers the quota summary with no credential at all")
    func agyLanguageServerPath() async {
        let provider = Self.makeProvider(runner: Self.agyRunner, ls: StubHTTPClient { request in
            // The CLI ignores the token but the header is always sent.
            #expect(request.headers["x-codeium-csrf-token"] == "cli-dummy-token")
            #expect(request.url.host() == "127.0.0.1")
            #expect(request.url.port == 54400)
            switch request.url.absoluteString {
            case let url where url.hasSuffix("GetUnleashData"):
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            case let url where url.hasSuffix("GetUserStatus"):
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"userStatus": {"email": "dev@example.com", "userTier": {"name": "Google AI Pro"}}}
                """.utf8))
            case let url where url.hasSuffix("RetrieveUserQuotaSummary"):
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"groups": [{"buckets": [{"bucketId": "gemini-5h", "remainingFraction": 0.5}]}]}
                """.utf8))
            default:
                return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        })

        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.plan == "Pro")
        #expect(report.accountLabel == "dev@example.com")
        #expect(report.metrics.map(\.title) == ["Session"])
    }

    @Test("the desktop language server sends its real csrf token")
    func desktopCSRF() async {
        let provider = Self.makeProvider(
            runner: StubAntigravityRunner(psOutput: """
             42 /path/language_server_macos_arm --csrf_token=tok-abc --app_data_dir antigravity
            """),
            ls: StubHTTPClient { request in
                #expect(request.headers["x-codeium-csrf-token"] == "tok-abc")
                if request.url.absoluteString.hasSuffix("GetUnleashData") {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
                }
                if request.url.absoluteString.hasSuffix("GetUserStatus") {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"userStatus": {"planStatus": {"planInfo": {"planName": "Pro"}},
                     "cascadeModelConfigData": {"clientModelConfigs": [
                        {"label": "Gemini 3 Pro", "modelOrAlias": {"model": "gemini-3-pro"},
                         "quotaInfo": {"remainingFraction": 0.5}}]}}}
                    """.utf8))
                }
                // No quota summary on this build → legacy pooled metrics.
                return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
            })

        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.plan == "Pro")
        #expect(report.metrics.map(\.title) == ["Session"])
    }

    @Test("an install without a running server stays enabled but reports not-running")
    func installedNotRunning() async {
        let provider = Self.makeProvider(
            installPresent: true,
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient(status: 200, body: "{}"))
        #expect(provider.hasLocalCredentials())
        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .notConfigured = failure {} else {
            Issue.record("expected notConfigured, got \(failure)")
        }
    }

    @Test("no install and no process means not configured")
    func notConfigured() async {
        let provider = Self.makeProvider(
            installPresent: false,
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient(status: 200, body: "{}"))
        #expect(!provider.hasLocalCredentials())
        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .notConfigured = failure {} else {
            Issue.record("expected notConfigured, got \(failure)")
        }
    }

    @Test("a process whose ports never answer is a network failure")
    func unreachable() async {
        let provider = Self.makeProvider(
            runner: Self.agyRunner,
            ls: StubHTTPClient { _ in throw AgentUsageClientError.transport })
        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .network = failure {} else {
            Issue.record("expected network, got \(failure)")
        }
    }

    @Test("a server rejecting the stand-in token reports unreachable")
    func csrfRejected() async {
        // Live `agy` builds generate the CSRF token at runtime: the dummy
        // token earns a 401 on every method, so the endpoint is skipped like
        // a dead port and the surface error is a network one, not a parse
        // failure or a credential problem.
        let provider = Self.makeProvider(
            runner: Self.agyRunner,
            ls: StubHTTPClient(status: 401, body: #"{"code":"unauthenticated","message":"invalid CSRF token"}"#))
        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .network = failure {} else {
            Issue.record("expected network, got \(failure)")
        }
    }

    @Test("a build without GetUnleashData still answers the real endpoints")
    func unleashMissing() async {
        let provider = Self.makeProvider(
            runner: Self.agyRunner,
            ls: StubHTTPClient { request in
                if request.url.absoluteString.hasSuffix("GetUnleashData") {
                    return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
                if request.url.absoluteString.hasSuffix("RetrieveUserQuotaSummary") {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"groups": [{"buckets": [{"bucketId": "gemini-5h", "remainingFraction": 0.5}]}]}
                    """.utf8))
                }
                return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
            })
        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.metrics.map(\.title) == ["Session"])
    }

    @Test("endpoints answering with unusable data are an invalid response")
    func unparseable() async {
        let provider = Self.makeProvider(
            runner: Self.agyRunner,
            ls: StubHTTPClient(status: 200, body: "not json"))
        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .invalidResponse = failure {} else {
            Issue.record("expected invalidResponse, got \(failure)")
        }
    }

    // MARK: - Cloud Code fallback (the `agy` credential file)

    @Test("a credential file plus a dead local API falls back to the quota service")
    func cloudFallback() async throws {
        let recorder = RequestRecorder()
        let provider = Self.makeProvider(
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient { _ in throw AgentUsageClientError.transport },
            credentialURL: try Self.makeCredentialFile(),
            cloud: StubHTTPClient { request in
                recorder.record(request)
                #expect(request.headers["Authorization"] == "Bearer file-access")
                #expect(request.headers["User-Agent"] == AntigravityUsageClient.cloudUserAgent)
                switch request.url.absoluteString {
                case let url where url.contains("retrieveUserQuotaSummary"):
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"response": {"groups": [{"buckets": [
                        {"bucketId": "gemini-5h", "remainingFraction": 1.0},
                        {"bucketId": "gemini-weekly", "remainingFraction": 0.98},
                        {"bucketId": "3p-5h", "remainingFraction": 1.0},
                        {"bucketId": "3p-weekly", "remainingFraction": 1.0}
                    ]}]}}
                    """.utf8))
                case let url where url.contains("loadCodeAssist"):
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"paidTier": {"name": "Google AI Pro"}}
                    """.utf8))
                case let url where url.contains("userinfo"):
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"email": "dev@example.com"}
                    """.utf8))
                default:
                    return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            })

        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.plan == "Pro")
        #expect(report.accountLabel == "dev@example.com")
        #expect(report.metrics.map(\.title) == ["Session", "Weekly", "Claude", "Claude Weekly"])
        // A fresh file token goes straight to the quota call — no refresh.
        #expect(!recorder.requests.contains { $0.url.host() == "oauth2.googleapis.com" })
    }

    @Test("an expired file token is refreshed once, then reused")
    func expiredTokenRefreshed() async throws {
        let recorder = RequestRecorder()
        let provider = Self.makeProvider(
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient { _ in throw AgentUsageClientError.transport },
            credentialURL: try Self.makeCredentialFile(
                accessToken: "stale", expiry: "2000-01-01T00:00:00Z"),
            cloud: StubHTTPClient { request in
                recorder.record(request)
                if request.url.host() == "oauth2.googleapis.com" {
                    #expect(String(data: request.body ?? Data(), encoding: .utf8)?
                        .contains("grant_type=refresh_token") == true)
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"access_token": "fresh-token", "expires_in": 3600}
                    """.utf8))
                }
                #expect(request.headers["Authorization"] == "Bearer fresh-token")
                if request.url.absoluteString.contains("retrieveUserQuotaSummary") {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"groups": [{"buckets": [{"bucketId": "gemini-5h", "remainingFraction": 0.5}]}]}
                    """.utf8))
                }
                return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
            })

        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.metrics.map(\.title) == ["Session"])
        #expect(recorder.requests.filter { $0.url.host() == "oauth2.googleapis.com" }.count == 1)

        // A second refresh cycle reuses the cached token instead of
        // exchanging the refresh token again.
        let second = await provider.fetchUsage()
        guard case .success = second else {
            Issue.record("expected success, got \(second)")
            return
        }
        #expect(recorder.requests.filter { $0.url.host() == "oauth2.googleapis.com" }.count == 1)
    }

    @Test("a rejected refresh is an auth failure, not a generic network error")
    func refreshRejected() async throws {
        let provider = Self.makeProvider(
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient { _ in throw AgentUsageClientError.transport },
            credentialURL: try Self.makeCredentialFile(expiry: "2000-01-01T00:00:00Z"),
            cloud: StubHTTPClient(status: 400, body: #"{"error": "invalid_grant"}"#))
        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .authExpired = failure {} else {
            Issue.record("expected authExpired, got \(failure)")
        }
    }

    @Test("a rejected quota call is an auth failure")
    func cloudUnauthorized() async throws {
        let provider = Self.makeProvider(
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient { _ in throw AgentUsageClientError.transport },
            credentialURL: try Self.makeCredentialFile(),
            cloud: StubHTTPClient(status: 401))
        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .authExpired = failure {} else {
            Issue.record("expected authExpired, got \(failure)")
        }
    }

    @Test("a CSRF-gated agy still reaches the cloud path")
    func csrfGatedFallsBack() async throws {
        let provider = Self.makeProvider(
            runner: Self.agyRunner,
            ls: StubHTTPClient(status: 401, body: #"{"code":"unauthenticated"}"#),
            credentialURL: try Self.makeCredentialFile(),
            cloud: StubHTTPClient { request in
                guard request.url.absoluteString.contains("retrieveUserQuotaSummary") else {
                    return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"groups": [{"buckets": [{"bucketId": "3p-weekly", "remainingFraction": 0.9}]}]}
                """.utf8))
            })
        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.metrics.map(\.title) == ["Claude Weekly"])
    }

    @Test("a CSRF rejection after GetUnleashData 404 still falls back to Keychain and supplements Gemini quota")
    func keychainFallbackAndPartialSummary() async {
        let recorder = RequestRecorder()
        let provider = Self.makeProvider(
            runner: Self.agyRunner,
            ls: StubHTTPClient { request in
                if request.url.absoluteString.hasSuffix("GetUnleashData") {
                    return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data("404 page not found".utf8))
                }
                return AgentUsageHTTPResponse(
                    statusCode: 401, headers: [:],
                    body: Data(#"{"code":"unauthenticated","message":"invalid CSRF token"}"#.utf8))
            },
            keychainPayload: Self.makeGoKeyringPayload(),
            cloud: StubHTTPClient { request in
                recorder.record(request)
                #expect(request.headers["Authorization"] == "Bearer keychain-access")
                switch request.url.absoluteString {
                case let url where url.contains("retrieveUserQuotaSummary"):
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"groups": [{"buckets": [
                        {"bucketId": "3p-weekly", "remainingFraction": 1.0},
                        {"bucketId": "3p-5h", "remainingFraction": 1.0}
                    ]}]}
                    """.utf8))
                case let url where url.contains("fetchAvailableModels"):
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"models": {
                        "gemini-3-flash": {"displayName": "Gemini 3 Flash", "quotaInfo": {"remainingFraction": 0.83}},
                        "claude-opus-5-5-high": {"displayName": "Claude Opus 5.5 (High)", "quotaInfo": {"remainingFraction": 1.0}}
                    }}
                    """.utf8))
                case let url where url.contains("loadCodeAssist"):
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"paidTier": {"name": "Google AI Ultra"}}
                    """.utf8))
                default:
                    return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            })

        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.plan == "Ultra")
        #expect(report.accountLabel == "dev@example.com")
        #expect(report.metrics.map(\.title) == ["Session", "Claude", "Claude Weekly"])
        // Email came from `id_token_email`, so `userinfo` was skipped.
        #expect(!recorder.requests.contains { $0.url == AntigravityUsageClient.userInfoURL })
    }

    @Test("a CSRF rejection after GetUnleashData 404 without credentials reports unreachable")
    func csrfRejectedAfterUnleash404() async {
        let provider = Self.makeProvider(
            runner: Self.agyRunner,
            ls: StubHTTPClient { request in
                if request.url.absoluteString.hasSuffix("GetUnleashData") {
                    return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data("404 page not found".utf8))
                }
                return AgentUsageHTTPResponse(
                    statusCode: 401, headers: [:],
                    body: Data(#"{"code":"unauthenticated","message":"invalid CSRF token"}"#.utf8))
            })
        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .network = failure {} else {
            Issue.record("expected network, got \(failure)")
        }
    }

    @Test("refresh tries candidate OAuth clients until one matches and caches the winner")
    func multiClientRefresh() async {
        let recorder = RequestRecorder()
        let wrongClient = AntigravityOAuthClient(id: "id-a.apps.googleusercontent.com", secret: "sec-wrong")
        let wrongID = AntigravityOAuthClient(id: "id-a.apps.googleusercontent.com", secret: "sec-a")
        let skipped = AntigravityOAuthClient(id: "id-a.apps.googleusercontent.com", secret: "sec-a-2")
        let right = AntigravityOAuthClient(id: "id-b.apps.googleusercontent.com", secret: "sec-b")
        let provider = Self.makeProvider(
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient { _ in throw AgentUsageClientError.transport },
            keychainPayload: Self.makeGoKeyringPayload(accessToken: "stale", expiry: "2000-01-01T00:00:00Z"),
            cloud: StubHTTPClient { request in
                recorder.record(request)
                if request.url.host() == "oauth2.googleapis.com" {
                    let body = String(data: request.body ?? Data(), encoding: .utf8) ?? ""
                    if body.contains("client_secret=sec-wrong") {
                        return AgentUsageHTTPResponse(statusCode: 401, headers: [:], body: Data(#"{"error":"invalid_client"}"#.utf8))
                    }
                    if body.contains("client_secret=sec-a") {
                        return AgentUsageHTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"unauthorized_client"}"#.utf8))
                    }
                    #expect(body.contains("client_id=id-b.apps.googleusercontent.com"))
                    #expect(body.contains("client_secret=sec-b"))
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"access_token": "fresh-keychain-token", "expires_in": 3600}
                    """.utf8))
                }
                #expect(request.headers["Authorization"] == "Bearer fresh-keychain-token")
                if request.url.absoluteString.contains("retrieveUserQuotaSummary") {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
                    {"groups": [{"buckets": [{"bucketId": "gemini-5h", "remainingFraction": 0.7}]}]}
                    """.utf8))
                }
                return AgentUsageHTTPResponse(statusCode: 404, headers: [:], body: Data())
            },
            oauthClients: [wrongClient, wrongID, skipped, right])

        let result = await provider.fetchUsage()
        guard case let .success(report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.metrics.map(\.title) == ["Session"])
        // `skipped` was bypassed once `id-a` returned `unauthorized_client`.
        let oauthRequests = recorder.requests.filter { $0.url.host() == "oauth2.googleapis.com" }
        #expect(oauthRequests.count == 3)
    }
}

@Suite("Antigravity credential file", .english)
struct AntigravityAuthStoreTests {
    @Test("a well-formed token file parses")
    func loads() throws {
        let url = try AntigravityProviderTests.makeCredentialFile()
        let credentials = AntigravityCredentialFile.load(url: url)
        #expect(credentials?.accessToken == "file-access")
        #expect(credentials?.refreshToken == "file-refresh")
        #expect(credentials?.expiry != nil)
    }

    @Test("go-keyring base64 and hex Keychain payloads parse including email")
    func parsesKeychainPayloads() {
        let payload = AntigravityProviderTests.makeGoKeyringPayload(
            accessToken: "kc-tok", refreshToken: "kc-ref", email: "user@example.com")
        let parsed = AntigravityCredentialFile.parse(payload)
        #expect(parsed?.accessToken == "kc-tok")
        #expect(parsed?.refreshToken == "kc-ref")
        #expect(parsed?.email == "user@example.com")

        let hexWrapped = Data(payload.map { String(format: "%02x", $0) }.joined().utf8)
        #expect(AntigravityCredentialFile.parse(hexWrapped) == parsed)
    }

    @Test("a Keychain item alone makes the provider detected")
    func detectedFromKeychain() {
        let provider = AntigravityProviderTests.makeProvider(
            installPresent: false,
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient(status: 200, body: "{}"),
            keychainPayload: AntigravityProviderTests.makeGoKeyringPayload())
        #expect(provider.hasLocalCredentials())
    }

    @Test("missing and malformed files mean absent")
    func absent() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-tests-\(UUID().uuidString)/none.json")
        #expect(AntigravityCredentialFile.load(url: missing) == nil)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = dir.appendingPathComponent("token.json")
        try "not json".write(to: garbage, atomically: true, encoding: .utf8)
        #expect(AntigravityCredentialFile.load(url: garbage) == nil)

        let noToken = dir.appendingPathComponent("token2.json")
        try #"{"token": {}}"#.write(to: noToken, atomically: true, encoding: .utf8)
        #expect(AntigravityCredentialFile.load(url: noToken) == nil)
    }

    @Test("a credential file alone makes the provider detected")
    func detected() async throws {
        let provider = AntigravityProviderTests.makeProvider(
            installPresent: false,
            runner: NoLanguageServerRunner(),
            ls: StubHTTPClient(status: 200, body: "{}"),
            credentialURL: try AntigravityProviderTests.makeCredentialFile())
        #expect(provider.hasLocalCredentials())
    }
}

@MainActor
@Suite("Antigravity provider deadline and cancellation", .english)
struct AntigravityProviderLifecycleTests {
    @Test("slow optional cloud metadata preserves quota", arguments: [false, true])
    func optionalMetadataDeadline(slowUserInfo: Bool) async throws {
        let credentialURL = try AntigravityProviderTests.makeCredentialFile()
        defer { try? FileManager.default.removeItem(at: credentialURL.deletingLastPathComponent()) }
        let recorder = RequestRecorder()
        let provider = AntigravityProviderTests.makeProvider(
            ls: StubHTTPClient(status: 500), credentialURL: credentialURL,
            cloud: StubHTTPClient { request in
                recorder.record(request)
                if request.url == AntigravityUsageClient.quotaSummaryURL {
                    try await Task.sleep(for: .seconds(0.5))
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                        #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.5}]}]}"#.utf8))
                }
                if slowUserInfo && request.url == AntigravityUsageClient.loadCodeAssistURL {
                    return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(
                        #"{"paidTier":{"name":"Google AI Pro"}}"#.utf8))
                }
                try await Task.sleep(for: .seconds(4))
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            })
        let suite = "com.spike.prism.tests.antigravity.deadline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentUsageController(
            providers: [provider], preferences: AgentUsagePreferencesStore())
        AgentUsageTiming.$current.withValue(.testing) { controller.refresh(force: true) }
        await controller.waitForPendingRefresh()

        let row = try #require(controller.row(for: .antigravity))
        #expect(row.failure == nil)
        #expect(!row.metrics.isEmpty)
        #expect(row.fetchedAt != nil)
        #expect(row.plan == (slowUserInfo ? "Pro" : nil))
        #expect(recorder.requests.count == (slowUserInfo ? 3 : 2))
    }

    @Test("cancelling either local probe stops discovery and cloud fallback", arguments: [false, true])
    func cancelledProbe(cli: Bool) async throws {
        let started = AgentUsageTestEvent()
        let runner = CountingAntigravityRunner(base: StubAntigravityRunner(psOutput: cli
            ? "42 /Users/x/.local/bin/agy"
            : "42 /path/language_server_macos_arm --csrf_token=token --app_data_dir antigravity"))
        let cloudCalled = FlagRecorder()
        let credentialURL = try AntigravityProviderTests.makeCredentialFile()
        defer { try? FileManager.default.removeItem(at: credentialURL.deletingLastPathComponent()) }
        let provider = AntigravityProviderTests.makeProvider(
            runner: runner,
            ls: StubHTTPClient { _ in
                started.signal()
                try await Task.sleep(for: .seconds(30))
                return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data())
            },
            credentialURL: credentialURL,
            cloud: StubHTTPClient { _ in
                cloudCalled.set()
                return AgentUsageHTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        let task = Task { await provider.fetchUsage() }
        let didStart = await started.wait()
        task.cancel()
        let result = await task.value

        #expect(didStart)
        #expect(result == .failure(.network("Cancelled.")))
        #expect(runner.scanCount == (cli ? 2 : 1))
        #expect(!cloudCalled.isSet)
    }

    @Test("an already cancelled refresh does not start discovery")
    func cancelledBeforeDiscovery() async {
        let runner = CountingAntigravityRunner(base: StubAntigravityRunner(psOutput: ""))
        let gate = AgentUsageTestGate()
        let provider = AntigravityProviderTests.makeProvider(
            runner: runner, ls: StubHTTPClient(status: 500))
        let task = Task {
            await gate.wait()
            return await provider.fetchUsage()
        }
        task.cancel()
        await gate.open()
        let result = await task.value
        #expect(result == .failure(.network("Cancelled.")))
        #expect(runner.scanCount == 0)
    }

    @Test("cancellation returns while subprocess discovery is still blocked")
    func blockedDiscoveryCancellation() async {
        let runner = BlockingAntigravityRunner()
        defer { runner.release() }
        let provider = AntigravityProviderTests.makeProvider(
            runner: runner, ls: StubHTTPClient(status: 500))
        let task = Task { await provider.fetchUsage() }
        let didStart = await runner.started.wait()
        #expect(didStart)

        let cancelledAt = ContinuousClock.now
        task.cancel()
        let result = await task.value
        #expect(result == .failure(.network("Cancelled.")))
        #expect(ContinuousClock.now - cancelledAt < .seconds(2))
    }
}

private final class BlockingAntigravityRunner: AntigravityProcessRunning, @unchecked Sendable {
    let started = AgentUsageTestEvent()
    private let gate = DispatchSemaphore(value: 0)

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws
        -> AntigravityProcessResult
    {
        started.signal()
        _ = gate.wait(timeout: .now() + 5)
        return AntigravityProcessResult(exitCode: 0, stdout: "")
    }

    func release() { gate.signal() }
}

private final class CountingAntigravityRunner: AntigravityProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0
    let base: StubAntigravityRunner

    init(base: StubAntigravityRunner) { self.base = base }

    var scanCount: Int { lock.withLock { scans } }

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws
        -> AntigravityProcessResult
    {
        if executable == "/bin/ps" { lock.withLock { scans += 1 } }
        return try base.run(executable: executable, arguments: arguments, timeout: timeout)
    }
}

@Suite("Antigravity OAuth client", .english)
struct AntigravityOAuthClientTests {
    /// Built at run time so the repository holds nothing shaped like a real secret.
    private static let fakeSecret = "GOCSPX" + "-" + String(repeating: "x", count: 28)

    private static func idToken(_ claims: String) -> String {
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJSUzI1NiJ9.\(payload).signature"
    }

    @Test("the client ID comes from the ID token's authorized party")
    func clientID() {
        #expect(AntigravityOAuthClientLocator.clientID(fromIDToken: Self.idToken(
            #"{"azp":"123-abc.apps.googleusercontent.com","aud":"other"}"#)) == "123-abc.apps.googleusercontent.com")
        #expect(AntigravityOAuthClientLocator.clientID(fromIDToken: Self.idToken(
            #"{"aud":"456-def.apps.googleusercontent.com"}"#)) == "456-def.apps.googleusercontent.com")
        #expect(AntigravityOAuthClientLocator.clientID(fromIDToken: Self.idToken(#"{"aud":"not-google"}"#)) == nil)
        #expect(AntigravityOAuthClientLocator.clientID(fromIDToken: "garbage") == nil)
    }

    @Test("the secret is found inside the agy executable, and nothing without one")
    func secretScan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agy = folder.appendingPathComponent("agy")
        var binary = Data(repeating: 0, count: 4096)
        binary.append(Data((Self.fakeSecret + "\u{0}more").utf8))
        try binary.write(to: agy)
        let plain = folder.appendingPathComponent("plain")
        try Data(repeating: 7, count: 4096).write(to: plain)

        #expect(AntigravityOAuthClientLocator.secrets(in: agy) == [Self.fakeSecret])
        #expect(AntigravityOAuthClientLocator.secrets(in: plain).isEmpty)
        let token = Self.idToken(#"{"azp":"123-abc.apps.googleusercontent.com"}"#)
        #expect(AntigravityOAuthClientLocator.locate(idToken: token, executables: [plain, agy])
            == AntigravityOAuthClient(id: "123-abc.apps.googleusercontent.com", secret: Self.fakeSecret))
        #expect(AntigravityOAuthClientLocator.locate(idToken: token, executables: [plain]) == nil)
        #expect(AntigravityOAuthClientLocator.locate(idToken: nil, executables: [agy]) == nil)
    }

    @Test("Go binary string concatenation trims secrets to 35 chars and finds client IDs across chunk boundaries")
    func goBinaryScan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agy-go-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agy = folder.appendingPathComponent("agy")
        let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
        // Place the secret across the 1 MiB streaming chunk boundary and simulate
        // packed Go `.rodata` with no null terminators between string literals.
        var binary = Data(repeating: 0, count: 1_048_566)
        binary.append(Data(("authorize" + Self.fakeSecret + "https://cloudcode-pa.googleapis.com").utf8))
        binary.append(Data(("label" + clientID + "GetHubOAuthAccessToken").utf8))
        try binary.write(to: agy)

        #expect(AntigravityOAuthClientLocator.secrets(in: agy) == [Self.fakeSecret])
        #expect(AntigravityOAuthClientLocator.clientIDs(in: agy) == [clientID])
        #expect(AntigravityOAuthClientLocator.locateAll(idToken: nil, executables: [agy])
            == [AntigravityOAuthClient(id: clientID, secret: Self.fakeSecret)])
    }

    @Test("an expired token without a findable client asks the user to refresh the sign-in")
    func missingClient() async throws {
        let credentialURL = try AntigravityProviderTests.makeCredentialFile(expiry: "2000-01-01T00:00:00Z")
        defer { try? FileManager.default.removeItem(at: credentialURL.deletingLastPathComponent()) }
        let store = AntigravityAuthStore(credentialURL: credentialURL, httpClient: StubHTTPClient(status: 500))
        store.readKeychainSecret = { _, _ in nil }
        store.keychainItemExists = { _, _ in false }
        store.oauthClients = { _ in [] }
        guard case let .failed(failure) = await store.accessToken() else {
            Issue.record("A refresh without a client fails")
            return
        }
        #expect(failure.message.contains("Run `agy`"))
    }
}
