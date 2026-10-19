import CryptoKit
import Foundation
import Security

/// The claude.ai login Claude Code stores for its own `/usage` view.
struct ClaudeCredentials: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
    /// OAuth scopes granted to the token; `nil` when the record predates them.
    let scopes: [String]?
    let subscriptionType: String?
    let rateLimitTier: String?

    /// Long-lived `claude setup-token` credentials are inference-only and are
    /// rejected by the usage endpoint.
    var canReadUsage: Bool {
        scopes.map { $0.contains("user:profile") } ?? true
    }
}

enum ClaudeAuthError: Error, Equatable, Sendable {
    /// No Keychain item or credentials file with a usable access token.
    case notLoggedIn
}

/// Reads Claude Code's OAuth record without ever writing to it. Claude Code
/// rotates its refresh token on every renewal, so a refresh from here would log
/// the CLI out; an expired token surfaces as "run `claude`" instead.
///
/// Sources, in the CLI's own order: the login Keychain item
/// `Claude Code-credentials`, then `.credentials.json` inside the secure-storage
/// directory. `$CLAUDE_SECURESTORAGE_CONFIG_DIR` selects that directory when
/// set, even to an empty string; otherwise `$CLAUDE_CONFIG_DIR` does.
struct ClaudeAuthStore: Sendable {
    static let keychainService = "Claude Code-credentials"
    static let configDirectoryKey = "CLAUDE_CONFIG_DIR"
    static let secureStorageDirectoryKey = "CLAUDE_SECURESTORAGE_CONFIG_DIR"

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Returns the Keychain item's secret, or `nil` when there is none. Must
    /// return promptly once the calling task is cancelled.
    var readKeychainSecret: @Sendable (_ service: String) async -> Data? = ClaudeKeychain.readSecret
    /// Attribute-only probe: never decrypts the secret, so it never prompts.
    var keychainItemExists: @Sendable (_ service: String) -> Bool = ClaudeKeychain.itemExists

    var configDirectory: URL {
        if let configDir = environment[Self.configDirectoryKey]?.trimmedCredentialValue, !configDir.isEmpty {
            return CodexAuthStore.expandingTilde(configDir, homeDirectory: homeDirectory)
        }
        return homeDirectory.appendingPathComponent(".claude")
    }

    /// Where Claude Code keeps `.credentials.json`; an empty override means the
    /// default `~/.claude`.
    var secureStorageDirectory: URL {
        guard let override = environment[Self.secureStorageDirectoryKey] else { return configDirectory }
        let directory = override.trimmedCredentialValue
        guard !directory.isEmpty else { return homeDirectory.appendingPathComponent(".claude") }
        return CodexAuthStore.expandingTilde(directory, homeDirectory: homeDirectory)
    }

    var credentialsFileURL: URL {
        secureStorageDirectory.appendingPathComponent(".credentials.json")
    }

    /// Claude Code suffixes the service with a hash of the secure-storage
    /// override when one is set (an empty one selects the bare name), otherwise
    /// of `$CLAUDE_CONFIG_DIR` when that is non-empty. The CLI hashes the raw,
    /// untrimmed value in Unicode NFC, so this does too.
    var keychainServiceName: String {
        let hashedValue: String
        if let override = environment[Self.secureStorageDirectoryKey] {
            guard !override.isEmpty else { return Self.keychainService }
            hashedValue = override
        } else if let configDir = environment[Self.configDirectoryKey], !configDir.isEmpty {
            hashedValue = configDir
        } else {
            return Self.keychainService
        }
        let digest = SHA256.hash(data: Data(hashedValue.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(Self.keychainService)-\(hex.prefix(8))"
    }

    func hasCredentials() -> Bool {
        keychainItemExists(keychainServiceName)
            || FileManager.default.fileExists(atPath: credentialsFileURL.path)
    }

    func loadCredentials() async throws -> ClaudeCredentials {
        if let data = await readKeychainSecret(keychainServiceName),
           let credentials = Self.parse(data) {
            return credentials
        }
        // A cancelled lookup is not proof the Keychain item is missing.
        try Task.checkCancellation()
        if let data = try? Data(contentsOf: credentialsFileURL),
           let credentials = Self.parse(data) {
            return credentials
        }
        throw ClaudeAuthError.notLoggedIn
    }

    /// `{ "claudeAiOauth": { "accessToken", "expiresAt" (ms), "scopes",
    /// "subscriptionType", "rateLimitTier" } }`.
    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = AgentUsageParse.jsonObject(data),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = AgentUsageParse.string(oauth["accessToken"])
        else { return nil }
        return ClaudeCredentials(
            accessToken: accessToken,
            expiresAt: AgentUsageISO8601.date(fromAny: oauth["expiresAt"]),
            scopes: (oauth["scopes"] as? [Any])?.compactMap { $0 as? String },
            subscriptionType: AgentUsageParse.string(oauth["subscriptionType"]),
            rateLimitTier: AgentUsageParse.string(oauth["rateLimitTier"])
        )
    }
}

/// Keychain access for Claude Code's item.
enum ClaudeKeychain {
    private static let securityToolURL = URL(fileURLWithPath: "/usr/bin/security")

    /// Claude Code writes its item with `/usr/bin/security`, which leaves that
    /// tool on the item's access list. Reading through the same tool keeps the
    /// user from seeing a Keychain prompt for Prism on every refresh.
    ///
    /// A locked Keychain can hold the tool on an unlock prompt indefinitely, so
    /// cancelling the calling task terminates it; the refresh deadline and
    /// disabling the provider both cancel.
    @Sendable
    static func readSecret(service: String) async -> Data? {
        let lookup = SecurityToolLookup(
            executableURL: securityToolURL,
            arguments: ["find-generic-password", "-s", service, "-w"])
        guard let data = await withTaskCancellationHandler(
            operation: { await lookup.run() },
            onCancel: { lookup.cancel() }
        ) else { return nil }
        return data.isEmpty ? nil : data
    }

    @Sendable
    static func itemExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// One `/usr/bin/security` run that another thread can stop. The lock orders
/// launch against cancellation, because terminating a process that has not
/// launched raises an Objective-C exception.
final class SecurityToolLookup: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private var isCancelled = false

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    /// The tool's output when it exits successfully; `nil` on failure or
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
        // The secret is far below the pipe buffer, so the tool never blocks
        // on its write and the whole output is readable once it has exited.
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
