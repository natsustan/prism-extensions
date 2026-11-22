import Darwin
import Foundation
import PrismExtensionKit

/// Maps process entries to full-width list rows and actions.
enum ProcessRows {
    typealias ActionID = KillProcess.ActionID
    typealias FilterID = KillProcess.FilterID

    /// Per-`list.load` cache of localized constant labels and format styles so
    /// building ~1,000 rows resolves `Locale` and `String(localized:)` once.
    struct RowContext {
        let cpuFormat: FloatingPointFormatStyle<Double>.Percent
        let memoryFormat: ByteCountFormatStyle
        let cpuHelp: String
        let memoryHelp: String
        let killTitle: String
        let forceKillTitle: String
        let restartTitle: String
        let forceRestartTitle: String
        let showInFinderTitle: String
        let copyMenuTitle: String
        let copyPIDTitle: String
        let copyPathTitle: String
        let copyKillCommandTitle: String
        let copyForceKillCommandTitle: String
        let toggleAppGroupingTitle: String
        let toggleAppGroupingSymbol: String

        init(groupApps: Bool, locale: Locale = PrismLocalization.locale) {
            self.cpuFormat = FloatingPointFormatStyle<Double>.Percent.percent
                .precision(.fractionLength(1))
                .grouping(.never)
                .locale(locale)
            self.memoryFormat = ByteCountFormatStyle.byteCount(style: .memory).locale(locale)
            self.cpuHelp = localized("CPU Usage")
            self.memoryHelp = localized("Memory Usage")
            self.killTitle = localized("Kill")
            self.forceKillTitle = localized("Force Kill")
            self.restartTitle = localized("Restart")
            self.forceRestartTitle = localized("Force Restart")
            self.showInFinderTitle = localized("Show in Finder")
            self.copyMenuTitle = localized("Copy")
            self.copyPIDTitle = localized("Copy PID")
            self.copyPathTitle = localized("Copy Path")
            self.copyKillCommandTitle = localized("Copy Kill Command")
            self.copyForceKillCommandTitle = localized("Copy Force Kill Command")
            self.toggleAppGroupingTitle = groupApps
                ? localized("Ungroup App Processes")
                : localized("Group App Processes")
            self.toggleAppGroupingSymbol = groupApps ? "list.bullet" : "square.stack.3d.up"
        }

        func formatCPU(_ cpu: Double) -> String {
            (cpu / 100).formatted(cpuFormat)
        }

        func formatMemory(_ bytes: UInt64) -> String {
            Int64(clamping: bytes).formatted(memoryFormat)
        }
    }

    static var filters: [ExtensionListFilter] {
        [
            ExtensionListFilter(id: FilterID.cpu, title: localized("CPU Usage"), symbol: "cpu"),
            ExtensionListFilter(id: FilterID.memory, title: localized("Memory Usage"), symbol: "memorychip"),
        ]
    }

    static var emptyMessage: ExtensionListMessage {
        ExtensionListMessage(
            title: localized("No Running Processes"),
            message: localized("No running processes were found."),
            symbol: "cpu"
        )
    }

    static func item(
        for entry: ProcessEntry,
        sameNameOwnCounts: [String: Int],
        rowContext: RowContext,
        currentUserID: uid_t,
        fileExists: (String) -> Bool,
        bundleIdentifier: (String) -> String?
    ) -> ExtensionListItem {
        ExtensionListItem(
            id: entry.id,
            title: entry.displayTitle,
            subtitle: subtitle(for: entry),
            icon: icon(for: entry, bundleIdentifier: bundleIdentifier),
            accessories: accessories(for: entry, rowContext: rowContext),
            keywords: keywords(for: entry),
            actions: actions(
                for: entry,
                sameNameOwnCounts: sameNameOwnCounts,
                rowContext: rowContext,
                currentUserID: currentUserID,
                fileExists: fileExists
            )
        )
    }

    // MARK: - Actions

    static func actions(
        for entry: ProcessEntry,
        sameNameOwnCounts: [String: Int],
        rowContext: RowContext,
        currentUserID: uid_t,
        fileExists: (String) -> Bool
    ) -> [ExtensionAction] {
        var actions: [ExtensionAction] = []
        let main = entry.main

        if main.userID == currentUserID, main.pid > 1 {
            let targetLabel = entry.isAggregated
                ? localized("“\(entry.displayTitle)” (\(String(entry.members.count)) processes)")
                : localized("“\(entry.displayTitle)” (PID \(String(main.pid)))")

            actions.append(ExtensionAction(
                id: ActionID.kill,
                title: rowContext.killTitle,
                symbol: "xmark.circle",
                style: .destructive,
                confirmationMessage: localized("\(targetLabel) will quit.")
            ))
            actions.append(ExtensionAction(
                id: ActionID.forceKill,
                title: rowContext.forceKillTitle,
                symbol: "xmark.octagon",
                style: .destructive,
                shortcut: ExtensionShortcut("cmd+shift+delete"),
                confirmationMessage: localized("\(targetLabel) quits at once, without a chance to clean up.")
            ))

            if let launchPath = entry.restartLaunchPath, fileExists(launchPath) {
                actions.append(ExtensionAction(
                    id: ActionID.restart,
                    title: rowContext.restartTitle,
                    symbol: "arrow.clockwise",
                    style: .destructive,
                    shortcut: ExtensionShortcut("cmd+option+r"),
                    confirmationMessage: localized("\(targetLabel) quits and reopens.")
                ))
                actions.append(ExtensionAction(
                    id: ActionID.forceRestart,
                    title: rowContext.forceRestartTitle,
                    symbol: "arrow.clockwise.circle",
                    style: .destructive,
                    shortcut: ExtensionShortcut("cmd+option+shift+r"),
                    confirmationMessage: localized("\(targetLabel) quits at once and reopens.")
                ))
            }

            let sameNameCount = sameNameOwnCounts[main.name] ?? 0
            let inGroupSameNameCount = entry.members.filter {
                $0.userID == currentUserID && $0.name == main.name
            }.count
            if sameNameCount >= 2, !entry.isAggregated || sameNameCount > inGroupSameNameCount {
                actions.append(ExtensionAction(
                    id: ActionID.killAll,
                    title: localized("Kill All “\(main.name)” (\(String(sameNameCount)))"),
                    symbol: "xmark.circle.fill",
                    style: .destructive,
                    shortcut: ExtensionShortcut("cmd+option+delete"),
                    confirmationMessage: localized("All \(String(sameNameCount)) “\(main.name)” processes you own will quit.")
                ))
                actions.append(ExtensionAction(
                    id: ActionID.forceKillAll,
                    title: localized("Force Kill All “\(main.name)” (\(String(sameNameCount)))"),
                    symbol: "xmark.octagon.fill",
                    style: .destructive,
                    shortcut: ExtensionShortcut("cmd+option+shift+delete"),
                    confirmationMessage: localized("All \(String(sameNameCount)) “\(main.name)” processes you own quit at once, without a chance to clean up.")
                ))
            }
        }

        if entry.revealPath != nil {
            actions.append(ExtensionAction(
                id: ActionID.showInFinder,
                title: rowContext.showInFinderTitle,
                symbol: "folder",
                shortcut: ExtensionShortcut("cmd+shift+f")
            ))
        }

        var copies: [ExtensionAction] = []
        if let path = main.path {
            copies.append(ExtensionAction(
                id: ActionID.copyPath,
                title: rowContext.copyPathTitle,
                symbol: "folder",
                kind: .copy(text: path),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ))
        }
        copies.append(ExtensionAction(
            id: ActionID.copyPID,
            title: rowContext.copyPIDTitle,
            symbol: "number",
            kind: .copy(text: "\(main.pid)"),
            shortcut: main.path == nil ? ExtensionShortcut("cmd+shift+c") : nil
        ))
        if main.userID != currentUserID, main.pid > 1 {
            copies.append(ExtensionAction(
                id: ActionID.copyKillCommand,
                title: rowContext.copyKillCommandTitle,
                symbol: "xmark.circle",
                kind: .copy(text: "sudo kill \(main.pid)"),
                shortcut: ExtensionShortcut("cmd+shift+d")
            ))
            copies.append(ExtensionAction(
                id: ActionID.copyForceKillCommand,
                title: rowContext.copyForceKillCommandTitle,
                symbol: "xmark.octagon",
                kind: .copy(text: "sudo kill -9 \(main.pid)")
            ))
        }
        actions += group(ActionID.copyMenu, title: rowContext.copyMenuTitle, symbol: "doc.on.doc", copies)

        actions.append(ExtensionAction(
            id: ActionID.toggleAppGrouping,
            title: rowContext.toggleAppGroupingTitle,
            symbol: rowContext.toggleAppGroupingSymbol,
            shortcut: ExtensionShortcut("cmd+shift+g")
        ))

        return actions
    }

    private static func group(
        _ id: String,
        title: String,
        symbol: String,
        _ actions: [ExtensionAction]
    ) -> [ExtensionAction] {
        guard actions.count > 1 else { return actions }
        return [ExtensionAction(id: id, title: title, symbol: symbol, actions: actions)]
    }

    // MARK: - Pieces

    static func icon(for entry: ProcessEntry, bundleIdentifier: (String) -> String?) -> ExtensionIcon {
        if let appPath = entry.iconAppBundlePath, let identifier = bundleIdentifier(appPath) {
            return ExtensionIcon(symbol: "app", tint: "gray", app: identifier)
        }
        if entry.main.kind == .prefPane {
            return ExtensionIcon(symbol: "gearshape", tint: "gray")
        }
        return ExtensionIcon(symbol: "terminal", tint: "gray")
    }

    private static func subtitle(for entry: ProcessEntry) -> String? {
        if entry.isAggregated {
            return localized("\(String(entry.members.count)) processes")
        }
        if let appName = entry.appName, !appName.isEmpty,
           !entry.displayTitle.localizedCaseInsensitiveContains(appName) {
            return appName
        }
        return nil
    }

    private static func accessories(for entry: ProcessEntry, rowContext: RowContext) -> [ExtensionListAccessory] {
        [
            ExtensionListAccessory(
                text: rowContext.formatCPU(entry.cpu),
                symbol: "cpu",
                help: rowContext.cpuHelp
            ),
            ExtensionListAccessory(
                text: rowContext.formatMemory(entry.memoryBytes),
                symbol: "memorychip",
                help: rowContext.memoryHelp
            ),
        ]
    }

    private static func keywords(for entry: ProcessEntry) -> [String] {
        var values: [String] = ["\(entry.main.pid)", entry.main.name]
        if let appName = entry.appName { values.append(appName) }
        if let path = entry.main.path { values.append(path) }
        if entry.isAggregated {
            var seenNames: Set<String> = [entry.main.name]
            for member in entry.members where seenNames.insert(member.name).inserted {
                values.append(member.name)
            }
            for member in entry.members.prefix(20) where member.pid != entry.main.pid {
                values.append("\(member.pid)")
            }
        }
        return values
    }
}
