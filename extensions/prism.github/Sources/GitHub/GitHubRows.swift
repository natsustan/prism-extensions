import Foundation
import PrismExtensionKit

/// The list rows for GitHub's notifications, pull requests, issues, and
/// repositories. Return opens the page on GitHub; ⌘K copies its link or name.
enum GitHubRows {
    enum ActionID {
        static let open = "open"
        static let copyURL = "copy-url"
        static let copyTitle = "copy-title"
        static let copyName = "copy-name"
        static let createToken = "create-token"
        static let copyLoginCommand = "copy-login-command"
    }

    // MARK: - Notifications

    static func item(for notification: GitHubNotification, server: GitHubServer, sectioned: Bool, now: Date) -> ExtensionListItem {
        let url = webURL(for: notification, server: server)
        var accessories = [ExtensionListAccessory]()
        if let reason = reasonTitle(notification.reason) {
            accessories.append(ExtensionListAccessory(text: reason, help: "Why you were notified"))
        }
        accessories.append(ExtensionListAccessory(text: age(of: notification.updatedAt, now: now), help: "Updated"))
        return ExtensionListItem(
            id: notification.id,
            title: notification.subject.title,
            subtitle: notification.repository.fullName,
            icon: subjectIcon(notification.subject.type, unread: notification.unread),
            accessories: accessories,
            keywords: [notification.subject.type, notification.reason],
            section: sectioned ? (notification.unread ? "Unread" : "Read") : nil,
            actions: linkActions(url: url, title: notification.subject.title)
        )
    }

    static func webURL(for notification: GitHubNotification, server: GitHubServer) -> URL {
        if let api = notification.subject.url, let page = server.webURL(forAPI: api) {
            return page
        }
        if notification.subject.type == "Release" {
            return notification.repository.htmlUrl.appending(path: "releases")
        }
        return notification.repository.htmlUrl
    }

    static func reasonTitle(_ reason: String) -> String? {
        switch reason {
        case "approval_requested": "Approval Requested"
        case "assign": "Assigned"
        case "author": "Author"
        case "ci_activity": "CI"
        case "comment": "Comment"
        case "invitation": "Invitation"
        case "manual", "subscribed": "Subscribed"
        case "member_feature_requested": "Feature Request"
        case "mention": "Mentioned"
        case "review_requested": "Review Requested"
        case "security_alert", "security_advisory_credit": "Security"
        case "state_change": "State Changed"
        case "team_mention": "Team Mentioned"
        default: nil
        }
    }

    /// Blue while unread, as Mail marks unread mail; gray once read.
    static func subjectIcon(_ type: String, unread: Bool) -> ExtensionIcon {
        let tint = unread ? "blue" : "gray"
        return switch type {
        case "PullRequest": octicon("git-pull-request", symbol: "arrow.triangle.pull", tint: tint)
        case "Issue": octicon("issue-opened", symbol: "smallcircle.filled.circle", tint: tint)
        case "Release": octicon("tag", symbol: "tag", tint: tint)
        case "Discussion": octicon("comment-discussion", symbol: "bubble.left.and.bubble.right", tint: tint)
        case "Commit": octicon("git-commit", symbol: "smallcircle.filled.circle", tint: tint)
        case "CheckSuite", "WorkflowRun": octicon("play", symbol: "play.circle", tint: tint)
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread", "SecurityAdvisory":
            octicon("shield", symbol: "exclamationmark.shield", tint: unread ? "red" : "gray")
        default: octicon("bell", symbol: "bell", tint: tint)
        }
    }

    // MARK: - Pull requests and issues

    static func item(for issue: GitHubIssue, section: String?, now: Date) -> ExtensionListItem {
        let reference = "\(issue.repositoryName)#\(issue.number)"
        var accessories = [ExtensionListAccessory]()
        if issue.draft == true, issue.isOpen {
            accessories.append(ExtensionListAccessory(text: "Draft", help: "Draft pull request"))
        }
        if let author = issue.user?.login {
            accessories.append(ExtensionListAccessory(text: author, help: "Author"))
        }
        accessories.append(ExtensionListAccessory(text: age(of: issue.updatedAt, now: now), help: "Updated"))
        return ExtensionListItem(
            id: String(issue.id),
            title: issue.title,
            subtitle: reference,
            icon: stateIcon(for: issue),
            accessories: accessories,
            keywords: [issue.repositoryName, "#\(issue.number)", "\(issue.number)"],
            section: section,
            actions: linkActions(url: issue.htmlUrl, title: issue.title)
        )
    }

    /// GitHub's own state marks and colors: green open, gray draft or not
    /// planned, purple merged or completed, red closed unmerged.
    static func stateIcon(for issue: GitHubIssue) -> ExtensionIcon {
        if issue.isPullRequest {
            if issue.isMerged { return octicon("git-merge", symbol: "arrow.triangle.merge", tint: "violet") }
            if !issue.isOpen { return octicon("git-pull-request-closed", symbol: "xmark.circle", tint: "red") }
            if issue.draft == true { return octicon("git-pull-request-draft", symbol: "arrow.triangle.pull", tint: "gray") }
            return octicon("git-pull-request", symbol: "arrow.triangle.pull", tint: "green")
        }
        if issue.isOpen { return octicon("issue-opened", symbol: "smallcircle.filled.circle", tint: "green") }
        if issue.stateReason == "not_planned" { return octicon("skip", symbol: "slash.circle", tint: "gray") }
        return octicon("issue-closed", symbol: "checkmark.circle", tint: "violet")
    }

    /// One of GitHub's Octicons in `icons/octicons/`, drawn alone in the
    /// tint; `symbol` stands in where Prism can't draw the file.
    static func octicon(_ name: String, symbol: String, tint: String) -> ExtensionIcon {
        ExtensionIcon(symbol: symbol, tint: tint, image: "icons/octicons/\(name).svg", style: .glyph)
    }

    // MARK: - Repositories

    static func item(for repository: GitHubRepository, showsStars: Bool, now: Date) -> ExtensionListItem {
        var accessories = [ExtensionListAccessory]()
        if repository.private {
            accessories.append(ExtensionListAccessory(symbol: "lock.fill", help: "Private"))
        }
        if repository.archived == true {
            accessories.append(ExtensionListAccessory(text: "Archived", help: "Archived repository"))
        }
        if showsStars, let stars = repository.stargazersCount {
            accessories.append(ExtensionListAccessory(text: starCount(stars), symbol: "star", help: "Stars"))
        }
        if let date = repository.starredAt ?? repository.updatedAt {
            accessories.append(ExtensionListAccessory(
                text: age(of: date, now: now), help: repository.starredAt == nil ? "Updated" : "Starred"
            ))
        }
        var actions = linkActions(url: repository.htmlUrl, title: nil)
        actions.append(ExtensionAction(
            id: ActionID.copyName, title: "Copy Name", symbol: "doc.on.doc",
            kind: .copy(text: repository.fullName), shortcut: ExtensionShortcut("cmd+shift+t")
        ))
        return ExtensionListItem(
            id: String(repository.id),
            title: repository.fullName,
            subtitle: repository.description.flatMap { $0.isEmpty ? nil : $0 },
            icon: repository.fork == true
                ? octicon("repo-forked", symbol: "arrow.triangle.branch", tint: "gray")
                : octicon("repo", symbol: "book.closed", tint: "gray"),
            accessories: accessories,
            keywords: [repository.name],
            actions: actions
        )
    }

    static func starCount(_ count: Int) -> String {
        guard count >= 1_000 else { return "\(count)" }
        let thousands = Double(count) / 1_000
        return thousands >= 100 ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
    }

    // MARK: - Shared

    static func linkActions(url: URL, title: String?) -> [ExtensionAction] {
        var actions = [
            ExtensionAction(id: ActionID.open, title: "Open in Browser", symbol: "safari", kind: .open(url: url)),
            ExtensionAction(
                id: ActionID.copyURL, title: "Copy URL", symbol: "link",
                kind: .copy(text: url.absoluteString), shortcut: ExtensionShortcut("cmd+shift+c")
            ),
        ]
        if let title {
            actions.append(ExtensionAction(
                id: ActionID.copyTitle, title: "Copy Title", symbol: "doc.on.doc",
                kind: .copy(text: title), shortcut: ExtensionShortcut("cmd+shift+t")
            ))
        }
        return actions
    }

    /// A short age such as `now`, `5m`, `3h`, `2d`, `6w`, or `1y`.
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        if minutes < 1 { return "now" }
        if hours < 1 { return "\(minutes)m" }
        if days < 1 { return "\(hours)h" }
        if days < 7 { return "\(days)d" }
        if days < 365 { return "\(days / 7)w" }
        return "\(days / 365)y"
    }

    // MARK: - Setup and errors

    /// Shown until a token is set: Return opens GitHub's page for a new
    /// token with the right scopes filled in.
    static func tokenItem(server: GitHubServer) -> ExtensionListItem {
        ExtensionListItem(
            id: "create-token",
            title: "Add a GitHub Token",
            subtitle: "Create a classic token, then paste it in Settings → Extensions → GitHub",
            icon: ExtensionIcon(symbol: "key", tint: "gray", style: .glyph),
            actions: [ExtensionAction(
                id: ActionID.createToken, title: "Create Token on GitHub", symbol: "safari",
                kind: .open(url: server.newTokenURL)
            )]
        )
    }

    /// Shown when `gh` is installed but signed out: signing in there is
    /// enough, with no token to copy.
    static func cliItem(host: String) -> ExtensionListItem {
        let command = host == "github.com" ? GitHubCLI.loginCommand : "\(GitHubCLI.loginCommand) --hostname \(host)"
        return ExtensionListItem(
            id: "github-cli",
            title: "Sign In with GitHub CLI",
            subtitle: "Run \(command) in Terminal, then reopen this list",
            icon: ExtensionIcon(symbol: "terminal", tint: "gray", style: .glyph),
            actions: [ExtensionAction(
                id: ActionID.copyLoginCommand, title: "Copy Command", symbol: "doc.on.doc",
                kind: .copy(text: command)
            )]
        )
    }

    static func message(for error: GitHubError, source: GitHubTokenSource = .preferences, now: Date) -> ExtensionListMessage {
        if source == .githubCLI, error == .invalidToken || error == .missingScope {
            return ExtensionListMessage(
                title: "GitHub Didn’t Accept the GitHub CLI Login",
                message: "Run \(GitHubCLI.loginCommand) in Terminal again, or paste a token in Settings → Extensions → GitHub.",
                symbol: "terminal"
            )
        }
        return switch error {
        case .missingToken:
            ExtensionListMessage(title: "Add a GitHub Token", message: "Paste a token in Settings → Extensions → GitHub.", symbol: "key")
        case .invalidServer:
            ExtensionListMessage(title: "Check the Server Address", message: "Enter https://github.com or your GitHub Enterprise address in Settings → Extensions → GitHub.", symbol: "exclamationmark.triangle")
        case .invalidToken:
            ExtensionListMessage(title: "GitHub Didn’t Accept the Token", message: "It may have expired. Paste a new one in Settings → Extensions → GitHub.", symbol: "key")
        case .missingScope:
            ExtensionListMessage(title: "The Token Needs More Access", message: "Use a classic token with the \(GitHubClient.scopes.joined(separator: ", ")) scopes.", symbol: "key")
        case .notificationsNeedClassicToken:
            ExtensionListMessage(title: "Notifications Need a Classic Token", message: "GitHub doesn’t share notifications with fine-grained tokens. Create a classic token with the notifications scope.", symbol: "key")
        case .rateLimited, .status, .unexpectedResponse, .unreachable:
            ExtensionListMessage(title: summary(of: error, now: now), symbol: "exclamationmark.triangle")
        }
    }

    /// One line for a failure, shown beside rows kept from an earlier load.
    static func summary(of error: GitHubError, now: Date) -> String {
        switch error {
        case let .rateLimited(resetsAt):
            if let resetsAt, resetsAt > now {
                let minutes = max(1, Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up)))
                return "GitHub’s rate limit was reached. Try again in \(minutes) min."
            }
            return "GitHub’s rate limit was reached. Try again shortly."
        case let .status(code):
            return "GitHub answered with an error (HTTP \(code))."
        case .unexpectedResponse:
            return "GitHub sent a response Prism couldn’t read."
        case let .unreachable(reason):
            return "Couldn’t reach GitHub: \(reason)"
        case .missingToken, .invalidServer, .invalidToken, .missingScope, .notificationsNeedClassicToken:
            return message(for: error, now: now).title
        }
    }
}

/// Where the token in use came from, for messages that say how to fix it.
enum GitHubTokenSource: Sendable {
    case preferences
    case githubCLI
}
