import Foundation

struct GrokTokenRefreshResponse: Decodable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Calls the Grok CLI's own billing proxy: the same base URL, path, and
/// `X-XAI-Token-Auth` header the CLI's `billing.rs` uses, so it inherits the
/// CLI's stability guarantees instead of reverse-engineering grok.com's
/// gRPC-web surface.
struct GrokUsageClient: Sendable {
    var client: any AgentUsageHTTPClient

    static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    static let tokenAuthHeader = "xai-grok-cli"

    init(client: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()) {
        self.client = client
    }

    func fetchCredits(accessToken: String) async throws -> Data {
        try await send(url: Self.creditsURL, accessToken: accessToken, timeout: 10)
    }

    /// Plan name only; the caller tolerates a failure here.
    func fetchSettings(accessToken: String) async throws -> Data {
        try await send(url: Self.settingsURL, accessToken: accessToken, timeout: 10)
    }

    func refresh(credentials: GrokCredentials) async throws -> GrokTokenRefreshResponse {
        guard let refreshToken = credentials.refreshToken,
              let issuerURL = credentials.issuerURL
        else { throw AgentUsageClientError.unauthorized }

        let configurationURL = issuerURL
            .appendingPathComponent(".well-known/openid-configuration")
        let configuration = try await perform(AgentUsageHTTPRequest(
            url: configurationURL,
            headers: ["Accept": "application/json"],
            timeout: 10
        ))
        struct OpenIDConfiguration: Decodable {
            let tokenEndpoint: URL

            enum CodingKeys: String, CodingKey {
                case tokenEndpoint = "token_endpoint"
            }
        }
        let tokenEndpoint: URL
        do {
            tokenEndpoint = try JSONDecoder().decode(
                OpenIDConfiguration.self, from: configuration.body).tokenEndpoint
        } catch {
            throw AgentUsageClientError.invalidResponse
        }

        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.clientID,
        ]
        if let principalType = credentials.principalType { fields["principal_type"] = principalType }
        if let principalID = credentials.principalID { fields["principal_id"] = principalID }
        let body = fields.sorted { $0.key < $1.key }
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
        let response = try await perform(AgentUsageHTTPRequest(
            url: tokenEndpoint,
            method: "POST",
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
                "User-Agent": "Prism/1.0 (macOS)",
            ],
            body: Data(body.utf8),
            timeout: 10
        ), recognizesInvalidGrant: true)
        do {
            let decoded = try JSONDecoder().decode(GrokTokenRefreshResponse.self, from: response.body)
            let accessToken = decoded.accessToken.trimmedCredentialValue
            guard !accessToken.isEmpty else { throw AgentUsageClientError.invalidResponse }
            let refreshToken = decoded.refreshToken?.trimmedCredentialValue
            return GrokTokenRefreshResponse(
                accessToken: accessToken,
                refreshToken: refreshToken?.isEmpty == true ? nil : refreshToken,
                expiresIn: decoded.expiresIn
            )
        } catch {
            throw AgentUsageClientError.invalidResponse
        }
    }

    private func send(url: URL, accessToken: String, timeout: TimeInterval) async throws -> Data {
        try await perform(AgentUsageHTTPRequest(
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-XAI-Token-Auth": Self.tokenAuthHeader,
                "Accept": "application/json",
                "User-Agent": "Prism/1.0 (macOS)",
            ],
            timeout: timeout
        )).body
    }

    private func perform(
        _ request: AgentUsageHTTPRequest,
        recognizesInvalidGrant: Bool = false
    ) async throws -> AgentUsageHTTPResponse {
        let response: AgentUsageHTTPResponse
        try Task.checkCancellation()
        do {
            response = try await client.send(request)
        } catch {
            try Task.checkCancellation()
            throw AgentUsageClientError.transport
        }
        try Task.checkCancellation()
        switch response.statusCode {
        case 200..<300: return response
        case 401, 403: throw AgentUsageClientError.unauthorized
        case 400 where recognizesInvalidGrant:
            let payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            if payload?["error"] as? String == "invalid_grant" {
                throw AgentUsageClientError.unauthorized
            }
            throw AgentUsageClientError.http(response.statusCode)
        default: throw AgentUsageClientError.http(response.statusCode)
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
