import Foundation

/// One group of the pull request or issue list: a ⌘P filter and the search
/// that fills it, as GitHub's own "Your pull requests" tabs divide them.
struct GitHubSection: Hashable, Sendable {
    let id: String
    let title: String
    let symbol: String
    /// The search qualifiers, without the `is:pr` / `is:issue` kind.
    let qualifiers: String
    /// Closed items count only when they closed this recently.
    let closedWithinDays: Int?

    init(id: String, title: String, symbol: String, qualifiers: String, closedWithinDays: Int? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.qualifiers = qualifiers
        self.closedWithinDays = closedWithinDays
    }

    /// The search for this section; `text` narrows it to what the user typed.
    func query(kind: GitHubIssueKind, text: String = "", now: Date) -> String {
        var parts = ["is:\(kind.qualifier)", "archived:false", qualifiers]
        if let closedWithinDays {
            let since = Calendar(identifier: .gregorian).date(byAdding: .day, value: -closedWithinDays, to: now) ?? now
            parts.append("closed:>=\(Self.day.string(from: since))")
        }
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: " ")
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum GitHubIssueKind: Sendable {
    case pullRequest
    case issue

    var qualifier: String {
        switch self {
        case .pullRequest: "pr"
        case .issue: "issue"
        }
    }

    /// `Pull Requests` in titles, `Pull requests` in sentences.
    var plural: String {
        switch self {
        case .pullRequest: "Pull Requests"
        case .issue: "Issues"
        }
    }

    var sentencePlural: String {
        switch self {
        case .pullRequest: "Pull requests"
        case .issue: "Issues"
        }
    }

    /// The empty list's symbol; messages take SF Symbols only.
    var symbol: String {
        switch self {
        case .pullRequest: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        }
    }

    /// The sections shown together when no filter is chosen, in order. An
    /// item in several shows only in the first.
    var sections: [GitHubSection] {
        switch self {
        case .pullRequest:
            [
                GitHubSection(id: "created", title: "Created", symbol: "person", qualifiers: "is:open author:@me"),
                GitHubSection(id: "review-requested", title: "Review Requests", symbol: "eye", qualifiers: "is:open review-requested:@me"),
                GitHubSection(id: "assigned", title: "Assigned", symbol: "person.badge.plus", qualifiers: "is:open assignee:@me"),
                GitHubSection(id: "mentioned", title: "Mentioned", symbol: "at", qualifiers: "is:open mentions:@me"),
                GitHubSection(id: "reviewed", title: "Reviewed", symbol: "checkmark.bubble", qualifiers: "is:open reviewed-by:@me"),
                GitHubSection(
                    id: "recently-closed", title: "Recently Closed", symbol: "clock.arrow.circlepath",
                    qualifiers: "is:closed involves:@me", closedWithinDays: 14
                ),
            ]
        case .issue:
            [
                GitHubSection(id: "created", title: "Created", symbol: "person", qualifiers: "is:open author:@me"),
                GitHubSection(id: "assigned", title: "Assigned", symbol: "person.badge.plus", qualifiers: "is:open assignee:@me"),
                GitHubSection(id: "mentioned", title: "Mentioned", symbol: "at", qualifiers: "is:open mentions:@me"),
                GitHubSection(
                    id: "recently-closed", title: "Recently Closed", symbol: "clock.arrow.circlepath",
                    qualifiers: "is:closed involves:@me", closedWithinDays: 60
                ),
            ]
        }
    }

    /// What a typed search covers when no filter is chosen: anything the
    /// user took part in, open or closed.
    var involved: GitHubSection {
        GitHubSection(id: "involved", title: "Results", symbol: "magnifyingglass", qualifiers: "involves:@me")
    }
}
