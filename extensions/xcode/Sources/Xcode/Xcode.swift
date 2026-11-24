import Foundation
import PrismExtensionKit

/// Lists recently used Xcode projects, workspaces, Swift packages, and
/// playgrounds, and opens them directly in Xcode.
@main
struct Xcode: PrismExtension {
    enum CommandID {
        static let recentProjects = "recent-projects"
    }

    enum FilterID {
        static let all = "all"
        static let project = "project"
        static let workspace = "workspace"
        static let package = "package"
        static let playground = "playground"
    }

    enum ActionID {
        static let open = "open"
        static let showInFinder = "show-in-finder"
        static let copyPath = "copy-path"
        static let copyDirectory = "copy-directory"
    }

    enum PreferenceID {
        static let xcodeApp = "xcodeApp"
    }

    enum StateKey {
        static let recentOpens = "recentOpens"
    }

    /// Caps stored open timestamps so extension state stays small.
    static let maxRecordedOpens = 50

    let store: XcodeProjectStore
    let launcher: any XcodeLaunching
    let now: @Sendable () -> Date
    let calendar: Calendar

    init() {
        self.init(store: XcodeProjectStore(), launcher: WorkspaceXcodeLauncher())
    }

    init(
        store: XcodeProjectStore,
        launcher: any XcodeLaunching,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
        self.launcher = launcher
        self.now = now
        self.calendar = calendar
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.recentProjects else {
            throw PrismExtensionError(localized("Xcode has no list “\(command)”."))
        }
        try Task.checkCancellation()

        let recordedOpens = await Self.recordedOpens(from: context)
        let allProjects = store.loadProjects(recordedOpens: recordedOpens)
        try Task.checkCancellation()

        let selectedKind = Self.kind(for: filter)
        let shown = selectedKind.map { kind in
            allProjects.filter { $0.kind == kind }
        } ?? allProjects

        let loadedAt = now()
        let dates = ProjectDates(
            now: loadedAt,
            calendar: calendar,
            locale: ProjectDates.locale(prismLanguage: PrismLocalization.language)
        )
        return ExtensionList(
            items: shown.map {
                XcodeRows.item(for: $0, homeDirectory: store.homeDirectory, dates: dates)
            },
            filtering: .prism,
            searchPlaceholder: XcodeRows.searchPlaceholder,
            filters: XcodeRows.filters,
            emptyMessage: XcodeRows.emptyMessage(for: selectedKind),
            fetchedAt: loadedAt
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard command == CommandID.recentProjects else {
            throw PrismExtensionError(localized("Xcode has no list “\(command)”."))
        }

        switch action {
        case ActionID.open:
            return try await openProject(item: item, context: context)
        case ActionID.showInFinder:
            return await revealProject(item: item)
        default:
            throw PrismExtensionError(localized("Xcode has no action “\(action)”."))
        }
    }

    // MARK: - Actions

    private func openProject(item: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard let classified = XcodeProjectClassifier.classify(
            rawPath: item,
            fileExists: store.fileExists,
            isDirectory: store.isDirectory
        ) else {
            let name = URL(fileURLWithPath: item).lastPathComponent
            return .reload(message: localized("“\(name)” no longer exists on disk."))
        }

        let preferredXcode = context.preferences.string(PreferenceID.xcodeApp)
        do {
            try await launcher.openProject(at: classified.openPath, xcodeAppPath: preferredXcode)
        } catch XcodeLaunchError.projectNotFound {
            return .reload(message: localized("“\(classified.name)” no longer exists on disk."))
        } catch let XcodeLaunchError.xcodeNotFound(customPath) {
            if let customPath, !customPath.isEmpty {
                return ExtensionActionResult(.failed(message: localized("Xcode couldn’t be found at “\(customPath)”.")))
            }
            return ExtensionActionResult(.failed(message: localized("Xcode isn’t installed on this Mac.")))
        } catch let XcodeLaunchError.openFailed(reason) {
            return ExtensionActionResult(.failed(message: localized("Couldn’t open “\(classified.name)” in Xcode: \(reason)")))
        }

        await recordOpen(path: classified.canonicalPath, at: now(), context: context)
        return .done
    }

    private func revealProject(item: String) async -> ExtensionActionResult {
        let name = URL(fileURLWithPath: item).lastPathComponent
        do {
            try await launcher.revealInFinder(path: item)
            return .done
        } catch XcodeLaunchError.projectNotFound {
            return .reload(message: localized("“\(name)” no longer exists on disk."))
        } catch {
            return ExtensionActionResult(.failed(message: localized("Finder couldn’t show “\(name)”.")))
        }
    }

    // MARK: - Helpers

    static func kind(for filter: String?) -> XcodeProjectKind? {
        switch filter {
        case FilterID.project: .project
        case FilterID.workspace: .workspace
        case FilterID.package: .package
        case FilterID.playground: .playground
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

    private func recordOpen(path: String, at date: Date, context: PrismContext) async {
        var opens = await Self.recordedOpens(from: context)
        opens[path] = date
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
