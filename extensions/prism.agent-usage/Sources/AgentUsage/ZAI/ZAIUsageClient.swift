import Foundation

/// Calls the two endpoints Z.ai's own subscription UI uses: the quota meters
/// (required) and the subscription list (plan name only, best-effort).
struct ZAIUsageClient: Sendable {
    var client: any AgentUsageHTTPClient

    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!

    init(client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()) {
        self.client = client
    }

    func fetchQuota(apiKey: String) async throws -> AgentUsageHTTPResponse {
        try await get(Self.quotaURL, apiKey: apiKey)
    }

    func fetchSubscription(apiKey: String) async throws -> AgentUsageHTTPResponse {
        try await get(Self.subscriptionURL, apiKey: apiKey)
    }

    private func get(_ url: URL, apiKey: String) async throws -> AgentUsageHTTPResponse {
        let response: AgentUsageHTTPResponse
        try Task.checkCancellation()
        do {
            response = try await client.send(AgentUsageHTTPRequest(
                url: url,
                headers: [
                    "Authorization": "Bearer \(apiKey)",
                    "Accept": "application/json",
                    "User-Agent": "Prism/1.0 (macOS)",
                ],
                timeout: 10
            ))
        } catch {
            try Task.checkCancellation()
            throw AgentUsageClientError.transport
        }
        try Task.checkCancellation()
        return response
    }
}
