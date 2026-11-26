import AppKit
import Foundation
import PrismExtensionKit

/// Launches macOS Screen Sharing for a `vnc://` URL.
protocol ScreenSharingLaunching: Sendable {
    func open(_ url: URL) async throws
}

struct WorkspaceScreenSharingLauncher: ScreenSharingLaunching {
    func open(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Lists Macs discovered on the local network via Bonjour alongside pinned,
/// recent, and user-configured hosts, and connects via macOS Screen Sharing.
@main
struct ScreenSharing: PrismExtension {
    enum CommandID {
        static let connections = "connections"
    }

    enum FilterID {
        static let all = "all"
        static let pinned = "pinned"
        static let local = "local"
        static let recent = "recent"
    }

    enum ActionID {
        static let connect = "connect"
        static let togglePin = "toggle-pin"
        static let copyURL = "copy-url"
        static let copyAddress = "copy-address"
        static let removeRecent = "remove-recent"
        static let refresh = "refresh"
    }

    enum PreferenceID {
        static let savedHosts = "savedHosts"
    }

    let session: DiscoverySession
    let launcher: any ScreenSharingLaunching
    let now: @Sendable () -> Date

    init() {
        self.init(
            session: DiscoverySession(),
            launcher: WorkspaceScreenSharingLauncher()
        )
    }

    init(
        session: DiscoverySession,
        launcher: any ScreenSharingLaunching,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.launcher = launcher
        self.now = now
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.connections else {
            throw PrismExtensionError(localized("Screen Sharing has no list “\(command)”."))
        }
        try Task.checkCancellation()

        let snapshot = await session.snapshot(context: context)
        try Task.checkCancellation()

        let merged = await loadCatalog(snapshot: snapshot, context: context)
        try Task.checkCancellation()
        let results = HostCatalog.query(hosts: merged, query: query, filter: filter)

        let buckets = Set(results.map(HostCatalog.bucket(for:)))
        let showSections = buckets.count > 1 || results.contains(where: \.isQuickConnect)

        return ExtensionList(
            items: results.map { ScreenSharingRows.item(for: $0, showSections: showSections) },
            filtering: .extension,
            searchPlaceholder: ScreenSharingRows.searchPlaceholder,
            filters: ScreenSharingRows.filters,
            emptyMessage: ScreenSharingRows.emptyMessage(query: query, filter: filter),
            fetchedAt: snapshot.refreshedAt ?? now()
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard command == CommandID.connections else {
            throw PrismExtensionError(localized("Screen Sharing has no list “\(command)”."))
        }

        switch action {
        case ActionID.connect:
            return try await connect(item: item, context: context)
        case ActionID.togglePin:
            return try await togglePin(item: item, context: context)
        case ActionID.removeRecent:
            await HostStateStore.removeRecent(id: item, context: context)
            return .reload(message: localized("Removed from recent connections."))
        case ActionID.refresh:
            await session.forceRefresh(context: context)
            return .reload(message: localized("Refreshed local network."))
        default:
            throw PrismExtensionError(localized("Screen Sharing has no action “\(action)”."))
        }
    }

    // MARK: - Actions

    private func connect(item: String, context: PrismContext) async throws -> ExtensionActionResult {
        let target = await resolveTarget(item: item, context: context)
        guard let target, let url = target.address.vncURL else {
            throw PrismExtensionError(localized("Couldn’t build a valid Screen Sharing address."))
        }

        do {
            try await launcher.open(url)
        } catch {
            return ExtensionActionResult(.failed(
                message: localized("Couldn’t open Screen Sharing for “\(target.name)”: \(error.localizedDescription)")
            ))
        }

        await HostStateStore.recordConnection(
            name: target.name,
            address: target.address,
            model: target.model,
            at: now(),
            context: context
        )
        return .done
    }

    private func togglePin(item: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard let target = await resolveTarget(item: item, context: context) else {
            throw PrismExtensionError(localized("This host can’t be pinned."))
        }

        let pinned = await HostStateStore.togglePin(
            name: target.name,
            address: target.address,
            model: target.model,
            context: context
        )
        return .reload(message: pinned
            ? localized("Pinned “\(target.name)”.")
            : localized("Unpinned “\(target.name)”."))
    }

    private func loadCatalog(
        snapshot: DiscoverySession.Snapshot,
        context: PrismContext
    ) async -> [ResolvedHost] {
        let saved = HostAddressParser.parseSavedHosts(context.preferences.string(PreferenceID.savedHosts))
        let stored = await HostStateStore.load(from: context)
        return HostCatalog.merge(
            onlineLocal: snapshot.online,
            cachedLocal: snapshot.cached,
            saved: saved,
            stored: stored
        )
    }

    private func resolveTarget(
        item: String,
        context: PrismContext
    ) async -> (name: String, address: HostAddress, model: String?)? {
        let snapshot = await session.cachedSnapshot(context: context)
        let merged = await loadCatalog(snapshot: snapshot, context: context)

        if let existing = merged.first(where: { $0.id == item }) {
            return (existing.name, existing.address, existing.model)
        }
        if let address = HostCatalog.fallbackAddress(forItemID: item) {
            if let existing = merged.first(where: { $0.id == address.stableID }) {
                return (existing.name, existing.address, existing.model)
            }
            return (address.displayAddress, address, nil)
        }
        return nil
    }
}
