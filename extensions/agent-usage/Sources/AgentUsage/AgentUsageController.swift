import Foundation
import Observation

/// Owns the provider list and the refresh cycle behind the Agent Usage list,
/// its widgets, and its Agents preference. Refreshes are on demand (opening
/// the list, a widget coming on screen, Refresh, or turning an agent on) and
/// throttled, never polled: nothing here should spend the user's battery or
/// quota while Prism is not showing it.
@MainActor
@Observable
final class AgentUsageController {
    /// Reopening the scope inside this window reuses the last fetch.
    nonisolated static let refreshThrottle: TimeInterval = 60
    /// A provider that just failed waits this long before another attempt.
    nonisolated static let failureBackoff: TimeInterval = 60

    private(set) var rows: [AgentUsageRow] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?

    /// Fires whenever row state changes; the browser mirrors it into its list.
    var onChange: (() -> Void)?
    /// Fires when the master switch flips, so the app can rebuild the command
    /// catalog that decides whether the scope is reachable at all.
    var onFeatureEnabledChange: ((Bool) -> Void)?

    private let providers: [any AgentUsageProvider]
    private let preferences: AgentUsagePreferencesStore
    private let zaiSecrets: any ZAISecretStore
    private let now: @Sendable () -> Date
    /// Providers that had credentials on this Mac at launch: the default for a
    /// switch the user has never touched. Z.ai is updated when its settings key
    /// changes, so pasting a key turns that untouched switch on without a relaunch.
    private var detectedProviders: Set<AgentUsageProviderID>
    /// Providers Prism can read right now. The settings list shows these as
    /// Configured. A switch the user turned off stays off; the badge does not
    /// follow it, and a failed request does not clear it.
    private(set) var configuredProviderIDs: Set<AgentUsageProviderID>
    private var lastAttempt: [AgentUsageProviderID: Date] = [:]
    private var lastFailure: [AgentUsageProviderID: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private var providerTasks: [AgentUsageProviderID: Task<Result<AgentUsageReport, AgentUsageFailure>, Never>] = [:]
    private var generation = 0
    private var pending = 0
    private var queuedRefreshes: [AgentUsageProviderID: Bool] = [:]

    /// Production wiring: the providers that ship today — the established three
    /// first, then the rest alphabetically by display name. Z.ai reads the same
    /// secret store the settings field writes.
    static func defaultProviders(zaiSecrets: any ZAISecretStore) -> [any AgentUsageProvider] {
        var zai = ZAIAgentUsageProvider()
        zai.authStore.storedKey = { try zaiSecrets.apiKey() }
        return [
            CodexAgentUsageProvider(),
            ClaudeAgentUsageProvider(),
            GrokAgentUsageProvider(),
            AmpAgentUsageProvider(),
            AntigravityAgentUsageProvider(),
            DevinAgentUsageProvider(),
            zai,
        ]
    }

    init(
        providers: [any AgentUsageProvider]? = nil,
        preferences: AgentUsagePreferencesStore = AgentUsagePreferencesStore(),
        zaiSecrets: any ZAISecretStore = ZAIKeyMirror(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let providers = providers ?? Self.defaultProviders(zaiSecrets: zaiSecrets)
        self.providers = providers
        self.preferences = preferences
        self.zaiSecrets = zaiSecrets
        self.now = now
        let found = Set(providers.filter { $0.hasLocalCredentials() }.map(\.id))
        detectedProviders = found
        configuredProviderIDs = found
        rows = preferences.orderedProviderIDs(providers.map(\.id)).compactMap { id in
            providers.first { $0.id == id }
        }.map { provider in
            AgentUsageRow(
                id: provider.id,
                displayName: provider.displayName,
                icon: provider.icon
            )
        }
    }

    /// Takes the user's choices from the extension's preferences: stops
    /// agents that were switched off, fetches ones switched on, and reorders.
    func applyPreferences(_ snapshot: AgentUsagePreferencesStore.Snapshot) {
        let before = Set(rows.map(\.id).filter(isEnabled))
        preferences.replace(snapshot)
        rows = preferences.orderedProviderIDs(rows.map(\.id)).compactMap { id in rows.first { $0.id == id } }
        let after = Set(rows.map(\.id).filter(isEnabled))
        for id in before.subtracting(after) { stopProvider(id) }
        onChange?()
        let added = after.subtracting(before)
        if isFeatureEnabled, !added.isEmpty { refresh(force: true, only: added) }
    }

    // MARK: - Saving

    /// The rows and throttle as they stand, for a later process to pick up.
    struct Saved: Codable, Equatable {
        var rows: [AgentUsageRow]
        var lastAttempt: [AgentUsageProviderID: Date]
        var lastFailure: [AgentUsageProviderID: Date]
    }

    /// A fetch still in flight is not saved as attempted: a new process
    /// should try again rather than wait out the throttle with nothing.
    func saved() -> Saved {
        let refreshing = Set(rows.filter(\.isRefreshing).map(\.id))
        return Saved(
            rows: rows.map { row in
                var row = row
                row.isRefreshing = false
                return row
            },
            lastAttempt: lastAttempt.filter { !refreshing.contains($0.key) },
            lastFailure: lastFailure
        )
    }

    /// Takes back what an earlier process saved. Names and icons come from
    /// this build's providers; agents it no longer knows are dropped.
    func restore(_ saved: Saved) {
        for savedRow in saved.rows {
            guard let index = rows.firstIndex(where: { $0.id == savedRow.id }) else { continue }
            rows[index].plan = savedRow.plan
            rows[index].accountLabel = savedRow.accountLabel
            rows[index].metrics = savedRow.metrics
            rows[index].failure = savedRow.failure
            rows[index].fetchedAt = savedRow.fetchedAt
        }
        let known = Set(rows.map(\.id))
        lastAttempt = saved.lastAttempt.filter { known.contains($0.key) }
        lastFailure = saved.lastFailure.filter { known.contains($0.key) }
    }

    /// Whether credentials were found for this agent: the switch's default.
    func isDetected(_ id: AgentUsageProviderID) -> Bool {
        detectedProviders.contains(id)
    }

    // MARK: - Reads

    var visibleRows: [AgentUsageRow] {
        guard isFeatureEnabled else { return [] }
        return rows.filter { isEnabled($0.id) }
    }

    /// Master switch: while it is off nothing is fetched, listed, or drawn.
    var isFeatureEnabled: Bool { preferences.isEnabled }

    func setFeatureEnabled(_ isEnabled: Bool) {
        guard preferences.isEnabled != isEnabled else { return }
        preferences.isEnabled = isEnabled
        if !isEnabled {
            // Drop any in-flight cycle: its results belong to a feature the user
            // just turned off.
            refreshTask?.cancel()
            for task in providerTasks.values { task.cancel() }
            providerTasks.removeAll()
            generation &+= 1
            for row in rows where row.isRefreshing {
                lastAttempt[row.id] = nil
            }
            pending = 0
            queuedRefreshes.removeAll()
            isRefreshing = false
            for index in rows.indices {
                rows[index].isRefreshing = false
            }
        }
        onFeatureEnabledChange?(isEnabled)
        onChange?()
    }

    var showsRemaining: Bool { preferences.showsRemaining }

    func setShowsRemaining(_ showsRemaining: Bool) {
        preferences.showsRemaining = showsRemaining
        onChange?()
    }

    /// Keep failed edits in memory across settings pane navigation so they can be retried.
    private(set) var failedZAIAPIKeyDraft: String?
    private(set) var zaiAPIKeySaveError: String?
    private(set) var zaiAPIKeyReadError: String?

    /// The Z.ai key typed into Agent Usage settings. Empty when the user has
    /// not saved one; file and environment keys are not echoed here. A read
    /// failure returns nil so Settings never mistakes it for an empty key.
    func readZAIAPIKey() -> String? {
        do {
            let key = try zaiSecrets.apiKey() ?? ""
            zaiAPIKeyReadError = nil
            return key
        } catch {
            zaiAPIKeyReadError = "Could not read the Z.ai API key from the Keychain. Unlock it and reopen this setting."
            return nil
        }
    }

    /// Saves the Z.ai key into the Keychain. When the user has never touched
    /// Z.ai's switch, a non-empty key turns it on and clearing the last key
    /// turns it off, matching launch-time credential detection. An explicit
    /// on or off choice is left alone. An enabled Z.ai row refreshes immediately.
    @discardableResult
    func setZAIAPIKey(_ value: String) -> Bool {
        let trimmed = value.trimmedCredentialValue
        guard let currentKey = readZAIAPIKey() else {
            failedZAIAPIKeyDraft = value
            return false
        }
        if trimmed == currentKey {
            failedZAIAPIKeyDraft = nil
            zaiAPIKeySaveError = nil
            return true
        }
        do {
            try zaiSecrets.setAPIKey(trimmed)
        } catch {
            failedZAIAPIKeyDraft = value
            zaiAPIKeySaveError = "Could not save the Z.ai API key in the Keychain. Your edit has been kept; try again."
            return false
        }
        failedZAIAPIKeyDraft = nil
        zaiAPIKeySaveError = nil
        zaiKeyDidChange()
        return true
    }

    /// The saved Z.ai key changed (Settings saved a new one or cleared it).
    /// When the user has never touched Z.ai's switch, a key turns it on and
    /// clearing the last key turns it off; an explicit choice is left alone.
    /// An enabled Z.ai row refreshes immediately.
    func zaiKeyDidChange() {
        // The previous report belongs to the old credential. Drop its request
        // and data before another fetch can publish or retain that account.
        stopProvider(.zai)
        if let index = rows.firstIndex(where: { $0.id == .zai }) {
            let row = rows[index]
            rows[index] = AgentUsageRow(id: row.id, displayName: row.displayName, icon: row.icon)
        }
        lastAttempt[.zai] = nil
        lastFailure[.zai] = nil
        if preferences.explicitEnabled(.zai) == nil {
            let available = providers.first { $0.id == .zai }?.hasLocalCredentials() == true
            if available { detectedProviders.insert(.zai) }
            else { detectedProviders.remove(.zai) }
        }
        let enabled = isEnabled(.zai)
        refreshCredentialHints()
        onChange?()
        if enabled && isFeatureEnabled {
            refresh(force: true, only: [.zai])
        }
    }

    /// A login or key is already on this Mac. File and environment sources
    /// count, including a Z.ai key saved from Settings.
    func isConfigured(_ id: AgentUsageProviderID) -> Bool {
        configuredProviderIDs.contains(id)
    }

    /// Re-reads local credential files. Settings calls this when the pane
    /// opens, so a CLI login finished while Prism was running shows up without
    /// changing any switch.
    func refreshCredentialHints() {
        let found = Set(providers.filter { $0.hasLocalCredentials() }.map(\.id))
        guard found != configuredProviderIDs else { return }
        configuredProviderIDs = found
    }

    func isEnabled(_ id: AgentUsageProviderID) -> Bool {
        preferences.explicitEnabled(id) ?? detectedProviders.contains(id)
    }

    func row(for id: AgentUsageProviderID) -> AgentUsageRow? {
        rows.first { $0.id == id }
    }

    /// Reorder every provider, including disabled ones, so enabling one later
    /// does not change the user's chosen priority.
    func move(_ id: AgentUsageProviderID, onto target: AgentUsageProviderID) {
        guard id != target,
              let source = rows.firstIndex(where: { $0.id == id }),
              let destination = rows.firstIndex(where: { $0.id == target }) else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: destination)
        preferences.setProviderOrder(rows.map(\.id))
        onChange?()
    }

    // MARK: - Writes

    func setEnabled(_ isEnabled: Bool, for id: AgentUsageProviderID) {
        let wasEnabled = self.isEnabled(id)
        preferences.setEnabled(isEnabled, for: id)
        if !isEnabled && wasEnabled {
            stopProvider(id)
        }
        onChange?()
        if isEnabled && !wasEnabled {
            // A provider the user just turned on should not stay blank.
            refresh(force: true, only: [id])
        }
    }

    /// Drops an in-flight fetch for one provider without recording an explicit
    /// off choice. Used when a switch turns off and when Z.ai loses its last key.
    private func stopProvider(_ id: AgentUsageProviderID) {
        providerTasks.removeValue(forKey: id)?.cancel()
        queuedRefreshes[id] = nil
        if let index = rows.firstIndex(where: { $0.id == id }), rows[index].isRefreshing {
            rows[index].isRefreshing = false
            lastAttempt[id] = nil
            pending = max(pending - 1, 0)
            isRefreshing = pending > 0
        }
    }

    /// Called when the scope opens: honours the "refresh on open" preference and
    /// the per-provider throttle.
    func refreshIfNeeded() {
        guard preferences.refreshesOnOpen else { return }
        refresh(force: false)
    }

    func refresh(force: Bool = false, only: Set<AgentUsageProviderID>? = nil) {
        guard isFeatureEnabled else { return }
        if isRefreshing {
            for provider in providers where isEnabled(provider.id) {
                guard only?.contains(provider.id) ?? true else { continue }
                queuedRefreshes[provider.id] = (queuedRefreshes[provider.id] ?? false) || force
            }
            return
        }
        let currentTime = now()
        let targets = providers.filter { provider in
            guard isEnabled(provider.id) else { return false }
            if let only, !only.contains(provider.id) { return false }
            guard !force else { return true }
            if let last = lastAttempt[provider.id],
               currentTime.timeIntervalSince(last) < Self.refreshThrottle {
                return false
            }
            if let failed = lastFailure[provider.id],
               currentTime.timeIntervalSince(failed) < Self.failureBackoff {
                return false
            }
            return true
        }
        guard !targets.isEmpty else { return }

        generation &+= 1
        let generation = self.generation
        pending = targets.count
        isRefreshing = true
        for target in targets {
            lastAttempt[target.id] = currentTime
            if let index = rows.firstIndex(where: { $0.id == target.id }) {
                rows[index].isRefreshing = true
            }
        }
        onChange?()
        AgentUsageLog.logger.info(
            "Refreshing agent usage for \(targets.count, privacy: .public) provider(s)")

        let previousRefresh = refreshTask
        // Keep cancellation handles before yielding so even an immediate toggle
        // can cancel just this provider. Re-enables wait for the old cycle to drain.
        let tasks = targets.map { provider in
            let task = Task {
                await previousRefresh?.value
                guard !Task.isCancelled else { return Result<AgentUsageReport, AgentUsageFailure>.failure(.network("Cancelled.")) }
                return await Self.fetchWithDeadline(provider)
            }
            providerTasks[provider.id] = task
            return (provider.id, task)
        }
        refreshTask = Task { [weak self] in
            // A quick re-enable waits for the cancelled cycle to finish before
            // issuing another request with the same credentials.
            await previousRefresh?.value
            guard let self, !Task.isCancelled else { return }
            await withTaskGroup(
                of: (AgentUsageProviderID, Result<AgentUsageReport, AgentUsageFailure>).self
            ) { group in
                for (id, task) in tasks {
                    group.addTask { @Sendable in
                        (id, await task.value)
                    }
                }
                for await (id, result) in group {
                    guard !Task.isCancelled else { continue }
                    guard let task = tasks.first(where: { $0.0 == id })?.1, !task.isCancelled else { continue }
                    self.apply(result, for: id, generation: generation)
                }
            }
            guard generation == self.generation else { return }
            let queued = self.queuedRefreshes
            self.queuedRefreshes.removeAll()
            // Forced requests keep their semantics; ordinary requests still
            // honor each provider's throttle and current enable preference.
            let forced = Set(queued.filter { $0.value }.map(\.key))
            let ordinary = Set(queued.filter { !$0.value }.map(\.key))
            if !forced.isEmpty { self.refresh(force: true, only: forced) }
            if !ordinary.isEmpty { self.refresh(only: ordinary) }
        }
    }

    /// Test seam: waits for the in-flight refresh cycle to finish.
    func waitForPendingRefresh() async {
        repeat {
            let generation = self.generation
            await refreshTask?.value
            if generation == self.generation { break }
        } while true
    }

    private func apply(
        _ result: Result<AgentUsageReport, AgentUsageFailure>,
        for id: AgentUsageProviderID,
        generation: Int
    ) {
        guard generation == self.generation else { return }
        providerTasks[id] = nil
        pending = max(pending - 1, 0)
        defer {
            if pending == 0 { isRefreshing = false }
            onChange?()
        }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].isRefreshing = false
        switch result {
        case let .success(report):
            rows[index].plan = report.plan
            rows[index].accountLabel = report.accountLabel
            rows[index].metrics = report.metrics
            rows[index].fetchedAt = report.fetchedAt
            rows[index].failure = nil
            lastFailure[id] = nil
            lastRefreshAt = now()
            AgentUsageLog.logger.info("Agent usage refreshed for \(id.rawValue, privacy: .public)")
        case let .failure(failure):
            // Keep whatever the last successful fetch produced: a failed
            // refresh must not blank a quota the user is mid-glance at.
            rows[index].failure = failure
            lastFailure[id] = now()
            AgentUsageLog.logger.error(
                "Agent usage refresh failed for \(id.rawValue, privacy: .public): \(failure.message, privacy: .public)")
        }
    }

    /// Races the provider's fetch against the deadline; whichever lands first is
    /// the result, and the loser is cancelled.
    private nonisolated static func fetchWithDeadline(
        _ provider: any AgentUsageProvider
    ) async -> Result<AgentUsageReport, AgentUsageFailure> {
        // A hard per-provider ceiling, so one hung request cannot hold the list open.
        let timing = AgentUsageTiming.current
        return await withTaskGroup(of: Result<AgentUsageReport, AgentUsageFailure>.self) { group in
            group.addTask { await provider.fetchUsage() }
            group.addTask {
                try? await Task.sleep(for: timing.refreshDeadline)
                return .failure(.network("Timed out after \(timing.refreshDeadlineSeconds) seconds."))
            }
            let first = await group.next() ?? .failure(.network("Timed out."))
            group.cancelAll()
            return first
        }
    }
}
