import Foundation

/// Reports GLM Coding Plan quota through the endpoints Z.ai's own subscription
/// UI calls. The API key comes from Agent Usage settings, or from a key the
/// user already keeps on this Mac. Prism writes only the settings key.
struct ZAIAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID = .zai
    let displayName = "Z.ai"
    let icon: AgentUsageProviderIcon = .asset("icons/zai.svg")

    var authStore = ZAIAuthStore()
    var client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()

    func hasLocalCredentials() -> Bool {
        // Keep the row available so a refresh can show a Keychain read error.
        // A failed read cannot establish that the saved key is absent.
        do { return try authStore.loadAPIKey() != nil }
        catch { return true }
    }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        let subscriptionDeadline = AgentUsageTiming.current.enrichmentDeadline
        let apiKey: String
        do {
            guard let key = try authStore.loadAPIKey() else {
                return .failure(.notConfigured(
                    "No Z.ai API key. Add one in Agent Usage settings, or export ZAI_API_KEY, or save it to ~/.config/zai/key.json."))
            }
            apiKey = key
        } catch {
            return .failure(.invalidResponse(
                "Could not read the Z.ai API key from the Keychain. Unlock it and try again."))
        }

        let usageClient = ZAIUsageClient(client: client)
        let quota: AgentUsageHTTPResponse
        do {
            let response = try await usageClient.fetchQuota(apiKey: apiKey)
            switch response.statusCode {
            case 401, 403: throw AgentUsageClientError.unauthorized
            case 200..<300: quota = response
            default: throw AgentUsageClientError.http(response.statusCode)
            }
        } catch {
            return .failure(Self.failure(from: error))
        }

        // A valid key with no GLM Coding Plan gets a 2xx `success:false`:
        // surface the reason rather than blank meters.
        if ZAIUsageMapper.isNoCodingPlan(quota.body) {
            return .failure(.notConfigured(
                "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage."))
        }

        // The subscription call is plan-name sugar; it must not blank the meters.
        let subscription = await AgentUsageRequestBudget.optionalData(before: subscriptionDeadline) {
            let response = try await usageClient.fetchSubscription(apiKey: apiKey)
            guard response.isSuccess else { throw AgentUsageClientError.http(response.statusCode) }
            return response.body
        }

        do {
            return .success(try ZAIUsageMapper.report(
                quotaBody: quota.body,
                subscriptionBody: subscription,
                fetchedAt: Date()))
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    static func failure(from error: Error) -> AgentUsageFailure {
        switch error {
        case AgentUsageClientError.unauthorized:
            return .authExpired(
                "Z.ai rejected the API key. Check it at z.ai/manage-apikey/apikey-list.")
        case let AgentUsageClientError.http(status):
            return .network("Z.ai usage request failed (HTTP \(status)). Try again in a moment.")
        case AgentUsageClientError.transport:
            return .network("Could not reach Z.ai. Check the connection and try again.")
        case ZAIUsageError.noCodingPlan:
            return .notConfigured("No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage.")
        case ZAIUsageError.invalidResponse, AgentUsageClientError.invalidResponse:
            return .invalidResponse("Z.ai returned an unexpected response.")
        default:
            return .invalidResponse("Z.ai usage could not be read.")
        }
    }
}
