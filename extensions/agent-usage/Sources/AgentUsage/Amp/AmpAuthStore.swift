import Foundation

/// The Amp CLI login stored on this Mac.
struct AmpCredentials: Equatable, Sendable {
    let apiKey: String
}

enum AmpAuthError: Error, Equatable, Sendable {
    /// No secrets file, no env var — the CLI was never signed in here.
    case notLoggedIn
}

/// Reads the API key the Amp CLI writes at `~/.local/share/amp/secrets.json`
/// (keys look like `apiKey@https://ampcode.com/`), falling back to the
/// `AMP_API_KEY` environment variable. Read-only: sign-in stays with the CLI.
struct AmpAuthStore: Sendable {
    var secretsFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/amp/secrets.json")
    var environment: [String: String] = ProcessInfo.processInfo.environment

    static let preferredSecretsKey = "apiKey@https://ampcode.com/"
    static let environmentName = "AMP_API_KEY"

    func loadCredentials() throws -> AmpCredentials {
        if let key = loadSecretsKey() { return AmpCredentials(apiKey: key) }
        if let key = environment[Self.environmentName]?.trimmedCredentialValue, !key.isEmpty {
            return AmpCredentials(apiKey: key)
        }
        throw AmpAuthError.notLoggedIn
    }

    private func loadSecretsKey() -> String? {
        guard let data = try? Data(contentsOf: secretsFileURL),
              let json = AgentUsageParse.jsonObject(data)
        else { return nil }
        return AgentUsageParse.string(json[Self.preferredSecretsKey])
    }
}
