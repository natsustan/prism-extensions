import Foundation

/// Reads the Amp CLI's stored API key and queries the same `ampcode.com`
/// JSON-RPC endpoint as `amp usage`. Read-only: sign-in stays with the CLI.
struct AmpAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID = .amp
    let displayName = "Amp"
    let icon: AgentUsageProviderIcon = .asset("icons/amp.svg")

    var authStore = AmpAuthStore()
    var client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()

    func hasLocalCredentials() -> Bool {
        (try? authStore.loadCredentials()) != nil
    }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        let credentials: AmpCredentials
        do {
            credentials = try authStore.loadCredentials()
        } catch {
            return .failure(.notConfigured(
                "Not signed in. Run `amp login` to connect this Mac."))
        }

        let data: Data
        do {
            data = try await AmpUsageClient(client: client).fetchBalance(apiKey: credentials.apiKey)
        } catch {
            return .failure(Self.failure(from: error))
        }

        do {
            return .success(try AmpUsageMapper.report(from: data, fetchedAt: Date()))
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    static func failure(from error: Error) -> AgentUsageFailure {
        switch error {
        case AgentUsageClientError.unauthorized, AmpUsageError.authRejected:
            return .authExpired("Amp rejected the saved API key. Run `amp login` to refresh it.")
        case let AgentUsageClientError.http(status):
            return .network("Amp usage request failed (HTTP \(status)). Try again in a moment.")
        case AgentUsageClientError.transport:
            return .network("Could not reach Amp. Check the connection and try again.")
        case let AmpUsageError.requestFailed(message):
            return .invalidResponse("Amp usage request failed: \(message)")
        case AmpUsageError.invalidResponse, AgentUsageClientError.invalidResponse:
            return .invalidResponse("Amp returned an unexpected response.")
        default:
            return .invalidResponse("Amp usage could not be read.")
        }
    }
}
