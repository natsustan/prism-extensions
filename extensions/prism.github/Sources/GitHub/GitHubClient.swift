import Foundation

/// Sends one request and returns the body with its HTTP response. Tests pass
/// canned responses; the extension uses `URLSession`.
typealias GitHubTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// The few GitHub REST calls the lists need, for one account.
struct GitHubClient: Sendable {
    /// The classic token scopes the lists need: private repositories and
    /// their issues (`repo`), organization repositories (`read:org`), and
    /// the inbox (`notifications`).
    static let scopes = ["repo", "read:org", "notifications"]

    static let notificationsPerPage = 50
    static let notificationPages = 2
    static let searchPerPage = 50
    static let repositoriesPerPage = 100
    static let repositoryPages = 10

    let server: GitHubServer
    let token: String
    let transport: GitHubTransport

    func notifications(includeRead: Bool) async throws -> [GitHubNotification] {
        var query = [URLQueryItem(name: "per_page", value: "\(Self.notificationsPerPage)")]
        if includeRead { query.append(URLQueryItem(name: "all", value: "true")) }
        return try await pages(
            "notifications", query: query, endpoint: .notifications,
            perPage: Self.notificationsPerPage, limit: Self.notificationPages
        ) { (page: [GitHubNotification]) in page }
    }

    /// Issues and pull requests matching a search, most recently updated first.
    func searchIssues(_ query: String) async throws -> [GitHubIssue] {
        let response: GitHubSearchPage<GitHubIssue> = try await get("search/issues", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "\(Self.searchPerPage)"),
        ], endpoint: .search)
        return response.items
    }

    /// Repositories the user owns, collaborates on, or reaches through an
    /// organization, most recently updated first.
    func myRepositories() async throws -> [GitHubRepository] {
        try await pages("user/repos", query: [
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "per_page", value: "\(Self.repositoriesPerPage)"),
        ], endpoint: .repositories, perPage: Self.repositoriesPerPage, limit: Self.repositoryPages) { (page: [GitHubRepository]) in
            page
        }
    }

    /// Starred repositories, newest star first.
    func starredRepositories() async throws -> [GitHubRepository] {
        try await pages("user/starred", query: [
            URLQueryItem(name: "sort", value: "created"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: "\(Self.repositoriesPerPage)"),
        ], endpoint: .repositories, perPage: Self.repositoriesPerPage, limit: Self.repositoryPages,
           accept: "application/vnd.github.star+json") { (page: [GitHubStar]) in
            page.map(\.repository)
        }
    }

    /// Repositories anywhere on the server matching a search.
    func searchRepositories(_ query: String) async throws -> [GitHubRepository] {
        let response: GitHubSearchPage<GitHubRepository> = try await get("search/repositories", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "\(Self.searchPerPage)"),
        ], endpoint: .search)
        return response.items
    }

    // MARK: - Requests

    enum Endpoint: Sendable {
        case notifications, search, repositories
    }

    private func pages<Page: Decodable, Item>(
        _ path: String,
        query: [URLQueryItem],
        endpoint: Endpoint,
        perPage: Int,
        limit: Int,
        accept: String = "application/vnd.github+json",
        items: (Page) -> [Item]
    ) async throws -> [Item] where Page: Collection {
        var collected = [Item]()
        for page in 1...limit {
            let response: Page = try await get(
                path, query: query + [URLQueryItem(name: "page", value: "\(page)")], endpoint: endpoint, accept: accept
            )
            collected += items(response)
            if response.count < perPage { break }
        }
        return collected
    }

    private func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem],
        endpoint: Endpoint,
        accept: String = "application/vnd.github+json"
    ) async throws -> Response {
        var components = URLComponents(url: server.apiURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Prism-GitHub-Extension", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw GitHubError.unreachable(error.localizedDescription)
        }
        guard (200...299).contains(response.statusCode) else {
            throw GitHubError(response: response, body: data, endpoint: endpoint)
        }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw GitHubError.unexpectedResponse
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let urlSession: GitHubTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

// MARK: - Errors

enum GitHubError: Error, Equatable, Sendable {
    case missingToken
    case invalidServer
    case invalidToken
    case missingScope
    case notificationsNeedClassicToken
    case rateLimited(resetsAt: Date?)
    case status(Int)
    case unexpectedResponse
    case unreachable(String)

    init(response: HTTPURLResponse, body: Data, endpoint: GitHubClient.Endpoint) {
        let message = ((try? JSONDecoder().decode(Message.self, from: body))?.message ?? "").lowercased()
        let isRateLimited = response.statusCode == 429
            || (response.statusCode == 403
                && (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || message.contains("rate limit")))
        if isRateLimited {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
            self = .rateLimited(resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
            return
        }
        switch response.statusCode {
        case 401:
            self = .invalidToken
        case 403, 404:
            if endpoint == .notifications,
               message.contains("fine-grained") || message.contains("personal access token") {
                self = .notificationsNeedClassicToken
            } else if message.contains("resource not accessible") || message.contains("insufficient")
                        || message.contains("must have") {
                self = .missingScope
            } else {
                self = .status(response.statusCode)
            }
        default:
            self = .status(response.statusCode)
        }
    }

    private struct Message: Decodable {
        let message: String
    }
}

// MARK: - Models

struct GitHubNotification: Decodable, Hashable, Sendable {
    struct Subject: Decodable, Hashable, Sendable {
        let title: String
        let url: URL?
        let type: String
    }

    struct Repository: Decodable, Hashable, Sendable {
        let fullName: String
        let htmlUrl: URL
    }

    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: Date
    let subject: Subject
    let repository: Repository
}

struct GitHubIssue: Decodable, Hashable, Sendable {
    struct PullRequest: Decodable, Hashable, Sendable {
        let mergedAt: Date?
    }

    struct User: Decodable, Hashable, Sendable {
        let login: String
    }

    let id: Int
    let number: Int
    let title: String
    let state: String
    let draft: Bool?
    let updatedAt: Date
    let htmlUrl: URL
    let repositoryUrl: URL
    let user: User?
    let pullRequest: PullRequest?

    var isPullRequest: Bool { pullRequest != nil }
    var isOpen: Bool { state == "open" }
    var isMerged: Bool { pullRequest?.mergedAt != nil }

    /// `owner/name`, from the API URL `…/repos/owner/name`.
    var repositoryName: String {
        let parts = repositoryUrl.pathComponents
        guard let repos = parts.lastIndex(of: "repos"), repos + 2 < parts.count else {
            return repositoryUrl.lastPathComponent
        }
        return "\(parts[repos + 1])/\(parts[repos + 2])"
    }
}

struct GitHubRepository: Decodable, Hashable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let description: String?
    let `private`: Bool
    let fork: Bool?
    let archived: Bool?
    let stargazersCount: Int?
    let updatedAt: Date?
    let htmlUrl: URL
    /// When the user starred it; only for starred repositories.
    var starredAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, fullName, description, `private`, fork, archived, stargazersCount, updatedAt, htmlUrl
    }
}

/// One entry of `user/starred` with the `star+json` media type.
struct GitHubStar: Decodable, Sendable {
    let starredAt: Date?
    let repo: GitHubRepository

    var repository: GitHubRepository {
        var repository = repo
        repository.starredAt = starredAt
        return repository
    }
}

struct GitHubSearchPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
}
