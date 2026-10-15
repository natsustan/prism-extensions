import Foundation
import Testing
@testable import AgentUsage

@Suite("Codex auth store")
struct CodexAuthStoreTests {
    @Test("reads the ChatGPT access token and account id from the auth file")
    func readsCredentials() throws {
        let file = try TemporaryCredentialFile(relativePath: ".codex/auth.json", contents: """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "test-access-token",
            "refresh_token": "test-refresh-token",
            "id_token": "test-id-token",
            "account_id": "acct-test"
          },
          "last_refresh": "2026-09-09T15:28:56.047081Z"
        }
        """)
        defer { file.remove() }

        let store = CodexAuthStore(environment: [:], homeDirectory: file.directory)
        let credentials = try store.loadCredentials()

        #expect(credentials.accessToken == "test-access-token")
        #expect(credentials.accountID == "acct-test")
    }

    @Test("CODEX_HOME replaces the default location")
    func codexHomeOverride() throws {
        let file = try TemporaryCredentialFile(relativePath: "auth.json", contents: """
        {"tokens": {"access_token": "override-token", "account_id": "acct-override"}}
        """)
        defer { file.remove() }

        let store = CodexAuthStore(
            environment: ["CODEX_HOME": file.directory.path],
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home")
        )
        let credentials = try store.loadCredentials()
        #expect(credentials.accessToken == "override-token")
        #expect(credentials.accountID == "acct-override")
    }

    @Test("~/.config/codex is the fallback when ~/.codex has no auth file")
    func configFallback() throws {
        let file = try TemporaryCredentialFile(relativePath: ".config/codex/auth.json", contents: """
        {"tokens": {"access_token": "config-token"}}
        """)
        defer { file.remove() }

        let store = CodexAuthStore(environment: [:], homeDirectory: file.directory)
        let credentials = try store.loadCredentials()
        #expect(credentials.accessToken == "config-token")
        #expect(credentials.accountID == nil)
    }

    @Test("an API-key-only login is called out instead of reported as signed out")
    func apiKeyOnly() throws {
        let file = try TemporaryCredentialFile(relativePath: ".codex/auth.json", contents: """
        {"auth_mode": "api-key", "OPENAI_API_KEY": "sk-test", "tokens": {}}
        """)
        defer { file.remove() }

        let store = CodexAuthStore(environment: [:], homeDirectory: file.directory)
        #expect(throws: CodexAuthError.apiKeyOnly) { try store.loadCredentials() }
    }

    @Test("no auth file at all reads as not signed in")
    func notLoggedIn() throws {
        let file = try TemporaryCredentialFile(relativePath: ".codex/keep.txt", contents: "x")
        defer { file.remove() }

        let store = CodexAuthStore(environment: [:], homeDirectory: file.directory)
        #expect(throws: CodexAuthError.notLoggedIn) { try store.loadCredentials() }
        #expect(store.authFileURLs.count == 2)
    }

    @Test("a token-less auth file is not mistaken for an API-key login")
    func tokenlessFile() throws {
        let file = try TemporaryCredentialFile(relativePath: ".codex/auth.json", contents: """
        {"auth_mode": "chatgpt", "tokens": {"refresh_token": "only-refresh"}}
        """)
        defer { file.remove() }

        let store = CodexAuthStore(environment: [:], homeDirectory: file.directory)
        #expect(throws: CodexAuthError.notLoggedIn) { try store.loadCredentials() }
    }
}
