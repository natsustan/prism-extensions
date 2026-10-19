import Foundation

/// The first two agents' quotas, resolved for the quota widget templates
/// (`AgentUsagePresentation.quotaCard`). Testable without a window.
struct AgentUsageWidgetSnapshot: Equatable, Sendable {
    struct Metric: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        /// The provider's mark, drawn in the middle of the ring.
        let icon: AgentUsageProviderIcon
        /// 0...1 of what the card meters: the remaining share, or the used share
        /// when the Used/Left preference is off. `nil` when the agent reported no
        /// quota, which the card draws as a status instead of a number.
        let fraction: Double?
        /// The same percentage shown beside the provider in the usage list.
        let valueText: String
        /// 0...1 remaining, for the warning tint. `nil` alongside `fraction`.
        let remainingFraction: Double?
        /// Compact countdown to the window's reset, when the agent reports one.
        let resetText: String?
        /// Short failure state ("Sign In"), including failures with retained quota.
        let statusText: String?

        /// What the card prints: the number, or the reason there is none.
        var displayText: String { statusText ?? valueText }
    }

    let metrics: [Metric]

    init(metrics: [Metric] = []) {
        self.metrics = Array(metrics.prefix(2))
    }

    static let empty = AgentUsageWidgetSnapshot()

    /// Maps rows onto card metrics. An agent the user enabled keeps its name even
    /// with no numbers to show, so a card never silently drops it.
    static func make(rows: [AgentUsageRow], showsRemaining: Bool, now: Date) -> Self {
        AgentUsageWidgetSnapshot(metrics: rows.prefix(2).map { row in
            guard let metric = row.report?.primaryMetric,
                  case let .progress(used, limit, _, resetsAt, _) = metric.value else {
                return Metric(
                    id: row.id.rawValue,
                    title: row.displayName,
                    icon: row.icon,
                    fraction: nil,
                    valueText: "—",
                    remainingFraction: nil,
                    resetText: nil,
                    statusText: row.failure?.shortStatusText
                )
            }
            return Metric(
                id: row.id.rawValue,
                title: row.displayName,
                icon: row.icon,
                // The same rule the launcher's ring and detail bar fill by.
                fraction: AgentUsageFormat.displayedFraction(
                    used: used, limit: limit, showsRemaining: showsRemaining),
                valueText: AgentUsageFormat.meterPercent(
                    used: used, limit: limit, showsRemaining: showsRemaining),
                remainingFraction: AgentUsageFormat.remainingFraction(used: used, limit: limit),
                resetText: resetsAt.map { AgentUsageFormat.resetCountdownText(resetsAt: $0, now: now) },
                statusText: row.failure?.shortStatusText
            )
        })
    }
}
