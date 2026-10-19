import Foundation

/// Where the API and the web pages of one GitHub live. GitHub.com serves its
/// API from api.github.com; GitHub Enterprise Server serves it under
/// `/api/v3` on the same host, and either address may be entered.
struct GitHubServer: Hashable, Sendable {
    static let dotCom = GitHubServer(
        webURL: URL(string: "https://github.com")!,
        apiURL: URL(string: "https://api.github.com")!
    )

    let webURL: URL
    let apiURL: URL

    init(webURL: URL, apiURL: URL) {
        self.webURL = webURL
        self.apiURL = apiURL
    }

    /// The server for the preference's address; blank means GitHub.com.
    init(address: String) throws(GitHubError) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .dotCom
            return
        }
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw .invalidServer
        }
        if host == "github.com" || host == "www.github.com" || host == "api.github.com" {
            self = .dotCom
            return
        }
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let namesAPI = path.hasSuffix("/api/v3")
        if namesAPI { path.removeLast("/api/v3".count) }

        components.path = path
        guard let webURL = components.url else { throw .invalidServer }
        components.path = path + "/api/v3"
        guard let apiURL = components.url else { throw .invalidServer }
        self.init(webURL: webURL, apiURL: apiURL)
    }

    /// The page for an API URL of a pull request, issue, discussion, or
    /// commit (`…/repos/o/r/pulls/1` → `…/o/r/pull/1`); nil for anything else.
    func webURL(forAPI url: URL) -> URL? {
        let apiPath = apiURL.path.hasSuffix("/") ? String(apiURL.path.dropLast()) : apiURL.path
        guard url.path.hasPrefix(apiPath + "/repos/") else { return nil }
        let parts = url.path.dropFirst(apiPath.count + "/repos/".count).split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        let kind: String
        switch parts[2] {
        case "pulls": kind = "pull"
        case "issues": kind = "issues"
        case "discussions": kind = "discussions"
        case "commits": kind = "commit"
        default: return nil
        }
        return webURL.appending(path: "\(parts[0])/\(parts[1])/\(kind)/\(parts[3])")
    }

    /// GitHub's page for a new classic token with the scopes this extension uses.
    var newTokenURL: URL {
        var components = URLComponents(url: webURL.appending(path: "settings/tokens/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "scopes", value: GitHubClient.scopes.joined(separator: ",")),
            URLQueryItem(name: "description", value: "Prism"),
        ]
        return components.url!
    }
}
