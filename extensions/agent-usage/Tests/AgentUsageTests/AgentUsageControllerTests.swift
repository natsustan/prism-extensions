import AppKit
import Foundation
import Testing
@testable import AgentUsage

@MainActor
@Suite("Agent usage controller", .serialized)
struct AgentUsageControllerTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.spike.prism.tests.agentusage.\(UUID().uuidString)")!
    }

    private func makeController(
        _ providers: [any AgentUsageProvider],
        preferences: AgentUsagePreferencesStore? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> AgentUsageController {
        AgentUsageController(
            providers: providers,
            preferences: preferences ?? AgentUsagePreferencesStore(),
            now: now
        )
    }

    @Test("completed providers publish while another provider is still pending")
    func publishesIncrementally() async {
        let slow = ControlledAgentUsageProvider(id: .grok)
        let fast = StubAgentUsageProvider(id: .codex, displayName: "Codex")
        let controller = makeController([fast, slow])
        let published = AgentUsageTestEvent()
        controller.onChange = {
            if controller.row(for: .codex)?.fetchedAt != nil { published.signal() }
        }

        controller.refresh(force: true)
        #expect(await slow.started.wait())
        #expect(await published.wait())
        #expect(controller.row(for: .codex)?.isRefreshing == false)
        #expect(controller.row(for: .grok)?.isRefreshing == true)
        #expect(controller.isRefreshing)
        await slow.gate.open()
        await controller.waitForPendingRefresh()
        controller.onChange = nil
        #expect(!controller.isRefreshing)
    }

    @Test("disabling cancels active work and re-enabling waits for it to unwind", arguments: [false, true])
    func cancellationDrainsBeforeRestart(disableFeature: Bool) async {
        let provider = ControlledAgentUsageProvider(id: .codex)
        let controller = makeController([provider])
        controller.refresh()
        #expect(await provider.started.wait())

        if disableFeature { controller.setFeatureEnabled(false) }
        else { controller.setEnabled(false, for: .codex) }
        #expect(await provider.cancelled.wait())
        #expect(!controller.isRefreshing)
        if disableFeature {
            controller.setFeatureEnabled(true)
            controller.refresh()
        } else {
            controller.setEnabled(true, for: .codex)
        }
        #expect(controller.isRefreshing)
        #expect(await provider.state.fetchCount == 1)

        await provider.gate.open()
        await controller.waitForPendingRefresh()
        #expect(await provider.state.fetchCount == 2)
        #expect(controller.row(for: .codex)?.failure == nil)
        #expect(controller.row(for: .codex)?.fetchedAt != nil)
        #expect(!controller.isRefreshing)
    }

    @Test("disabling one provider discards its late result while the other finishes")
    func disablingOneProvider() async {
        let disabled = ControlledAgentUsageProvider(id: .codex)
        let enabled = ControlledAgentUsageProvider(id: .grok)
        let controller = makeController([disabled, enabled])
        let published = AgentUsageTestEvent()
        controller.onChange = {
            if controller.row(for: .grok)?.fetchedAt != nil { published.signal() }
        }
        controller.refresh(force: true)
        #expect(await disabled.started.wait())
        #expect(await enabled.started.wait())
        controller.setEnabled(false, for: .codex)
        #expect(await disabled.cancelled.wait())
        #expect(controller.row(for: .codex)?.isRefreshing == false)
        #expect(controller.isRefreshing)

        await enabled.gate.open()
        #expect(await published.wait())
        #expect(!controller.isRefreshing)
        #expect(controller.row(for: .grok)?.failure == nil)
        #expect(controller.row(for: .codex)?.fetchedAt == nil)
        await disabled.gate.open()
        await controller.waitForPendingRefresh()
        #expect(controller.row(for: .codex)?.fetchedAt == nil)
        #expect(controller.row(for: .codex)?.failure == nil)
        controller.onChange = nil
    }

    @Test("an immediate provider disable prevents its scheduled request from starting")
    func disableBeforeFetchStarts() async {
        let provider = StubAgentUsageProvider(id: .codex, displayName: "Codex")
        let controller = makeController([provider])
        controller.refresh(force: true)
        controller.setEnabled(false, for: .codex)
        #expect(!controller.isRefreshing)
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 0)
        #expect(controller.row(for: .codex)?.fetchedAt == nil)
    }

    @Test("providers that have credentials on this Mac start enabled; the rest stay off")
    func firstRunSeeding() {
        let controller = makeController([
            StubAgentUsageProvider(id: .codex, displayName: "Codex", hasLocalCredentialsValue: true),
            StubAgentUsageProvider(id: .grok, displayName: "Grok", hasLocalCredentialsValue: false),
        ])

        #expect(controller.visibleRows.map(\.id) == [.codex])
        #expect(controller.isEnabled(.codex))
        #expect(!controller.isEnabled(.grok))
        #expect(controller.isConfigured(.codex))
        #expect(!controller.isConfigured(.grok))
        #expect(controller.showsRemaining)
    }

    @Test("turning a configured provider off keeps the credential badge")
    func configuredStaysWhenDisabled() {
        let controller = makeController([
            StubAgentUsageProvider(id: .codex, displayName: "Codex", hasLocalCredentialsValue: true),
        ])
        controller.setEnabled(false, for: .codex)
        #expect(!controller.isEnabled(.codex))
        #expect(controller.isConfigured(.codex))
    }

    @Test("a refresh fills the row, and a later failure keeps the last numbers on screen")
    func failureKeepsData() async {
        let provider = StubAgentUsageProvider(
            id: .codex,
            displayName: "Codex",
            outcomes: [
                .success(.fixture(usedPercent: 42)),
                .failure(.network("Could not reach Codex.")),
            ]
        )
        let clock = TestClock()
        let controller = makeController([provider], now: { clock.now })

        controller.refresh(force: true)
        await controller.waitForPendingRefresh()

        #expect(controller.row(for: .codex)?.failure == nil)
        #expect(controller.row(for: .codex)?.report?.primaryMetric != nil)
        #expect(controller.row(for: .codex)?.fetchedAt != nil)
        #expect(!controller.isRefreshing)

        clock.advance(120)
        controller.refresh(force: true)
        await controller.waitForPendingRefresh()

        let row = controller.row(for: .codex)
        #expect(row?.failure == .network("Could not reach Codex."))
        #expect(row?.metrics.count == 1)
        #expect(row?.fetchedAt != nil)
    }

    @Test("one failing provider leaves the other's data intact")
    func failureIsolation() async {
        let failing = StubAgentUsageProvider(
            id: .codex, displayName: "Codex", outcome: .failure(.authExpired("Run codex login.")))
        let healthy = StubAgentUsageProvider(
            id: .grok,
            displayName: "Grok",
            outcome: .success(.fixture(provider: .grok, providerName: "Grok", plan: nil, usedPercent: 10))
        )
        let controller = makeController([failing, healthy])

        controller.refresh(force: true)
        await controller.waitForPendingRefresh()

        #expect(controller.row(for: .grok)?.failure == nil)
        #expect(controller.row(for: .grok)?.metrics.count == 1)
        #expect(controller.row(for: .codex)?.failure?.message == "Run codex login.")
        #expect(!controller.isRefreshing)
    }

    @Test("reopening the scope inside the throttle window reuses the last fetch")
    func throttle() async {
        let provider = StubAgentUsageProvider(id: .codex, displayName: "Codex")
        let clock = TestClock()
        let controller = makeController([provider], now: { clock.now })

        controller.refreshIfNeeded()
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 1)

        clock.advance(10)
        controller.refreshIfNeeded()
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 1)

        clock.advance(60)
        controller.refreshIfNeeded()
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 2)
    }

    @Test("force refresh ignores the throttle")
    func forceRefresh() async {
        let provider = StubAgentUsageProvider(id: .codex, displayName: "Codex")
        let clock = TestClock()
        let controller = makeController([provider], now: { clock.now })

        controller.refreshIfNeeded()
        await controller.waitForPendingRefresh()
        controller.refresh(force: true)
        await controller.waitForPendingRefresh()

        #expect(await provider.fetchCount() == 2)
    }

    @Test("a failed provider waits out the backoff before the next attempt")
    func failureBackoff() async {
        let provider = StubAgentUsageProvider(
            id: .codex, displayName: "Codex", outcome: .failure(.network("offline")))
        let clock = TestClock()
        let controller = makeController([provider], now: { clock.now })

        controller.refreshIfNeeded()
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 1)

        clock.advance(10)
        controller.refreshIfNeeded()
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 1)

        clock.advance(60)
        controller.refreshIfNeeded()
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 2)
    }

    @Test("the refresh-on-open preference is honored")
    func refreshOnOpenPreference() async {
        let provider = StubAgentUsageProvider(id: .codex, displayName: "Codex")
        let preferences = AgentUsagePreferencesStore()
        preferences.refreshesOnOpen = false
        let controller = makeController([provider], preferences: preferences)

        controller.refreshIfNeeded()
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 0)

        controller.refresh(force: true)
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 1)
    }

    @Test("an explicit re-enable retries a failed provider immediately without duplicate enable fetches")
    func reenableBypassesBackoff() async {
        let provider = StubAgentUsageProvider(
            id: .codex, displayName: "Codex",
            outcomes: [.failure(.authExpired("Sign in")), .success(.fixture())])
        let clock = TestClock()
        let controller = makeController([provider], now: { clock.now })
        controller.refresh()
        await controller.waitForPendingRefresh()
        controller.setEnabled(false, for: .codex)
        controller.setEnabled(true, for: .codex)
        controller.setEnabled(true, for: .codex)
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 2)
        #expect(controller.row(for: .codex)?.failure == nil)
        #expect(controller.row(for: .codex)?.fetchedAt != nil)
        controller.setEnabled(true, for: .codex)
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 2)
    }

    @Test("turning a provider on fetches it; turning one off drops its row")
    func togglingProviders() async {
        let codex = StubAgentUsageProvider(id: .codex, displayName: "Codex")
        let grok = StubAgentUsageProvider(id: .grok, displayName: "Grok", hasLocalCredentialsValue: false)
        let preferences = AgentUsagePreferencesStore()
        let controller = makeController([codex, grok], preferences: preferences)
        #expect(controller.visibleRows.map(\.id) == [.codex])

        controller.setEnabled(true, for: .grok)
        await controller.waitForPendingRefresh()
        #expect(controller.visibleRows.map(\.id) == [.codex, .grok])
        #expect(await grok.fetchCount() == 1)
        #expect(preferences.explicitEnabled(.grok) == true)

        controller.setEnabled(false, for: .codex)
        #expect(controller.visibleRows.map(\.id) == [.grok])
        // A disabled provider is not fetched again — and this one was never
        // fetched at all, since only Grok was turned on.
        controller.refresh(force: true)
        await controller.waitForPendingRefresh()
        #expect(await codex.fetchCount() == 0)
    }

    @Test("providers enabled during a refresh are fetched without another user action")
    func enablingDuringRefresh() async {
        let codex = StubAgentUsageProvider(id: .codex, displayName: "Codex", hasLocalCredentialsValue: false)
        let grok = StubAgentUsageProvider(id: .grok, displayName: "Grok", hasLocalCredentialsValue: false)
        let controller = makeController([codex, grok])

        // No suspension: the second enable deterministically lands in flight.
        controller.setEnabled(true, for: .codex)
        controller.setEnabled(true, for: .grok)
        controller.setEnabled(true, for: .grok)
        await controller.waitForPendingRefresh()

        #expect(await codex.fetchCount() == 1)
        #expect(await grok.fetchCount() == 1)
        #expect(controller.row(for: .grok)?.fetchedAt != nil)
        #expect(!controller.isRefreshing)
    }

    @Test("queued refreshes respect provider disable and master-switch cancellation")
    func queuedRefreshCancellation() async {
        for disableFeature in [false, true] {
            let codex = StubAgentUsageProvider(id: .codex, displayName: "Codex")
            let grok = StubAgentUsageProvider(id: .grok, displayName: "Grok", hasLocalCredentialsValue: false)
            let controller = makeController([codex, grok])
            controller.refresh()
            controller.setEnabled(true, for: .grok)
            if disableFeature {
                controller.setFeatureEnabled(false)
            } else {
                controller.setEnabled(false, for: .grok)
            }
            await controller.waitForPendingRefresh()
            #expect(await grok.fetchCount() == 0)
            #expect(!controller.isRefreshing)
        }
    }

    @Test("a provider that never answers is cut off by the refresh deadline")
    func deadline() async {
        let provider = StubAgentUsageProvider(
            id: .codex, displayName: "Codex", delay: .seconds(8))
        let controller = makeController([provider])

        AgentUsageTiming.$current.withValue(.testing) { controller.refresh(force: true) }
        await controller.waitForPendingRefresh()

        #expect(controller.row(for: .codex)?.failure?.message.contains("Timed out") == true)
        #expect(!controller.isRefreshing)
    }

    @Test("reordering agents updates the list and widget priority")
    func providerOrder() {
        let preferences = AgentUsagePreferencesStore()
        preferences.refreshesOnOpen = false
        let providers: [any AgentUsageProvider] = [
            StubAgentUsageProvider(id: .codex, displayName: "Codex"),
            StubAgentUsageProvider(id: .grok, displayName: "Grok"),
            StubAgentUsageProvider(id: .amp, displayName: "Amp"),
        ]
        let controller = makeController(providers, preferences: preferences)

        controller.move(.amp, onto: .codex)
        #expect(controller.rows.map(\.id) == [.amp, .codex, .grok])
        #expect(AgentUsageWidgetSnapshot.make(
            rows: controller.visibleRows, showsRemaining: true, now: Date()
        ).metrics.map(\.id) == ["amp", "codex"])

        controller.setEnabled(false, for: .amp)
        #expect(controller.visibleRows.map(\.id) == [.codex, .grok])
        #expect(AgentUsageWidgetSnapshot.make(
            rows: controller.visibleRows, showsRemaining: true, now: Date()
        ).metrics.map(\.id) == ["codex", "grok"])
    }

    @Test("the master switch stops every fetch and hides the rows, keeping the agent choices")
    func masterSwitchGatesFetching() async {
        let provider = StubAgentUsageProvider(id: .codex, displayName: "Codex")
        let preferences = AgentUsagePreferencesStore()
        let controller = makeController([provider], preferences: preferences)

        controller.setFeatureEnabled(false)
        #expect(!controller.isFeatureEnabled)
        #expect(controller.visibleRows.isEmpty)

        controller.refresh(force: true)
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 0)

        controller.setFeatureEnabled(true)
        #expect(controller.visibleRows.map(\.id) == [.codex])

        controller.refresh(force: true)
        await controller.waitForPendingRefresh()
        #expect(await provider.fetchCount() == 1)
        #expect(controller.row(for: .codex)?.fetchedAt != nil)
    }

    @Test("flipping the master switch reports the change once, so the catalog rebuilds")
    func masterSwitchNotifies() {
        let controller = makeController([StubAgentUsageProvider(id: .codex, displayName: "Codex")])
        var changes: [Bool] = []
        controller.onFeatureEnabledChange = { changes.append($0) }

        controller.setFeatureEnabled(false)
        controller.setFeatureEnabled(false)
        controller.setFeatureEnabled(true)

        #expect(changes == [false, true])
    }

    @Test("a refresh already in flight is dropped when the feature is switched off")
    func masterSwitchDropsInFlightRefresh() async {
        let provider = StubAgentUsageProvider(
            id: .codex, displayName: "Codex", outcome: .success(.fixture()), delay: .milliseconds(50))
        let controller = makeController([provider])

        controller.refresh(force: true)
        controller.setFeatureEnabled(false)
        await controller.waitForPendingRefresh()

        #expect(controller.row(for: .codex)?.fetchedAt == nil)
        #expect(!controller.isRefreshing)
    }
}

@MainActor
@Suite("Agent usage provider cancellation")
struct AgentUsageProviderCancellationTests {
    @Test("cancelling usage stops the request and skips optional follow-up requests",
          arguments: AgentUsageProviderID.allCases, [false, true])
    func cancellationStopsFollowups(id: AgentUsageProviderID, disableFeature: Bool) async throws {
        let fixture = try Self.providerFixture(id: id, client: CancelledUsageHTTPClient())
        defer { fixture.file.remove() }
        let client = fixture.client
        let provider = fixture.provider
        let defaults = UserDefaults(suiteName: "com.spike.prism.tests.cancellation.\(UUID().uuidString)")!
        let controller = AgentUsageController(
            providers: [provider], preferences: AgentUsagePreferencesStore())
        controller.refresh(force: true)
        #expect(await client.started.wait())
        if disableFeature { controller.setFeatureEnabled(false) }
        else { controller.setEnabled(false, for: id) }
        #expect(await client.cancelled.wait())
        await controller.waitForPendingRefresh()
        #expect(await client.state.fetchCount == 1)
        #expect(controller.row(for: id)?.fetchedAt == nil)
        #expect(controller.row(for: id)?.failure == nil)
        #expect(fixture.file.text() == fixture.contents)
    }

    /// A real provider wired to a throwaway credential fixture plus the
    /// cancelling client, so the cancellation path under test is the provider's
    /// own. The returned file is the credential material the test checks for
    /// post-cancellation integrity.
    private static func providerFixture(
        id: AgentUsageProviderID, client: CancelledUsageHTTPClient
    ) throws -> (provider: any AgentUsageProvider, client: CancelledUsageHTTPClient,
                 file: TemporaryCredentialFile, contents: String) {
        switch id {
        case .codex:
            let contents = #"{"tokens":{"access_token":"saved-token"}}"#
            let file = try TemporaryCredentialFile(relativePath: "auth.json", contents: contents)
            return (CodexAgentUsageProvider(
                        authStore: CodexAuthStore(environment: ["CODEX_HOME": file.directory.path]),
                        client: client),
                    client, file, contents)
        case .claude:
            let contents = #"{"claudeAiOauth":{"accessToken":"saved-token"}}"#
            let file = try TemporaryCredentialFile(relativePath: ".credentials.json", contents: contents)
            return (ClaudeAgentUsageProvider(
                        authStore: ClaudeAuthStore(
                            environment: ["CLAUDE_CONFIG_DIR": file.directory.path],
                            readKeychainSecret: { _ in nil },
                            keychainItemExists: { _ in false }),
                        client: client),
                    client, file, contents)
        case .grok:
            let contents = #"{"https://auth.x.ai::test":{"key":"saved-token","refresh_token":"shared-refresh"}}"#
            let file = try TemporaryCredentialFile(relativePath: "auth.json", contents: contents)
            return (GrokAgentUsageProvider(authStore: GrokAuthStore(authFilePath: file.url), client: client),
                    client, file, contents)
        case .amp:
            let contents = #"{"apiKey@https://ampcode.com/":"saved-token"}"#
            let file = try TemporaryCredentialFile(relativePath: "secrets.json", contents: contents)
            return (AmpAgentUsageProvider(
                        authStore: AmpAuthStore(secretsFileURL: file.url, environment: [:]),
                        client: client),
                    client, file, contents)
        case .devin:
            let contents = #"windsurf_api_key = "saved-token""#
            let file = try TemporaryCredentialFile(relativePath: "credentials.toml", contents: contents)
            return (DevinAgentUsageProvider(
                        authStore: DevinAuthStore(
                            credentialsFileURL: file.url,
                            stateDatabaseURL: file.directory.appendingPathComponent("absent/state.vscdb")),
                        client: client),
                    client, file, contents)
        case .zai:
            let contents = #"{"apiKey":"saved-token"}"#
            let file = try TemporaryCredentialFile(relativePath: "key.json", contents: contents)
            return (ZAIAgentUsageProvider(
                        authStore: ZAIAuthStore(
                            environment: [:],
                            configFileURL: file.url,
                            claudeSettingsURL: file.directory.appendingPathComponent("absent/settings.json")),
                        client: client),
                    client, file, contents)
        case .antigravity:
            // Antigravity reads no credential file — a discovered `agy` process
            // routes the probe into the cancelling client; the fixture file
            // only proves the provider never writes.
            let contents = "{}"
            let file = try TemporaryCredentialFile(
                relativePath: "antigravity-placeholder.json", contents: contents)
            var provider = AntigravityAgentUsageProvider()
            provider.installPresence = { true }
            provider.usageClient.loopbackClient = client
            provider.discovery = AntigravityLanguageServerDiscovery(
                processRunner: StubAntigravityRunner(psOutput: " 42 /Users/x/.local/bin/agy\n"))
            return (provider, client, file, contents)
        }
    }
}

private struct CancelledUsageHTTPClient: AgentUsageHTTPClient {
    let started = AgentUsageTestEvent()
    let cancelled = AgentUsageTestEvent()
    let state = StubProviderState()

    func send(_ request: AgentUsageHTTPRequest) async throws -> AgentUsageHTTPResponse {
        _ = await state.next(from: [])
        return await withTaskCancellationHandler {
            started.signal()
            // Return a valid body even on cancellation to exercise the client's
            // post-transport cancellation check before optional follow-ups.
            try? await Task.sleep(for: .seconds(30))
            let body = request.url == CodexUsageClient.usageURL
                ? #"{"rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":604800}}}"#
                : #"{"config":{"creditUsagePercent":42,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-03T04:01:09Z","end":"2026-07-10T04:01:09Z"}}}"#
            return AgentUsageHTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        } onCancel: {
            cancelled.signal()
        }
    }
}
