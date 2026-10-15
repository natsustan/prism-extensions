import Foundation

/// Calls the Connect-RPC `GetUserStatus` endpoint the Devin app and CLI use.
/// Auth rides inside the JSON metadata (there is no Authorization header).
struct DevinUsageClient: Sendable {
    var client: any AgentUsageHTTPClient

    static let cloudService = "exa.seat_management_pb.SeatManagementService"
    /// The client version Devin's own calls claim, kept current enough that the
    /// server keeps answering.
    static let cloudCompatVersion = "1.108.2"

    init(client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()) {
        self.client = client
    }

    func fetchUserStatus(
        credentials: DevinCredentials,
        apiServerURL: String
    ) async throws -> AgentUsageHTTPResponse {
        guard let url = URL(string: "\(apiServerURL)/\(Self.cloudService)/GetUserStatus") else {
            throw AgentUsageClientError.invalidResponse
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "apiKey": credentials.apiKey,
                "ideName": "devin",
                "ideVersion": Self.cloudCompatVersion,
                "extensionName": "devin",
                "extensionVersion": Self.cloudCompatVersion,
                "locale": "en",
            ],
        ])
        let response: AgentUsageHTTPResponse
        try Task.checkCancellation()
        do {
            response = try await client.send(AgentUsageHTTPRequest(
                url: url,
                method: "POST",
                headers: [
                    "Content-Type": "application/json",
                    "Connect-Protocol-Version": "1",
                    "Accept": "application/json",
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
        case 200..<300: return response
        case 401, 403: throw AgentUsageClientError.unauthorized
        default: throw AgentUsageClientError.http(response.statusCode)
        }
    }
}
