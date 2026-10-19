import Foundation

/// The GitHub CLI's login, used when no token is set in preferences. `gh`
/// keeps its token in the login Keychain and hands it out with
/// `gh auth token`, so asking `gh` reads it without a Keychain prompt and
/// follows `gh auth login` and `gh auth switch`.
struct GitHubCLI: Sendable {
    /// Where `gh` is installed, or nil. Prism starts extensions with a short
    /// `PATH`, so the folders of Homebrew, MacPorts, Nix, and version
    /// managers' shims (mise, asdf) are checked too.
    var executable: @Sendable () -> URL?
    /// The token `gh` holds for a host, or nil when it has none.
    var token: @Sendable (_ executable: URL, _ host: String) async -> String?
    /// When `gh`'s login last changed, or nil when it has none.
    var loginChanged: @Sendable () -> Date? = { nil }

    static let installed = GitHubCLI(executable: Self.findExecutable, token: Self.readToken, loginChanged: Self.hostsFileDate)
    static let none = GitHubCLI(executable: { nil }, token: { _, _ in nil })

    static let loginCommand = "gh auth login"

    static func host(of server: GitHubServer) -> String {
        server == .dotCom ? "github.com" : (server.webURL.host ?? "github.com")
    }

    // MARK: - gh

    /// How long `gh auth token` may take; it only reads the Keychain.
    static let timeout: Duration = .seconds(5)

    @Sendable
    static func findExecutable() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = path + [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims", "\(home)/.asdf/shims",
            "\(home)/.nix-profile/bin", "/run/current-system/sw/bin",
        ]
        return folders.lazy
            .map { URL(fileURLWithPath: $0).appending(path: "gh") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `gh auth login`, `switch`, and `logout` rewrite `hosts.yml`, which
    /// names each host's active account; the token itself is in the Keychain.
    /// Only the file's date is read, found the way `gh` finds its folder.
    @Sendable
    static func hostsFileDate() -> Date? {
        let environment = ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty }
        let folder = environment["GH_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0).appending(path: "gh") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/gh")
        let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appending(path: "hosts.yml").path)
        return attributes?[.modificationDate] as? Date
    }

    @Sendable
    static func readToken(executable: URL, host: String) async -> String? {
        await readToken(executable: executable, host: host, timeout: timeout)
    }

    static func readToken(executable: URL, host: String, timeout: Duration) async -> String? {
        let lookup = ProcessLookup(executableURL: executable, arguments: ["auth", "token", "--hostname", host])
        let data = await withTaskCancellationHandler {
            await withTaskGroup(of: Data?.self) { group in
                group.addTask { await lookup.run() }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    lookup.cancel()
                    return nil
                }
                let first = await group.next() ?? nil
                lookup.cancel()
                group.cancelAll()
                return first
            }
        } onCancel: {
            lookup.cancel()
        }
        let token = data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}

/// Runs one short-lived tool and returns its output when it succeeds.
/// Cancelling terminates it, so no `gh` outlives the request that started it.
final class ProcessLookup: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private var isCancelled = false

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    /// The tool's output when it exits successfully; nil on failure or
    /// cancellation.
    func run() async -> Data? {
        let status: Int32? = await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelled else {
                continuation.resume(returning: nil)
                return
            }
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
        // A token is far below the pipe buffer, so the tool never blocks on
        // its write and the whole output is readable once it has exited.
        guard status == 0, !isCancelledNow else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if process.isRunning { process.terminate() }
    }

    private var isCancelledNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

/// The `gh` token per host, kept instead of asking on every keystroke until
/// `gh`'s login changes, so `gh auth switch` or `gh auth logout` applies to
/// the next load even though the old token still works. A token GitHub
/// rejects is forgotten at once; a missing login is asked again after a few
/// seconds.
actor GitHubCLILogin {
    enum Lookup: Equatable, Sendable {
        case token(String)
        /// `gh` is installed but has no login for the host.
        case signedOut
        case notInstalled
    }

    static let retryAfter: TimeInterval = 5

    private let cli: GitHubCLI
    private let now: @Sendable () -> Date
    private var lookups: [String: (lookup: Lookup, at: Date, loginChanged: Date?)] = [:]

    init(cli: GitHubCLI, now: @escaping @Sendable () -> Date) {
        self.cli = cli
        self.now = now
    }

    func lookup(host: String) async -> Lookup {
        let loginChanged = cli.loginChanged()
        if let cached = lookups[host], cached.loginChanged == loginChanged {
            if case .token = cached.lookup { return cached.lookup }
            if now().timeIntervalSince(cached.at) < Self.retryAfter { return cached.lookup }
        }
        guard let executable = cli.executable() else {
            lookups[host] = (.notInstalled, now(), loginChanged)
            return .notInstalled
        }
        guard let token = await cli.token(executable, host) else {
            // A cancelled load says nothing about the login.
            if !Task.isCancelled { lookups[host] = (.signedOut, now(), loginChanged) }
            return .signedOut
        }
        lookups[host] = (.token(token), now(), loginChanged)
        return .token(token)
    }

    func forget(host: String) {
        lookups[host] = nil
    }
}
