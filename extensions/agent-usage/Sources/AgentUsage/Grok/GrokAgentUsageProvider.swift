import Foundation

/// Reads the Grok CLI's saved xAI session, renews it under the CLI's shared
/// credential lock when needed, and queries its billing proxy.
struct GrokAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID = .grok
    let displayName = "Grok"
    let icon: AgentUsageProviderIcon = .asset("icons/grok.svg")

    var authStore = GrokAuthStore()
    var client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()
    var now: @Sendable () -> Date = Date.init

    func hasLocalCredentials() -> Bool {
        (try? authStore.loadCredentials()) != nil
    }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        // Leave time to deliver decoded quota before the controller's ceiling.
        // A monotonic deadline includes credits latency.
        let settingsDeadline = AgentUsageTiming.current.enrichmentDeadline
        let credentials: GrokCredentials
        do {
            credentials = try authStore.loadCredentials()
        } catch {
            return .failure(.notConfigured("Not signed in. Run `grok login` to connect this Mac."))
        }

        let usageClient = GrokUsageClient(client: client)
        var active = credentials
        if authStore.needsRefresh(active),
           let refreshed = try? await refreshCredentials(
               usageClient: usageClient, replacing: active, force: false)
        {
            active = refreshed
        }

        let creditsData: Data
        do {
            creditsData = try await usageClient.fetchCredits(accessToken: active.accessToken)
        } catch AgentUsageClientError.unauthorized {
            do {
                active = try await refreshCredentials(
                    usageClient: usageClient, replacing: active, force: true)
            } catch {
                return .failure(Self.failure(from: error))
            }
            do {
                creditsData = try await usageClient.fetchCredits(accessToken: active.accessToken)
            } catch {
                return .failure(Self.failure(from: error))
            }
        } catch {
            return .failure(Self.failure(from: error))
        }

        let config: GrokUsageMapper.CreditsConfig
        do {
            config = try GrokUsageMapper.decodeCreditsConfig(creditsData)
        } catch {
            return .failure(Self.failure(from: error))
        }

        // The plan name is display sugar; a failure here keeps the quota rows.
        let settingsToken = active.accessToken
        let settings = await AgentUsageRequestBudget.optionalData(before: settingsDeadline) {
            try await usageClient.fetchSettings(accessToken: settingsToken)
        }
        let plan = settings.flatMap(GrokUsageMapper.planName(fromSettings:))

        return .success(GrokUsageMapper.report(
            config: config,
            credentials: active,
            plan: plan,
            fetchedAt: now()
        ))
    }

    private func refreshCredentials(
        usageClient: GrokUsageClient,
        replacing previous: GrokCredentials,
        force: Bool
    ) async throws -> GrokCredentials {
        // Grok CLI uses this same persistent flock. Re-read only after the
        // lock is held so another process's completed rotation always wins.
        let lock = try await authStore.acquireCredentialLock()
        defer { withExtendedLifetime(lock) {} }
        let current = try authStore.loadCredentials()
        if current.accessToken != previous.accessToken {
            return current
        }
        guard current.refreshToken != nil, current.issuerURL != nil else {
            throw AgentUsageClientError.unauthorized
        }
        if !force, !authStore.needsRefresh(current) {
            return current
        }
        let response = try await usageClient.refresh(credentials: current)
        return try authStore.persistRefreshed(response, for: current)
    }

    static func failure(from error: Error) -> AgentUsageFailure {
        switch error {
        case AgentUsageClientError.unauthorized:
            return .authExpired("Grok rejected the saved login. Run `grok login` to refresh it.")
        case let AgentUsageClientError.http(status):
            return .network("Grok usage request failed (HTTP \(status)). Try again in a moment.")
        case AgentUsageClientError.transport:
            return .network("Could not reach Grok. Check the connection and try again.")
        case AgentUsageClientError.invalidResponse:
            return .invalidResponse("Grok returned an unexpected response.")
        default:
            return .invalidResponse("Grok usage could not be read.")
        }
    }
}
