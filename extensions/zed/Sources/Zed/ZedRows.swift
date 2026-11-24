import Foundation
import PrismExtensionKit

/// Maps recent Zed workspaces to Prism list rows, filters, empty states, and actions.
enum ZedRows {
    typealias ActionID = Zed.ActionID
    typealias FilterID = Zed.FilterID

    static var searchPlaceholder: String {
        localized("Search recent Zed projects…")
    }

    static var filters: [ExtensionListFilter] {
        [
            ExtensionListFilter(
                id: FilterID.all,
                title: localized("All Projects"),
                symbol: "chevron.left.forwardslash.chevron.right"
            ),
            ExtensionListFilter(
                id: FilterID.local,
                title: localized("Local"),
                symbol: ZedWorkspaceKind.local.symbol
            ),
            ExtensionListFilter(
                id: FilterID.remote,
                title: localized("Remote"),
                symbol: ZedWorkspaceKind.remote.symbol
            ),
        ]
    }

    static func emptyMessage(for kind: ZedWorkspaceKind?) -> ExtensionListMessage {
        switch kind {
        case nil:
            ExtensionListMessage(
                title: localized("No Recent Projects"),
                message: localized("Projects, multi-folder workspaces, and remote workspaces you open in Zed appear here."),
                symbol: "chevron.left.forwardslash.chevron.right"
            )
        case .local:
            ExtensionListMessage(
                title: localized("No Local Projects"),
                message: localized("Local projects and folders you open in Zed appear here."),
                symbol: ZedWorkspaceKind.local.symbol
            )
        case .remote:
            ExtensionListMessage(
                title: localized("No Remote Workspaces"),
                message: localized("Remote SSH and container workspaces you open in Zed appear here."),
                symbol: ZedWorkspaceKind.remote.symbol
            )
        }
    }

    static func item(
        for workspace: ZedWorkspace,
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

    private static func accessories(for workspace: ZedWorkspace) -> [ExtensionListAccessory] {
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

    private static func actions(for workspace: ZedWorkspace) -> [ExtensionAction] {
        var actions: [ExtensionAction] = []
        let copyText = workspace.paths.joined(separator: "\n")

        if workspace.remote == nil || workspace.remote?.isSSH == true {
            actions.append(ExtensionAction(
                id: ActionID.open,
                title: localized("Open in Zed"),
                symbol: "chevron.left.forwardslash.chevron.right"
            ))
            if workspace.remote == nil {
                actions.append(ExtensionAction(
                    id: ActionID.showInFinder,
                    title: localized("Show in Finder"),
                    symbol: "folder",
                    shortcut: ExtensionShortcut("cmd+shift+f")
                ))
            }
            actions.append(ExtensionAction(
                id: ActionID.copyPath,
                title: localized("Copy Path"),
                symbol: "doc.on.doc",
                kind: .copy(text: copyText),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ))
            if workspace.remote == nil, workspace.directoryPath != workspace.primaryPath {
                actions.append(ExtensionAction(
                    id: ActionID.copyDirectory,
                    title: localized("Copy Containing Folder"),
                    symbol: "folder",
                    kind: .copy(text: workspace.directoryPath),
                    shortcut: ExtensionShortcut("cmd+shift+d")
                ))
            }
        } else {
            // Non-SSH remotes (e.g. Docker, WSL) don't have a direct deep link.
            actions.append(ExtensionAction(
                id: ActionID.copyPath,
                title: localized("Copy Path"),
                symbol: "doc.on.doc",
                kind: .copy(text: copyText)
            ))
        }

        return actions
    }

    private static func keywords(for workspace: ZedWorkspace, homeDirectory: String) -> [String] {
        var terms: [String] = []
        for path in workspace.paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let parentName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            let compact = workspace.remote == nil
                ? ZedWorkspace.abbreviatingHome(path, homeDirectory: homeDirectory)
                : path
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
            terms.append("local")
            if workspace.isMultiFolder {
                terms.append(contentsOf: ["workspace", "multi-folder"])
            } else if !workspace.isDirectory {
                terms.append("file")
            }
        }

        var seen: Set<String> = []
        return terms.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
