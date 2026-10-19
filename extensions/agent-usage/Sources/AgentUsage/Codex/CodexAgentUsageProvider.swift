import Foundation

/// Reads the Codex CLI's stored ChatGPT login and turns it into a usage report.
///
/// Credential source mirrors the CLI: `$CODEX_HOME/auth.json` when set,
/// otherwise `~/.codex/auth.json`, then `~/.config/codex/auth.json`. Everything
/// here is read-only — Codex token refresh stays with the CLI, and a rejected
/// token surfaces as "run `codex login`".
struct CodexAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID = .codex
    let displayName = "Codex"
    let icon: AgentUsageProviderIcon = .asset("icons/codex.svg")

    var authStore: CodexAuthStore = CodexAuthStore()
    var client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()

    func hasLocalCredentials() -> Bool {
        (try? authStore.loadCredentials()) != nil
    }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        let optionalDeadline = AgentUsageTiming.current.enrichmentDeadline
        let credentials: CodexCredentials
        do {
            credentials = try authStore.loadCredentials()
        } catch CodexAuthError.apiKeyOnly {
            return .failure(.notConfigured(
                "Usage is not available for API-key logins. Run `codex login` to sign in with ChatGPT."))
        } catch {
            return .failure(.notConfigured("Not signed in. Run `codex login` to connect this Mac."))
        }

        let usageClient = CodexUsageClient(client: client)
        let usageData: Data
        do {
            usageData = try await usageClient.fetchUsage(credentials: credentials)
        } catch {
            return .failure(Self.failure(from: error))
        }

        // Optional reset credits must not consume the provider's entire budget
        // and discard the quota returned by the primary request.
        let resetCredits = await AgentUsageRequestBudget.optionalData(before: optionalDeadline) {
            try await usageClient.fetchResetCredits(credentials: credentials)
        }

        do {
            return .success(try CodexUsageMapper.report(
                from: usageData,
                resetCredits: resetCredits,
                credentials: credentials,
                fetchedAt: Date()
            ))
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    static func failure(from error: Error) -> AgentUsageFailure {
        switch error {
        case AgentUsageClientError.unauthorized:
            return .authExpired("Codex rejected the saved login. Run `codex login` to refresh it.")
        case let AgentUsageClientError.http(status):
            return .network("Codex usage request failed (HTTP \(status)). Try again in a moment.")
        case AgentUsageClientError.transport:
            return .network("Could not reach Codex. Check the connection and try again.")
        case AgentUsageClientError.invalidResponse:
            return .invalidResponse("Codex returned an unexpected response.")
        default:
            return .invalidResponse("Codex usage could not be read.")
        }
    }
}
