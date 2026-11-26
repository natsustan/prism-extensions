import Foundation
import PrismExtensionKit

/// Maps `ResolvedHost` values into Prism list items, filters, and empty states.
enum ScreenSharingRows {
    static var searchPlaceholder: String {
        localized("Search Macs or enter a host, IP, or vnc:// address…")
    }

    static var filters: [ExtensionListFilter] {
        [
            ExtensionListFilter(id: ScreenSharing.FilterID.all, title: localized("All"), symbol: "display"),
            ExtensionListFilter(id: ScreenSharing.FilterID.pinned, title: localized("Pinned"), symbol: "pin"),
            ExtensionListFilter(id: ScreenSharing.FilterID.local, title: localized("Local Network"), symbol: "bonjour"),
            ExtensionListFilter(id: ScreenSharing.FilterID.recent, title: localized("Recent"), symbol: "clock"),
        ]
    }

    static func item(for host: ResolvedHost, showSections: Bool) -> ExtensionListItem {
        let vncURL = host.address.vncURL?.absoluteString
        let actions = Self.actions(for: host, vncURL: vncURL)

        if host.isQuickConnect {
            return ExtensionListItem(
                id: host.id,
                title: localized("Connect to \(host.address.displayAddress)"),
                subtitle: vncURL,
                icon: ExtensionIcon(symbol: "arrow.right.circle", tint: "blue"),
                section: showSections ? localized("Quick Connect") : nil,
                actions: actions
            )
        }

        let symbol = DeviceModelIcon.symbol(for: host.model, name: host.name)
        let tint = host.isLocalOnline ? "blue" : (host.isPinned ? "indigo" : "gray")
        let subtitle = host.name.caseInsensitiveCompare(host.address.displayAddress) == .orderedSame
            ? vncURL
            : host.address.displayAddress

        var accessories = [ExtensionListAccessory]()
        if host.isLocalOnline {
            accessories.append(ExtensionListAccessory(
                text: localized("Online"),
                tint: "green",
                style: .tag
            ))
        } else if host.isLocalCached {
            accessories.append(ExtensionListAccessory(
                text: localized("Local"),
                tint: "gray",
                style: .tag
            ))
        }
        if host.isPinned {
            accessories.append(ExtensionListAccessory(
                symbol: "pin.fill",
                tint: "orange",
                help: localized("Pinned")
            ))
        }

        return ExtensionListItem(
            id: host.id,
            title: host.name,
            subtitle: subtitle,
            icon: ExtensionIcon(symbol: symbol, tint: tint),
            accessories: accessories,
            keywords: PinyinKeywords.keywords(for: host.name),
            section: showSections ? sectionTitle(for: host) : nil,
            actions: actions
        )
    }

    private static func actions(for host: ResolvedHost, vncURL: String?) -> [ExtensionAction] {
        var actions = [
            ExtensionAction(
                id: ScreenSharing.ActionID.connect,
                title: localized("Connect"),
                symbol: "rectangle.inset.filled.and.person.filled"
            ),
            ExtensionAction(
                id: ScreenSharing.ActionID.togglePin,
                title: host.isPinned ? localized("Unpin Host") : localized("Pin Host"),
                symbol: host.isPinned ? "pin.slash" : "pin",
                shortcut: ExtensionShortcut("cmd+shift+p")
            ),
        ]

        if let vncURL {
            actions.append(ExtensionAction(
                id: ScreenSharing.ActionID.copyURL,
                title: localized("Copy VNC Link"),
                symbol: "link",
                kind: .copy(text: vncURL),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ))
        }

        actions.append(ExtensionAction(
            id: ScreenSharing.ActionID.copyAddress,
            title: localized("Copy Address"),
            symbol: "doc.on.doc",
            kind: .copy(text: host.address.displayAddress),
            shortcut: ExtensionShortcut("cmd+shift+a")
        ))

        if host.isRecent {
            actions.append(ExtensionAction(
                id: ScreenSharing.ActionID.removeRecent,
                title: localized("Remove from Recent"),
                symbol: "trash",
                style: .destructive,
                shortcut: ExtensionShortcut("cmd+backspace")
            ))
        }

        if !host.isQuickConnect {
            actions.append(ExtensionAction(
                id: ScreenSharing.ActionID.refresh,
                title: localized("Refresh Local Network"),
                symbol: "arrow.clockwise",
                shortcut: ExtensionShortcut("cmd+r")
            ))
        }

        return actions
    }

    static func sectionTitle(for host: ResolvedHost) -> String {
        if host.isQuickConnect { return localized("Quick Connect") }
        if host.isPinned { return localized("Pinned") }
        if host.isLocal { return localized("Local Network") }
        if host.isSaved { return localized("Saved") }
        return localized("Recent")
    }

    static func emptyMessage(query: String, filter: String?) -> ExtensionListMessage {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ExtensionListMessage(
                title: localized("No Matching Hosts"),
                message: localized("Type an IP address, .local hostname, or vnc:// URL to connect directly."),
                symbol: "magnifyingglass"
            )
        }
        switch filter {
        case ScreenSharing.FilterID.pinned:
            return ExtensionListMessage(
                title: localized("No Pinned Hosts"),
                message: localized("Pin a Mac with ⌘⇧P to keep it at the top of the list."),
                symbol: "pin"
            )
        case ScreenSharing.FilterID.local:
            return ExtensionListMessage(
                title: localized("No Macs Found Nearby"),
                message: localized("Turn on Screen Sharing on another Mac on your local network, or press ⌘R to scan again."),
                symbol: "bonjour"
            )
        case ScreenSharing.FilterID.recent:
            return ExtensionListMessage(
                title: localized("No Recent Connections"),
                message: localized("Macs you connect to from Prism appear here."),
                symbol: "clock"
            )
        default:
            return ExtensionListMessage(
                title: localized("No Macs Found"),
                message: localized("Type a hostname or IP address to connect, or add hosts in extension settings."),
                symbol: "display"
            )
        }
    }
}
