import Foundation
import SQLite3

/// The Devin login stored on this Mac: an API key plus the API server it was
/// issued against (self-hosted Devin deployments set `api_server_url`).
struct DevinCredentials: Equatable, Sendable {
    var apiKey: String
    var apiServerURL: String?
}

enum DevinAuthError: Error, Equatable, Sendable {
    case notLoggedIn
}

/// Reads the credentials the Devin CLI writes to
/// `~/.local/share/devin/credentials.toml`, then the Devin app's own state
/// database as a fallback. Read-only: a rejected key surfaces as
/// "run `devin auth login`", never a rewrite from here.
struct DevinAuthStore: Sendable {
    static let defaultAPIServerURL = "https://server.codeium.com"

    var credentialsFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/devin/credentials.toml")
    var stateDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Application Support/Devin/User/globalStorage/state.vscdb")

    // MARK: - CLI credentials file

    func loadCredentialsFile() -> DevinCredentials? {
        guard let text = try? String(contentsOf: credentialsFileURL, encoding: .utf8),
              let apiKey = Self.readTomlString(text, key: "windsurf_api_key")
        else { return nil }
        return DevinCredentials(
            apiKey: apiKey,
            apiServerURL: Self.cleanAPIServerURL(Self.readTomlString(text, key: "api_server_url"))
        )
    }

    // MARK: - Devin app state database

    /// The app's VS Code-style storage: `ItemTable` holds `windsurfAuthStatus`
    /// as a JSON blob carrying `apiKey`.
    func loadAppCredentials() -> DevinCredentials? {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path),
              let raw = Self.readItem("windsurfAuthStatus", from: stateDatabaseURL),
              let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let apiKey = (json["apiKey"] as? String)?.trimmedCredentialValue,
              !apiKey.isEmpty
        else { return nil }
        return DevinCredentials(apiKey: apiKey, apiServerURL: nil)
    }

    /// One `ItemTable` value, read from the database opened read-only.
    static func readItem(_ key: String, from url: URL) -> String? {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database, "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1", -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_BLOB {
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            return String(decoding: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))), as: UTF8.self)
        }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    func effectiveAPIServerURL(_ credentials: DevinCredentials) -> String {
        credentials.apiServerURL ?? Self.defaultAPIServerURL
    }

    /// A usable override is https-prefixed and non-empty once trimmed of
    /// trailing slashes.
    static func cleanAPIServerURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmedCredentialValue,
              trimmed.hasPrefix("https://")
        else { return nil }
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Minimal TOML reader for the flat `key = "value"` shape the CLI writes.
    static func readTomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmedCredentialValue == key
            else { continue }

            var value = parts[1].trimmedCredentialValue
            guard !value.isEmpty else { return nil }

            if value.first == "\"" || value.first == "'" {
                return readQuoted(value)
            }
            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmedCredentialValue
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func readQuoted(_ value: String) -> String? {
        guard let quote = value.first else { return nil }
        var output = ""
        var previous: Character?
        for character in value.dropFirst() {
            if character == quote, previous != "\\" {
                let trimmed = output.trimmedCredentialValue
                return trimmed.isEmpty ? nil : trimmed
            }
            output.append(character)
            previous = character
        }
        return nil
    }
}
