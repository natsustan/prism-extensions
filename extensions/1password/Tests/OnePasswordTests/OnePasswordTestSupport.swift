import Foundation
@testable import OnePassword

/// A 1Password CLI that answers from canned output, keyed by the command's
/// first words, and records every call.
final class FakeCLI: OnePasswordCLI, @unchecked Sendable {
    enum Answer {
        case output(CLIOutput)
        case timeout
        /// Waits, as `op` does on 1Password's prompt, until `release`.
        case held(AsyncStream<CLIOutput>)
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private var calls: [[String]] = []
    var installed = true

    var runs: [[String]] {
        lock.withLock { calls }
    }

    /// Answers `op <command…>` (matched on the words before the first flag).
    func answer(_ command: String, json: String) {
        answer(command, text: json)
    }

    func answer(_ command: String, text: String) {
        set(command, .output(CLIOutput(stdout: Data(text.utf8))))
    }

    func fail(_ command: String, stderr: String) {
        set(command, .output(CLIOutput(status: 1, stderr: stderr)))
    }

    func timeOut(_ command: String) {
        set(command, .timeout)
    }

    /// `op <command>` waits until the returned closure answers it with JSON.
    func hold(_ command: String) -> @Sendable (String) -> Void {
        let (stream, continuation) = AsyncStream<CLIOutput>.makeStream()
        set(command, .held(stream))
        return { json in
            continuation.yield(CLIOutput(stdout: Data(json.utf8)))
            continuation.finish()
        }
    }

    private func set(_ command: String, _ answer: Answer) {
        lock.withLock { answers[command] = answer }
    }

    func run(_ arguments: [String], executable: String, timeout: Duration) async throws -> CLIOutput? {
        let (answer, installed) = lock.withLock { () -> (Answer?, Bool) in
            calls.append(arguments)
            let words = arguments.prefix { !$0.hasPrefix("--") }
            // `item get <id>` is keyed with its ID, and with `--otp` when asked
            // for one; any key can name an account as `@<uuid>`.
            var key = words.joined(separator: " ")
            if arguments.contains("--otp") { key += " --otp" }
            let account = arguments.firstIndex(of: "--account").map { " @" + arguments[$0 + 1] } ?? ""
            let short = words.prefix(2).joined(separator: " ")
            let answer = [key + account, key, short + account, short].lazy.compactMap { self.answers[$0] }.first
            return (answer, self.installed)
        }
        guard installed else { return nil }
        switch answer {
        case let .output(output): return output
        case .timeout: throw CLITimeout()
        case let .held(stream):
            for await output in stream { return output }
            throw CancellationError()
        case nil: return CLIOutput(status: 1, stderr: "[ERROR] 2026/01/15 12:00:00 unexpected command \(arguments)")
        }
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    /// Noon UTC, a day away from midnight in every time zone.
    init(_ date: Date = Date(timeIntervalSince1970: 1_768_478_400)) {
        self.date = date
    }

    var now: Date { lock.withLock { date } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { date += seconds }
    }
}

enum Fixture {
    static let whoami = """
    {"url": "my.1password.com", "email": "ada@example.com", "user_uuid": "USER1", "account_uuid": "ACCOUNT1"}
    """
    static let noSession = "[ERROR] 2026/01/15 12:00:00 account is not signed in"
    static let accounts = """
    [{"url": "my.1password.com", "email": "ada@example.com", "user_uuid": "USER1", "account_uuid": "ACCOUNT1"}]
    """
    static let twoAccounts = """
    [{"url": "my.1password.com", "email": "ada@example.com", "user_uuid": "USER1", "account_uuid": "ACCOUNT1"},
     {"url": "work.1password.com", "email": "ada@work.example", "user_uuid": "USER2", "account_uuid": "ACCOUNT2"}]
    """
    static let items = """
    [
      {"id": "github", "title": "GitHub", "version": 3, "vault": {"id": "personal", "name": "Personal"},
       "category": "LOGIN", "additional_information": "ada", "favorite": true, "tags": ["dev"],
       "urls": [{"label": "website", "href": "https://github.com/login"}, {"primary": true, "href": "https://github.com"}],
       "created_at": "2025-01-01T00:00:00Z", "updated_at": "2025-06-01T00:00:00Z"},
      {"id": "wifi", "title": "Attic Wi-Fi", "vault": {"id": "shared", "name": "Shared"},
       "category": "WIRELESS_ROUTER", "updated_at": "2026-01-10T09:00:00Z"},
      {"id": "note", "title": "Bike Lock", "vault": {"id": "personal", "name": "Personal"},
       "category": "SECURE_NOTE", "additional_information": "Combination", "updated_at": "2025-12-01T08:30:00.123Z"},
      {"id": "card", "title": "Visa", "vault": {"id": "personal", "name": "Personal"},
       "category": "CREDIT_CARD", "additional_information": "4111 ****"}
    ]
    """
    static let workItems = """
    [{"id": "jira", "title": "Jira", "vault": {"id": "private", "name": "Private"}, "category": "LOGIN", "additional_information": "ada.l"}]
    """
    /// A CLI with one signed-in account and its items.
    static func cli() -> FakeCLI {
        let cli = FakeCLI()
        cli.answer("whoami", json: whoami)
        cli.answer("item list", json: items)
        return cli
    }
}

extension FakeCLI {
    /// 1Password has two accounts; `whoami` names only the first.
    func useTwoAccounts() {
        answer("account list", json: Fixture.twoAccounts)
    }
}
