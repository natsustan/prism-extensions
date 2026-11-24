import Foundation
import PrismExtensionKit

/// Lists recently used Zed projects, multi-folder workspaces, and remote
/// workspaces, and opens them directly in Zed.
@main
struct Zed: PrismExtension {
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
        static let showInFinder = "show-in-finder"
        static let copyPath = "copy-path"
        static let copyDirectory = "copy-directory"
    }

    enum PreferenceID {
        static let zedApp = "zedApp"
    }

    enum StateKey {
        static let recentOpens = "recentOpens"
    }

    /// Caps stored open timestamps so extension state stays small.
    static let maxRecordedOpens = 50

    let store: ZedWorkspaceStore
    let launcher: any ZedLaunching
    let now: @Sendable () -> Date

    init() {
        self.init(store: ZedWorkspaceStore(), launcher: WorkspaceZedLauncher())
    }

    init(
        store: ZedWorkspaceStore,
        launcher: any ZedLaunching,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.launcher = launcher
        self.now = now
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.recentProjects else {
            throw PrismExtensionError(localized("Zed has no list “\(command)”."))
        }
        try Task.checkCancellation()

        let preferredZed = context.preferences.string(PreferenceID.zedApp)
        let channel = ZedChannel.infer(fromAppPath: preferredZed)
        let recordedOpens = await Self.recordedOpens(from: context)
        let allWorkspaces = store.loadWorkspaces(channel: channel, recordedOpens: recordedOpens)
        try Task.checkCancellation()

        let selectedKind = Self.kind(for: filter)
        let shown = selectedKind.map { kind in
            allWorkspaces.filter { $0.kind == kind }
        } ?? allWorkspaces

        return ExtensionList(
            items: shown.map {
                ZedRows.item(for: $0, homeDirectory: store.homeDirectory)
            },
            filtering: .prism,
            searchPlaceholder: ZedRows.searchPlaceholder,
            filters: ZedRows.filters,
            emptyMessage: ZedRows.emptyMessage(for: selectedKind),
            fetchedAt: now()
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard command == CommandID.recentProjects else {
            throw PrismExtensionError(localized("Zed has no list “\(command)”."))
        }

        switch action {
        case ActionID.open:
            return try await openWorkspace(item: item, context: context)
        case ActionID.showInFinder:
            return await revealWorkspace(item: item, context: context)
        default:
            throw PrismExtensionError(localized("Zed has no action “\(action)”."))
        }
    }

    // MARK: - Actions

    private func openWorkspace(item: String, context: PrismContext) async throws -> ExtensionActionResult {
        let preferredZed = context.preferences.string(PreferenceID.zedApp)
        let channel = ZedChannel.infer(fromAppPath: preferredZed)
        let recordedOpens = await Self.recordedOpens(from: context)
        let workspaces = store.loadWorkspaces(
            channel: channel,
            recordedOpens: recordedOpens,
            includeGitBranch: false
        )

        guard let workspace = workspaces.first(where: { $0.id == item }) else {
            if !item.hasPrefix("remote:") {
                let firstPath = item.split(whereSeparator: \.isNewline).first.map(String.init) ?? item
                let name = URL(fileURLWithPath: firstPath).lastPathComponent
                return .reload(message: localized("“\(name)” no longer exists on disk."))
            }
            return .reload(message: localized("This workspace is no longer in Zed’s recent list."))
        }

        do {
            if let remote = workspace.remote {
                guard let url = workspace.sshURL(scheme: channel.urlScheme) else {
                    return ExtensionActionResult(.failed(
                        message: localized("Opening \(remote.badge) remote workspaces directly isn’t supported yet. Open it from Zed’s Remote Projects dialog.")
                    ))
                }
                try await launcher.openRemoteWorkspace(url: url, zedAppPath: preferredZed)
            } else {
                try await launcher.openLocalWorkspace(paths: workspace.paths, zedAppPath: preferredZed)
            }
        } catch let ZedLaunchError.projectNotFound(missingPath) {
            let name = missingPath.isEmpty ? workspace.title : URL(fileURLWithPath: missingPath).lastPathComponent
            return .reload(message: localized("“\(name)” no longer exists on disk."))
        } catch let ZedLaunchError.zedNotFound(customPath) {
            if let customPath, !customPath.isEmpty {
                return ExtensionActionResult(.failed(message: localized("Zed couldn’t be found at “\(customPath)”.")))
            }
            return ExtensionActionResult(.failed(message: localized("Zed isn’t installed on this Mac.")))
        } catch let ZedLaunchError.openFailed(reason) {
            return ExtensionActionResult(.failed(message: localized("Couldn’t open “\(workspace.title)” in Zed: \(reason)")))
        }

        await recordOpen(id: workspace.id, at: now(), context: context)
        return .done
    }

    private func revealWorkspace(item: String, context: PrismContext) async -> ExtensionActionResult {
        let preferredZed = context.preferences.string(PreferenceID.zedApp)
        let channel = ZedChannel.infer(fromAppPath: preferredZed)
        let workspaces = store.loadWorkspaces(channel: channel, includeGitBranch: false)
        let path = workspaces.first(where: { $0.id == item })?.primaryPath
            ?? item.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? item
        let name = URL(fileURLWithPath: path).lastPathComponent
        do {
            try await launcher.revealInFinder(path: path)
            return .done
        } catch ZedLaunchError.projectNotFound {
            return .reload(message: localized("“\(name)” no longer exists on disk."))
        } catch {
            return ExtensionActionResult(.failed(message: localized("Finder couldn’t show “\(name)”.")))
        }
    }

    // MARK: - Helpers

    static func kind(for filter: String?) -> ZedWorkspaceKind? {
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
