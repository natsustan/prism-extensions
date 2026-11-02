import Foundation
import PrismExtensionKit

/// 1Password items through the 1Password CLI (`op`) and its desktop app
/// integration: search every account's items, paste or copy a password or
/// one-time password, and generate new passwords. Secrets are read only when
/// an action asks for one, and Prism keeps them out of clipboard histories
/// and clears them after 90 seconds.
@main
struct OnePassword: PrismExtension {
    enum CommandID {
        static let search = "search"
        static let generate = "generate"
    }

    enum PreferenceID {
        static let returnPastes = "returnPastes"
        static let cliPath = "cliPath"
    }

    typealias ActionID = OnePasswordRows.ActionID

    let cli: any OnePasswordCLI
    let generator: PasswordGenerator
    let library: VaultLibrary
    let authorization: AppAuthorization
    let generated = GeneratedPasswords()

    init() {
        self.init(cli: InstalledOnePasswordCLI(), generator: .secure)
    }

    init(
        cli: any OnePasswordCLI, generator: PasswordGenerator, now: @escaping @Sendable () -> Date = Date.init,
        authorizationWait: Duration = .seconds(2)
    ) {
        self.cli = cli
        self.generator = generator
        self.library = VaultLibrary(now: now)
        self.authorization = AppAuthorization(quickWait: authorizationWait)
    }

    private func client(_ context: PrismContext) -> OnePasswordClient {
        OnePasswordClient(
            cli: cli,
            executable: context.preferences.string(PreferenceID.cliPath).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Lists

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        switch command {
        case CommandID.search: try await search(filter: filter, context: context)
        case CommandID.generate: await generate()
        default: throw PrismExtensionError("1Password has no list “\(command)”.")
        }
    }

    private func search(filter: String?, context: PrismContext) async throws -> ExtensionList {
        let placeholder = "Search 1Password…"
        let snapshot: VaultSnapshot
        do {
            if let fresh = await library.fresh() {
                snapshot = fresh
            } else {
                CLIFailures.reset()
                let client = client(context)
                let accounts: [OnePasswordAccount]
                if let signedIn = try await client.signedInAccounts() {
                    accounts = signedIn
                } else {
                    let outcome = await authorization.accounts(client) {
                        await context.listChanged(CommandID.search)
                    }
                    guard let outcome else {
                        try Task.checkCancellation()
                        return ExtensionList(
                            items: [OnePasswordRows.waitingItem], searchPlaceholder: placeholder,
                            filters: OnePasswordRows.filters(for: nil)
                        )
                    }
                    accounts = try outcome.get()
                }
                try Task.checkCancellation()
                snapshot = try await library.load(client, accounts: accounts)
            }
        } catch let error as OnePasswordError {
            try Task.checkCancellation()
            let setup = OnePasswordRows.setupItem(for: error, details: CLIFailures.latest)
            return ExtensionList(
                items: setup.map { [$0] } ?? [],
                searchPlaceholder: placeholder,
                filters: OnePasswordRows.filters(for: nil),
                emptyMessage: OnePasswordRows.failureMessage(error)
            )
        }
        let returnPastes = context.preferences.bool(PreferenceID.returnPastes, default: true)
        let sectioned = snapshot.accounts.count > 1
        let items = snapshot.accounts.flatMap { entry in
            entry.items
                .filter { OnePasswordRows.matches(filter, item: $0, account: entry.account) }
                .map {
                    OnePasswordRows.item(
                        $0, account: entry.account, section: sectioned ? entry.account.name : nil, returnPastes: returnPastes
                    )
                }
        }
        return ExtensionList(
            items: items,
            searchPlaceholder: placeholder,
            filters: OnePasswordRows.filters(for: snapshot),
            emptyMessage: OnePasswordRows.emptyMessage(for: filter),
            fetchedAt: snapshot.error == nil ? nil : snapshot.fetchedAt,
            error: snapshot.error
        )
    }

    /// New passwords on every load, so ⌘R makes another set.
    private func generate() async -> ExtensionList {
        let passwords = PasswordRecipe.allCases.map { ($0, generator.password($0)) }
        await generated.replace(with: Dictionary(uniqueKeysWithValues: passwords.map { ($0.0.rawValue, $0.1) }))
        return ExtensionList(
            items: passwords.map { OnePasswordRows.generated($0.0, password: $0.1) },
            searchPlaceholder: "Generate Password"
        )
    }

    // MARK: - Actions

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        if command == CommandID.generate {
            guard let password = await generated.password(for: item) else {
                return ExtensionActionResult(.failed(message: "Press ⌘R for a new password, then try again."), reload: true)
            }
            return Self.secret(password, paste: action == ActionID.paste, copied: "Copied Password")
        }
        if action == ActionID.signIn {
            return ExtensionActionResult(await signIn(context))
        }
        guard let target = OnePasswordRows.parse(item) else {
            throw PrismExtensionError("1Password has no item “\(item)”.")
        }
        let listed = await library.item(id: target.item, account: target.account)
        let name = listed.map { "“\($0.title)”" } ?? "This item"
        let client = client(context)
        let read = { (field: String) in
            try await client.read(field, item: target.item, vault: target.vault, account: target.account)
        }
        do {
            switch action {
            case ActionID.pastePassword, ActionID.copyPassword:
                let password = try await read("password")
                return Self.secret(password, paste: action == ActionID.pastePassword, copied: "Copied Password")
            case ActionID.pasteUsername:
                // The row already showed a login's username, as Copy Username copies it.
                if let listed, listed.category == "LOGIN", let username = listed.additionalInformation, !username.isEmpty {
                    return ExtensionActionResult(.paste(text: username))
                }
                return ExtensionActionResult(.paste(text: try await read("username")))
            case ActionID.copyOneTimePassword, ActionID.pasteOneTimePassword:
                let code = try await client.oneTimePassword(item: target.item, vault: target.vault, account: target.account)
                return Self.secret(code, paste: action == ActionID.pasteOneTimePassword, copied: "Copied One-Time Password")
            default:
                throw PrismExtensionError("1Password has no action “\(action)”.")
            }
        } catch OnePasswordError.missingField {
            let field = switch action {
            case ActionID.pasteUsername: "username"
            case ActionID.copyOneTimePassword, ActionID.pasteOneTimePassword: "one-time password"
            default: "password"
            }
            return ExtensionActionResult(.failed(message: "\(name) has no \(field)."))
        } catch let error as OnePasswordError {
            return ExtensionActionResult(.failed(message: OnePasswordRows.describe(error)))
        }
    }

    /// A password or code for Prism to paste or copy, kept out of clipboard
    /// histories.
    private static func secret(_ text: String, paste: Bool, copied: String) -> ExtensionActionResult {
        ExtensionActionResult(paste ? .paste(text: text, concealed: true) : .copy(text: text, message: copied, concealed: true))
    }

    /// Asks the 1Password app for a CLI session, as the list does, but
    /// with the launcher closed and long enough for the user to unlock
    /// 1Password and approve its prompt; the list then loads again.
    private func signIn(_ context: PrismContext) async -> ExtensionCommandResult {
        do {
            _ = try await client(context).accounts(timeout: OnePasswordClient.signInTimeout)
        } catch let error as OnePasswordError {
            return .failed(message: OnePasswordRows.describe(error))
        } catch {
            return .failed(message: error.localizedDescription)
        }
        await library.forget()
        await context.listChanged(CommandID.search)
        return .hud(message: "Signed In to 1Password")
    }
}
