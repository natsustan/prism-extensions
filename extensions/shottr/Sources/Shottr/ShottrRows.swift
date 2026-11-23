import Foundation
import PrismExtensionKit

enum ShottrRows {
    static var filters: [ExtensionListFilter] {
        [
            ExtensionListFilter(id: Shottr.FilterID.capture, title: localized("Capture"), symbol: "camera.viewfinder"),
            ExtensionListFilter(id: Shottr.FilterID.tools, title: localized("Tools"), symbol: "wrench.and.screwdriver"),
        ]
    }

    static func items(
        filter: String?,
        closeBeforeCapture: Bool,
        delaySeconds: Int?
    ) -> [ExtensionListItem] {
        let visible = ShottrAction.allCases.filter { action in
            switch filter {
            case Shottr.FilterID.capture: action.group == .capture
            case Shottr.FilterID.tools: action.group == .tools || action.group == .app
            default: true
            }
        }
        return visible.map { row(for: $0, closeBeforeCapture: closeBeforeCapture, delaySeconds: delaySeconds) }
    }

    static func notInstalledItem() -> ExtensionListItem {
        ExtensionListItem(
            id: "install-shottr",
            title: localized("Install Shottr"),
            subtitle: localized("Shottr isn’t installed. Download it from shottr.cc, then enable URL Schema API in Settings → Advanced."),
            icon: ExtensionIcon(symbol: "arrow.down.circle", tint: "orange"),
            actions: [
                ExtensionAction(
                    id: Shottr.ActionID.download,
                    title: localized("Open shottr.cc"),
                    symbol: "safari",
                    kind: .open(url: WorkspaceShottrOpener.downloadURL)
                ),
                ExtensionAction(
                    id: Shottr.ActionID.copyURL,
                    title: localized("Copy Download Link"),
                    symbol: "link",
                    kind: .copy(text: WorkspaceShottrOpener.downloadURL.absoluteString),
                    shortcut: ExtensionShortcut("cmd+shift+c")
                ),
            ]
        )
    }

    private static func row(
        for action: ShottrAction,
        closeBeforeCapture: Bool,
        delaySeconds: Int?
    ) -> ExtensionListItem {
        let url = action.url(delaySeconds: delaySeconds)
        let interactive = action.capturesScreen && closeBeforeCapture

        var actions: [ExtensionAction] = [
            ExtensionAction(
                id: Shottr.ActionID.run,
                title: action.title,
                symbol: action.icon.symbol,
                kind: .open(url: url),
                interactive: interactive
            ),
        ]

        if action == .delayed {
            actions.append(
                ExtensionAction(
                    id: Shottr.ActionID.delayMenu,
                    title: localized("Delay…"),
                    symbol: "timer",
                    actions: ShottrAction.delayPresets.map { seconds in
                        ExtensionAction(
                            id: "\(Shottr.ActionID.delayPrefix)\(seconds)",
                            title: localized("\(seconds) Seconds"),
                            symbol: "timer",
                            kind: .open(url: action.url(delaySeconds: seconds)),
                            interactive: interactive
                        )
                    }
                )
            )
        }

        if action.supportsPostCapture {
            actions.append(
                ExtensionAction(
                    id: Shottr.ActionID.thenMenu,
                    title: localized("Capture and…"),
                    symbol: "sparkles",
                    actions: ShottrAction.PostCapture.allCases.map { post in
                        ExtensionAction(
                            id: "\(Shottr.ActionID.thenPrefix)\(post.rawValue)",
                            title: post.title,
                            symbol: post.symbol,
                            kind: .open(url: action.url(delaySeconds: delaySeconds, then: post)),
                            interactive: interactive
                        )
                    }
                )
            )
        }

        if interactive {
            actions.append(
                ExtensionAction(
                    id: Shottr.ActionID.runKeepingPrism,
                    title: localized("Capture Without Closing Prism"),
                    symbol: "macwindow",
                    kind: .open(url: url),
                    interactive: false
                )
            )
        }

        actions.append(
            ExtensionAction(
                id: Shottr.ActionID.copyURL,
                title: localized("Copy URL"),
                symbol: "link",
                kind: .copy(text: url.absoluteString),
                shortcut: ExtensionShortcut("cmd+shift+c")
            )
        )

        var accessories: [ExtensionListAccessory] = []
        if action == .delayed {
            let seconds = delaySeconds ?? ShottrAction.defaultDelaySeconds
            accessories.append(ExtensionListAccessory(text: localized("\(seconds)s"), style: .tag))
        }

        return ExtensionListItem(
            id: action.rawValue,
            title: action.title,
            subtitle: action.subtitle(delaySeconds: delaySeconds),
            icon: action.icon,
            accessories: accessories,
            keywords: action.keywords,
            section: action.group.sectionTitle,
            actions: actions
        )
    }
}
