import Foundation
import Testing
@testable import AgentUsage

@Suite("Devin auth store")
struct DevinAuthStoreTests {
    @Test("reads the API key and a valid https API server override")
    func readsCredentialsFile() throws {
        let file = try TemporaryCredentialFile(relativePath: "credentials.toml", contents: """
        windsurf_api_key = "sk-test-key"
        api_server_url = "https://devin.example.internal/"
        """)
        defer { file.remove() }

        let store = DevinAuthStore(credentialsFileURL: file.url)
        let credentials = try #require(store.loadCredentialsFile())
        #expect(credentials.apiKey == "sk-test-key")
        #expect(credentials.apiServerURL == "https://devin.example.internal")
        #expect(store.effectiveAPIServerURL(credentials) == "https://devin.example.internal")
    }

    @Test("a non-https server override is dropped for the default")
    func rejectsInsecureServerURL() throws {
        let file = try TemporaryCredentialFile(relativePath: "credentials.toml", contents: """
        windsurf_api_key = "sk-test-key"
        api_server_url = "http://insecure.example.com"
        """)
        defer { file.remove() }

        let store = DevinAuthStore(credentialsFileURL: file.url)
        let credentials = try #require(store.loadCredentialsFile())
        #expect(credentials.apiServerURL == nil)
        #expect(store.effectiveAPIServerURL(credentials) == DevinAuthStore.defaultAPIServerURL)
    }

    @Test("missing file is absent, not an error")
    func missingFile() throws {
        let file = try TemporaryCredentialFile(relativePath: "absent/credentials.toml")
        defer { file.remove() }

        let store = DevinAuthStore(credentialsFileURL: file.url)
        #expect(store.loadCredentialsFile() == nil)
    }
}

@Suite("Devin usage mapping")
struct DevinUsageMapperTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("remaining percentages flip to used; resets and balance map")
    func mapsUserStatus() throws {
        let body = Data("""
        {"userStatus": {"planStatus": {
            "planInfo": {"planName": "Teams"},
            "dailyQuotaRemainingPercent": 75,
            "dailyQuotaResetAtUnix": 1700086400,
            "weeklyQuotaRemainingPercent": 40,
            "weeklyQuotaResetAtUnix": 1701000000,
            "overageBalanceMicros": 12500000
        }}}
        """.utf8)

        let report = try DevinUsageMapper.report(from: body, fetchedAt: Self.now)
        #expect(report.plan == "Teams")
        #expect(report.metrics.count == 3)

        guard case let .progress(daily, _, _, dailyReset, dailyWindow) = report.metrics[0].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(daily == 25)
        #expect(dailyReset == Date(timeIntervalSince1970: 1_700_086_400))
        #expect(dailyWindow == 86_400)

        guard case let .progress(weekly, _, _, _, weeklyWindow) = report.metrics[1].value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(weekly == 60)
        #expect(weeklyWindow == 604_800)

        #expect(report.metrics[2].value == .text("$12.50"))
    }

    @Test("a weekly reset with no percentage is an exhausted window, not missing data")
    func proto3ZeroWeekly() throws {
        let body = Data("""
        {"userStatus": {"planStatus": {
            "dailyQuotaRemainingPercent": 10,
            "weeklyQuotaResetAtUnix": 1701000000
        }}}
        """.utf8)

        let report = try DevinUsageMapper.report(from: body, fetchedAt: Self.now)
        let weekly = report.metrics.first { $0.id == "weekly" }
        guard case let .progress(used, _, _, _, _) = try #require(weekly).value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 100)
    }

    @Test("a daily reset with no percentage is an exhausted window")
    func proto3ZeroDaily() throws {
        let body = Data("""
        {"userStatus": {"planStatus": {"dailyQuotaResetAtUnix": 1700086400}}}
        """.utf8)
        let report = try DevinUsageMapper.report(from: body, fetchedAt: Self.now)
        let daily = try #require(report.metrics.first { $0.id == "daily" })
        guard case let .progress(used, _, _, reset, _) = daily.value else {
            Issue.record("expected a progress metric")
            return
        }
        #expect(used == 100)
        #expect(reset == Date(timeIntervalSince1970: 1_700_086_400))
    }

    @Test("a present-but-unparsable weekly percentage is schema drift")
    func malformedPercentage() {
        let body = Data("""
        {"userStatus": {"planStatus": {"weeklyQuotaRemainingPercent": "soon"}}}
        """.utf8)
        #expect(throws: DevinUsageError.invalidResponse) {
            try DevinUsageMapper.report(from: body, fetchedAt: Self.now)
        }
    }

    @Test("a body without userStatus is invalid")
    func missingUserStatus() {
        #expect(throws: DevinUsageError.invalidResponse) {
            try DevinUsageMapper.report(from: Data("{}".utf8), fetchedAt: Self.now)
        }
    }
}

@Suite("Devin provider")
struct DevinAgentUsageProviderTests {
    @Test("the Connect-RPC request carries the API key in metadata")
    func requestShape() async throws {
        let file = try TemporaryCredentialFile(relativePath: "credentials.toml", contents: """
        windsurf_api_key = "sk-test-key"
        """)
        defer { file.remove() }

        let captured = RequestRecorder()
        var provider = DevinAgentUsageProvider()
        provider.authStore = DevinAuthStore(
            credentialsFileURL: file.url,
            stateDatabaseURL: file.directory.appendingPathComponent("absent/state.vscdb"))
        provider.client = StubHTTPClient { request in
            captured.record(request)
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data("""
            {"userStatus": {"planStatus": {"dailyQuotaRemainingPercent": 50}}}
            """.utf8))
        }

        let result = await provider.fetchUsage()
        guard case .success = result else {
            Issue.record("expected success")
            return
        }
        let request = try #require(captured.lastRequest)
        #expect(request.url.absoluteString
            == "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")
        #expect(request.headers["Connect-Protocol-Version"] == "1")
        let body = try JSONSerialization.jsonObject(with: #require(request.body)) as? [String: Any]
        let metadata = body?["metadata"] as? [String: Any]
        #expect(metadata?["apiKey"] as? String == "sk-test-key")
    }

    @Test("a rejected file key falls through to the app credential")
    func appCredentialFallback() async throws {
        let file = try TemporaryCredentialFile(relativePath: "credentials.toml", contents: """
        windsurf_api_key = "sk-dead-key"
        """)
        defer { file.remove() }

        let captured = RequestRecorder()
        var provider = DevinAgentUsageProvider()
        provider.authStore = DevinAuthStore(
            credentialsFileURL: file.url,
            // No state database exists, so the app credential never appears —
            // this test instead verifies the rejected key yields authExpired.
            stateDatabaseURL: file.directory.appendingPathComponent("absent/state.vscdb"))
        provider.client = StubHTTPClient { request in
            captured.record(request)
            return AgentUsageHTTPResponse(statusCode: 401, headers: [:], body: Data())
        }

        let result = await provider.fetchUsage()
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .authExpired = failure {} else {
            Issue.record("expected authExpired, got \(failure)")
        }
        let request = try #require(captured.lastRequest)
        let body = try JSONSerialization.jsonObject(with: #require(request.body)) as? [String: Any]
        #expect((body?["metadata"] as? [String: Any])?["apiKey"] as? String == "sk-dead-key")
    }

    @Test("no credentials anywhere is not configured")
    func notConfigured() async throws {
        let file = try TemporaryCredentialFile(relativePath: "absent/credentials.toml")
        defer { file.remove() }

        var provider = DevinAgentUsageProvider()
        provider.authStore = DevinAuthStore(
            credentialsFileURL: file.url,
            stateDatabaseURL: file.directory.appendingPathComponent("absent/state.vscdb"))

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
