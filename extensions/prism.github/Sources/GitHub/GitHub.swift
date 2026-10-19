import Foundation
import PrismExtensionKit

/// GitHub notifications, pull requests, issues, and repositories for one
/// account on GitHub.com or GitHub Enterprise Server, read with a personal
/// access token from preferences or, without one, the GitHub CLI's login.
/// Every row opens its page on GitHub; nothing is changed there.
@main
struct GitHub: PrismExtension {
    enum CommandID {
        static let notifications = "notifications"
        static let pullRequests = "pull-requests"
        static let issues = "issues"
        static let repositories = "repositories"
    }

    enum FilterID {
        static let unread = "unread"
        static let all = "all"
        static let mine = "mine"
        static let starred = "starred"
        static let everywhere = "everywhere"
    }

    enum PreferenceID {
        static let token = "token"
        static let server = "server"
    }

    /// How long a search answers from the cache. GitHub allows 30 searches a
    /// minute, and the pull request list alone runs six.
    static let searchMaxAge: TimeInterval = 60
    /// Repository lists take up to ten requests and change rarely.
    static let repositoriesMaxAge: TimeInterval = 300

    let transport: GitHubTransport
    let now: @Sendable () -> Date
    let cache: ResponseCache
    let cliLogin: GitHubCLILogin

    init() {
        self.init(transport: GitHubClient.urlSession, cli: .installed)
    }

    init(transport: @escaping GitHubTransport, cli: GitHubCLI = .none, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
        self.cache = ResponseCache(now: now)
        self.cliLogin = GitHubCLILogin(cli: cli, now: now)
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        let shape = try Self.shape(of: command, now: now())
        let server: GitHubServer
        do {
            server = try GitHubServer(address: context.preferences.string(PreferenceID.server))
        } catch {
            return shape.list(items: [], emptyMessage: GitHubRows.message(for: error, now: now()))
        }
        let host = GitHubCLI.host(of: server)
        let token: String
        let source: GitHubTokenSource
        let preference = context.preferences.string(PreferenceID.token).trimmingCharacters(in: .whitespacesAndNewlines)
        if !preference.isEmpty {
            (token, source) = (preference, .preferences)
        } else {
            switch await cliLogin.lookup(host: host) {
            case let .token(cliToken):
                (token, source) = (cliToken, .githubCLI)
            case .signedOut:
                try Task.checkCancellation()
                return shape.list(items: [GitHubRows.cliItem(host: host), GitHubRows.tokenItem(server: server)])
            case .notInstalled:
                return shape.list(items: [GitHubRows.tokenItem(server: server)])
            }
        }
        let client = GitHubClient(server: server, token: token, transport: transport)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch command {
            case CommandID.notifications:
                return try await notifications(client, filter: filter, shape: shape)
            case CommandID.pullRequests:
                return try await issues(.pullRequest, client, text: text, filter: filter, shape: shape)
            case CommandID.issues:
                return try await issues(.issue, client, text: text, filter: filter, shape: shape)
            default:
                return try await repositories(client, text: text, filter: filter, shape: shape)
            }
        } catch let error as GitHubError {
            // gh may have a new login by the next load.
            if source == .githubCLI, error == .invalidToken { await cliLogin.forget(host: host) }
            return shape.list(items: [], emptyMessage: GitHubRows.message(for: error, source: source, now: now()))
        }
    }

    // MARK: - Notifications

    private func notifications(_ client: GitHubClient, filter: String?, shape: ListShape) async throws -> ExtensionList {
        let includeRead = filter == FilterID.all
        // Always asked again, so the inbox is current; the cache only keeps
        // the last inbox on screen when GitHub can't be reached.
        let entry = try await cache.value(cacheKey(client, "notifications", includeRead ? "all" : "unread"), maxAge: 0) {
            try await client.notifications(includeRead: includeRead)
        }
        let now = now()
        return shape.list(
            items: entry.value.map { GitHubRows.item(for: $0, server: client.server, sectioned: includeRead, now: now) },
            emptyMessage: includeRead
                ? ExtensionListMessage(title: "No Notifications", symbol: "bell")
                : ExtensionListMessage(title: "You’re All Caught Up", message: "New notifications on GitHub appear here.", symbol: "checkmark.circle"),
            entry: entry
        )
    }

    // MARK: - Pull requests and issues

    private func issues(
        _ kind: GitHubIssueKind, _ client: GitHubClient, text: String, filter: String?, shape: ListShape
    ) async throws -> ExtensionList {
        let chosen = kind.sections.first { $0.id == filter }
        let sections = text.isEmpty ? chosen.map { [$0] } ?? kind.sections : [chosen ?? kind.involved]
        let date = now()
        let entries = try await withThrowingTaskGroup(of: (Int, ResponseCache.Entry<[GitHubIssue]>).self) { group in
            for (index, section) in sections.enumerated() {
                let query = section.query(kind: kind, text: text, now: date)
                group.addTask {
                    (index, try await cache.value(cacheKey(client, "search", query), maxAge: Self.searchMaxAge) {
                        try await client.searchIssues(query)
                    })
                }
            }
            var entries = [ResponseCache.Entry<[GitHubIssue]>?](repeating: nil, count: sections.count)
            for try await (index, entry) in group { entries[index] = entry }
            return entries.compactMap { $0 }
        }

        // Sections are titled only when several are shown together.
        let titled = sections.count > 1
        var seen = Set<Int>()
        var items = [ExtensionListItem]()
        for (section, entry) in zip(sections, entries) {
            for issue in entry.value where seen.insert(issue.id).inserted {
                items.append(GitHubRows.item(for: issue, section: titled ? section.title : nil, now: date))
            }
        }
        let noun = kind == .pullRequest ? "Pull Requests" : "Issues"
        let sentenceNoun = kind == .pullRequest ? "Pull requests" : "Issues"
        return shape.list(
            items: items,
            emptyMessage: text.isEmpty
                ? ExtensionListMessage(title: "No \(noun)", message: chosen == nil ? "\(sentenceNoun) you created, were assigned, or were mentioned in appear here." : nil, symbol: kind == .pullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                : ExtensionListMessage(title: "No Matching \(noun)", symbol: "magnifyingglass"),
            fetchedAt: entries.map(\.fetchedAt).min(),
            error: entries.lazy.compactMap(\.error).first
        )
    }

    // MARK: - Repositories

    private func repositories(_ client: GitHubClient, text: String, filter: String?, shape: ListShape) async throws -> ExtensionList {
        let date = now()
        if filter == FilterID.everywhere {
            guard !text.isEmpty else {
                return shape.list(items: [], emptyMessage: ExtensionListMessage(
                    title: "Search All of GitHub", message: "Type a repository name, owner, or topic.", symbol: "magnifyingglass"
                ))
            }
            let entry = try await cache.value(cacheKey(client, "repositories", text), maxAge: Self.searchMaxAge) {
                try await client.searchRepositories(text)
            }
            return shape.list(
                items: entry.value.map { GitHubRows.item(for: $0, showsStars: true, now: date) },
                emptyMessage: ExtensionListMessage(title: "No Matching Repositories", symbol: "magnifyingglass"),
                entry: entry
            )
        }

        let starred = filter == FilterID.starred
        let entry = try await cache.value(cacheKey(client, starred ? "starred" : "mine"), maxAge: Self.repositoriesMaxAge) {
            try await starred ? client.starredRepositories() : client.myRepositories()
        }
        let matches = RepositoryMatcher(text).matches(in: entry.value)
        return shape.list(
            items: matches.map { GitHubRows.item(for: $0, showsStars: starred, now: date) },
            emptyMessage: text.isEmpty
                ? ExtensionListMessage(title: starred ? "No Starred Repositories" : "No Repositories", symbol: "book.closed")
                : ExtensionListMessage(
                    title: "No Matching Repositories",
                    message: "Choose All of GitHub with ⌘P to search beyond your own.", symbol: "magnifyingglass"
                ),
            entry: entry
        )
    }

    // MARK: - Shape

    /// What every load of a command shares, whatever its rows.
    struct ListShape {
        let filtering: ExtensionList.Filtering
        let searchPlaceholder: String
        let filters: [ExtensionListFilter]
        let now: Date

        func list(
            items: [ExtensionListItem],
            emptyMessage: ExtensionListMessage? = nil,
            fetchedAt: Date? = nil,
            error: GitHubError? = nil
        ) -> ExtensionList {
            ExtensionList(
                items: items,
                filtering: filtering,
                searchPlaceholder: searchPlaceholder,
                filters: filters,
                emptyMessage: emptyMessage,
                fetchedAt: fetchedAt,
                error: error.map { GitHubRows.summary(of: $0, now: now) }
            )
        }

        func list<Value>(items: [ExtensionListItem], emptyMessage: ExtensionListMessage, entry: ResponseCache.Entry<Value>) -> ExtensionList {
            list(items: items, emptyMessage: emptyMessage, fetchedAt: entry.fetchedAt, error: entry.error)
        }
    }

    static func shape(of command: String, now: Date) throws -> ListShape {
        switch command {
        case CommandID.notifications:
            return ListShape(
                filtering: .prism,
                searchPlaceholder: "Filter notifications…",
                filters: [
                    ExtensionListFilter(id: FilterID.unread, title: "Unread", symbol: "circle.fill"),
                    ExtensionListFilter(id: FilterID.all, title: "All", symbol: "tray.full"),
                ],
                now: now
            )
        case CommandID.pullRequests, CommandID.issues:
            let kind: GitHubIssueKind = command == CommandID.pullRequests ? .pullRequest : .issue
            return ListShape(
                filtering: .extension,
                searchPlaceholder: kind == .pullRequest ? "Search your pull requests…" : "Search your issues…",
                filters: kind.sections.map { ExtensionListFilter(id: $0.id, title: $0.title, symbol: $0.symbol) },
                now: now
            )
        case CommandID.repositories:
            return ListShape(
                filtering: .extension,
                searchPlaceholder: "Search repositories…",
                filters: [
                    ExtensionListFilter(id: FilterID.mine, title: "Your Repositories", symbol: "person"),
                    ExtensionListFilter(id: FilterID.starred, title: "Starred", symbol: "star"),
                    ExtensionListFilter(id: FilterID.everywhere, title: "All of GitHub", symbol: "globe"),
                ],
                now: now
            )
        default:
            throw PrismExtensionError("GitHub has no list “\(command)”.")
        }
    }

    /// Responses are kept per server and token, so changing either never
    /// shows another account's rows.
    private func cacheKey(_ client: GitHubClient, _ parts: String...) -> String {
        ([client.server.apiURL.absoluteString, String(client.token.hashValue)] + parts).joined(separator: "\u{1F}")
    }
}

/// Narrows a repository list to what the user typed: every word must appear
/// in the name, owner, or description. Name matches come first, then the
/// list's own order (recently updated, or recently starred).
struct RepositoryMatcher {
    let words: [String]

    init(_ text: String) {
        words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func matches(in repositories: [GitHubRepository]) -> [GitHubRepository] {
        guard !words.isEmpty else { return repositories }
        return repositories.enumerated()
            .compactMap { offset, repository in score(repository).map { (offset, $0, repository) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.2)
    }

    /// Lower is better; nil when a word appears nowhere.
    private func score(_ repository: GitHubRepository) -> Int? {
        let name = repository.name.lowercased()
        let fullName = repository.fullName.lowercased()
        let description = repository.description?.lowercased() ?? ""
        var score = 0
        for word in words {
            if name.hasPrefix(word) { continue }
            if name.contains(word) { score += 1 } else if fullName.contains(word) { score += 2 }
            else if description.contains(word) { score += 4 } else { return nil }
        }
        return score
    }
}
