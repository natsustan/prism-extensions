import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import GitHub

/// A GitHub that answers from canned JSON and records what was asked.
actor FakeGitHub {
    struct Reply: Sendable {
        var status = 200
        var body: String
        var headers: [String: String] = [:]
    }

    private(set) var requests: [URLRequest] = []
    private var routes: [(match: @Sendable (URLComponents) -> Bool, reply: Reply)] = []

    /// Answers requests whose path ends with `path` and whose query has
    /// every item of `query`. Later routes win.
    func route(_ path: String, query: [String: String] = [:], _ reply: Reply) {
        routes.insert(({ components in
            components.path.hasSuffix(path) && query.allSatisfy { key, value in
                components.queryItems?.contains { $0.name == key && $0.value == value } ?? false
            }
        }, reply), at: 0)
    }

    func route(_ path: String, query: [String: String] = [:], json: String) {
        route(path, query: query, Reply(body: json))
    }

    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let reply = routes.first { $0.match(components) }?.reply ?? Reply(status: 404, body: #"{"message":"Not Found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    /// The `q` of every search request, in order.
    var searches: [String] {
        requests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        }
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    var transport: GitHubTransport {
        { request in try await self.handle(request) }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date { lock.withLock { date } }

    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

/// 2026-10-19 12:00:00 UTC.
let referenceDate = Date(timeIntervalSince1970: 1_792_411_200)

func makeHost(
    _ github: FakeGitHub, clock: Clock = Clock(referenceDate), token: String = "ghp_test", server: String = "https://github.com",
    cli: GitHubCLI = .none
) async throws -> PrismTestHost {
    let transport = await github.transport
    return try await PrismTestHost(
        GitHub(transport: transport, cli: cli, now: { clock.now }),
        extensionID: "prism.github",
        preferences: ["token": .string(token), "server": .string(server)]
    )
}

func issueJSON(
    id: Int, number: Int, title: String, repo: String = "octo/app", state: String = "open",
    pullRequest: Bool = true, merged: Bool = false, draft: Bool = false, updated: String = "2026-10-19T09:00:00Z"
) -> String {
    let pr = pullRequest ? #","pull_request":{"merged_at":\#(merged ? #""2026-10-18T00:00:00Z""# : "null")}"# : ""
    return """
    {"id":\(id),"number":\(number),"title":"\(title)","state":"\(state)","draft":\(draft),\
    "updated_at":"\(updated)","html_url":"https://github.com/\(repo)/\(pullRequest ? "pull" : "issues")/\(number)",\
    "repository_url":"https://api.github.com/repos/\(repo)","user":{"login":"mona"}\(pr)}
    """
}

func searchJSON(_ items: String...) -> String {
    #"{"total_count":\#(items.count),"items":[\#(items.joined(separator: ","))]}"#
}

let notificationsJSON = """
[
  {"id":"1","unread":true,"reason":"review_requested","updated_at":"2026-10-19T11:00:00Z",
   "subject":{"title":"Add dark mode","url":"https://api.github.com/repos/octo/app/pulls/12","type":"PullRequest"},
   "repository":{"full_name":"octo/app","html_url":"https://github.com/octo/app"}},
  {"id":"2","unread":false,"reason":"subscribed","updated_at":"2026-10-17T12:00:00Z",
   "subject":{"title":"v2.0","url":"https://api.github.com/repos/octo/app/releases/99","type":"Release"},
   "repository":{"full_name":"octo/app","html_url":"https://github.com/octo/app"}}
]
"""

func repositoryJSON(id: Int, name: String, owner: String = "octo", description: String? = nil, private: Bool = false, stars: Int = 0) -> String {
    let description = description.map { "\"\($0)\"" } ?? "null"
    return """
    {"id":\(id),"name":"\(name)","full_name":"\(owner)/\(name)","description":\(description),"private":\(`private`),\
    "fork":false,"archived":false,"stargazers_count":\(stars),"updated_at":"2026-10-18T12:00:00Z",\
    "html_url":"https://github.com/\(owner)/\(name)"}
    """
}

extension ExtensionListItem {
    var openURL: URL? {
        if case let .open(url) = actions.first?.kind { return url }
        return nil
    }
}

@Suite("GitHub server address")
struct GitHubServerTests {
    @Test("GitHub.com in any spelling uses api.github.com")
    func dotCom() throws {
        for address in ["", "https://github.com", "github.com/", "https://www.github.com", "https://api.github.com"] {
            #expect(try GitHubServer(address: address) == .dotCom)
        }
    }

    @Test("an Enterprise host serves its API under /api/v3, whether or not the address names it")
    func enterprise() throws {
        for address in ["ghe.example.com", "https://ghe.example.com/", "https://ghe.example.com/api/v3/"] {
            let server = try GitHubServer(address: address)
            #expect(server.webURL.absoluteString == "https://ghe.example.com")
            #expect(server.apiURL.absoluteString == "https://ghe.example.com/api/v3")
        }
    }

    @Test("an address that is not a web address is refused")
    func invalid() {
        #expect(throws: GitHubError.invalidServer) { try GitHubServer(address: "ftp://ghe.example.com") }
        #expect(throws: GitHubError.invalidServer) { try GitHubServer(address: "https://") }
    }

    @Test("API links of pull requests, issues, and commits become their pages")
    func webURLs() throws {
        let server = try GitHubServer(address: "https://ghe.example.com")
        let api = "https://ghe.example.com/api/v3/repos/octo/app"
        #expect(server.webURL(forAPI: URL(string: "\(api)/pulls/12")!)?.absoluteString == "https://ghe.example.com/octo/app/pull/12")
        #expect(server.webURL(forAPI: URL(string: "\(api)/issues/3")!)?.absoluteString == "https://ghe.example.com/octo/app/issues/3")
        #expect(server.webURL(forAPI: URL(string: "\(api)/commits/abc")!)?.absoluteString == "https://ghe.example.com/octo/app/commit/abc")
        #expect(server.webURL(forAPI: URL(string: "\(api)/releases/9")!) == nil)
    }
}

@Suite("GitHub lists")
struct GitHubListTests {
    @Test("without a token each list offers to create one with the needed scopes and asks GitHub nothing")
    func missingToken() async throws {
        let github = FakeGitHub()
        let prism = try await makeHost(github, token: "  ")
        for command in ["notifications", "pull-requests", "issues", "repositories"] {
            let list = try await prism.list(command)
            #expect(list.items.map(\.id) == ["create-token"])
            let url = try #require(list.items.first?.openURL)
            #expect(url.absoluteString.hasPrefix("https://github.com/settings/tokens/new?"))
            #expect(url.absoluteString.contains("scopes=repo,read:org,notifications"))
        }
        #expect(await github.requests.isEmpty)
    }

    @Test("notifications show unread ones by default, linking to their pages")
    func unreadNotifications() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", json: notificationsJSON)
        let prism = try await makeHost(github)

        let list = try await prism.list("notifications")
        #expect(list.filtering == .prism)
        #expect(list.filters.map(\.id) == ["unread", "all"])
        #expect(list.items.map(\.title) == ["Add dark mode", "v2.0"])
        #expect(list.items.map(\.section) == [nil, nil])
        #expect(list.items[0].subtitle == "octo/app")
        #expect(list.items[0].openURL?.absoluteString == "https://github.com/octo/app/pull/12")
        #expect(list.items[1].openURL?.absoluteString == "https://github.com/octo/app/releases")
        #expect(list.items[0].accessories.compactMap(\.text) == ["Review Requested", "1h"])

        let request = try #require(await github.requests.first)
        #expect(request.url?.host == "api.github.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test")
        #expect(request.url?.query?.contains("all=true") == false)
    }

    @Test("the All filter asks for read notifications too and splits them from the unread ones")
    func allNotifications() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", query: ["all": "true"], json: notificationsJSON)
        let prism = try await makeHost(github)

        let list = try await prism.list("notifications", filter: "all")
        #expect(list.items.map(\.section) == ["Unread", "Read"])
    }

    @Test("a fine-grained token's refusal says notifications need a classic token")
    func fineGrainedNotifications() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", .init(
            status: 403, body: #"{"message":"Resource not accessible by personal access token"}"#
        ))
        let prism = try await makeHost(github)

        let list = try await prism.list("notifications")
        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "Notifications Need a Classic Token")
    }

    @Test("pull requests are grouped as on GitHub, each shown once, in its first group")
    func pullRequestSections() async throws {
        let github = FakeGitHub()
        let mine = issueJSON(id: 1, number: 12, title: "Add dark mode", draft: true)
        let merged = issueJSON(id: 3, number: 9, title: "Fix crash", state: "closed", merged: true)
        await github.route("/search/issues", json: searchJSON())
        await github.route("/search/issues", query: ["q": "is:pr archived:false is:open author:@me"], json: searchJSON(mine))
        await github.route("/search/issues", query: ["q": "is:pr archived:false is:open review-requested:@me"], json: searchJSON(
            mine, issueJSON(id: 2, number: 40, title: "Speed up search", repo: "octo/core")
        ))
        await github.route("/search/issues", query: ["q": "is:pr archived:false is:closed involves:@me closed:>=2026-10-05"], json: searchJSON(merged))
        let prism = try await makeHost(github)

        let list = try await prism.list("pull-requests")
        #expect(await github.searches.count == 6)
        #expect(list.filtering == .extension)
        #expect(list.items.map(\.title) == ["Add dark mode", "Speed up search", "Fix crash"])
        #expect(list.items.map(\.section) == ["Created", "Review Requests", "Recently Closed"])
        #expect(list.items[0].subtitle == "octo/app#12")
        #expect(list.items[0].icon?.tint == "gray")
        #expect(list.items[0].accessories.compactMap(\.text) == ["Draft", "mona", "3h"])
        #expect(list.items[1].icon == ExtensionIcon(
            symbol: "arrow.triangle.pull", tint: "green", image: "icons/octicons/git-pull-request.svg", style: .glyph
        ))
        #expect(list.items[2].icon?.image == "icons/octicons/git-merge.svg")
        #expect(list.items[2].icon?.tint == "violet")
        #expect(list.items[0].openURL?.absoluteString == "https://github.com/octo/app/pull/12")
    }

    @Test("a filter shows one group, and typing searches within it, or within everything the user took part in")
    func typedSearch() async throws {
        let github = FakeGitHub()
        await github.route("/search/issues", json: searchJSON(issueJSON(id: 5, number: 2, title: "Crash on launch", pullRequest: false)))
        let prism = try await makeHost(github)

        let assigned = try await prism.list("issues", filter: "assigned")
        #expect(assigned.items.map(\.section) == [nil])
        _ = try await prism.list("issues", query: "crash")
        _ = try await prism.list("issues", query: " crash ", filter: "assigned")
        #expect(await github.searches == [
            "is:issue archived:false is:open assignee:@me",
            "is:issue archived:false involves:@me crash",
            "is:issue archived:false is:open assignee:@me crash",
        ])
        #expect(assigned.items.first?.icon?.image == "icons/octicons/issue-opened.svg")
    }

    @Test("reopening a list within a minute answers from the cache instead of spending search quota")
    func searchCache() async throws {
        let github = FakeGitHub()
        await github.route("/search/issues", json: searchJSON())
        let clock = Clock(referenceDate)
        let prism = try await makeHost(github, clock: clock)

        _ = try await prism.list("pull-requests")
        _ = try await prism.list("pull-requests")
        #expect(await github.searches.count == 6)
        clock.advance(61)
        _ = try await prism.list("pull-requests")
        #expect(await github.searches.count == 12)
    }

    @Test("a refresh that hits the rate limit keeps the last rows and says why they are stale")
    func staleOnRateLimit() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", json: notificationsJSON)
        let clock = Clock(referenceDate)
        let prism = try await makeHost(github, clock: clock)
        let fresh = try await prism.list("notifications")

        clock.advance(30)
        await github.route("/notifications", .init(
            status: 403, body: #"{"message":"API rate limit exceeded"}"#,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(clock.now.timeIntervalSince1970) + 300)]
        ))
        let stale = try await prism.list("notifications")
        #expect(stale.items.map(\.id) == fresh.items.map(\.id))
        #expect(stale.fetchedAt == fresh.fetchedAt)
        #expect(stale.error == "GitHub’s rate limit was reached. Try again in 5 min.")
    }

    @Test("a rejected token drops the cached rows instead of showing them as stale")
    func invalidTokenDropsRows() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", json: notificationsJSON)
        let prism = try await makeHost(github)
        _ = try await prism.list("notifications")

        await github.route("/notifications", .init(status: 401, body: #"{"message":"Bad credentials"}"#))
        let list = try await prism.list("notifications")
        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "GitHub Didn’t Accept the Token")
    }

    @Test("an Enterprise server is asked at its own API address")
    func enterpriseRequests() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", json: "[]")
        let prism = try await makeHost(github, server: "https://ghe.example.com")
        let list = try await prism.list("notifications")
        #expect(list.emptyMessage?.title == "You’re All Caught Up")
        #expect(await github.requests.first?.url?.absoluteString.hasPrefix("https://ghe.example.com/api/v3/notifications?") == true)
    }
}

@Suite("GitHub repositories")
struct GitHubRepositoryTests {
    @Test("your repositories narrow as you type, name matches first, without asking GitHub again")
    func mine() async throws {
        let github = FakeGitHub()
        await github.route("/user/repos", json: "[" + [
            repositoryJSON(id: 1, name: "website", description: "The prism landing page"),
            repositoryJSON(id: 2, name: "prism", private: true),
            repositoryJSON(id: 3, name: "notes"),
        ].joined(separator: ",") + "]")
        let prism = try await makeHost(github)

        let all = try await prism.list("repositories")
        #expect(all.items.map(\.title) == ["octo/website", "octo/prism", "octo/notes"])
        #expect(all.items[1].accessories.first?.symbol == "lock.fill")
        #expect(all.items[1].openURL?.absoluteString == "https://github.com/octo/prism")

        let typed = try await prism.list("repositories", query: "prism")
        #expect(typed.items.map(\.title) == ["octo/prism", "octo/website"])
        #expect(await github.paths == ["/user/repos"])
    }

    @Test("starred repositories come newest star first, with their star counts")
    func starred() async throws {
        let github = FakeGitHub()
        await github.route("/user/starred", json: """
        [{"starred_at":"2026-10-19T10:00:00Z","repo":\(repositoryJSON(id: 9, name: "swift", owner: "apple", stars: 68_412))}]
        """)
        let prism = try await makeHost(github)

        let list = try await prism.list("repositories", filter: "starred")
        #expect(list.items.map(\.title) == ["apple/swift"])
        #expect(list.items[0].accessories.compactMap(\.text) == ["68.4k", "2h"])
        let request = try #require(await github.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.star+json")
    }

    @Test("All of GitHub waits for a query, then searches every repository")
    func everywhere() async throws {
        let github = FakeGitHub()
        await github.route("/search/repositories", json: searchJSON(repositoryJSON(id: 4, name: "linux", owner: "torvalds")))
        let prism = try await makeHost(github)

        let empty = try await prism.list("repositories", filter: "everywhere")
        #expect(empty.items.isEmpty)
        #expect(empty.emptyMessage?.title == "Search All of GitHub")
        #expect(await github.requests.isEmpty)

        let list = try await prism.list("repositories", query: "linux", filter: "everywhere")
        #expect(list.items.map(\.title) == ["torvalds/linux"])
        #expect(await github.searches == ["linux"])
    }
}

/// A `gh` that hands out queued answers and counts how often it was asked.
final class FakeCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String?]
    private(set) var hosts: [String] = []

    init(_ answers: String?...) { self.answers = answers }

    var asked: Int { lock.withLock { hosts.count } }

    var cli: GitHubCLI {
        GitHubCLI(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/gh") }, token: { _, host in
            self.lock.withLock {
                self.hosts.append(host)
                return self.answers.count > 1 ? self.answers.removeFirst() : self.answers.first ?? nil
            }
        })
    }
}

@Suite("GitHub CLI login")
struct GitHubCLITests {
    @Test("without a token in preferences the gh login is used, asked once for loads close together")
    func usesCLIToken() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", json: notificationsJSON)
        let gh = FakeCLI("gho_cli")
        let prism = try await makeHost(github, token: "", cli: gh.cli)

        _ = try await prism.list("notifications")
        _ = try await prism.list("notifications", filter: "all")
        #expect(gh.hosts == ["github.com"])
        let request = try #require(await github.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gho_cli")
    }

    @Test("a token in preferences comes first and gh is never asked")
    func preferenceFirst() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", json: "[]")
        let gh = FakeCLI("gho_cli")
        let prism = try await makeHost(github, cli: gh.cli)

        _ = try await prism.list("notifications")
        #expect(gh.asked == 0)
        #expect(await github.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test")
    }

    @Test("a signed-out gh offers its login command for the server's host, beside creating a token")
    func signedOut() async throws {
        let github = FakeGitHub()
        let gh = FakeCLI(nil)
        let prism = try await makeHost(github, token: "", server: "https://ghe.example.com", cli: gh.cli)

        let list = try await prism.list("pull-requests")
        #expect(list.items.map(\.id) == ["github-cli", "create-token"])
        #expect(list.items[0].subtitle == "Run gh auth login --hostname ghe.example.com in Terminal, then reopen this list")
        #expect(list.items[0].actions.first?.kind == .copy(text: "gh auth login --hostname ghe.example.com"))
        #expect(gh.hosts == ["ghe.example.com"])
        #expect(await github.requests.isEmpty)
    }

    @Test("a rejected gh login says to sign in again, and the next load asks gh afresh")
    func rejectedCLIToken() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", .init(status: 401, body: #"{"message":"Bad credentials"}"#))
        let gh = FakeCLI("gho_old", "gho_new")
        let prism = try await makeHost(github, token: "", cli: gh.cli)

        let list = try await prism.list("notifications")
        #expect(list.emptyMessage?.title == "GitHub Didn’t Accept the GitHub CLI Login")
        _ = try await prism.list("notifications")
        #expect(gh.asked == 2)
        #expect(await github.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer gho_new")
    }

    @Test("after gh auth switch the next load past the token's lifetime uses the new account")
    func switchedAccount() async throws {
        let github = FakeGitHub()
        await github.route("/notifications", json: notificationsJSON)
        let clock = Clock(referenceDate)
        let gh = FakeCLI("gho_first", "gho_second")
        let prism = try await makeHost(github, clock: clock, token: "", cli: gh.cli)

        _ = try await prism.list("notifications")
        clock.advance(GitHubCLILogin.tokenLifetime + 1)
        _ = try await prism.list("notifications")
        #expect(gh.asked == 2)
        #expect(await github.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer gho_second")
    }

    @Test("the token is read from the tool's output, trimmed")
    func readsProcessOutput() async throws {
        // `echo` stands in for gh: it prints its arguments.
        let token = await GitHubCLI.readToken(executable: URL(fileURLWithPath: "/bin/echo"), host: "github.com")
        #expect(token == "auth token --hostname github.com")
        #expect(await GitHubCLI.readToken(executable: URL(fileURLWithPath: "/usr/bin/false"), host: "github.com") == nil)
    }

    @Test("a gh that hangs is stopped at the timeout")
    func timeout() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "prism-github-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "gh")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let start = ContinuousClock.now
        let token = await GitHubCLI.readToken(executable: script, host: "github.com", timeout: .milliseconds(200))
        #expect(token == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

@Suite("GitHub row icons")
struct GitHubRowIconTests {
    @Test("every Octicon a row names ships in the extension's folder")
    func octiconsShip() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let issues = [
            issueJSON(id: 1, number: 1, title: "a"), issueJSON(id: 2, number: 2, title: "b", draft: true),
            issueJSON(id: 3, number: 3, title: "c", state: "closed", merged: true), issueJSON(id: 4, number: 4, title: "d", state: "closed"),
            issueJSON(id: 5, number: 5, title: "e", pullRequest: false), issueJSON(id: 6, number: 6, title: "f", state: "closed", pullRequest: false),
        ].map { try! GitHubClient.decoder.decode(GitHubIssue.self, from: Data($0.utf8)) }
        var icons = issues.map(GitHubRows.stateIcon(for:))
        icons += ["PullRequest", "Issue", "Release", "Discussion", "Commit", "CheckSuite", "SecurityAdvisory", "Other"]
            .map { GitHubRows.subjectIcon($0, unread: true) }
        for icon in icons {
            let image = try #require(icon.image)
            #expect(icon.style == .glyph)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: image).path), "\(image) is missing")
        }
    }

    @Test("a closed issue shows whether it was completed or not planned")
    func notPlanned() throws {
        let json = issueJSON(id: 7, number: 7, title: "g", state: "closed", pullRequest: false)
            .replacingOccurrences(of: #""state":"closed""#, with: #""state":"closed","state_reason":"not_planned""#)
        let issue = try GitHubClient.decoder.decode(GitHubIssue.self, from: Data(json.utf8))
        #expect(GitHubRows.stateIcon(for: issue).image == "icons/octicons/skip.svg")
        #expect(GitHubRows.stateIcon(for: issue).tint == "gray")
    }
}
