import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import AgentUsage

/// Agent Usage driven the way Prism drives it, with stub providers in place
/// of the real agents.
@MainActor
final class AgentUsageFixture {
    let codex = StubAgentUsageProvider(id: .codex, displayName: "Codex", outcome: .success(.fixture(usedPercent: 42)))
    let grok = StubAgentUsageProvider(
        id: .grok, displayName: "Grok", hasLocalCredentialsValue: false,
        outcome: .success(.fixture(provider: .grok, providerName: "Grok")))
    let session: AgentUsageSession
    let prism: PrismTestHost

    init(
        preferences: [String: ExtensionValue] = [:],
        dataDirectory: URL? = nil,
        extra: @escaping @MainActor (any ZAISecretStore) -> [any AgentUsageProvider] = { _ in [] }
    ) async throws {
        let codex = codex, grok = grok
        session = AgentUsageSession { secrets in
            AgentUsageController(providers: [codex, grok] + extra(secrets), zaiSecrets: secrets)
        }
        prism = try await PrismTestHost(
            AgentUsage(session: session), extensionID: "prism.agent-usage",
            preferences: preferences, dataDirectory: dataDirectory
        )
    }

    var controller: AgentUsageController { session.controller! }

    func settle() async {
        await session.waitForPendingRefresh()
    }
}

@MainActor
@Suite("Agent Usage extension")
struct AgentUsageExtensionTests {
    @Test("the manifest validates and declares the list, grouped preferences, and the widgets it serves")
    func manifest() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: url))
        try manifest.validate(allowsReservedNamespace: true)
        #expect(manifest.commands.map(\.id) == ["usage"] && manifest.command(id: "usage")?.mode == .list)
        #expect(manifest.preferences.map(\.type) == [.orderedList, .bool, .secret])
        #expect(manifest.preferenceSections.map(\.title) == ["Agents", "Display", "Z.ai"])
        #expect(Dictionary(uniqueKeysWithValues: manifest.widgets.map { ($0.id, $0.template) })
            == AgentUsageSession.widgetTemplates)
    }

    @Test("opening the list fetches detected agents and tells Prism when the numbers land")
    func list() async throws {
        let fixture = try await AgentUsageFixture()
        var list = try await fixture.prism.list("usage")
        #expect(list.items.map(\.id) == ["codex"] && list.showsDetail)
        await fixture.settle()
        list = try await fixture.prism.list("usage")
        #expect(await fixture.prism.changedLists.contains("usage"))
        #expect(list.items[0].accessories.last?.text == "58%")
        #expect(await fixture.codex.fetchCount() == 1)
    }

    @Test("the Agents preference lists every provider with detection defaults and orders the list")
    func agentsPreference() async throws {
        let fixture = try await AgentUsageFixture()
        let items = try await fixture.prism.preferenceItems("agents")
        #expect(items.map(\.id) == ["codex", "grok"])
        #expect(items.map(\.isOn) == [true, false])
        #expect(items[0].badge == "Configured" && items[1].badge == nil)

        let arrangement = ExtensionOrderedList(value: nil)
            .setting("grok", isOn: true, items: items)
            .moving("grok", onto: "codex", items: items)
        try await fixture.prism.setPreferences(["agents": arrangement.value])
        #expect(try await fixture.prism.list("usage").items.map(\.id) == ["grok", "codex"])
        await fixture.settle()
        #expect(fixture.controller.row(for: .grok)?.fetchedAt != nil)

        try await fixture.prism.setPreferences(["agents": arrangement.setting("codex", isOn: false, items: items).value])
        #expect(try await fixture.prism.list("usage").items.map(\.id) == ["grok"])
    }

    @Test("the remaining switch flips list and detail text")
    func showsRemaining() async throws {
        let fixture = try await AgentUsageFixture(preferences: ["showsRemaining": .bool(false)])
        _ = try await fixture.prism.list("usage")
        await fixture.settle()
        let list = try await fixture.prism.list("usage")
        #expect(list.items[0].accessories.last?.text == "42%")
        #expect(list.items[0].detail?.sections.first?.rows.first?.value == "42% used")
    }

    @Test("a Z.ai key from Prism reaches the provider and turns an untouched Z.ai switch on")
    func zaiKey() async throws {
        let fixture = try await AgentUsageFixture { secrets in
            var zai = ZAIAgentUsageProvider()
            zai.authStore = ZAIAuthStore(
                environment: [:],
                configFileURL: URL(fileURLWithPath: "/nonexistent"),
                claudeSettingsURL: URL(fileURLWithPath: "/nonexistent"),
                storedKey: { try secrets.apiKey() })
            zai.client = StubHTTPClient(status: 500)
            return [zai]
        }
        _ = try await fixture.prism.list("usage")
        #expect(!fixture.controller.isDetected(.zai))

        try await fixture.prism.setPreferences(["zaiKey": .string(" zai-key ")])
        #expect(try await fixture.prism.list("usage").items.map(\.id).contains("zai"))
        #expect(fixture.controller.isDetected(.zai))
        await fixture.settle()

        try await fixture.prism.setPreferences([:])
        _ = try await fixture.prism.list("usage")
        #expect(!fixture.controller.isDetected(.zai))
        await fixture.settle()
    }

    @Test("the row's Refresh action fetches at once")
    func refresh() async throws {
        let fixture = try await AgentUsageFixture()
        _ = try await fixture.prism.list("usage")
        await fixture.settle()
        #expect(try await fixture.prism.perform("refresh", on: "codex", in: "usage").result == .keepOpen(message: ""))
        await fixture.settle()
        #expect(await fixture.codex.fetchCount() == 2)
    }

    @Test("quota widgets show the visible agents in the requested template")
    func widgets() async throws {
        let fixture = try await AgentUsageFixture()
        _ = try await fixture.prism.list("usage")
        await fixture.settle()
        guard case let .quota(template, card) = try await fixture.prism.widget("rings") else {
            Issue.record("Agent Usage widgets are quota cards")
            return
        }
        #expect(template == .quotaRings && card.items.map(\.id) == ["codex"] && card.openCommandID == "usage")
        await #expect(throws: PrismTestHost.Failure.self) { try await fixture.prism.widget("missing") }
    }

    @Test("a restarted process shows the cached numbers at once and keeps the throttle")
    func cache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await AgentUsageFixture(dataDirectory: directory)
        _ = try await first.prism.list("usage")
        await first.settle()
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cache.json").path))

        // A new process: a fresh session and providers that have not fetched.
        let second = try await AgentUsageFixture(dataDirectory: directory)
        let list = try await second.prism.list("usage")
        #expect(list.items[0].accessories.last?.text == "58%")
        await second.settle()
        #expect(await second.codex.fetchCount() == 0)
    }
}

@MainActor
@Suite("Agent Usage presentation")
struct AgentUsagePresentationTests {
    private func row(failure: AgentUsageFailure? = nil, refreshing: Bool = false) -> AgentUsageRow {
        let report = AgentUsageReport.fixture(usedPercent: 80)
        return AgentUsageRow(
            id: .codex, displayName: "Codex", icon: .asset("icons/codex.svg"),
            plan: report.plan, accountLabel: report.accountLabel, metrics: report.metrics,
            failure: failure, fetchedAt: report.fetchedAt, isRefreshing: refreshing
        )
    }

    @Test("a row leads with its primary quota and keeps a failure beside retained numbers")
    func listItem() throws {
        let item = AgentUsagePresentation.item(for: row(failure: .network("Offline now")), showsRemaining: true)
        #expect(item.title == "Codex" && item.icon?.image == "icons/codex.svg")
        #expect(item.accessories.map(\.text) == ["Offline", "20%"])
        #expect(item.accessories[0].tint == "orange")
        let meter = try #require(item.accessories[1].meter)
        #expect(abs(meter.fraction - 0.2) < 0.0001 && meter.tone == .warning)
        #expect(meter.resetsAt == Date(timeIntervalSince1970: 1_700_086_400))
        #expect(item.actions.map(\.id) == ["refresh", "copy-summary"])
        guard case let .copy(text) = item.actions[1].kind else {
            Issue.record("Expected a copy action")
            return
        }
        #expect(text.hasPrefix("Status: Offline — last refresh failed; showing cached usage."))

        let missing = AgentUsagePresentation.item(for: row(failure: .notConfigured("Sign in with codex")), showsRemaining: true)
        #expect(missing.accessories[0].tint == nil)
        #expect(AgentUsagePresentation.item(for: row(refreshing: true), showsRemaining: true).isLoading)
    }

    @Test("the detail carries identity, freshness, the failure, and metric rows with meters")
    func detail() throws {
        let detail = AgentUsagePresentation.detail(for: row(failure: .authExpired("Sign in again")), showsRemaining: false)
        #expect(detail.title == "Codex")
        #expect(detail.subtitle == "Pro 5x · person@example.com")
        #expect(detail.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(detail.notice == ExtensionNotice(text: "Sign in again", symbol: "key.slash", tone: .warning))
        let metric = try #require(detail.sections.first?.rows.first)
        #expect(metric.label == "Weekly" && metric.value == "80% used")
        #expect(abs((metric.meter?.fraction ?? 0) - 0.8) < 0.0001 && metric.meter?.tone == .warning)

        let empty = AgentUsagePresentation.detail(
            for: AgentUsageRow(id: .grok, displayName: "Grok", icon: .symbol("circle", tint: "gray")),
            showsRemaining: true
        )
        #expect(empty.markdown == "No usage reported yet." && empty.sections.isEmpty)
    }

    @Test("badges and dates keep their kind")
    func valueKinds() {
        let date = Date(timeIntervalSince1970: 1_700_500_000)
        #expect(AgentUsagePresentation.row(
            for: AgentUsageMetric(id: "b", title: "Plan", section: .limits, value: .badge("Disabled")), showsRemaining: true
        ) == ExtensionMetadataRow(label: "Plan", value: "Disabled", style: .badge))
        #expect(AgentUsagePresentation.row(
            for: AgentUsageMetric(id: "d", title: "Expires", section: .creditsAndResets, value: .date(date)), showsRemaining: true
        ) == ExtensionMetadataRow(label: "Expires", date: date))
    }

    @Test("an empty list explains where to turn agents on")
    func emptyList() {
        let list = AgentUsagePresentation.list(rows: [], showsRemaining: true)
        #expect(list.items.isEmpty && list.emptyMessage?.title == "No agents enabled")
    }
}
