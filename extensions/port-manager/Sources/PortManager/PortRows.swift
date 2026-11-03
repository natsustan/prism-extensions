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

    static var filters: [ExtensionListFilter] { [
        ExtensionListFilter(id: FilterID.all, title: localized("All Ports"), symbol: "network"),
        ExtensionListFilter(id: FilterID.localhost, title: localized("Localhost Only"), symbol: Exposure.localhost.symbol),
        ExtensionListFilter(id: FilterID.network, title: localized("Reachable from Network"), symbol: Exposure.network.symbol),
        ExtensionListFilter(id: FilterID.interface, title: localized("Specific Interface"), symbol: Exposure.interface.symbol),
    ] }

    static func emptyMessage(for exposure: Exposure?) -> ExtensionListMessage {
        switch exposure {
        case nil:
            ExtensionListMessage(
                title: localized("No Open Ports"),
                message: localized("Nothing is listening on a TCP port."),
                symbol: "network.slash"
            )
        case .localhost:
            ExtensionListMessage(
                title: localized("No Localhost Ports"),
                message: localized("No port is open only to this Mac."),
                symbol: Exposure.localhost.symbol
            )
        case .network:
            ExtensionListMessage(
                title: localized("No Ports Reachable from Network"),
                message: localized("No port is open on every network interface."),
                symbol: Exposure.network.symbol
            )
        case .interface:
            ExtensionListMessage(
                title: localized("No Ports on a Specific Interface"),
                message: localized("No port is bound to one interface’s address."),
                symbol: Exposure.interface.symbol
            )
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
        let owner = process.flatMap {
            $0.userID == currentUserID ? nil : $0.userName ?? localized("user \(String($0.userID))")
        }
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
            let name = localized("“\(process.name)” (PID \(String(process.pid)))")
            actions.append(ExtensionAction(
                id: ActionID.kill, title: localized("Kill Process"), symbol: "xmark.circle", style: .destructive,
                confirmationMessage: localized("\(name) stops listening on \(portList(listener.ports)) and quits.")
            ))
            actions.append(ExtensionAction(
                id: ActionID.forceKill, title: localized("Force Kill Process"), symbol: "xmark.octagon", style: .destructive,
                shortcut: ExtensionShortcut("cmd+shift+delete"),
                confirmationMessage: localized("\(name) quits at once, without a chance to clean up.")
            ))
            if let parent = listener.parent, parent.userID == currentUserID {
                actions.append(ExtensionAction(
                    id: ActionID.killParent, title: localized("Kill Parent Process"), symbol: "arrow.up.circle", style: .destructive,
                    confirmationMessage: localized("“\(parent.name)” (PID \(String(parent.pid))), which started “\(process.name)”, quits.")
                ))
            }
        }
        actions += group(ActionID.browserMenu, title: localized("Open in Browser"), symbol: "safari", browserActions(for: listener.ports))

        var finder: [ExtensionAction] = []
        if process?.path != nil {
            finder.append(ExtensionAction(
                id: ActionID.showInFinder, title: localized("Show in Finder"), symbol: "folder",
                shortcut: ExtensionShortcut("cmd+shift+f")
            ))
        }
        if listener.parent?.path != nil {
            finder.append(ExtensionAction(id: ActionID.showParentInFinder, title: localized("Show Parent in Finder"), symbol: "folder"))
        }
        actions += group(ActionID.finderMenu, title: localized("Show in Finder"), symbol: "folder", finder)

        var copies = [ExtensionAction(
            id: ActionID.copyPID, title: localized("Copy PID"), symbol: "number",
            kind: .copy(text: "\(listener.pid)"), shortcut: ExtensionShortcut("cmd+shift+c")
        )]
        if let path = process?.path {
            copies.append(ExtensionAction(id: ActionID.copyPath, title: localized("Copy Path"), symbol: "folder", kind: .copy(text: path)))
        }
        if let commandLine = process?.commandLine {
            copies.append(ExtensionAction(
                id: ActionID.copyCommandLine, title: localized("Copy Command Line"), symbol: "terminal",
                kind: .copy(text: commandLine), shortcut: ExtensionShortcut("cmd+shift+l")
            ))
        }
        // Prism can't stop another user's process, but an administrator can
        // in Terminal. Never launchd, which would take the Mac down.
        if let process, process.userID != currentUserID, process.pid > 1 {
            copies.append(ExtensionAction(
                id: ActionID.copyKillCommand, title: localized("Copy Kill Command"), symbol: "xmark.circle",
                kind: .copy(text: "sudo kill \(process.pid)"), shortcut: ExtensionShortcut("cmd+shift+k")
            ))
        }
        actions += group(ActionID.copyMenu, title: localized("Copy"), symbol: "doc.on.doc", copies)
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
                    title: single
                        ? localized("Open in Browser")
                        : localized("Open \(String(port.port)) in Browser"),
                    symbol: "safari",
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
                help: Self.help(
                    [names[port.port], port.addresses.joined(separator: ", ")].compactMap { $0 }.joined(separator: ", "),
                    port.exposure.help
                ),
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

    /// “3000, 127.0.0.1:3000: reachable only from this Mac”.
    private static func help(_ port: String, _ reach: String) -> String {
        localized("\(port): \(reach)")
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
                label: names[port.port].map {
                    localized("Port \(String(port.port)) (\($0))")
                } ?? localized("Port \(String(port.port))"),
                value: port.addresses.joined(separator: ", ")
                    + " · \(port.exposure.summary)"
            )
        }
        rows.append(ExtensionMetadataRow(label: "PID", value: "\(listener.pid)"))
        if let process {
            rows.append(ExtensionMetadataRow(
                label: localized("User"), value: process.userName.map { "\($0) (\(process.userID))" } ?? "\(process.userID)"
            ))
        }
        if let parent = listener.parent {
            rows.append(ExtensionMetadataRow(label: localized("Parent"), value: "\(parent.name) (\(parent.pid))"))
        }
        if let path = process?.path {
            rows.append(ExtensionMetadataRow(label: localized("Path"), value: path))
        }
        if let path = listener.parent?.path {
            rows.append(ExtensionMetadataRow(label: localized("Parent Path"), value: path))
        }
        if let process {
            rows.append(ExtensionMetadataRow(label: localized("Started"), date: process.startedAt))
        }
        let numbers = listener.ports.map { "\($0.port)" }.joined(separator: ", ")
        return ExtensionDetail(
            title: listener.processName,
            subtitle: listener.ports.count == 1
                ? localized("Port \(numbers)")
                : localized("Ports \(numbers)"),
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

    /// “port 3000”, “ports 3000 and 5173”, “ports 3000, 5173, and 8080”,
    /// listed the way Prism's language lists things.
    static func portList(_ ports: [ListeningPort]) -> String {
        let numbers = ports.map { "\($0.port)" }
        if numbers.count == 1, let number = numbers.first {
            return localized("port \(number)")
        }
        let list = numbers.formatted(.list(type: .and).locale(PrismLocalization.locale))
        return localized("ports \(list)")
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
        case .localhost: localized("reachable only from this Mac")
        case .interface: localized("reachable only through this address")
        case .network: localized("reachable from other devices on your network")
        }
    }

    var summary: String {
        switch self {
        case .localhost: localized("This Mac only")
        case .interface: localized("One network interface")
        case .network: localized("Every network interface")
        }
    }
}
