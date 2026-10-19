import Foundation

/// Calls the claude.ai OAuth endpoints Claude Code uses for its own `/usage`.
struct ClaudeUsageClient: Sendable {
    var client: any AgentUsageHTTPClient

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let betaHeader = "oauth-2025-04-20"

    init(client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()) {
        self.client = client
    }

    func fetchUsage(credentials: ClaudeCredentials) async throws -> Data {
        try await send(url: Self.usageURL, credentials: credentials, timeout: 10)
    }

    /// Account email only; a failure here is tolerated by the caller.
    func fetchProfile(credentials: ClaudeCredentials) async throws -> Data {
        try await send(url: Self.profileURL, credentials: credentials, timeout: 4)
    }

    private func send(
        url: URL,
        credentials: ClaudeCredentials,
        timeout: TimeInterval
    ) async throws -> Data {
        let headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "anthropic-beta": Self.betaHeader,
            "User-Agent": "Prism/1.0 (macOS)",
        ]

        let response: AgentUsageHTTPResponse
        try Task.checkCancellation()
        do {
            response = try await client.send(
                AgentUsageHTTPRequest(url: url, headers: headers, timeout: timeout))
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
