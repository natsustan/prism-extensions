import Foundation
import Testing
@testable import AgentUsage

@Suite("Grok auth store")
struct GrokAuthStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let liveKey = "https://auth.x.ai::client-live"
    private static let otherKey = "https://auth.x.ai::client-other"

    private static func authFile(
        liveToken: String = "live-token",
        liveRefresh: String = "live-refresh",
        liveExpiry: String = "2030-01-01T00:00:00.000000Z",
        otherToken: String = "other-token",
        otherRefresh: String = "other-refresh",
        legacy: String? = nil
    ) -> String {
        var entries = [
            Self.liveKey: """
            {"key": "\(liveToken)", "refresh_token": "\(liveRefresh)", "expires_at": "\(liveExpiry)",
             "oidc_client_id": "client-live", "email": "person@example.com", "first_name": "Test",
             "last_name": "Person", "auth_mode": "supergrok", "team_id": "team-1",
             "coding_data_retention_opt_out": false}
            """,
            Self.otherKey: """
            {"key": "\(otherToken)", "refresh_token": "\(otherRefresh)", "expires_at": "2020-01-01T00:00:00Z",
             "oidc_client_id": "client-other", "email": "other@example.com"}
            """,
        ]
        if let legacy {
            entries["https://accounts.x.ai/sign-in"] = legacy
        }
        let body = entries
            .sorted { $0.key < $1.key }
            .map { "\"\($0.key)\": \($0.value)" }
            .joined(separator: ",\n  ")
        return "{\n  \(body)\n}"
    }

    @Test("the live OIDC entry wins and its account details come along")
    func selectsLiveEntry() throws {
        let file = try TemporaryCredentialFile(
            relativePath: ".grok/auth.json", contents: Self.authFile())
        defer { file.remove() }

        let store = GrokAuthStore(authFilePath: file.url, now: { Self.now })
        let credentials = try store.loadCredentials()

        #expect(credentials.accessToken == "live-token")
        #expect(credentials.refreshToken == "live-refresh")
        #expect(credentials.clientID == "client-live")
        #expect(credentials.entryKey == Self.liveKey)
        #expect(credentials.email == "person@example.com")
        #expect(credentials.displayName == "Test Person")
        #expect(credentials.teamID == "team-1")
    }

    @Test("a legacy sign-in entry is used when no OIDC entry exists")
    func legacyEntryFallback() throws {
        let legacy = """
        {"key": "legacy-token", "oidc_client_id": "client-legacy", "email": "legacy@example.com"}
        """
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {"https://accounts.x.ai/sign-in": \(legacy)}
        """)
        defer { file.remove() }

        let store = GrokAuthStore(authFilePath: file.url, now: { Self.now })
        #expect(try store.loadCredentials().accessToken == "legacy-token")
    }

    @Test("JWT expiry and recorded expiry both constrain credential liveness",
          arguments: ["missing", "future", "past"], [false, true])
    func jwtExpiryAffectsSelection(recorded: String, jwtExpired: Bool) throws {
        let expiry = Self.now.addingTimeInterval(jwtExpired ? -60 : 3600).timeIntervalSince1970
        let payload = Data("{\"exp\":\(expiry)}".utf8).base64EncodedString()
        let token = "header.\(payload).signature"
        let recordedField = recorded == "missing" ? "" :
            ", \"expires_at\":\"\(recorded == "past" ? "2020" : "2030")-01-01T00:00:00Z\""
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {
            "https://auth.x.ai::client": {"key":"\(token)"\(recordedField)},
            "unscoped": {"key":"fallback-token", "expires_at":"2030-01-01T00:00:00Z"}
        }
        """)
        defer { file.remove() }
        let store = GrokAuthStore(authFilePath: file.url, now: { Self.now })
        let expected = jwtExpired || recorded == "past" ? "fallback-token" : token
        #expect(try store.loadCredentials().accessToken == expected)
    }

    @Test("credential liveness takes priority over OIDC scope", arguments: [false, true], [false, true])
    func prefersLiveCredentials(oidcExpired: Bool, fallbackExpired: Bool) throws {
        for fallbackKey in ["https://accounts.x.ai/sign-in", "unscoped"] {
            let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
            {
                "https://auth.x.ai::client": {
                    "key":"oidc-token", "expires_at":"\(oidcExpired ? "2020" : "2030")-01-01T00:00:00Z"
                },
                "\(fallbackKey)": {
                    "key":"fallback-token", "expires_at":"\(fallbackExpired ? "2020" : "2030")-01-01T00:00:00Z"
                }
            }
            """)
            defer { file.remove() }
            let store = GrokAuthStore(authFilePath: file.url, now: { Self.now })
            let expected = oidcExpired && !fallbackExpired ? "fallback-token" : "oidc-token"
            #expect(try store.loadCredentials().accessToken == expected)
        }
    }

    @Test("a fallback with unknown expiry is preferred to a known expired OIDC token")
    func unknownFallbackExpiry() throws {
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {
            "https://auth.x.ai::client": {"key":"expired-token", "expires_at":"2020-01-01T00:00:00Z"},
            "unscoped": {"key":"fallback-token"}
        }
        """)
        defer { file.remove() }
        let store = GrokAuthStore(authFilePath: file.url, now: { Self.now })
        #expect(try store.loadCredentials().accessToken == "fallback-token")
    }

    @Test("the client id falls back to the entry key and then to the CLI default")
    func clientIDFallback() throws {
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {"https://auth.x.ai::client-from-key": {"key": "token", "expires_at": "2030-01-01T00:00:00Z"}}
        """)
        defer { file.remove() }

        let store = GrokAuthStore(authFilePath: file.url, now: { Self.now })
        #expect(try store.loadCredentials().clientID == "client-from-key")

        let unnamed = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {"unscoped": {"key": "token", "expires_at": "2030-01-01T00:00:00Z"}}
        """)
        defer { unnamed.remove() }
        let fallbackStore = GrokAuthStore(authFilePath: unnamed.url, now: { Self.now })
        #expect(try fallbackStore.loadCredentials().clientID == GrokAuthStore.defaultClientID)
    }

    @Test("a missing auth file reads as not signed in")
    func missingFile() throws {
        let file = try TemporaryCredentialFile(relativePath: ".grok/keep.txt", contents: "x")
        defer { file.remove() }

        let store = GrokAuthStore(authFilePath: file.directory.appendingPathComponent(".grok/auth.json"),
                                  now: { Self.now })
        #expect(throws: GrokAuthError.notLoggedIn) { try store.loadCredentials() }
    }

    @Test("a file whose entries carry no access token reads as a broken login")
    func unusableEntries() throws {
        let file = try TemporaryCredentialFile(relativePath: ".grok/auth.json", contents: """
        {"https://auth.x.ai::client-live": {"key": "   ", "refresh_token": "r"}}
        """)
        defer { file.remove() }

        let store = GrokAuthStore(authFilePath: file.url, now: { Self.now })
        #expect(throws: GrokAuthError.invalidAuth) { try store.loadCredentials() }
    }

    @Test("the access token's own expiry is read from the JWT")
    func jwtExpiry() {
        // {"exp": 4102444800} → 2100-01-01
        let payloadJSON = #"{"exp": 4102444800}"#
        let payload = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let token = "header.\(payload).signature"
        #expect(AgentUsageISO8601.jwtExpiry(token) == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(AgentUsageISO8601.jwtExpiry("not-a-jwt") == nil)
    }
}
