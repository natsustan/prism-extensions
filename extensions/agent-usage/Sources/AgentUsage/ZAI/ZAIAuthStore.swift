import Foundation

/// A Z.ai (Zhipu AI) API key found on this Mac.
struct ZAICredentials: Equatable, Sendable {
    let apiKey: String
}

enum ZAIAuthError: Error, Equatable, Sendable {
    case missingKey
}

/// Z.ai's GLM Coding Plan has no companion CLI that stashes a credential, so
/// the key comes from places the user can actually reach from a GUI app.
/// First match wins:
///
/// 1. The key saved in Agent Usage settings (Keychain). An explicit choice for
///    this copy of Prism outranks everything else.
/// 2. `ZAI_API_KEY` / `GLM_API_KEY` environment variables (the legacy Zhipu
///    name is still accepted).
/// 3. `~/.config/zai/key.json` — `{"apiKey": "…"}` (`api_key`/`key` work too),
///    or a plain-text file containing only the key.
/// 4. `~/.claude/settings.json` — a `env.ANTHROPIC_AUTH_TOKEN` paired with a
///    `env.ANTHROPIC_BASE_URL` pointing at z.ai, the way the coding plan is
///    usually wired into Claude Code.
///
/// A GUI app does not inherit a login shell's environment, so the Keychain and
/// the file sources are what a packaged build can actually see. File sources
/// stay read-only; only the settings key is written, and only from Settings.
struct ZAIAuthStore: Sendable {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var configFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/zai/key.json")
    var claudeSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    /// Empty unless production wires this to the extension's saved key. Tests pass their own
    /// closure so a developer key saved in Settings cannot leak into fixtures.
    var storedKey: @Sendable () throws -> String? = { nil }

    static let environmentNames = ["ZAI_API_KEY", "GLM_API_KEY"]

    func loadCredentials() throws -> ZAICredentials {
        if let key = try loadAPIKey() { return ZAICredentials(apiKey: key) }
        throw ZAIAuthError.missingKey
    }

    func loadAPIKey() throws -> String? {
        if let key = try storedKey()?.trimmedCredentialValue.nilIfEmpty { return key }
        for name in Self.environmentNames {
            if let key = environment[name]?.trimmedCredentialValue.nilIfEmpty { return key }
        }
        if let key = loadConfigFileKey() { return key }
        return loadClaudeSettingsKey()
    }

    private func loadConfigFileKey() -> String? {
        guard let raw = try? String(contentsOf: configFileURL, encoding: .utf8) else { return nil }
        let text = raw.trimmedCredentialValue
        guard !text.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            for field in ["apiKey", "api_key", "key"] {
                if let key = AgentUsageParse.string(json[field]) { return key }
            }
            return nil
        }
        // Plain-text file holding only the key.
        return text.contains(where: { $0.isWhitespace }) ? nil : text
    }

    /// Claude Code points at z.ai through `ANTHROPIC_BASE_URL`; when it does,
    /// the paired auth token is the coding-plan key.
    private func loadClaudeSettingsKey() -> String? {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let baseURL = (env["ANTHROPIC_BASE_URL"] as? String)
                .flatMap(URLComponents.init(string:)),
              baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host?.lowercased(),
              host == "z.ai" || host.hasSuffix(".z.ai")
        else { return nil }
        return AgentUsageParse.string(env["ANTHROPIC_AUTH_TOKEN"])
    }
}
