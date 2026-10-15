import Foundation

/// Calls the ChatGPT backend endpoints the Codex CLI uses for its own `/status`.
/// Only reads: the reset-credit *consume* endpoint is deliberately not wired up.
struct CodexUsageClient: Sendable {
    var client: any AgentUsageHTTPClient

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    init(client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()) {
        self.client = client
    }

    func fetchUsage(credentials: CodexCredentials) async throws -> Data {
        try await send(url: Self.usageURL, credentials: credentials, timeout: 10)
    }

    /// Extra row only; a failure here is tolerated by the caller.
    func fetchResetCredits(credentials: CodexCredentials) async throws -> Data {
        try await send(
            url: Self.resetCreditsURL,
            credentials: credentials,
            timeout: 4,
            extraHeaders: ["OpenAI-Beta": "codex-1", "originator": "Codex Desktop"]
        )
    }

    private func send(
        url: URL,
        credentials: CodexCredentials,
        timeout: TimeInterval,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "User-Agent": "Prism/1.0 (macOS)",
        ]
        if let accountID = credentials.accountID {
            headers["ChatGPT-Account-ID"] = accountID
        }
        headers.merge(extraHeaders) { _, new in new }

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
