import Foundation
import Synchronization

/// Where the Z.ai provider reads the key the user saved in Prism.
protocol ZAISecretStore: Sendable {
    func apiKey() throws -> String?
    func setAPIKey(_ value: String) throws
}

/// The extension's `zaiKey` secret, mirrored for the provider, which reads it
/// off the main actor. The extension refreshes it from the Keychain-backed
/// preference whenever preferences change; a failed Keychain read is kept as
/// a failure so the provider does not fall back to another account's key.
final class ZAIKeyMirror: ZAISecretStore {
    enum Value: Sendable {
        case key(String?)
        case unreadable
    }

    struct Unreadable: Error {}

    private let value = Mutex<Value>(.key(nil))

    func update(_ newValue: Value) {
        value.withLock { $0 = newValue }
    }

    func apiKey() throws -> String? {
        switch value.withLock({ $0 }) {
        case let .key(key): return key
        case .unreadable: throw Unreadable()
        }
    }

    /// Saving goes through the extension's preference; this only mirrors it.
    func setAPIKey(_ value: String) throws {
        update(.key(value.trimmedCredentialValue.nilIfEmpty))
    }
}
