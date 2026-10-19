import Foundation

/// Calls the JSON-RPC endpoint the Amp CLI's own `amp usage` uses. The reply
/// carries a pre-rendered `displayText` block, which the mapper parses.
struct AmpUsageClient: Sendable {
    var client: any AgentUsageHTTPClient

    static let apiURL = URL(string: "https://ampcode.com/api/internal")!

    init(client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()) {
        self.client = client
    }

    func fetchBalance(apiKey: String) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: [
            "method": "userDisplayBalanceInfo",
            "params": [String: String](),
        ])
        let response: AgentUsageHTTPResponse
        try Task.checkCancellation()
        do {
            response = try await client.send(AgentUsageHTTPRequest(
                url: Self.apiURL,
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(apiKey)",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "User-Agent": "Prism/1.0 (macOS)",
                ],
                body: body,
                timeout: 10
            ))
        } catch {
            try Task.checkCancellation()
            throw AgentUsageClientError.transport
        }
        try Task.checkCancellation()
        switch response.statusCode {
        case 200..<300: return response.body
        case 401, 403: throw AgentUsageClientError.unauthorized
        default: throw AgentUsageClientError.http(response.statusCode)
        }
    }
}
