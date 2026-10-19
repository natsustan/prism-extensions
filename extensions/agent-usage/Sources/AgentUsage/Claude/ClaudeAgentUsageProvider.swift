import Foundation

/// Reads Claude Code's stored claude.ai login and turns it into a usage report.
///
/// Read-only like Codex: Claude Code renews its own token whenever it runs, and
/// a rejected or expired token surfaces as "run `claude`".
struct ClaudeAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID = .claude
    let displayName = "Claude"
    let icon: AgentUsageProviderIcon = .asset("icons/claude.svg")

    var authStore = ClaudeAuthStore()
    var client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()

    func hasLocalCredentials() -> Bool {
        authStore.hasCredentials()
    }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        let optionalDeadline = AgentUsageTiming.current.enrichmentDeadline
        let credentials: ClaudeCredentials
        do {
            credentials = try await authStore.loadCredentials()
        } catch is CancellationError {
            return .failure(.network("Cancelled."))
        } catch {
            return .failure(.notConfigured("Not signed in. Run `claude` and sign in to connect this Mac."))
        }
        guard credentials.canReadUsage else {
            return .failure(.notConfigured(
                "This Claude Code token cannot read usage. Run `claude` and use /login to sign in with claude.ai."))
        }

        let usageClient = ClaudeUsageClient(client: client)
        let usageData: Data
        do {
            usageData = try await usageClient.fetchUsage(credentials: credentials)
        } catch {
            return .failure(Self.failure(from: error))
        }

        // The account email is display sugar; it must not cost the quota rows.
        let profile = await AgentUsageRequestBudget.optionalData(before: optionalDeadline) {
            try await usageClient.fetchProfile(credentials: credentials)
        }

        do {
            return .success(try ClaudeUsageMapper.report(
                from: usageData,
                profile: profile,
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
            return .authExpired("Claude rejected the saved login. Run `claude` to refresh it.")
        case AgentUsageClientError.http(429):
            return .network("Claude is rate limiting usage requests. Try again in a few minutes.")
        case let AgentUsageClientError.http(status):
            return .network("Claude usage request failed (HTTP \(status)). Try again in a moment.")
        case AgentUsageClientError.transport:
            return .network("Could not reach Claude. Check the connection and try again.")
        case AgentUsageClientError.invalidResponse:
            return .invalidResponse("Claude returned an unexpected response.")
        default:
            return .invalidResponse("Claude usage could not be read.")
        }
    }
}
