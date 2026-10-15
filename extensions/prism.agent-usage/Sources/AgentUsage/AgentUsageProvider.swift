import Foundation

/// One AI agent: where its credentials live on this Mac, how to call its usage
/// API, and how to normalize the answer. Providers never touch the UI — they
/// return a `Result` and let `AgentUsageController` decide what to show.
protocol AgentUsageProvider: Sendable {
    var id: AgentUsageProviderID { get }
    var displayName: String { get }
    /// Brand mark (or a fallback tile) for the list row and detail header.
    var icon: AgentUsageProviderIcon { get }

    /// Cheap local probe (files only, never the network) used to decide whether
    /// the provider is on before the user has expressed a preference.
    func hasLocalCredentials() -> Bool

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure>
}

/// Outbound request shape for read-only usage queries.
struct AgentUsageHTTPRequest: Sendable {
    var method: String = "GET"
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 10

    init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 10
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

struct AgentUsageHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Case-insensitive header lookup, because HTTP header names are not
    /// case-sensitive and providers disagree on the casing they use.
    func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}

/// The network seam. Tests inject a stub so usage parsing and refresh logic are
/// covered without real requests.
protocol AgentUsageHTTPClient: Sendable {
    func send(_ request: AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse
}

/// Client-side failure, mapped to `AgentUsageFailure` by each provider so the
/// copy can name that provider's CLI.
enum AgentUsageClientError: Error, Equatable, Sendable {
    /// 401/403: credentials were rejected.
    case unauthorized
    /// Any other non-2xx status.
    case http(Int)
    /// The request never completed (offline, DNS, TLS, timeout).
    case transport
    /// A 2xx body that did not match the expected shape.
    case invalidResponse
}

struct URLSessionAgentUsageHTTPClient: AgentUsageHTTPClient {
    /// Ephemeral and cache-free: quota responses are live data, and nothing here
    /// should be persisted by URLSession on the user's behalf.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    func send(_ request: AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // A stale or corrupt credential must surface as a 401 we can explain,
        // not as a thrown URLError the provider would report as "network".
        let (data, response) = try await Self.session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AgentUsageClientError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name] = String(describing: value)
        }
        return AgentUsageHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

/// Bounds optional enrichment by a monotonic deadline shared with the primary
/// request, leaving the provider time to return its already-fetched quota.
enum AgentUsageRequestBudget {
    static func optionalData(
        before deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> Data
    ) async -> Data? {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await ContinuousClock().sleep(until: deadline)
                return nil
            }
            let data = await group.next() ?? nil
            group.cancelAll()
            return data
        }
    }
}
