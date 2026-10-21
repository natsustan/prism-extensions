import Darwin
import Foundation
import PrismExtensionKit

/// Maps listening processes to list rows, details, and actions.
enum PortRows {
    typealias ActionID = PortManager.ActionID
    typealias FilterID = PortManager.FilterID

    /// How many ports a row shows before the rest become “+N”: the list
    /// column fits two port tags beside a title.
    static let visiblePorts = 2
    /// How many ports get their own Open in Browser action.
    static let browserPorts = 5

    static let filters = [
        ExtensionListFilter(id: FilterID.all, title: "All Ports", symbol: "network"),
        ExtensionListFilter(id: FilterID.localhost, title: "Localhost Only", symbol: Exposure.localhost.symbol),
        ExtensionListFilter(id: FilterID.network, title: "Reachable from Network", symbol: Exposure.network.symbol),
        ExtensionListFilter(id: FilterID.interface, title: "Specific Interface", symbol: Exposure.interface.symbol),
    ]

    static func emptyMessage(for exposure: Exposure?) -> ExtensionListMessage {
        switch exposure {
        case nil:
            ExtensionListMessage(title: "No Open Ports", message: "Nothing is listening on a TCP port.", symbol: "network.slash")
        case .localhost:
            ExtensionListMessage(title: "No Localhost Ports", message: "No port is open only to this Mac.", symbol: Exposure.localhost.symbol)
        case .network:
            ExtensionListMessage(title: "No Ports Reachable from Network", message: "No port is open on every network interface.", symbol: Exposure.network.symbol)
        case .interface:
            ExtensionListMessage(title: "No Ports on a Specific Interface", message: "No port is bound to one interface’s address.", symbol: Exposure.interface.symbol)
        }
    }

    /// `ports` are the ones the row shows, which a filter narrows.
    static func item(
        for listener: ListeningProcess, showing ports: [ListeningPort]? = nil, names: PortNames, currentUserID: uid_t,
        bundleIdentifier: (String) -> String?
    ) -> ExtensionListItem {
        let process = listener.process
        let icon = icon(for: process, bundleIdentifier: bundleIdentifier)
        // Another user's process says whose it is, which is also why it
        // offers no kill.
        let owner = process.flatMap { $0.userID == currentUserID ? nil : $0.userName ?? "user \($0.userID)" }
        return ExtensionListItem(
            id: listener.id,
            title: listener.processName,
            subtitle: owner,
            icon: icon,
            accessories: accessories(for: ports ?? listener.ports, names: names),
            keywords: keywords(for: listener, names: names),
            detail: detail(for: listener, names: names, icon: icon),
            actions: actions(for: listener, currentUserID: currentUserID)
        )
    }

    // MARK: - Actions

    static func actions(for listener: ListeningProcess, currentUserID: uid_t) -> [ExtensionAction] {
        var actions: [ExtensionAction] = []
        let process = listener.process
        if let process, process.userID == currentUserID {
            let name = "“\(process.name)” (PID \(process.pid))"
            actions.append(ExtensionAction(
                id: ActionID.kill, title: "Kill Process", symbol: "xmark.circle", style: .destructive,
                confirmationMessage: "\(name) stops listening on \(portList(listener.ports)) and quits."
            ))
            actions.append(ExtensionAction(
                id: ActionID.forceKill, title: "Force Kill Process", symbol: "xmark.octagon", style: .destructive,
                shortcut: ExtensionShortcut("cmd+shift+delete"),
                confirmationMessage: "\(name) quits at once, without a chance to clean up."
            ))
            if let parent = listener.parent, parent.userID == currentUserID {
                actions.append(ExtensionAction(
                    id: ActionID.killParent, title: "Kill Parent Process", symbol: "arrow.up.circle", style: .destructive,
                    confirmationMessage: "“\(parent.name)” (PID \(parent.pid)), which started “\(process.name)”, quits."
                ))
            }
        }
        actions += group(ActionID.browserMenu, title: "Open in Browser", symbol: "safari", browserActions(for: listener.ports))

        var finder: [ExtensionAction] = []
        if process?.path != nil {
            finder.append(ExtensionAction(
                id: ActionID.showInFinder, title: "Show in Finder", symbol: "folder",
                shortcut: ExtensionShortcut("cmd+shift+f")
            ))
        }
        if listener.parent?.path != nil {
            finder.append(ExtensionAction(id: ActionID.showParentInFinder, title: "Show Parent in Finder", symbol: "folder"))
        }
        actions += group(ActionID.finderMenu, title: "Show in Finder", symbol: "folder", finder)

        var copies = [ExtensionAction(
            id: ActionID.copyPID, title: "Copy PID", symbol: "number",
            kind: .copy(text: "\(listener.pid)"), shortcut: ExtensionShortcut("cmd+shift+c")
        )]
        if let path = process?.path {
            copies.append(ExtensionAction(id: ActionID.copyPath, title: "Copy Path", symbol: "folder", kind: .copy(text: path)))
        }
        if let commandLine = process?.commandLine {
            copies.append(ExtensionAction(
                id: ActionID.copyCommandLine, title: "Copy Command Line", symbol: "terminal",
                kind: .copy(text: commandLine), shortcut: ExtensionShortcut("cmd+shift+l")
            ))
        }
        // Prism can't stop another user's process, but an administrator can
        // in Terminal. Never launchd, which would take the Mac down.
        if let process, process.userID != currentUserID, process.pid > 1 {
            copies.append(ExtensionAction(
                id: ActionID.copyKillCommand, title: "Copy Kill Command", symbol: "xmark.circle",
                kind: .copy(text: "sudo kill \(process.pid)"), shortcut: ExtensionShortcut("cmd+shift+k")
            ))
        }
        actions += group(ActionID.copyMenu, title: "Copy", symbol: "doc.on.doc", copies)
        return actions
    }

    /// One Open in Browser action per port, named by the port so a hotkey
    /// stays on it whichever port comes first; the first is on ⌘O.
    private static func browserActions(for ports: [ListeningPort]) -> [ExtensionAction] {
        let single = ports.count == 1
        return ports.prefix(browserPorts).enumerated().compactMap { index, port in
            port.url.map { url in
                ExtensionAction(
                    id: "\(ActionID.openInBrowser):\(port.port)",
                    title: single ? "Open in Browser" : "Open \(port.port) in Browser", symbol: "safari",
                    kind: .open(url: url), shortcut: index == 0 ? ExtensionShortcut("cmd+o") : nil
                )
            }
        }
    }

    /// Related actions as one submenu; a lone action stays as it is.
    private static func group(_ id: String, title: String, symbol: String, _ actions: [ExtensionAction]) -> [ExtensionAction] {
        guard actions.count > 1 else { return actions }
        return [ExtensionAction(id: id, title: title, symbol: symbol, actions: actions)]
    }

    // MARK: - Pieces

    private static func icon(for process: RunningProcess?, bundleIdentifier: (String) -> String?) -> ExtensionIcon {
        if let app = process?.appPath, let identifier = bundleIdentifier(app) {
            return ExtensionIcon(symbol: "app", tint: "gray", app: identifier)
        }
        return ExtensionIcon(symbol: "terminal", tint: "gray")
    }

    /// Each port in the color of its reach: green for this Mac only, orange
    /// for the network, blue for one address.
    static func accessories(for ports: [ListeningPort], names: PortNames) -> [ExtensionListAccessory] {
        let shown = ports.count > visiblePorts ? Array(ports.prefix(visiblePorts - 1)) : ports
        var accessories = shown.map { port in
            ExtensionListAccessory(
                text: "\(port.port)",
                tint: port.exposure.tint,
                help: [names[port.port], port.addresses.joined(separator: ", ")]
                    .compactMap { $0 }.joined(separator: ", ") + ": \(port.exposure.help)",
                style: .tag
            )
        }
        let hidden = ports.dropFirst(shown.count)
        if !hidden.isEmpty {
            accessories.append(ExtensionListAccessory(
                text: "+\(hidden.count)", help: hidden.map { "\($0.port)" }.joined(separator: ", "), style: .tag
            ))
        }
        return accessories
    }

    /// Typing a port, a port's name, an address, the process, its PID, path,
    /// or an argument finds the row.
    private static func keywords(for listener: ListeningProcess, names: PortNames) -> [String] {
        let process = listener.process
        let ports = listener.ports.flatMap { port in
            ["\(port.port)", names[port.port]].compactMap { $0 }
                + port.addresses
        }
        return ports + ["\(listener.pid)", process?.userName, process?.path, process?.commandLine].compactMap { $0 }
    }

    /// The command line above the Information block, which holds every
    /// fact about the process, as in Raycast: a row per port, then the
    /// process, its owner and parent, and where both programs live.
    private static func detail(for listener: ListeningProcess, names: PortNames, icon: ExtensionIcon) -> ExtensionDetail {
        let process = listener.process
        var rows = listener.ports.map { port in
            ExtensionMetadataRow(
                label: names[port.port].map { "Port \(port.port) (\($0))" } ?? "Port \(port.port)",
                value: port.addresses.joined(separator: ", ")
                    + " · \(port.exposure.summary)"
            )
        }
        rows.append(ExtensionMetadataRow(label: "PID", value: "\(listener.pid)"))
        if let process {
            rows.append(ExtensionMetadataRow(
                label: "User", value: process.userName.map { "\($0) (\(process.userID))" } ?? "\(process.userID)"
            ))
        }
        if let parent = listener.parent {
            rows.append(ExtensionMetadataRow(label: "Parent", value: "\(parent.name) (\(parent.pid))"))
        }
        if let path = process?.path {
            rows.append(ExtensionMetadataRow(label: "Path", value: path))
        }
        if let path = listener.parent?.path {
            rows.append(ExtensionMetadataRow(label: "Parent Path", value: path))
        }
        if let process {
            rows.append(ExtensionMetadataRow(label: "Started", date: process.startedAt))
        }
        let numbers = listener.ports.map { "\($0.port)" }.joined(separator: ", ")
        return ExtensionDetail(
            title: listener.processName,
            subtitle: listener.ports.count == 1 ? "Port \(numbers)" : "Ports \(numbers)",
            icon: icon,
            // Another user's arguments can't be read; the path still shows below.
            markdown: process?.commandLine.map(codeBlock),
            metadata: rows
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

    /// “port 3000”, “ports 3000 and 5173”, “ports 3000, 5173, and 8080”.
    static func portList(_ ports: [ListeningPort]) -> String {
        let numbers = ports.map { "\($0.port)" }
        switch numbers.count {
        case 1: return "port \(numbers[0])"
        case 2: return "ports \(numbers[0]) and \(numbers[1])"
        default: return "ports \(numbers.dropLast().joined(separator: ", ")), and \(numbers.last!)"
        }
    }
}

extension Exposure {
    var symbol: String {
        switch self {
        case .localhost: "lock"
        case .interface: "point.3.connected.trianglepath.dotted"
        case .network: "globe"
        }
    }

    var tint: String {
        switch self {
        case .localhost: "green"
        case .interface: "blue"
        case .network: "orange"
        }
    }

    var help: String {
        switch self {
        case .localhost: "reachable only from this Mac"
        case .interface: "reachable only through this address"
        case .network: "reachable from other devices on your network"
        }
    }

    var summary: String {
        switch self {
        case .localhost: "This Mac only"
        case .interface: "One network interface"
        case .network: "Every network interface"
        }
    }
}
