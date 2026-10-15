import Foundation
import PrismExtensionKit
import Testing
@testable import AgentUsage

/// The AI usage widgets read the same controller rows the list does; these
/// tests cover the mapping. Prism tests how its cards lay the data out.
@MainActor
@Suite("Agent usage widgets")
struct AgentUsageWidgetTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.spike.prism.tests.agentusagewidgets.\(UUID().uuidString)")!
    }

    private func row(
        _ id: AgentUsageProviderID = .codex,
        name: String = "Codex",
        usedPercent: Double = 42,
        failure: AgentUsageFailure? = nil,
        keepsLastNumbers: Bool = true
    ) -> AgentUsageRow {
        let report = AgentUsageReport.fixture(provider: id, providerName: name, usedPercent: usedPercent)
        return AgentUsageRow(
            id: id,
            displayName: name,
            icon: .symbol("circle", tint: "gray"),
            metrics: keepsLastNumbers ? report.metrics : [],
            failure: failure,
            fetchedAt: keepsLastNumbers ? report.fetchedAt : nil
        )
    }

    @Test("the card meters what the pane shows: remaining, or used when the preference is off")
    func resolvesUsedAndRemaining() {
        let remaining = AgentUsageWidgetSnapshot.make(
            rows: [row(usedPercent: 42)],
            showsRemaining: true,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(remaining.metrics.first?.valueText == "58%")
        #expect(abs((remaining.metrics.first?.fraction ?? 0) - 0.58) < 0.0001)
        #expect(remaining.metrics.first?.statusText == nil)
        // The fixture's window resets a day after the fetch.
        #expect(remaining.metrics.first?.resetText == "1d")

        let used = AgentUsageWidgetSnapshot.make(
            rows: [row(usedPercent: 42)],
            showsRemaining: false,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(used.metrics.first?.valueText == "42%")
        #expect(abs((used.metrics.first?.fraction ?? 0) - 0.42) < 0.0001)
        // Tint follows what is left, not what the card prints.
        #expect(abs((used.metrics.first?.remainingFraction ?? 0) - 0.58) < 0.0001)
    }

    @Test("widgets use the list percentage for dollar and count quotas")
    func nonPercentQuotas() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ampReport = try AmpUsageMapper.report(fromDisplayText:
            "Individual credits: $12.00 remaining (includes $2.00 Amp Free remaining today; resets daily)",
            fetchedAt: now)
        let amp = AgentUsageRow(
            id: .amp, displayName: "Amp", icon: .asset("icons/amp.svg"),
            metrics: ampReport.metrics, fetchedAt: now)
        let count = AgentUsageRow(
            id: .zai, displayName: "ZAI", icon: .symbol("circle", tint: "gray"),
            metrics: [AgentUsageMetric(id: "count", title: "Count", section: .limits,
                value: .progress(used: 1, limit: 4, format: .count, resetsAt: nil, windowSeconds: nil))],
            fetchedAt: now)

        let remaining = AgentUsageWidgetSnapshot.make(rows: [amp, count], showsRemaining: true, now: now)
        #expect(remaining.metrics.map(\.valueText) == ["40%", "75%"])
        #expect(abs((remaining.metrics[0].fraction ?? 0) - 0.4) < 0.0001)
        #expect(abs((remaining.metrics[1].fraction ?? 0) - 0.75) < 0.0001)

        let used = AgentUsageWidgetSnapshot.make(rows: [amp, count], showsRemaining: false, now: now)
        #expect(used.metrics.map(\.valueText) == ["60%", "25%"])
        #expect(abs((used.metrics[0].fraction ?? 0) - 0.6) < 0.0001)
        #expect(abs((used.metrics[1].fraction ?? 0) - 0.25) < 0.0001)
    }

    @Test("an agent with no numbers keeps its name and shows why")
    func failureBecomesStatus() {
        let snapshot = AgentUsageWidgetSnapshot.make(
            rows: [row(.grok, name: "Grok", failure: .authExpired("Run grok login."), keepsLastNumbers: false)],
            showsRemaining: true,
            now: Date()
        )
        let metric = snapshot.metrics.first
        #expect(metric?.title == "Grok")
        #expect(metric?.statusText == "Sign In")
        #expect(metric?.displayText == "Sign In")
        #expect(metric?.fraction == nil)
    }

    @Test("each metric carries its provider's mark for the ring center, with or without numbers")
    func metricsCarryProviderIcon() {
        let claude = AgentUsageRow(
            id: .claude, displayName: "Claude", icon: .asset("icons/claude.svg"),
            metrics: AgentUsageReport.fixture(provider: .claude, providerName: "Claude").metrics,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let snapshot = AgentUsageWidgetSnapshot.make(
            rows: [claude, row(.grok, name: "Grok", failure: .authExpired("sign in"), keepsLastNumbers: false)],
            showsRemaining: true,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(snapshot.metrics.map(\.icon) == [.asset("icons/claude.svg"), .symbol("circle", tint: "gray")])
    }

    @Test("a failed refresh retains old numbers but displays its failure", arguments: [AgentUsageFailure.network("offline"), .authExpired("sign in")])
    func failureKeepsLastNumbers(failure: AgentUsageFailure) {
        let snapshot = AgentUsageWidgetSnapshot.make(
            rows: [row(failure: failure)],
            showsRemaining: true,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let metric = snapshot.metrics.first
        #expect(metric?.valueText == "58%")
        #expect(metric?.statusText == failure.shortStatusText)
        #expect(metric?.displayText == failure.shortStatusText)
        #expect(metric?.fraction != nil)
    }

    @Test("two-agent cards take the first two visible agents")
    func firstTwo() {
        let snapshot = AgentUsageWidgetSnapshot.make(
            rows: [row(.grok, name: "Grok"), row(.amp, name: "Amp"), row(.codex)],
            showsRemaining: true,
            now: Date()
        )
        #expect(snapshot.metrics.map(\.id) == ["grok", "amp"])
    }

    @Test("quota cards carry each agent's figure, mark, reset, and failure status")
    func quotaCardContent() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let card = AgentUsagePresentation.quotaCard(
            rows: [row(.codex, usedPercent: 92), row(.grok, name: "Grok", failure: .network("offline"))],
            showsRemaining: true, now: now, openCommandID: "usage"
        )
        #expect(card.openCommandID == "usage" && card.emptyText == "No agents enabled")
        let codex = try #require(card.items.first)
        #expect(codex.value == "8%" && codex.status == nil && codex.caption == "1d")
        #expect(codex.meter?.tone == .critical)
        let grok = card.items[1]
        #expect(grok.status == "Offline" && grok.caption == "Last 58%")
        #expect(AgentUsagePresentation.quotaCard(rows: [], showsRemaining: true, now: now, openCommandID: "usage")
            .items.isEmpty)
    }
}
