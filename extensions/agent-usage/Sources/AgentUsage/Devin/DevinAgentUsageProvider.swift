import Foundation

/// Reads Devin's quota through the Connect-RPC `GetUserStatus` endpoint, using
/// the Devin CLI's credentials file first and the Devin app's stored auth as a
/// fallback. Read-only: a rejected key is reported, never refreshed here.
struct DevinAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID = .devin
    let displayName = "Devin"
    let icon: AgentUsageProviderIcon = .asset("icons/devin.svg")

    var authStore = DevinAuthStore()
    var client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()

    func hasLocalCredentials() -> Bool {
        authStore.loadCredentialsFile() != nil || authStore.loadAppCredentials() != nil
    }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        var sawAuthFailure = false
        var sawCredentials = false

        // The app's auth is worth trying when the file login is absent or was
        // rejected — it may hold a different, working account.
        let candidates = [
            authStore.loadCredentialsFile(),
            authStore.loadAppCredentials(),
        ].compactMap { $0 }

        var lastError: Error?
        var attempted: Set<String> = []
        for credentials in candidates {
            sawCredentials = true
            // The same key can't succeed twice; skip the duplicate source.
            guard attempted.insert(credentials.apiKey).inserted else { continue }
            do {
                let response = try await DevinUsageClient(client: client).fetchUserStatus(
                    credentials: credentials,
                    apiServerURL: authStore.effectiveAPIServerURL(credentials))
                return .success(try DevinUsageMapper.report(from: response.body, fetchedAt: Date()))
            } catch AgentUsageClientError.unauthorized {
                sawAuthFailure = true
            } catch {
                lastError = error
            }
        }

        if sawAuthFailure {
            return .failure(.authExpired(
                localized("Devin rejected the saved login. Run `devin auth login` or sign in to the Devin app again.")))
        }
        if sawCredentials {
            return .failure(Self.failure(from: lastError ?? DevinUsageError.quotaUnavailable))
        }
        return .failure(.notConfigured(
            localized("Not signed in. Run `devin auth login` or sign in to the Devin app.")))
    }

    static func failure(from error: Error) -> AgentUsageFailure {
        switch error {
        case let AgentUsageClientError.http(status):
            return .network(localized("Devin usage request failed (HTTP \(status)). Try again in a moment."))
        case AgentUsageClientError.transport:
            return .network(localized("Could not reach Devin. Check the connection and try again."))
        case DevinUsageError.quotaUnavailable:
            return .invalidResponse(localized("Devin quota data is unavailable. Try again later."))
        case DevinUsageError.invalidResponse, AgentUsageClientError.invalidResponse:
            return .invalidResponse(localized("Devin returned an unexpected response."))
        default:
            return .invalidResponse(localized("Devin usage could not be read."))
        }
    }
}
