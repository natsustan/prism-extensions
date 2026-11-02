import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import OnePassword

typealias ActionID = OnePasswordRows.ActionID

private func host(_ cli: FakeCLI, clock: TestClock = TestClock(), preferences: [String: ExtensionValue] = [:]) async throws -> PrismTestHost {
    try await PrismTestHost(
        OnePassword(cli: cli, generator: .secure, now: { clock.now }),
        extensionID: "prism.1password",
        preferences: preferences
    )
}

@Suite("Search 1Password")
struct SearchTests {
    @Test("lists every item by title with its username, vault, and favorite star")
    func listsItems() async throws {
        let prism = try await host(Fixture.cli())
        let list = try await prism.list(OnePassword.CommandID.search)
        // Most recently changed first; Visa has no date, so it goes last.
        #expect(list.items.map(\.title) == ["Attic Wi-Fi", "Bike Lock", "GitHub", "Visa"])
        let github = try #require(list.items.first { $0.title == "GitHub" })
        #expect(github.id == "ACCOUNT1/personal/github")
        #expect(github.subtitle == "ada")
        #expect(github.icon?.symbol == "key")
        #expect(github.accessories.map(\.symbol) == ["star.fill", nil])
        #expect(github.accessories.last?.text == "Personal")
        #expect(github.keywords.contains("github.com") && github.keywords.contains("dev"))
        #expect(github.section == nil)
        #expect(list.items.first { $0.title == "Attic Wi-Fi" }?.subtitle == nil)
        #expect(list.error == nil && list.fetchedAt == nil)
    }

    @Test("a login pastes its password on Return and offers its username, one-time password, and links")
    func loginActions() async throws {
        let prism = try await host(Fixture.cli())
        let github = try #require(try await prism.list(OnePassword.CommandID.search).items.first { $0.title == "GitHub" })
        #expect(github.actions.map(\.id) == [
            ActionID.pastePassword, ActionID.copyPassword, ActionID.copyUsername, ActionID.pasteUsername,
            ActionID.copyOneTimePassword, ActionID.pasteOneTimePassword, ActionID.openWebsite, ActionID.view,
        ])
        // Raycast's shortcuts.
        #expect(github.actions.map { $0.shortcut?.description } == [
            "option+cmd+v", "option+cmd+c", "shift+cmd+c", "shift+cmd+v", "ctrl+cmd+c", "ctrl+cmd+v", "cmd+o", "shift+cmd+o",
        ])
        // Secrets are fetched when asked, with the launcher closed for 1Password's prompt.
        #expect(github.actions.filter(\.interactive).map(\.id) == [
            ActionID.pastePassword, ActionID.copyPassword, ActionID.pasteUsername,
            ActionID.copyOneTimePassword, ActionID.pasteOneTimePassword,
        ])
        #expect(github.actions.first { $0.id == ActionID.copyUsername }?.kind == .copy(text: "ada"))
        #expect(github.actions.first { $0.id == ActionID.openWebsite }?.kind == .open(url: URL(string: "https://github.com")!))
        #expect(github.actions.first { $0.id == ActionID.view }?.kind
            == .open(url: URL(string: "onepassword://view-item/?a=ACCOUNT1&v=personal&i=github")!))
    }

    @Test("with Paste on Return off, Return copies the password")
    func returnCopies() async throws {
        let prism = try await host(Fixture.cli(), preferences: ["returnPastes": .bool(false)])
        let github = try #require(try await prism.list(OnePassword.CommandID.search).items.first { $0.title == "GitHub" })
        #expect(github.actions.prefix(2).map(\.id) == [ActionID.copyPassword, ActionID.pastePassword])
    }

    @Test("an item without a password opens in 1Password on Return even when it has a website")
    func websiteWithoutPassword() {
        let note = OnePasswordItem(
            id: "router", title: "Router", category: "SECURE_NOTE", vault: .init(id: "personal", name: "Personal"),
            urls: [.init(href: "https://192.168.1.1", primary: true)]
        )
        let account = OnePasswordAccount(url: "my.1password.com", email: "ada@example.com", accountUUID: "ACCOUNT1")
        let actions = OnePasswordRows.actions(for: note, account: account, returnPastes: true).map(\.id)
        #expect(actions == [ActionID.view, ActionID.openWebsite])
    }

    @Test("items without a password open in 1Password on Return")
    func otherActions() async throws {
        let prism = try await host(Fixture.cli())
        let items = try await prism.list(OnePassword.CommandID.search).items
        #expect(items.first { $0.title == "Bike Lock" }?.actions.map(\.id) == [ActionID.view])
        #expect(items.first { $0.title == "Attic Wi-Fi" }?.actions.map(\.id) == [ActionID.view])
    }

    @Test("⌘P narrows to favorites, a category, or a vault")
    func filters() async throws {
        let prism = try await host(Fixture.cli())
        let list = try await prism.list(OnePassword.CommandID.search)
        #expect(list.filters.first?.id == "all")
        #expect(list.filters.suffix(2).map(\.title) == ["Personal", "Shared"])
        #expect(try await prism.list(OnePassword.CommandID.search, filter: "favorites").items.map(\.title) == ["GitHub"])
        #expect(try await prism.list(OnePassword.CommandID.search, filter: "category:CREDIT_CARD").items.map(\.title) == ["Visa"])
        #expect(try await prism.list(OnePassword.CommandID.search, filter: "vault:ACCOUNT1:shared").items.map(\.title) == ["Attic Wi-Fi"])
        let empty = try await prism.list(OnePassword.CommandID.search, filter: "category:SSH_KEY")
        #expect(empty.items.isEmpty && empty.emptyMessage?.title == "No SSH Keys")
        // Every load offers the same filters.
        #expect(empty.filters == list.filters)
    }

    @Test("several accounts are grouped by account, and their vaults are told apart")
    func accounts() async throws {
        let cli = Fixture.cli()
        cli.useTwoAccounts()
        cli.answer("item list @ACCOUNT2", json: Fixture.workItems)
        let prism = try await host(cli)
        let list = try await prism.list(OnePassword.CommandID.search)
        #expect(list.items.map(\.section) == Array(repeating: "ada@example.com", count: 4) + ["ada@work.example"])
        #expect(list.items.last?.id == "ACCOUNT2/private/jira")
        #expect(list.filters.last?.title == "Private (ada@work.example)")
    }

    @Test("an account that fails leaves the others, and says so")
    func partialFailure() async throws {
        let cli = Fixture.cli()
        cli.useTwoAccounts()
        cli.fail("item list @ACCOUNT2", stderr: "[ERROR] 2026/01/15 12:00:00 authorization prompt dismissed, please try again")
        let prism = try await host(cli)
        let list = try await prism.list(OnePassword.CommandID.search)
        #expect(list.items.count == 4)
        #expect(list.error == "Couldn’t load ada@work.example.")
        #expect(list.fetchedAt != nil)
    }

    @Test("a list opened again within half a minute is served from memory")
    func cache() async throws {
        let cli = Fixture.cli()
        let clock = TestClock()
        let prism = try await host(cli, clock: clock)
        _ = try await prism.list(OnePassword.CommandID.search)
        _ = try await prism.list(OnePassword.CommandID.search, filter: "favorites")
        #expect(cli.runs.filter { $0.starts(with: ["item", "list"]) }.count == 1)
        clock.advance(by: VaultLibrary.maxAge)
        _ = try await prism.list(OnePassword.CommandID.search)
        #expect(cli.runs.filter { $0.starts(with: ["item", "list"]) }.count == 2)
        // Each call names its account and asks for JSON.
        #expect(cli.runs.last == ["item", "list", "--account", "ACCOUNT1", "--format", "json"])
    }

    @Test("the CLI path preference is handed to the runner")
    func cliPath() async throws {
        final class PathRecorder: OnePasswordCLI, @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [String] = []
            var paths: Set<String> { lock.withLock { Set(recorded) } }
            func run(_ arguments: [String], executable: String, timeout: Duration) async throws -> CLIOutput? {
                lock.withLock { recorded.append(executable) }
                return nil
            }
        }
        let recorder = PathRecorder()
        let prism = try await PrismTestHost(
            OnePassword(cli: recorder, generator: .secure), preferences: ["cliPath": .string("  ~/bin/op ")]
        )
        _ = try await prism.list(OnePassword.CommandID.search)
        #expect(recorder.paths == ["~/bin/op"])
    }
}

@Suite("Setup and errors")
struct SetupTests {
    @Test("without op, the list offers to install it")
    func notInstalled() async throws {
        let cli = Fixture.cli()
        cli.installed = false
        let list = try await host(cli).list(OnePassword.CommandID.search)
        #expect(list.items.map(\.id) == ["setup-install"])
        #expect(list.items.first?.actions.map(\.id) == [ActionID.install, ActionID.copyInstallCommand])
        #expect(list.items.first?.actions.last?.kind == .copy(text: "brew install 1password-cli"))
    }

    @Test("without a CLI session, the list offers Sign In and asks 1Password nothing itself")
    func noSession() async throws {
        let cli = Fixture.cli()
        cli.fail("whoami", stderr: Fixture.noSession)
        let list = try await host(cli).list(OnePassword.CommandID.search)
        #expect(list.items.map(\.id) == ["setup-sign-in"])
        #expect(list.items.first?.actions.first?.interactive == true)
        let commands = cli.runs.map { $0.prefix { !$0.hasPrefix("--") }.joined(separator: " ") }
        #expect(!commands.contains("account get"))
    }

    @Test("an account the app hands a session for is named by its email")
    func appAccountEmail() async throws {
        let cli = Fixture.cli()
        cli.answer("account list", json: #"[{"url": "work.1password.com", "email": "ada@work.example", "account_uuid": "ACCOUNT2"}]"#)
        cli.answer("account get", json: #"{"id": "ACCOUNT2", "domain": "work"}"#)
        let accounts = try await OnePasswordClient(cli: cli, executable: "").appAccounts(timeout: .seconds(1))
        #expect(accounts.map(\.name) == ["ada@work.example"])
    }

    @Test("with several accounts, Sign In asks for each by name and keeps the ones allowed")
    func signInSeveralAccounts() async throws {
        let cli = Fixture.cli()
        cli.useTwoAccounts()
        cli.fail("account get", stderr: "[ERROR] 2026/01/15 12:00:00 multiple accounts found. Use the --account flag")
        cli.answer("account get @ACCOUNT1", json: #"{"id": "ACCOUNT1", "domain": "my"}"#)
        cli.fail("account get @ACCOUNT2", stderr: "[ERROR] 2026/01/15 12:00:00 authorization prompt dismissed, please try again")
        let accounts = try await OnePasswordClient(cli: cli, executable: "").appAccounts(timeout: .seconds(1))
        #expect(accounts.map(\.accountUUID) == ["ACCOUNT1"])
        #expect(cli.runs.filter { $0.starts(with: ["account", "get"]) }.map { $0.contains("--account") } == [true, true])
    }

    @Test("with several accounts, the list shows those the CLI has a session for")
    func someAccountsSignedIn() async throws {
        let cli = Fixture.cli()
        cli.useTwoAccounts()
        cli.fail("whoami", stderr: "[ERROR] 2026/01/15 12:00:00 multiple accounts found. Use the --account flag")
        cli.answer("whoami @ACCOUNT1", json: Fixture.whoami)
        cli.fail("whoami @ACCOUNT2", stderr: Fixture.noSession)
        let list = try await host(cli).list(OnePassword.CommandID.search)
        #expect(list.items.count == 4)
        #expect(list.items.allSatisfy { $0.section == nil })
    }

    @Test("with no account, the list says how to turn on the CLI integration")
    func integrationOff() async throws {
        let cli = Fixture.cli()
        cli.fail("whoami", stderr: "[ERROR] 2026/01/15 12:00:00 No accounts configured for use with 1Password CLI.")
        let list = try await host(cli).list(OnePassword.CommandID.search)
        #expect(list.items.map(\.id) == ["setup-integration"])
        #expect(list.items.first?.actions.first?.kind == .open(url: URL(string: "onepassword://settings")!))
    }

    @Test("a dismissed prompt or a slow 1Password makes Sign In say what to do")
    func signInFails() async throws {
        let cli = Fixture.cli()
        cli.fail("whoami", stderr: Fixture.noSession)
        cli.fail("account get", stderr: "[ERROR] 2026/01/15 12:00:00 authorization prompt dismissed, please try again")
        let prism = try await host(cli)
        #expect(try await prism.perform(ActionID.signIn, on: "setup-sign-in", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.failed(message: "Unlock 1Password and approve Prism, then try again.")))
        cli.timeOut("account get")
        #expect(try await prism.perform(ActionID.signIn, on: "setup-sign-in", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.failed(message: "1Password didn’t answer in time. Unlock it, then try again.")))
    }

    @Test("Sign In asks the 1Password app for a session, then reloads the list")
    func signIn() async throws {
        let cli = Fixture.cli()
        cli.fail("whoami", stderr: Fixture.noSession)
        cli.answer("account get", json: #"{"id": "ACCOUNT1", "domain": "my"}"#)
        let prism = try await host(cli)
        let result = try await prism.perform(ActionID.signIn, on: "setup-sign-in", in: OnePassword.CommandID.search)
        #expect(result == ExtensionActionResult(.hud(message: "Signed In to 1Password")))
        #expect(cli.runs.contains(["account", "get", "--format", "json"]))
        #expect(await prism.changedLists == [OnePassword.CommandID.search])
    }

    @Test("any other failure is shown as a message, without op's error prefix")
    func otherFailure() async throws {
        let cli = Fixture.cli()
        cli.fail("item list", stderr: "[ERROR] 2026/01/15 12:00:00 something unusual happened\nmore detail")
        let list = try await host(cli).list(OnePassword.CommandID.search)
        #expect(list.items.isEmpty)
        #expect(list.emptyMessage == ExtensionListMessage(
            title: "Couldn’t Load 1Password", message: "something unusual happened\nmore detail", symbol: "exclamationmark.triangle"
        ))
        cli.answer("item list", json: "not json")
        // A fresh host, so nothing is cached.
        let garbled = try await host(cli).list(OnePassword.CommandID.search)
        #expect(garbled.emptyMessage?.message == "1Password CLI answered in a way this extension doesn’t understand.")
    }
}

@Suite("Secrets")
struct SecretTests {
    @Test("Paste Password reads the password when asked and hands it to Prism as a secret")
    func pastePassword() async throws {
        let cli = Fixture.cli()
        cli.answer("read op://personal/github/password", text: "correct horse")
        let prism = try await host(cli)
        #expect(cli.runs.isEmpty)
        let paste = try await prism.perform(ActionID.pastePassword, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
        #expect(paste == ExtensionActionResult(.paste(text: "correct horse", concealed: true)))
        #expect(cli.runs.last == ["read", "op://personal/github/password", "--account", "ACCOUNT1", "--no-newline"])
        let copy = try await prism.perform(ActionID.copyPassword, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
        #expect(copy == ExtensionActionResult(.copy(text: "correct horse", message: "Copied Password", concealed: true)))
    }

    @Test("Paste Username reads the username and pastes it as plain text")
    func pasteUsername() async throws {
        let cli = Fixture.cli()
        cli.answer("read op://personal/github/username", text: "ada")
        let prism = try await host(cli)
        #expect(try await prism.perform(ActionID.pasteUsername, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.paste(text: "ada")))
    }

    @Test("Paste Username uses the username the list already showed")
    func pasteListedUsername() async throws {
        let cli = Fixture.cli()
        let prism = try await host(cli)
        _ = try await prism.list(OnePassword.CommandID.search)
        #expect(try await prism.perform(ActionID.pasteUsername, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.paste(text: "ada")))
        #expect(!cli.runs.contains { $0.first == "read" })
    }

    @Test("an item without a password says so by name")
    func missingPassword() async throws {
        let cli = Fixture.cli()
        cli.fail("read op://personal/github/password", stderr: "[ERROR] 2026/01/15 12:00:00 item 'GitHub' does not have a field 'password'")
        let prism = try await host(cli)
        _ = try await prism.list(OnePassword.CommandID.search)
        #expect(try await prism.perform(ActionID.copyPassword, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.failed(message: "“GitHub” has no password.")))
    }

    @Test("one-time passwords are read with --otp and handed over as secrets")
    func oneTimePassword() async throws {
        let cli = Fixture.cli()
        cli.answer("item get github --otp", text: "123456\n")
        let prism = try await host(cli)
        #expect(try await prism.perform(ActionID.copyOneTimePassword, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.copy(text: "123456", message: "Copied One-Time Password", concealed: true)))
        #expect(try await prism.perform(ActionID.pasteOneTimePassword, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.paste(text: "123456", concealed: true)))
    }

    @Test("an item without a one-time password says so by name once the list has loaded")
    func missingOneTimePassword() async throws {
        let cli = Fixture.cli()
        cli.fail("item get github --otp", stderr: "[ERROR] 2026/01/15 12:00:00 item does not contain a one-time password field")
        let prism = try await host(cli)
        _ = try await prism.list(OnePassword.CommandID.search)
        #expect(try await prism.perform(ActionID.copyOneTimePassword, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.failed(message: "“GitHub” has no one-time password.")))
    }

    @Test("a secret that can't be read fails with what to do")
    func lockedSecret() async throws {
        let cli = Fixture.cli()
        cli.timeOut("read op://personal/github/password")
        let prism = try await host(cli)
        #expect(try await prism.perform(ActionID.pastePassword, on: "ACCOUNT1/personal/github", in: OnePassword.CommandID.search)
            == ExtensionActionResult(.failed(message: "1Password didn’t answer in time. Unlock it, then try again.")))
    }
}

@Suite("Generate Password")
struct GenerateTests {
    @Test("offers each recipe with a fresh password that pastes and copies as a secret")
    func generate() async throws {
        let prism = try await host(FakeCLI())
        let list = try await prism.list(OnePassword.CommandID.generate)
        #expect(list.items.map(\.id) == ["random-20", "random-32", "letters-digits-20", "pin-6"])
        #expect(list.items.map(\.title.count) == [20, 32, 20, 6])
        let shown = list.items[0].title
        #expect(try await prism.perform(ActionID.paste, on: "random-20", in: OnePassword.CommandID.generate)
            == ExtensionActionResult(.paste(text: shown, concealed: true)))
        #expect(try await prism.perform(ActionID.copy, on: "random-20", in: OnePassword.CommandID.generate)
            == ExtensionActionResult(.copy(text: shown, message: "Copied Password", concealed: true)))
        // ⌘R makes new ones.
        #expect(try await prism.list(OnePassword.CommandID.generate).items[0].title != shown)
    }

    @Test("a password from before a restart asks for a new one")
    func afterRestart() async throws {
        let prism = try await host(FakeCLI())
        #expect(try await prism.perform(ActionID.paste, on: "random-20", in: OnePassword.CommandID.generate)
            == ExtensionActionResult(.failed(message: "Press ⌘R for a new password, then try again."), reload: true))
    }

    @Test("every password has a character from each of its sets and nothing else")
    func recipes() {
        for recipe in PasswordRecipe.allCases {
            for _ in 0..<200 {
                let password = PasswordGenerator.secure.password(recipe)
                #expect(password.count == recipe.length)
                for set in recipe.sets {
                    #expect(password.contains { set.contains($0) })
                }
                #expect(password.allSatisfy { character in recipe.sets.contains { $0.contains(character) } })
            }
        }
        let pin = PasswordGenerator.secure.password(.pin)
        #expect(pin.allSatisfy { $0.isNumber })
    }

    @Test("the characters follow the random source")
    func deterministic() {
        let zeros = PasswordGenerator { _ in 0 }
        #expect(zeros.password(.pin) == "000000")
        // Every set's first character, then shuffled by a source that always picks the first place.
        let password = zeros.password(.lettersAndDigits)
        #expect(Set(password) == ["a", "A", "2"])
    }
}

@Suite("CLI messages")
struct CLIMessageTests {
    @Test("op's errors map to what the user can do about them")
    func errors() {
        #expect(OnePasswordClient.error(from: "[ERROR] 2026/01/15 12:00:00 no account found for filter") == .noAccounts)
        #expect(OnePasswordClient.error(from: "No accounts configured for use with 1Password CLI.") == .noAccounts)
        #expect(OnePasswordClient.error(from: "[ERROR] 2026/01/15 12:00:00 error initializing client: connecting to desktop app: read: connection reset")
            == .notSignedIn)
        #expect(OnePasswordClient.error(from: "") == .failed("1Password CLI failed."))
        #expect(OnePasswordClient.message(from: "noise\n[ERROR] 2026/01/15 12:00:00 cause\n  fix it like this") == "cause\nfix it like this")
    }
}

@Suite("Running op")
struct CLIProcessTests {
    @Test("output far larger than a pipe's buffer comes back whole")
    func largeOutput() async throws {
        let output = try await InstalledOnePasswordCLI().run(
            ["-c", "head -c 1000000 /dev/zero; echo oops >&2; exit 3"], executable: "/bin/sh", timeout: .seconds(10)
        )
        #expect(output?.stdout.count == 1_000_000)
        #expect(output?.stderr == "oops\n")
        #expect(output?.status == 3)
    }

    @Test("a run past its timeout is stopped")
    func timeout() async throws {
        let started = ContinuousClock.now
        await #expect(throws: CLITimeout.self) {
            try await InstalledOnePasswordCLI().run(["-c", "sleep 30"], executable: "/bin/sh", timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("a path with no program behind it is not installed")
    func missing() async throws {
        #expect(try await InstalledOnePasswordCLI().run([], executable: "/nonexistent/op", timeout: .seconds(1)) == nil)
    }
}
