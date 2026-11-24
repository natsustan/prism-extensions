import Foundation
import PrismExtensionKit

/// Maps Antigravity projects and remote SSH hosts to Prism list rows, filters,
/// empty states, and actions.
enum AntigravityRows {
    typealias ActionID = Antigravity.ActionID
    typealias FilterID = Antigravity.FilterID

    static var searchPlaceholder: String {
        localized("Search Antigravity projects…")
    }

    static var filters: [ExtensionListFilter] {
        [
            ExtensionListFilter(
                id: FilterID.all,
                title: localized("All Projects"),
                symbol: "sparkles"
            ),
            ExtensionListFilter(
                id: FilterID.local,
                title: localized("Local"),
                symbol: AntigravityWorkspaceKind.local.symbol
            ),
            ExtensionListFilter(
                id: FilterID.remote,
                title: localized("Remote"),
                symbol: AntigravityWorkspaceKind.remote.symbol
            ),
        ]
    }

    static func emptyMessage(for kind: AntigravityWorkspaceKind?) -> ExtensionListMessage {
        switch kind {
        case nil:
            ExtensionListMessage(
                title: localized("No Recent Projects"),
                message: localized("Projects and remote SSH hosts you use in Antigravity appear here."),
                symbol: "sparkles"
            )
        case .local:
            ExtensionListMessage(
                title: localized("No Local Projects"),
                message: localized("Projects you add in Antigravity appear here."),
                symbol: AntigravityWorkspaceKind.local.symbol
            )
        case .remote:
            ExtensionListMessage(
                title: localized("No Remote SSH Hosts"),
                message: localized("Remote SSH hosts you connect to in Antigravity appear here."),
                symbol: AntigravityWorkspaceKind.remote.symbol
            )
        }
    }

    static func item(
        for workspace: AntigravityWorkspace,
        homeDirectory: String
    ) -> ExtensionListItem {
        ExtensionListItem(
            id: workspace.id,
            title: workspace.title,
            subtitle: workspace.subtitle(homeDirectory: homeDirectory),
            icon: ExtensionIcon(
                symbol: workspace.iconSymbol,
                tint: workspace.iconTint,
                style: .glyph
            ),
            accessories: accessories(for: workspace),
            keywords: keywords(for: workspace, homeDirectory: homeDirectory),
            actions: actions(for: workspace)
        )
    }

    private static func accessories(for workspace: AntigravityWorkspace) -> [ExtensionListAccessory] {
        var result: [ExtensionListAccessory] = []
        if let badge = workspace.badge {
            result.append(ExtensionListAccessory(
                text: badge,
                tint: workspace.iconTint,
                style: .tag
            ))
        }
        if let branch = workspace.gitBranch {
            result.append(ExtensionListAccessory(
                text: branch,
                symbol: "arrow.triangle.branch",
                tint: "gray",
                help: localized("Git branch \(branch)"),
                style: .tag
            ))
        }
        return result
    }

    private static func actions(for workspace: AntigravityWorkspace) -> [ExtensionAction] {
        var actions: [ExtensionAction] = [
            ExtensionAction(
                id: ActionID.open,
                title: localized("Open in Antigravity"),
                symbol: "sparkles"
            ),
        ]

        if let remote = workspace.remote {
            actions.append(ExtensionAction(
                id: ActionID.copyPath,
                title: localized("Copy SSH Host"),
                symbol: "doc.on.doc",
                kind: .copy(text: remote.host),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ))
            return actions
        }

        if let agyCommand = workspace.agyCommand {
            actions.append(ExtensionAction(
                id: ActionID.copyAGYCommand,
                title: localized("Copy agy CLI Command"),
                symbol: "terminal",
                kind: .copy(text: agyCommand),
                shortcut: ExtensionShortcut("cmd+shift+t")
            ))
        }

        if workspace.primaryPath != nil {
            actions.append(ExtensionAction(
                id: ActionID.showInFinder,
                title: localized("Show in Finder"),
                symbol: "folder",
                shortcut: ExtensionShortcut("cmd+shift+f")
            ))
            actions.append(ExtensionAction(
                id: ActionID.copyPath,
                title: localized("Copy Path"),
                symbol: "doc.on.doc",
                kind: .copy(text: workspace.paths.joined(separator: "\n")),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ))
        }

        return actions
    }

    private static func keywords(for workspace: AntigravityWorkspace, homeDirectory: String) -> [String] {
        var terms: [String] = [workspace.name]
        terms.append(contentsOf: PinyinKeywords.keywords(for: workspace.name))

        for path in workspace.paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let parentName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            let compact = AntigravityWorkspace.abbreviatingHome(path, homeDirectory: homeDirectory)
            terms.append(contentsOf: [name, parentName, compact])
            terms.append(contentsOf: PinyinKeywords.keywords(for: name))
            if parentName != name {
                terms.append(contentsOf: PinyinKeywords.keywords(for: parentName))
            }
        }

        if let branch = workspace.gitBranch {
            terms.append(branch)
        }
        if let remote = workspace.remote {
            terms.append(contentsOf: remote.searchKeywords)
        } else {
            terms.append(contentsOf: ["local", "project"])
            if workspace.isMultiFolder {
                terms.append(contentsOf: ["workspace", "multi-folder"])
            }
        }

        var seen: Set<String> = []
        return terms.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
