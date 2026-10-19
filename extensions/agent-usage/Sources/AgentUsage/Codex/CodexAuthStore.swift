import Foundation

/// The ChatGPT login the Codex CLI stores on disk.
struct CodexCredentials: Equatable, Sendable {
    let accessToken: String
    let accountID: String?
}

enum CodexAuthError: Error, Equatable, Sendable {
    /// No auth file, or one without a usable ChatGPT access token.
    case notLoggedIn
    /// Signed in with a plain API key, which has no quota endpoints.
    case apiKeyOnly
}

/// Reads `auth.json` without ever writing to it. Codex token refresh stays with
/// the CLI: this Mac may be running it at the same time, and a rotated refresh
/// token written from here could log the CLI out.
struct CodexAuthStore: Sendable {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    /// `$CODEX_HOME` wins outright (that is what the CLI does); otherwise the
    /// two documented locations are probed in order.
    var authFileURLs: [URL] {
        if let codexHome = environment["CODEX_HOME"]?.trimmedCredentialValue, !codexHome.isEmpty {
            return [Self.expandingTilde(codexHome, homeDirectory: homeDirectory)
                .appendingPathComponent("auth.json")]
        }
        return [
            homeDirectory.appendingPathComponent(".codex/auth.json"),
            homeDirectory.appendingPathComponent(".config/codex/auth.json"),
        ]
    }

    func loadCredentials() throws -> CodexCredentials {
        var sawAPIKey = false
        for url in authFileURLs {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            let tokens = json["tokens"] as? [String: Any]
            if let accessToken = (tokens?["access_token"] as? String)?.trimmedCredentialValue, !accessToken.isEmpty {
                let accountID = ((tokens?["account_id"] as? String)
                    ?? (tokens?["accountId"] as? String))?.trimmedCredentialValue
                return CodexCredentials(
                    accessToken: accessToken,
                    accountID: accountID?.isEmpty == true ? nil : accountID
                )
            }
            if let apiKey = (json["OPENAI_API_KEY"] as? String)?.trimmedCredentialValue, !apiKey.isEmpty {
                sawAPIKey = true
            }
        }
        throw sawAPIKey ? CodexAuthError.apiKeyOnly : CodexAuthError.notLoggedIn
    }

    static func expandingTilde(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}

extension StringProtocol {
    /// Shared by the auth stores, which parse whitespace-padded credential files.
    var trimmedCredentialValue: String {
        String(self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when the string is empty — credential fields and payload strings
    /// treat blank as absent.
    var nilIfEmpty: String? { isEmpty ? nil : String(self) }
}
