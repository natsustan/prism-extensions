import Foundation
import PrismExtensionKit

/// The rows of Search 1Password and Generate Password, and the setup rows
/// shown in their place when the CLI can't answer.
enum OnePasswordRows {
    enum ActionID {
        static let pastePassword = "paste-password"
        static let copyPassword = "copy-password"
        static let copyUsername = "copy-username"
        static let copyOneTimePassword = "copy-otp"
        static let pasteOneTimePassword = "paste-otp"
        static let openWebsite = "open-website"
        static let view = "view"
        static let pasteUsername = "paste-username"
        static let signIn = "sign-in"
        static let install = "install"
        static let copyInstallCommand = "copy-install-command"
        static let copyErrorDetails = "copy-error-details"
        static let openApp = "open-app"
        static let learnMore = "learn-more"
        static let paste = "paste"
        static let copy = "copy"
    }

    enum FilterID {
        static let all = "all"
        static let favorites = "favorites"
        static let categoryPrefix = "category:"
        static let vaultPrefix = "vault:"
    }

    static let appBundleID = "com.1password.1password"
    static let installCommand = "brew install 1password-cli"
    static let cliGuide = URL(string: "https://developer.1password.com/docs/cli/get-started/")!
    static let integrationGuide = URL(string: "https://developer.1password.com/docs/cli/app-integration/")!
    static let settings = URL(string: "onepassword://settings")!
    static let app = URL(fileURLWithPath: "/Applications/1Password.app")

    // MARK: - Item rows

    /// `<account>/<vault>/<item>`: everything `op item get` needs, so an
    /// action works even after Prism restarted the extension.
    static func itemID(_ item: OnePasswordItem, account: OnePasswordAccount) -> String {
        "\(account.accountUUID)/\(item.vault.id)/\(item.id)"
    }

    static func parse(_ id: String) -> (account: String, vault: String, item: String)? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    static func item(
        _ item: OnePasswordItem, account: OnePasswordAccount, section: String?, returnPastes: Bool
    ) -> ExtensionListItem {
        var accessories = [ExtensionListAccessory]()
        if item.favorite == true {
            accessories.append(ExtensionListAccessory(symbol: "star.fill", tint: "gold", help: "Favorite"))
        }
        accessories.append(ExtensionListAccessory(text: item.vault.name, help: "Vault"))
        let subtitle = item.additionalInformation.flatMap { $0.isEmpty ? nil : $0 }
        return ExtensionListItem(
            id: itemID(item, account: account),
            title: item.title,
            subtitle: subtitle,
            icon: ExtensionIcon(symbol: OnePasswordCategory.symbol(item.category), tint: OnePasswordCategory.tint(item.category)),
            accessories: accessories,
            keywords: [OnePasswordCategory.title(item.category), item.vault.name]
                + (item.urls ?? []).compactMap { URL(string: $0.href)?.host() }
                + (item.tags ?? []),
            section: section,
            actions: actions(for: item, account: account, returnPastes: returnPastes)
        )
    }

    /// A login pastes or copies its password on Return; anything else
    /// opens in 1Password. Secrets are read from `op` only when an action
    /// asks, never put in the list, and those actions run with the launcher
    /// closed so 1Password's prompt can take focus and wait for the user.
    static func actions(for item: OnePasswordItem, account: OnePasswordAccount, returnPastes: Bool) -> [ExtensionAction] {
        // Shortcuts follow Raycast's 1Password extension, so hands that
        // know it know these; Open in Browser takes ⌘O, since Prism's
        // shortcuts need ⌘ or ⌃ and Raycast's is ⌥↵.
        var actions = [ExtensionAction]()
        if OnePasswordCategory.withPassword.contains(item.category) {
            let paste = ExtensionAction(
                id: ActionID.pastePassword, title: "Paste Password", symbol: "doc.on.clipboard",
                shortcut: ExtensionShortcut("cmd+option+v"), interactive: true
            )
            let copy = ExtensionAction(
                id: ActionID.copyPassword, title: "Copy Password", symbol: "doc.on.doc",
                shortcut: ExtensionShortcut("cmd+option+c"), interactive: true
            )
            actions += returnPastes ? [paste, copy] : [copy, paste]
        }
        if item.category == "LOGIN" {
            if let username = item.additionalInformation, !username.isEmpty {
                actions.append(ExtensionAction(
                    id: ActionID.copyUsername, title: "Copy Username", symbol: "person",
                    kind: .copy(text: username), shortcut: ExtensionShortcut("cmd+shift+c")
                ))
                actions.append(ExtensionAction(
                    id: ActionID.pasteUsername, title: "Paste Username", symbol: "person.text.rectangle",
                    shortcut: ExtensionShortcut("cmd+shift+v"), interactive: true
                ))
            }
            actions.append(ExtensionAction(
                id: ActionID.copyOneTimePassword, title: "Copy One-Time Password", symbol: "clock",
                shortcut: ExtensionShortcut("ctrl+cmd+c"), interactive: true
            ))
            actions.append(ExtensionAction(
                id: ActionID.pasteOneTimePassword, title: "Paste One-Time Password", symbol: "clock.badge.checkmark",
                shortcut: ExtensionShortcut("ctrl+cmd+v"), interactive: true
            ))
        }
        if let website = item.website {
            actions.append(ExtensionAction(
                id: ActionID.openWebsite, title: "Open in Browser", symbol: "safari",
                kind: .open(url: website), shortcut: ExtensionShortcut("cmd+o")
            ))
        }
        actions.append(ExtensionAction(
            id: ActionID.view, title: "Open in 1Password", symbol: "arrow.up.forward.app",
            kind: .open(url: link(item: item, account: account)), shortcut: ExtensionShortcut("cmd+shift+o")
        ))
        return actions
    }

    /// 1Password's own link to an item, which opens it in the app.
    static func link(item: OnePasswordItem, account: OnePasswordAccount) -> URL {
        var components = URLComponents()
        components.scheme = "onepassword"
        components.host = "view-item"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "a", value: account.accountUUID),
            URLQueryItem(name: "v", value: item.vault.id),
            URLQueryItem(name: "i", value: item.id),
        ]
        return components.url!
    }

    // MARK: - Filters

    static func filters(for snapshot: VaultSnapshot?) -> [ExtensionListFilter] {
        var filters = [
            ExtensionListFilter(id: FilterID.all, title: "All Items", symbol: "square.grid.2x2"),
            ExtensionListFilter(id: FilterID.favorites, title: "Favorites", symbol: "star"),
        ]
        filters += OnePasswordCategory.filtered.map {
            ExtensionListFilter(
                id: FilterID.categoryPrefix + $0, title: OnePasswordCategory.pluralTitle($0), symbol: OnePasswordCategory.symbol($0)
            )
        }
        let accounts = snapshot?.accounts ?? []
        for entry in accounts {
            var seen = Set<String>()
            let vaults = entry.items.map(\.vault).filter { seen.insert($0.id).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            filters += vaults.map { vault in
                ExtensionListFilter(
                    id: "\(FilterID.vaultPrefix)\(entry.account.accountUUID):\(vault.id)",
                    // Two accounts can both have a vault named Personal.
                    title: accounts.count > 1 ? "\(vault.name) (\(entry.account.name))" : vault.name,
                    symbol: "lock.square.stack"
                )
            }
        }
        return filters
    }

    static func matches(_ filter: String?, item: OnePasswordItem, account: OnePasswordAccount) -> Bool {
        guard let filter, filter != FilterID.all else { return true }
        if filter == FilterID.favorites { return item.favorite == true }
        if filter.hasPrefix(FilterID.categoryPrefix) {
            return item.category == filter.dropFirst(FilterID.categoryPrefix.count)
        }
        if filter.hasPrefix(FilterID.vaultPrefix) {
            return filter == "\(FilterID.vaultPrefix)\(account.accountUUID):\(item.vault.id)"
        }
        return true
    }

    static func emptyMessage(for filter: String?) -> ExtensionListMessage {
        switch filter {
        case FilterID.favorites:
            ExtensionListMessage(title: "No Favorites", message: "Items you mark as favorites in 1Password appear here.", symbol: "star")
        case let filter? where filter.hasPrefix(FilterID.categoryPrefix):
            ExtensionListMessage(
                title: "No \(OnePasswordCategory.pluralTitle(String(filter.dropFirst(FilterID.categoryPrefix.count))))",
                symbol: "magnifyingglass"
            )
        case let filter? where filter.hasPrefix(FilterID.vaultPrefix):
            ExtensionListMessage(title: "This Vault Is Empty", symbol: "lock.square.stack")
        default:
            ExtensionListMessage(title: "No Items", message: "Items in your 1Password vaults appear here.", symbol: "key")
        }
    }

    // MARK: - Setup

    /// What the list shows in place of items when `op` can't list them.
    /// Nil when the error is best shown as a message instead.
    static func setupItem(for error: OnePasswordError, details: String? = nil) -> ExtensionListItem? {
        let item = setupItem(for: error)
        guard let item, let details, error != .notInstalled else { return item }
        // What `op` said, for when the row's advice doesn't fit.
        let copy = ExtensionAction(
            id: ActionID.copyErrorDetails, title: "Copy Error Details", symbol: "doc.on.clipboard",
            kind: .copy(text: details), shortcut: ExtensionShortcut("cmd+shift+e")
        )
        return ExtensionListItem(
            id: item.id, title: item.title, subtitle: item.subtitle, icon: item.icon, actions: item.actions + [copy]
        )
    }

    private static func setupItem(for error: OnePasswordError) -> ExtensionListItem? {
        switch error {
        case .notInstalled:
            ExtensionListItem(
                id: "setup-install", title: "Install 1Password CLI",
                subtitle: "Search 1Password reads your vaults through the op command.",
                icon: ExtensionIcon(symbol: "arrow.down.circle", tint: "blue"),
                actions: [
                    ExtensionAction(id: ActionID.install, title: "Open Install Guide", symbol: "safari", kind: .open(url: cliGuide)),
                    ExtensionAction(
                        id: ActionID.copyInstallCommand, title: "Copy Homebrew Command", symbol: "terminal",
                        kind: .copy(text: installCommand), shortcut: ExtensionShortcut("cmd+shift+c")
                    ),
                ]
            )
        case .noAccounts:
            ExtensionListItem(
                id: "setup-integration", title: "Turn On 1Password CLI Integration",
                subtitle: "In 1Password, choose Settings → Developer → Integrate with 1Password CLI.",
                icon: ExtensionIcon(symbol: "switch.2", tint: "blue", app: appBundleID),
                actions: [
                    ExtensionAction(id: ActionID.openApp, title: "Open 1Password Settings", symbol: "gear", kind: .open(url: settings)),
                    ExtensionAction(id: ActionID.learnMore, title: "Learn More", symbol: "safari", kind: .open(url: integrationGuide)),
                ]
            )
        case .notSignedIn, .timedOut:
            ExtensionListItem(
                id: "setup-sign-in", title: "Sign In to 1Password",
                subtitle: error == .timedOut
                    ? "1Password didn’t answer in time. Unlock it, then approve Prism."
                    : "Unlock 1Password, then approve Prism when it asks.",
                icon: ExtensionIcon(symbol: "lock.open", tint: "blue", app: appBundleID),
                actions: [
                    ExtensionAction(id: ActionID.signIn, title: "Sign In", symbol: "person.badge.key", interactive: true),
                    ExtensionAction(id: ActionID.openApp, title: "Open 1Password Settings", symbol: "gear", kind: .open(url: settings)),
                ]
            )
        case .missingField, .failed:
            nil
        }
    }

    /// Shown while 1Password asks the user to allow Prism; the list loads
    /// again once they answer.
    static let waitingItem = ExtensionListItem(
        id: "setup-waiting", title: "Waiting for 1Password…",
        subtitle: "Allow Prism in 1Password’s window, and your items appear here.",
        icon: ExtensionIcon(symbol: "lock.open", tint: "blue", app: appBundleID),
        actions: [ExtensionAction(id: ActionID.openApp, title: "Open 1Password", symbol: "arrow.up.forward.app", kind: .open(url: app))],
        isLoading: true
    )

    static func failureMessage(_ error: OnePasswordError) -> ExtensionListMessage {
        ExtensionListMessage(
            title: "Couldn’t Load 1Password", message: describe(error), symbol: "exclamationmark.triangle"
        )
    }

    /// The error as a sentence for a HUD or a message.
    static func describe(_ error: OnePasswordError) -> String {
        switch error {
        case .notInstalled: "Install 1Password CLI to use 1Password in Prism."
        case .noAccounts: "Turn on Integrate with 1Password CLI in 1Password’s Developer settings."
        case .notSignedIn: "Unlock 1Password and approve Prism, then try again."
        case .timedOut: "1Password didn’t answer in time. Unlock it, then try again."
        case .missingField: "This item doesn’t have that."
        case let .failed(message): message
        }
    }

    // MARK: - Generate Password

    static func generated(_ recipe: PasswordRecipe, password: String) -> ExtensionListItem {
        ExtensionListItem(
            id: recipe.rawValue,
            title: password,
            subtitle: recipe.summary,
            icon: ExtensionIcon(symbol: recipe == .pin ? "number" : "key.horizontal", tint: "blue"),
            actions: [
                ExtensionAction(id: ActionID.paste, title: "Paste Password", symbol: "doc.on.clipboard"),
                ExtensionAction(
                    id: ActionID.copy, title: "Copy Password", symbol: "doc.on.doc", shortcut: ExtensionShortcut("cmd+shift+c")
                ),
            ]
        )
    }
}
