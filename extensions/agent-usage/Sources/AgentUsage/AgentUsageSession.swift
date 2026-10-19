import CryptoKit
import Foundation
import PrismExtensionKit

/// The extension's state for the life of its process: one controller, set up
/// from Prism's preferences and the saved cache on the first request.
@MainActor
final class AgentUsageSession {
    /// What survives the process: the rows on screen, the throttle, and which
    /// Z.ai key the Z.ai row was fetched with.
    struct Saved: Codable, Equatable {
        var controller: AgentUsageController.Saved
        var zaiKeyFingerprint: String?
    }

    static let cacheFileName = "cache.json"

    static let widgetTemplates: [String: ExtensionWidgetTemplate] = [
        "numbers": .quotaNumbers, "rings": .quotaRings, "bars": .quotaBars,
        "singleNumber": .quotaNumber, "singleRing": .quotaRing,
    ]

    private let makeController: @MainActor (any ZAISecretStore) -> AgentUsageController
    private let zaiKey = ZAIKeyMirror()
    private(set) var controller: AgentUsageController?
    private var applied: AgentUsagePreferencesStore.Snapshot?
    private var zaiKeyFingerprint: String?
    private var cacheURL: URL?
    private var context: PrismContext?

    nonisolated init(
        makeController: @escaping @MainActor (any ZAISecretStore) -> AgentUsageController = {
            AgentUsageController(zaiSecrets: $0)
        }
    ) {
        self.makeController = makeController
    }

    // MARK: - Requests

    func list(_ context: PrismContext) -> ExtensionList {
        let controller = prepare(context)
        // Opening (and reloading) the list fetches, within the throttle.
        if !controller.isRefreshing { controller.refreshIfNeeded() }
        return AgentUsagePresentation.list(rows: controller.visibleRows, showsRemaining: controller.showsRemaining)
    }

    func refresh(_ context: PrismContext) {
        prepare(context).refresh(force: true)
    }

    func widget(_ widget: String, context: PrismContext) throws -> ExtensionWidgetContent {
        guard let template = Self.widgetTemplates[widget] else {
            throw PrismExtensionError("Agent Usage has no widget “\(widget)”.")
        }
        let controller = prepare(context)
        controller.refreshIfNeeded()
        return .quota(template, AgentUsagePresentation.quotaCard(
            rows: controller.visibleRows, showsRemaining: controller.showsRemaining, now: Date(),
            openCommandID: AgentUsage.CommandID.usage
        ))
    }

    func preferenceItems(_ context: PrismContext) -> [ExtensionPreferenceItem] {
        let controller = prepare(context)
        controller.refreshCredentialHints()
        return controller.rows.map { row in
            ExtensionPreferenceItem(
                id: row.id.rawValue,
                title: row.displayName,
                icon: row.icon.extensionIcon,
                badge: controller.isConfigured(row.id) ? "Configured" : nil,
                isOn: controller.isDetected(row.id)
            )
        }
    }

    /// Test seam: waits for the refresh in flight, if any.
    func waitForPendingRefresh() async {
        await controller?.waitForPendingRefresh()
    }

    // MARK: - Setup

    /// The controller, created on the first request and kept in step with the
    /// preferences each request carries.
    @discardableResult
    private func prepare(_ context: PrismContext) -> AgentUsageController {
        self.context = context
        let key = context.preferences.string(AgentUsage.PreferenceID.zaiKey).trimmedCredentialValue.nilIfEmpty
        let fingerprint = key.map(Self.fingerprint)
        let snapshot = Self.snapshot(context.preferences)
        if let controller {
            if fingerprint != zaiKeyFingerprint {
                zaiKey.update(.key(key))
                zaiKeyFingerprint = fingerprint
                controller.zaiKeyDidChange()
            }
            if snapshot != applied {
                applied = snapshot
                controller.applyPreferences(snapshot)
            }
            return controller
        }

        zaiKey.update(.key(key))
        let controller = makeController(zaiKey)
        self.controller = controller
        // Nothing is fetched or published until everything below is in place.
        controller.setFeatureEnabled(false)
        cacheURL = context.dataDirectory?.appendingPathComponent(Self.cacheFileName)
        if let saved = loadCache() {
            controller.restore(saved.controller)
            zaiKeyFingerprint = saved.zaiKeyFingerprint
        }
        // A key saved before this process started counts like one on disk; a
        // different key from the cached Z.ai row's drops that row.
        if fingerprint != zaiKeyFingerprint {
            zaiKeyFingerprint = fingerprint
            controller.zaiKeyDidChange()
        }
        applied = snapshot
        controller.applyPreferences(snapshot)
        controller.onChange = { [weak self] in self?.controllerChanged() }
        controller.setFeatureEnabled(true)
        return controller
    }

    private func controllerChanged() {
        saveCache()
        guard let context else { return }
        Task { await context.listChanged(AgentUsage.CommandID.usage) }
    }

    /// The user's agent order and switches, as the controller reads them.
    static func snapshot(_ preferences: Preferences) -> AgentUsagePreferencesStore.Snapshot {
        var snapshot = AgentUsagePreferencesStore.Snapshot()
        let arrangement = preferences.orderedList(AgentUsage.PreferenceID.agents)
        snapshot.enabledProviders = Dictionary(
            arrangement.entries.map { ($0.id, $0.isOn) }, uniquingKeysWith: { first, _ in first }
        )
        snapshot.providerOrder = arrangement.entries.map(\.id)
        snapshot.showsRemaining = preferences.bool(AgentUsage.PreferenceID.showsRemaining, default: true)
        return snapshot
    }

    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache

    private func loadCache() -> Saved? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    private func saveCache() {
        guard let cacheURL, let controller else { return }
        let saved = Saved(controller: controller.saved(), zaiKeyFingerprint: zaiKeyFingerprint)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
