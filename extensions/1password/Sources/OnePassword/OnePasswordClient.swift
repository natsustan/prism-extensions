import Foundation

/// Why the CLI could not answer, in the terms the list shows.
enum OnePasswordError: Error, Equatable {
    /// No `op` at the preference's path or in the usual folders.
    case notInstalled
    /// `op` knows no account: the desktop app integration is off.
    case noAccounts
    /// The user dismissed 1Password's prompt, or 1Password is locked or
    /// not running.
    case notSignedIn
    /// `op` waited longer than a request may, usually on 1Password's prompt.
    case timedOut
    /// The item has no field of the kind asked for.
    case missingField
    case failed(String)
}

/// The 1Password CLI's commands this extension uses, following the Raycast
/// 1Password extension's sign-in: `op whoami` answers at once when the CLI
/// already has a session, and `op account get` asks the 1Password app for
/// one, which shows its “Allow Prism to get CLI access” prompt.
struct OnePasswordClient: Sendable {
    /// How long a list load or an action may wait on `op`, inside the
    /// 15 seconds Prism gives a request.
    static let requestTimeout: Duration = .seconds(12)
    /// How long Sign In, and an action reading a secret, wait for the user
    /// to unlock 1Password and approve its prompt, inside the 5 minutes Prism
    /// gives an interactive action.
    static let signInTimeout: Duration = .seconds(120)

    let cli: any OnePasswordCLI
    let executable: String

    /// The account the CLI already has a session for, or nil. `whoami`
    /// only reads the CLI's own session, so it answers quickly and never
    /// asks the user anything. `account` names one of several accounts.
    func signedInAccount(_ account: String? = nil) async throws -> OnePasswordAccount? {
        do {
            let scope = account.map { ["--account", $0] } ?? []
            return try await decode(OnePasswordAccount.self, ["whoami"] + scope + ["--format", "json"], timeout: .seconds(2))
        } catch let error as OnePasswordError where error == .notInstalled || error == .noAccounts {
            throw error
        } catch {
            // With the app integration and no session, `whoami` fails
            // although the app would hand one out.
            return nil
        }
    }

    /// The accounts the CLI has a session for, or nil when none. With
    /// several accounts, `whoami` answers only for one named with
    /// `--account`, so each is asked on its own.
    func signedInAccounts() async throws -> [OnePasswordAccount]? {
        let listed = (try? await listedAccounts()) ?? []
        guard listed.count > 1 else { return try await signedInAccount().map { [$0] } }
        let signedIn = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            for (index, account) in listed.enumerated() {
                group.addTask { (index, try await signedInAccount(account.accountUUID) != nil) }
            }
            var signedIn = Set<Int>()
            for try await (index, isSignedIn) in group where isSignedIn { signedIn.insert(index) }
            return signedIn
        }
        let accounts = listed.indices.filter(signedIn.contains).map { listed[$0] }
        return accounts.isEmpty ? nil : accounts
    }

    /// Asks the 1Password app for a session: `op account get` shows
    /// 1Password's prompt when it needs one and waits for the user. With
    /// several accounts, each is asked for by name, and every account the
    /// user allows is used.
    func appAccounts(timeout: Duration) async throws -> [OnePasswordAccount] {
        // `account get` names no email, which sections and messages show.
        let listed = (try? await listedAccounts()) ?? []
        guard listed.count > 1 else {
            let account = try await authorize(nil, timeout: timeout)
            return [listed.first { $0.accountUUID == account.id }
                ?? OnePasswordAccount(url: "\(account.domain).1password.com", email: "", accountUUID: account.id)]
        }
        // One at a time, so 1Password shows one prompt after another.
        var allowed = [OnePasswordAccount]()
        var firstError: (any Error)?
        for account in listed {
            do {
                _ = try await authorize(account.accountUUID, timeout: timeout)
                allowed.append(account)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
            }
        }
        if allowed.isEmpty, let firstError { throw firstError }
        return allowed
    }

    private func authorize(_ account: String?, timeout: Duration) async throws -> AppAccount {
        let scope = account.map { ["--account", $0] } ?? []
        return try await decode(AppAccount.self, ["account", "get"] + scope + ["--format", "json"], timeout: timeout)
    }

    func accounts(timeout: Duration) async throws -> [OnePasswordAccount] {
        if let accounts = try await signedInAccounts() { return accounts }
        return try await appAccounts(timeout: timeout)
    }

    /// The accounts `op` knows, which asks the user nothing.
    private func listedAccounts() async throws -> [OnePasswordAccount] {
        try await decode([OnePasswordAccount].self, ["account", "list", "--format", "json"])
    }

    func items(in account: OnePasswordAccount) async throws -> [OnePasswordItem] {
        try await decode([OnePasswordItem].self, ["item", "list", "--account", account.accountUUID, "--format", "json"])
    }

    /// One field of an item, such as `password` or `username`, read with
    /// a secret reference.
    func read(_ field: String, item: String, vault: String, account: String) async throws -> String {
        let output = try await run(
            ["read", "op://\(vault)/\(item)/\(field)", "--account", account, "--no-newline"], timeout: Self.signInTimeout
        )
        let value = String(decoding: output, as: UTF8.self)
        guard !value.isEmpty else { throw OnePasswordError.missingField }
        return value
    }

    /// The item's current one-time password.
    func oneTimePassword(item: String, vault: String, account: String) async throws -> String {
        let output = try await run(["item", "get", item, "--vault", vault, "--account", account, "--otp"], timeout: Self.signInTimeout)
        let code = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw OnePasswordError.missingField }
        return code
    }

    /// `op account get`'s answer, which names the account by ID and domain.
    private struct AppAccount: Decodable {
        var id: String
        var domain: String
    }

    // MARK: - Running op

    private func decode<Value: Decodable>(
        _ type: Value.Type, _ arguments: [String], timeout: Duration = requestTimeout
    ) async throws -> Value {
        let data = try await run(arguments, timeout: timeout)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OnePasswordError.failed("1Password CLI answered in a way this extension doesn’t understand.")
        }
    }

    private func run(_ arguments: [String], timeout: Duration = requestTimeout) async throws -> Data {
        let output: CLIOutput?
        do {
            output = try await cli.run(arguments, executable: executable, timeout: timeout)
        } catch is CLITimeout {
            CLIFailures.record(arguments: arguments, stderr: "Timed out after \(timeout).")
            throw OnePasswordError.timedOut
        }
        guard let output else { throw OnePasswordError.notInstalled }
        guard output.status == 0 else {
            CLIFailures.record(arguments: arguments, stderr: output.stderr)
            throw Self.error(from: output.stderr)
        }
        return output.stdout
    }

    static func error(from stderr: String) -> OnePasswordError {
        let message = message(from: stderr)
        let lowered = message.lowercased()
        if lowered.contains("no accounts configured") || lowered.contains("no account found") {
            return .noAccounts
        }
        let signedOut = [
            "authorization prompt dismissed", "authorization timeout", "not currently signed in",
            "not signed in", "session expired", "connecting to desktop app", "cannot connect to 1password",
            "1password app is not running", "is locked",
        ]
        if signedOut.contains(where: lowered.contains) { return .notSignedIn }
        if lowered.contains("one-time password") || lowered.contains("totp") || lowered.contains("does not have a field") {
            return .missingField
        }
        return .failed(message.isEmpty ? "1Password CLI failed." : message)
    }

    /// `op` puts the cause on its first `[ERROR] <date> <time>` line and
    /// the steps to fix it after, so everything from that line on is kept,
    /// without the tags.
    static func message(from stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        let start = lines.firstIndex { $0.hasPrefix("[") } ?? 0
        return lines.dropFirst(start).map { line -> String in
            guard let match = line.firstMatch(of: /^\[\w+\]\s+\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2}:\d{2}\s+/) else { return line }
            return String(line[match.range.upperBound...])
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}

/// The last thing `op` said when it failed, for Copy Error Details on the
/// setup rows, as Raycast's extension offers. Arguments name items and
/// accounts but never hold a secret, and `op` never prints one on failure.
enum CLIFailures {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: String?

    static func record(arguments: [String], stderr: String) {
        let text = "op \(arguments.joined(separator: " "))\n\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        lock.withLock { last = text }
    }

    static var latest: String? {
        lock.withLock { last }
    }

    /// Forgets the last failure, so a setup row never offers one from an
    /// earlier load.
    static func reset() {
        lock.withLock { last = nil }
    }
}
