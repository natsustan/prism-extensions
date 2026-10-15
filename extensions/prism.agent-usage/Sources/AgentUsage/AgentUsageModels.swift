import Foundation

/// One AI coding agent Prism can report usage for. The raw values are stable
/// preference keys, so persisted toggles survive renames of the display name.
enum AgentUsageProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case claude
    case grok
    case amp
    case antigravity
    case devin
    case zai

    var id: String { rawValue }
}

/// How a provider draws its mark in the list and detail header.
enum AgentUsageProviderIcon: Equatable, Codable, Sendable {
    /// Brand mark from the extension's `icons/` folder, rendered as a
    /// template so it follows the surrounding foreground style.
    case asset(String)
    /// Fallback for a provider without a brand mark: a tinted symbol tile.
    case symbol(String, tint: String)
}

/// One normalized row of a provider's report: a bounded quota with a reset
/// time, a bare number, a state pill, or a dated line (a reset credit's expiry).
/// Values are provider-agnostic so the list and detail render every agent the
/// same way.
struct AgentUsageMetric: Identifiable, Equatable, Codable, Sendable {
    /// What a metric is about, so the detail pane can break a long report into
    /// blocks. Providers assign this explicitly; nothing infers a group from an
    /// id, which would break the moment a provider renames one.
    enum Section: String, CaseIterable, Identifiable, Codable, Sendable {
        /// The account's own windows ("5h Limit", "Weekly Limit").
        case limits
        /// Per-model or per-feature windows layered on top of those.
        case perModel
        /// Balances and manual resets: money and credits, not meters.
        case creditsAndResets

        var id: String { rawValue }

        var title: String {
            switch self {
            case .limits: "Limits"
            case .perModel: "Per-model"
            case .creditsAndResets: "Credits & Resets"
            }
        }
    }

    enum Value: Equatable, Codable, Sendable {
        /// A meter with a ceiling. `used` and `limit` are in `format`'s unit.
        case progress(used: Double, limit: Double, format: Format, resetsAt: Date?, windowSeconds: Int?)
        /// An unbounded value, already formatted ("2 available").
        case text(String)
        /// A state pill ("Disabled", "2500 cap").
        case badge(String)
        /// A date the detail pane renders as absolute time plus a countdown.
        case date(Date)
    }

    enum Format: Equatable, Codable, Sendable {
        case percent
        case count
        case currency
    }

    let id: String
    let title: String
    /// Required: a metric that forgot its group would silently land in the
    /// wrong block, so make that a compile error instead.
    let section: Section
    let value: Value

    init(id: String, title: String, section: Section, value: Value) {
        self.id = id
        self.title = title
        self.section = section
        self.value = value
    }
}

/// A full report for one provider. Failure copy lives on `AgentUsageFailure`,
/// so a report only ever describes data that was actually fetched.
struct AgentUsageReport: Identifiable, Equatable, Sendable {
    let providerID: AgentUsageProviderID
    let providerName: String
    /// Human-readable plan, when the provider exposes one ("Pro 5x").
    let plan: String?
    /// Account label for display only (email or user id) — never a credential.
    let accountLabel: String?
    let metrics: [AgentUsageMetric]
    let fetchedAt: Date

    var id: AgentUsageProviderID { providerID }

    /// The meter the list row leads with: the first progress metric, which is
    /// the window the provider itself treats as primary.
    var primaryMetric: AgentUsageMetric? {
        metrics.first { if case .progress = $0.value { return true } else { return false } }
    }

    var secondaryMetrics: [AgentUsageMetric] {
        guard let primaryMetric else { return metrics }
        return metrics.filter { $0.id != primaryMetric.id }
    }

    /// One block of the detail pane: a section and the metrics that named it.
    struct Group: Identifiable, Equatable, Sendable {
        let section: AgentUsageMetric.Section
        let metrics: [AgentUsageMetric]

        var id: String { section.id }
    }

    /// The metrics as the detail pane groups them: section order is fixed, and
    /// an empty section is dropped rather than shown as a heading with no rows.
    var groups: [Group] {
        AgentUsageMetric.Section.allCases.compactMap { section in
            let grouped = metrics.filter { $0.section == section }
            return grouped.isEmpty ? nil : Group(section: section, metrics: grouped)
        }
    }

    /// Short reports stay a flat list: two rows under two headings reads worse
    /// than two rows. Grouping only pays once there is enough to scan.
    var showsSectionHeaders: Bool { metrics.count >= Self.sectionHeaderThreshold }

    private static let sectionHeaderThreshold = 4

    /// Plain-text form for the "Copy Usage Summary" action.
    var summaryText: String {
        // Export absolute timestamps: pasted text cannot keep a countdown current.
        var lines = [providerName + (plan.map { " · \($0)" } ?? ""),
                     "Fetched at: \(fetchedAt.ISO8601Format())"]
        for metric in metrics {
            switch metric.value {
            case let .progress(used, limit, format, resetsAt, _):
                let value = AgentUsageFormat.progressText(
                    used: used, limit: limit, format: format, showsRemaining: false)
                let reset = resetsAt.map { ", resets at \($0.ISO8601Format())" } ?? ""
                lines.append("\(metric.title): \(value)\(reset)")
            case let .text(text), let .badge(text):
                lines.append("\(metric.title): \(text)")
            case let .date(date):
                lines.append("\(metric.title): \(date.ISO8601Format())")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Why a provider has no data. Copy is composed by the provider, so hints can
/// name the CLI the user has to run.
enum AgentUsageFailure: Error, Equatable, Codable, Sendable {
    /// No local credentials: the agent was never signed in on this Mac.
    case notConfigured(String)
    /// The provider rejected the credentials and they could not be refreshed.
    case authExpired(String)
    /// Transport or server-side failure; a retry may succeed.
    case network(String)
    /// The endpoint answered, but not in a shape we understand.
    case invalidResponse(String)

    var message: String {
        switch self {
        case let .notConfigured(message), let .authExpired(message),
             let .network(message), let .invalidResponse(message):
            message
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured: "person.crop.circle.badge.questionmark"
        case .authExpired: "key.slash"
        case .network: "wifi.exclamationmark"
        case .invalidResponse: "exclamationmark.triangle"
        }
    }

    /// Never-signed-in is a state, not a failure: the list shows it in secondary
    /// text instead of alarm orange.
    var isMissingCredentials: Bool {
        if case .notConfigured = self { return true }
        return false
    }

    /// Two-or-three-word form for the places that have no room for the full
    /// sentence: the Agent Usage list row and the AI usage widgets.
    var shortStatusText: String {
        switch self {
        case .notConfigured: "Not Configured"
        case .authExpired: "Sign In"
        case .network: "Offline"
        case .invalidResponse: "Error"
        }
    }
}

/// One list row: the provider's identity plus whatever data (or failure) the
/// last refresh produced. Rows survive a failed refresh so the list never
/// blanks out under the user.
struct AgentUsageRow: Identifiable, Equatable, Codable, Sendable {
    let id: AgentUsageProviderID
    let displayName: String
    let icon: AgentUsageProviderIcon
    var plan: String?
    var accountLabel: String?
    var metrics: [AgentUsageMetric] = []
    var failure: AgentUsageFailure?
    var fetchedAt: Date?
    var isRefreshing = false

    var report: AgentUsageReport? {
        guard let fetchedAt else { return nil }
        return AgentUsageReport(
            providerID: id,
            providerName: displayName,
            plan: plan,
            accountLabel: accountLabel,
            metrics: metrics,
            fetchedAt: fetchedAt
        )
    }

    var isConnected: Bool { fetchedAt != nil && failure == nil }
}
