import Foundation
import PrismExtensionKit

/// Agent Usage rows as protocol values. Pure, so the exact list, detail, and
/// widget content stay covered by tests without a window.
enum AgentUsagePresentation {
    // MARK: - List

    static func list(rows: [AgentUsageRow], showsRemaining: Bool) -> ExtensionList {
        ExtensionList(
            items: rows.map { item(for: $0, showsRemaining: showsRemaining) },
            searchPlaceholder: "Filter agents…",
            emptyMessage: ExtensionListMessage(
                title: "No agents enabled",
                message: "Turn your agents on in Settings → Extensions → Agent Usage to see their quotas here.",
                symbol: "gauge.with.needle"
            ),
            showsDetail: true
        )
    }

    static func item(for row: AgentUsageRow, showsRemaining: Bool) -> ExtensionListItem {
        var accessories = [ExtensionListAccessory]()
        // A failed refresh keeps the quota, so its status sits beside it.
        if let failure = row.failure {
            accessories.append(ExtensionListAccessory(
                text: failure.shortStatusText,
                tint: failure.isMissingCredentials ? nil : "orange",
                help: failure.message
            ))
        }
        if let metric = row.report?.primaryMetric, case let .progress(used, limit, _, resetsAt, _) = metric.value {
            accessories.append(ExtensionListAccessory(
                text: AgentUsageFormat.meterPercent(used: used, limit: limit, showsRemaining: showsRemaining),
                meter: meter(used: used, limit: limit, showsRemaining: showsRemaining, resetsAt: resetsAt)
            ))
        }
        var actions = [ExtensionAction(id: AgentUsage.ActionID.refresh, title: "Refresh", symbol: "arrow.clockwise")]
        if let summary = summary(for: row) {
            actions.append(ExtensionAction(
                id: AgentUsage.ActionID.copySummary, title: "Copy Usage Summary", symbol: "doc.on.doc",
                kind: .copy(text: summary), shortcut: ExtensionShortcut("cmd+shift+c")
            ))
        }
        return ExtensionListItem(
            id: row.id.rawValue,
            title: row.displayName,
            icon: row.icon.extensionIcon,
            accessories: accessories,
            keywords: [row.plan, row.id.rawValue].compactMap { $0 },
            detail: detail(for: row, showsRemaining: showsRemaining),
            actions: actions,
            isLoading: row.isRefreshing
        )
    }

    static func detail(for row: AgentUsageRow, showsRemaining: Bool) -> ExtensionDetail {
        let subtitle = [row.plan, row.accountLabel].compactMap { $0 }
        var sections = [ExtensionDetailSection]()
        if let report = row.report {
            if report.showsSectionHeaders {
                sections = report.groups.map { group in
                    ExtensionDetailSection(
                        title: group.section.title,
                        rows: group.metrics.map { self.row(for: $0, showsRemaining: showsRemaining) }
                    )
                }
            } else {
                sections = [ExtensionDetailSection(rows: report.metrics.map { self.row(for: $0, showsRemaining: showsRemaining) })]
            }
        }
        let empty = row.metrics.isEmpty && row.failure == nil
        return ExtensionDetail(
            title: row.displayName,
            subtitle: subtitle.isEmpty ? nil : subtitle.joined(separator: " · "),
            icon: row.icon.extensionIcon,
            updatedAt: row.fetchedAt,
            notice: row.failure.map { failure in
                ExtensionNotice(text: failure.message, symbol: failure.symbol, tone: .warning)
            },
            markdown: empty && !row.isRefreshing ? "No usage reported yet." : nil,
            sections: sections
        )
    }

    static func row(for metric: AgentUsageMetric, showsRemaining: Bool) -> ExtensionMetadataRow {
        switch metric.value {
        case let .progress(used, limit, format, resetsAt, _):
            let text = format == .percent
                ? AgentUsageFormat.meterText(used: used, limit: limit, showsRemaining: showsRemaining)
                : AgentUsageFormat.progressText(used: used, limit: limit, format: format, showsRemaining: showsRemaining)
            return ExtensionMetadataRow(
                label: metric.title, value: text,
                meter: meter(used: used, limit: limit, showsRemaining: showsRemaining, resetsAt: resetsAt)
            )
        case let .text(text):
            return ExtensionMetadataRow(label: metric.title, value: text)
        case let .badge(text):
            return ExtensionMetadataRow(label: metric.title, value: text, style: .badge)
        case let .date(date):
            return ExtensionMetadataRow(label: metric.title, date: date)
        }
    }

    /// Fills with the quantity the text reports; the tone follows what is
    /// left, so "about to run dry" reads the same either way.
    static func meter(used: Double, limit: Double, showsRemaining: Bool, resetsAt: Date?) -> ExtensionMeter {
        ExtensionMeter(
            fraction: AgentUsageFormat.displayedFraction(used: used, limit: limit, showsRemaining: showsRemaining),
            tone: tone(remaining: AgentUsageFormat.remainingFraction(used: used, limit: limit)),
            resetsAt: resetsAt
        )
    }

    static func tone(remaining: Double) -> ExtensionTone {
        if remaining <= 0.1 { return .critical }
        if remaining <= 0.25 { return .warning }
        return .normal
    }

    /// The "Copy Usage Summary" text: absolute times, and a status line while
    /// the numbers are cached from before a failed refresh.
    static func summary(for row: AgentUsageRow) -> String? {
        guard let report = row.report else { return nil }
        var summary = report.summaryText
        if let failure = row.failure {
            summary = "Status: \(failure.shortStatusText) — last refresh failed; showing cached usage.\n" + summary
        }
        return summary
    }

    // MARK: - Widgets

    static func quotaCard(
        rows: [AgentUsageRow], showsRemaining: Bool, now: Date, openCommandID: String
    ) -> ExtensionQuotaCard {
        let snapshot = AgentUsageWidgetSnapshot.make(rows: rows, showsRemaining: showsRemaining, now: now)
        return ExtensionQuotaCard(
            items: snapshot.metrics.map { metric in
                ExtensionQuotaItem(
                    id: metric.id,
                    title: metric.title,
                    icon: metric.icon.extensionIcon,
                    meter: metric.fraction.map { fraction in
                        ExtensionMeter(fraction: fraction, tone: tone(remaining: metric.remainingFraction ?? 1))
                    },
                    value: metric.valueText,
                    // A failure keeps the last number under its status.
                    caption: metric.statusText == nil ? metric.resetText
                        : (metric.fraction == nil ? nil : "Last \(metric.valueText)"),
                    status: metric.statusText
                )
            },
            emptyText: "No agents enabled",
            openCommandID: openCommandID
        )
    }
}

extension AgentUsageProviderIcon {
    /// Brand marks are SVGs in the extension's `icons/` folder, drawn as templates.
    var extensionIcon: ExtensionIcon {
        switch self {
        case let .asset(name): ExtensionIcon(symbol: "sparkle", tint: "gray", image: name)
        case let .symbol(symbol, tint): ExtensionIcon(symbol: symbol, tint: tint)
        }
    }
}
