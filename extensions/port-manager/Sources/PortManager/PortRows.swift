import Darwin
import Foundation
import PrismExtensionKit

/// Maps open ports to list rows, details, and actions.
enum PortRows {
    typealias ActionID = PortManager.ActionID
    typealias FilterID = PortManager.FilterID

    static let filters = [
        ExtensionListFilter(id: FilterID.all, title: "All Ports", symbol: "network"),
        ExtensionListFilter(id: FilterID.localhost, title: "Localhost Only", symbol: "lock"),
        ExtensionListFilter(id: FilterID.network, title: "Reachable from Network", symbol: "globe"),
        ExtensionListFilter(id: FilterID.interface, title: "Specific Interface", symbol: "point.3.connected.trianglepath.dotted"),
    ]

    static func emptyMessage(for exposure: Exposure?) -> ExtensionListMessage {
        switch exposure {
        case nil:
            ExtensionListMessage(title: "No Open Ports", message: "Nothing is listening on a TCP port.", symbol: "network.slash")
        case .localhost:
            ExtensionListMessage(title: "No Localhost Ports", message: "No port is open only to this Mac.", symbol: "lock")
        case .network:
            ExtensionListMessage(title: "No Ports Reachable from Network", message: "No port is open on every network interface.", symbol: "globe")
        case .interface:
            ExtensionListMessage(title: "No Ports on a Specific Interface", message: "No port is bound to one interface’s address.", symbol: "point.3.connected.trianglepath.dotted")
        }
    }

    static func item(
        for port: OpenPort, name: String?, currentUserID: uid_t, bundleIdentifier: (String) -> String?
    ) -> ExtensionListItem {
        let process = port.process
        let icon = icon(for: process, bundleIdentifier: bundleIdentifier)
        var accessories: [ExtensionListAccessory] = []
        if let process, process.userID != currentUserID {
            let owner = process.userName ?? "user \(process.userID)"
            accessories.append(ExtensionListAccessory(
                text: owner, symbol: "person", help: "Owned by \(owner), so only an administrator can kill it"
            ))
        }
        accessories.append(accessory(for: port))

        return ExtensionListItem(
            id: port.id,
            title: "\(port.port)",
            subtitle: [name, port.processName].compactMap { $0 }.joined(separator: " · "),
            icon: icon,
            accessories: accessories,
            keywords: keywords(for: port, name: name),
            detail: detail(for: port, name: name, icon: icon),
            actions: actions(for: port, currentUserID: currentUserID)
        )
    }

    // MARK: - Actions

    static func actions(for port: OpenPort, currentUserID: uid_t) -> [ExtensionAction] {
        var actions: [ExtensionAction] = []
        let process = port.process
        if let process, process.userID == currentUserID {
            let name = "“\(process.name)” (PID \(process.pid))"
            actions.append(ExtensionAction(
                id: ActionID.kill, title: "Kill Process", symbol: "xmark.circle", style: .destructive,
                confirmationMessage: "\(name) stops listening on port \(port.port) and quits."
            ))
            actions.append(ExtensionAction(
                id: ActionID.forceKill, title: "Force Kill Process", symbol: "xmark.octagon", style: .destructive,
                shortcut: ExtensionShortcut("cmd+shift+delete"),
                confirmationMessage: "\(name) quits at once, without a chance to clean up."
            ))
            if let parent = port.parent, parent.userID == currentUserID {
                actions.append(ExtensionAction(
                    id: ActionID.killParent, title: "Kill Parent Process", symbol: "arrow.up.circle", style: .destructive,
                    confirmationMessage: "“\(parent.name)” (PID \(parent.pid)), which started “\(process.name)”, quits."
                ))
            }
        }
        if let url = port.url {
            actions.append(ExtensionAction(
                id: ActionID.openInBrowser, title: "Open in Browser", symbol: "safari",
                kind: .open(url: url), shortcut: ExtensionShortcut("cmd+o")
            ))
        }
        if process?.path != nil {
            actions.append(ExtensionAction(
                id: ActionID.showInFinder, title: "Show in Finder", symbol: "folder",
                shortcut: ExtensionShortcut("cmd+shift+f")
            ))
        }
        actions.append(ExtensionAction(
            id: ActionID.copyPID, title: "Copy PID", symbol: "doc.on.doc",
            kind: .copy(text: "\(port.pid)"), shortcut: ExtensionShortcut("cmd+shift+c")
        ))
        if let commandLine = process?.commandLine {
            actions.append(ExtensionAction(
                id: ActionID.copyCommandLine, title: "Copy Command Line", symbol: "terminal",
                kind: .copy(text: commandLine), shortcut: ExtensionShortcut("cmd+shift+l")
            ))
        }
        return actions
    }

    // MARK: - Pieces

    private static func icon(for process: RunningProcess?, bundleIdentifier: (String) -> String?) -> ExtensionIcon {
        if let app = process?.appPath, let identifier = bundleIdentifier(app) {
            return ExtensionIcon(symbol: "app", tint: "gray", app: identifier)
        }
        return ExtensionIcon(symbol: "terminal", tint: "gray")
    }

    private static func accessory(for port: OpenPort) -> ExtensionListAccessory {
        switch port.exposure {
        case .localhost:
            ExtensionListAccessory(text: "Localhost", symbol: "lock.fill", tint: "green", help: "Reachable only from this Mac")
        case .network:
            ExtensionListAccessory(text: "Network", symbol: "globe", tint: "orange", help: "Reachable from other devices on your network")
        case .interface:
            ExtensionListAccessory(
                text: port.hosts.first { Exposure(host: $0) == .interface },
                symbol: "point.3.connected.trianglepath.dotted", tint: "blue",
                help: "Reachable only through this address"
            )
        }
    }

    /// Typing a process, an address, a PID, a path, or an argument finds the row.
    private static func keywords(for port: OpenPort, name: String?) -> [String] {
        let process = port.process
        return [port.processName, name, "\(port.pid)", process?.userName, process?.path, process?.commandLine]
            .compactMap { $0 } + port.hosts.map { OpenPort.address(host: $0, port: port.port) }
    }

    private static func detail(for port: OpenPort, name: String?, icon: ExtensionIcon) -> ExtensionDetail {
        let process = port.process
        var processRows = [
            ExtensionMetadataRow(label: "Name", value: port.processName),
            ExtensionMetadataRow(label: "PID", value: "\(port.pid)"),
        ]
        if let process {
            processRows.append(ExtensionMetadataRow(label: "User", value: process.userName ?? "\(process.userID)"))
        }
        if let parent = port.parent {
            processRows.append(ExtensionMetadataRow(label: "Parent", value: "\(parent.name) (PID \(parent.pid))"))
        }
        if let path = process?.path {
            processRows.append(ExtensionMetadataRow(label: "Path", value: path))
        }
        return ExtensionDetail(
            title: name.map { "Port \(port.port) · \($0)" } ?? "Port \(port.port)",
            subtitle: port.processName,
            icon: icon,
            markdown: process?.commandLine.map(codeBlock),
            sections: [
                ExtensionDetailSection(title: "Listening On", rows: port.hosts.map {
                    ExtensionMetadataRow(label: OpenPort.address(host: $0, port: port.port), value: Exposure(host: $0).summary)
                }),
                ExtensionDetailSection(title: "Process", rows: processRows),
            ],
            metadata: process.map { [ExtensionMetadataRow(label: "Started", date: $0.startedAt)] } ?? []
        )
    }

    /// A fence longer than any run of backticks in the command line, which
    /// comes from someone else's process.
    static func codeBlock(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text)\n\(fence)"
    }
}

extension Exposure {
    var summary: String {
        switch self {
        case .localhost: "This Mac only"
        case .interface: "One network interface"
        case .network: "Every network interface"
        }
    }
}
