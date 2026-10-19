import Foundation

/// Connect-RPC over the Antigravity language server's loopback API. Every call
/// is a POST with Connect-protocol JSON (`Connect-Protocol-Version: 1`) and a
/// `metadata` body. The `x-codeium-csrf-token` header is always sent — the
/// desktop server's own `--csrf_token`, or the "cli-dummy-token" stand-in used
/// when the `agy` CLI exposes no token. `agy` builds that enforce a
/// runtime-generated token reject the stand-in; those endpoints then fail the
/// reachability check like a dead port.
struct AntigravityUsageClient: Sendable {
    static let lsService = "/exa.language_server_pb.LanguageServerService"

    /// Shared metadata fields the server expects on every RPC body.
    static let lsMetadata = """
        "metadata": {"ideName": "antigravity", "extensionName": "antigravity", \
        "ideVersion": "unknown", "locale": "en"}
        """

    /// The unleash payload distinguishes the API port from other listeners the
    /// same process holds open: only the real server answers it with 200.
    static let lsUnleashBody = """
        {"context": {"properties": {\
        "devMode": "false", "extensionVersion": "unknown", \
        "hasAnthropicModelAccess": "true", "ide": "antigravity", \
        "ideVersion": "unknown", "installationId": "prism-agent-usage", \
        "language": "UNSPECIFIED", "os": "macos", \
        "requestedModelId": "MODEL_UNSPECIFIED"}}}
        """

    /// Loopback-only session that accepts the LS's self-signed certificate.
    var loopbackClient: any AgentUsageHTTPClient = LoopbackAgentUsageHTTPClient()
    /// General transport for the Cloud Code endpoints the `agy` credential
    /// answers — ordinary HTTPS, no certificate overrides.
    var httpClient: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient()

    /// The `agy` CLI identifies itself to Cloud Code with this user agent.
    static let cloudUserAgent = "antigravity/1.11.3 darwin/arm64"
    static let quotaSummaryURL = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    static let loadCodeAssistURL = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let userInfoURL = URL(
        string: "https://openidconnect.googleapis.com/v1/userinfo")!

    /// POST an empty JSON body to a Cloud Code endpoint.
    func cloudPost(_ url: URL, accessToken: String) async throws -> AgentUsageHTTPResponse {
        try await httpClient.send(AgentUsageHTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "User-Agent": Self.cloudUserAgent,
            ],
            body: Data("{}".utf8),
            timeout: 15))
    }

    /// GET the OpenID userinfo endpoint (the account email).
    func cloudGet(_ url: URL, accessToken: String) async throws -> AgentUsageHTTPResponse {
        try await httpClient.send(AgentUsageHTTPRequest(
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "User-Agent": Self.cloudUserAgent,
            ],
            timeout: 15))
    }

    /// Loopback Connect-RPC: POST the RPC body with the process's CSRF token.
    /// `body` defaults to the shared metadata envelope; `GetUnleashData` uses
    /// its own context payload. A nil return means transport failure — any
    /// HTTP status still proves the port is a live HTTP service.
    func callLS(
        scheme: String, port: Int, csrf: String,
        method: String, body: String? = nil
    ) async -> AgentUsageHTTPResponse? {
        guard let url = URL(
            string: "\(scheme)://127.0.0.1:\(port)\(Self.lsService)/\(method)")
        else { return nil }
        let req = AgentUsageHTTPRequest(
            url: url, method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
                "User-Agent": "antigravity/1.104.0",
                "x-codeium-csrf-token": csrf,
            ],
            body: (body ?? "{\(Self.lsMetadata)}").data(using: .utf8))
        do { return try await loopbackClient.send(req) } catch { return nil }
    }
}

/// URLSession that accepts self-signed certificates on loopback only — the
/// language server serves a locally generated cert. Never used for remote
/// hosts.
private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

private final class LoopbackAgentUsageHTTPClient: AgentUsageHTTPClient, @unchecked Sendable {
    private let session = URLSession(
        configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            return config
        }(),
        delegate: LoopbackTrustDelegate(), delegateQueue: nil)

    func send(_ request: AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AgentUsageFailure.network("Non-HTTP response.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name] = String(describing: value)
        }
        return AgentUsageHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
