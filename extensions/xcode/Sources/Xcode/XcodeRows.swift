import Foundation
import PrismExtensionKit

/// Maps recent Xcode projects to Prism list rows, filters, empty states, and actions.
enum XcodeRows {
    typealias ActionID = Xcode.ActionID
    typealias FilterID = Xcode.FilterID

    static var searchPlaceholder: String {
        localized("Search recent Xcode projects…")
    }

    static var filters: [ExtensionListFilter] {
        [
            ExtensionListFilter(id: FilterID.all, title: localized("All Projects"), symbol: "hammer"),
            ExtensionListFilter(id: FilterID.project, title: localized("Projects"), symbol: XcodeProjectKind.project.symbol),
            ExtensionListFilter(id: FilterID.workspace, title: localized("Workspaces"), symbol: XcodeProjectKind.workspace.symbol),
            ExtensionListFilter(id: FilterID.package, title: localized("Swift Packages"), symbol: XcodeProjectKind.package.symbol),
            ExtensionListFilter(id: FilterID.playground, title: localized("Playgrounds"), symbol: XcodeProjectKind.playground.symbol),
        ]
    }

    static func emptyMessage(for kind: XcodeProjectKind?) -> ExtensionListMessage {
        switch kind {
        case nil:
            ExtensionListMessage(
                title: localized("No Recent Projects"),
                message: localized("Projects, workspaces, Swift packages, and playgrounds you open in Xcode appear here."),
                symbol: "hammer"
            )
        case .project:
            ExtensionListMessage(
                title: localized("No Recent Xcode Projects"),
                message: localized("Xcode projects you open appear here."),
                symbol: XcodeProjectKind.project.symbol
            )
        case .workspace:
            ExtensionListMessage(
                title: localized("No Recent Workspaces"),
                message: localized("Workspaces you open in Xcode appear here."),
                symbol: XcodeProjectKind.workspace.symbol
            )
        case .package:
            ExtensionListMessage(
                title: localized("No Recent Swift Packages"),
                message: localized("Swift packages you open in Xcode appear here."),
                symbol: XcodeProjectKind.package.symbol
            )
        case .playground:
            ExtensionListMessage(
                title: localized("No Recent Playgrounds"),
                message: localized("Playgrounds you open in Xcode appear here."),
                symbol: XcodeProjectKind.playground.symbol
            )
        }
    }

    static func item(
        for project: XcodeProject,
        homeDirectory: String,
        dates: ProjectDates
    ) -> ExtensionListItem {
        let location = project.compactLocation(homeDirectory: homeDirectory)
        return ExtensionListItem(
            id: project.path,
            title: project.name,
            subtitle: location,
            icon: ExtensionIcon(symbol: project.kind.symbol, tint: project.kind.tint),
            accessories: accessories(for: project, dates: dates),
            keywords: keywords(for: project, homeDirectory: homeDirectory),
            actions: actions(for: project)
        )
    }

    private static func accessories(for project: XcodeProject, dates: ProjectDates) -> [ExtensionListAccessory] {
        var result = [
            ExtensionListAccessory(
                text: project.kind.badge,
                tint: project.kind.tint,
                style: .tag
            )
        ]
        if let lastOpened = project.lastOpened {
            let label = dates.label(for: lastOpened)
            result.append(ExtensionListAccessory(
                text: label,
                help: localized("Last opened \(label)")
            ))
        }
        return result
    }

    private static func actions(for project: XcodeProject) -> [ExtensionAction] {
        var actions = [
            ExtensionAction(
                id: ActionID.open,
                title: localized("Open in Xcode"),
                symbol: "hammer"
            ),
            ExtensionAction(
                id: ActionID.showInFinder,
                title: localized("Show in Finder"),
                symbol: "folder",
                shortcut: ExtensionShortcut("cmd+shift+f")
            ),
            ExtensionAction(
                id: ActionID.copyPath,
                title: localized("Copy Path"),
                symbol: "doc.on.doc",
                kind: .copy(text: project.path),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ),
        ]
        if project.directoryPath != project.path {
            actions.append(ExtensionAction(
                id: ActionID.copyDirectory,
                title: localized("Copy Project Directory"),
                symbol: "folder",
                kind: .copy(text: project.directoryPath),
                shortcut: ExtensionShortcut("cmd+shift+d")
            ))
        }
        return actions
    }

    private static func keywords(for project: XcodeProject, homeDirectory: String) -> [String] {
        let filename = URL(fileURLWithPath: project.path).lastPathComponent
        let parentName = URL(fileURLWithPath: project.directoryPath).lastPathComponent
        let compactFullPath = XcodeProject.abbreviatingHome(project.path, homeDirectory: homeDirectory)

        var terms = [filename, parentName, compactFullPath]
        terms.append(contentsOf: project.kind.searchKeywords)
        terms.append(contentsOf: PinyinKeywords.keywords(for: project.name))
        if parentName != project.name {
            terms.append(contentsOf: PinyinKeywords.keywords(for: parentName))
        }

        var seen: Set<String> = []
        return terms.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
