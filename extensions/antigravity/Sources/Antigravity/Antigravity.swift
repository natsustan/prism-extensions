import Foundation
import PrismExtensionKit

/// Lists Antigravity projects and recently connected remote SSH hosts, opens
/// Antigravity or connects directly to an SSH host, and offers quick `agy` CLI,
/// Finder, and path actions.
@main
struct Antigravity: PrismExtension {
    enum CommandID {
        static let recentProjects = "recent-projects"
    }

    enum FilterID {
        static let all = "all"
        static let local = "local"
        static let remote = "remote"
    }

    enum ActionID {
        static let open = "open"
        static let copyAGYCommand = "copy-agy-command"
        static let showInFinder = "show-in-finder"
        static let copyPath = "copy-path"
    }

    enum PreferenceID {
        static let antigravityApp = "antigravityApp"
    }

    enum StateKey {
        static let recentOpens = "recentOpens"
    }

    /// Caps stored open timestamps so extension state stays small.
    static let maxRecordedOpens = 50

    let store: AntigravityWorkspaceStore
    let launcher: any AntigravityLaunching
    let now: @Sendable () -> Date

    init() {
        self.init(store: AntigravityWorkspaceStore(), launcher: WorkspaceAntigravityLauncher())
    }

    init(
        store: AntigravityWorkspaceStore,
        launcher: any AntigravityLaunching,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.launcher = launcher
        self.now = now
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.recentProjects else {
            throw PrismExtensionError(localized("Antigravity has no list “\(command)”."))
        }
        try Task.checkCancellation()

        let preferredApp = context.preferences.string(PreferenceID.antigravityApp)
        let channel = AntigravityChannel.infer(fromAppPath: preferredApp)
        let recordedOpens = await Self.recordedOpens(from: context)
        let allWorkspaces = store.loadWorkspaces(channel: channel, recordedOpens: recordedOpens)
        try Task.checkCancellation()

        let selectedKind = Self.kind(for: filter)
        let shown = selectedKind.map { kind in
            allWorkspaces.filter { $0.kind == kind }
        } ?? allWorkspaces

        return ExtensionList(
            items: shown.map {
                AntigravityRows.item(for: $0, homeDirectory: store.homeDirectory)
            },
            filtering: .prism,
            searchPlaceholder: AntigravityRows.searchPlaceholder,
            filters: AntigravityRows.filters,
            emptyMessage: AntigravityRows.emptyMessage(for: selectedKind),
            fetchedAt: now()
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard command == CommandID.recentProjects else {
            throw PrismExtensionError(localized("Antigravity has no list “\(command)”."))
        }

        switch action {
        case ActionID.open:
            return try await openWorkspace(item: item, context: context)
        case ActionID.showInFinder:
            return await revealWorkspace(item: item, context: context)
        default:
            throw PrismExtensionError(localized("Antigravity has no action “\(action)”."))
        }
    }

    // MARK: - Actions

    private func openWorkspace(item: String, context: PrismContext) async throws -> ExtensionActionResult {
        let preferredApp = context.preferences.string(PreferenceID.antigravityApp)
        let channel = AntigravityChannel.infer(fromAppPath: preferredApp)
        let recordedOpens = await Self.recordedOpens(from: context)
        let workspaces = store.loadWorkspaces(
            channel: channel,
            recordedOpens: recordedOpens,
            includeGitBranch: false
        )

        guard let workspace = workspaces.first(where: { $0.id == item }) else {
            if item.hasPrefix("remote:") {
                return .reload(message: localized("This remote host is no longer in Antigravity’s recent list."))
            }
            return .reload(message: localized("This project is no longer in Antigravity."))
        }

        do {
            if let remote = workspace.remote {
                try await launcher.openRemoteSSHHost(remote.host, antigravityAppPath: preferredApp)
            } else {
                try await launcher.openLocalApp(antigravityAppPath: preferredApp)
            }
        } catch let AntigravityLaunchError.projectNotFound(missingPath) {
            let name = missingPath.isEmpty ? workspace.title : URL(fileURLWithPath: missingPath).lastPathComponent
            return .reload(message: localized("“\(name)” no longer exists on disk."))
        } catch let AntigravityLaunchError.appNotFound(customPath) {
            if let customPath, !customPath.isEmpty {
                return ExtensionActionResult(.failed(message: localized("Antigravity couldn’t be found at “\(customPath)”.")))
            }
            return ExtensionActionResult(.failed(message: localized("Antigravity isn’t installed on this Mac.")))
        } catch let AntigravityLaunchError.openFailed(reason) {
            return ExtensionActionResult(.failed(message: localized("Couldn’t open “\(workspace.title)” in Antigravity: \(reason)")))
        }

        await recordOpen(id: workspace.id, at: now(), context: context)
        return .done
    }

    private func revealWorkspace(item: String, context: PrismContext) async -> ExtensionActionResult {
        let preferredApp = context.preferences.string(PreferenceID.antigravityApp)
        let channel = AntigravityChannel.infer(fromAppPath: preferredApp)
        let workspaces = store.loadWorkspaces(channel: channel, includeGitBranch: false)
        guard let path = workspaces.first(where: { $0.id == item })?.primaryPath else {
            return .reload(message: localized("This project is no longer in Antigravity."))
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        do {
            try await launcher.revealInFinder(path: path)
            return .done
        } catch AntigravityLaunchError.projectNotFound {
            return .reload(message: localized("“\(name)” no longer exists on disk."))
        } catch {
            return ExtensionActionResult(.failed(message: localized("Finder couldn’t show “\(name)”.")))
        }
    }

    // MARK: - Helpers

    static func kind(for filter: String?) -> AntigravityWorkspaceKind? {
        switch filter {
        case FilterID.local: .local
        case FilterID.remote: .remote
        default: nil
        }
    }

    private static func recordedOpens(from context: PrismContext) async -> [String: Date] {
        guard let raw = await context.state(StateKey.recentOpens)?.stringValue,
              let data = raw.data(using: .utf8),
              let timestamps = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return timestamps.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func recordOpen(id: String, at date: Date, context: PrismContext) async {
        var opens = await Self.recordedOpens(from: context)
        opens[id] = date
        let trimmed = opens
            .sorted { $0.value > $1.value }
            .prefix(Self.maxRecordedOpens)
        let timestamps = Dictionary(uniqueKeysWithValues: trimmed.map {
            ($0.key, $0.value.timeIntervalSince1970)
        })
        guard let data = try? JSONEncoder().encode(timestamps),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        await context.setState(.string(encoded), for: StateKey.recentOpens)
    }
}
