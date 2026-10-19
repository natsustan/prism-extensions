import Foundation
import Darwin

@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// The xAI session the Grok CLI stores, resolved to one usable account.
struct GrokCredentials: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    /// Expiry recorded in the auth file, which the CLI keeps in step with the JWT.
    let expiresAt: Date?
    let clientID: String
    /// Scope key of the chosen entry, e.g. "https://auth.x.ai::<client-id>".
    let entryKey: String
    let issuerURL: URL?
    let principalType: String?
    let principalID: String?
    let email: String?
    let displayName: String?
    let teamID: String?
    let loginMethod: String?

    func replacing(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?
    ) -> GrokCredentials {
        GrokCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken ?? self.refreshToken,
            expiresAt: expiresAt ?? self.expiresAt,
            clientID: clientID,
            entryKey: entryKey,
            issuerURL: issuerURL,
            principalType: principalType,
            principalID: principalID,
            email: email,
            displayName: displayName,
            teamID: teamID,
            loginMethod: loginMethod
        )
    }
}

enum GrokAuthError: Error, Equatable, Sendable {
    case notLoggedIn
    case invalidAuth
}

/// Reads and refreshes the Grok CLI's credentials using the CLI's shared lock
/// file, so refresh-token rotation remains coordinated across processes.
struct GrokAuthStore: Sendable {
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"

    var authFilePath: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".grok/auth.json")
    var now: @Sendable () -> Date = Date.init

    // MARK: - Reading

    func loadCredentials() throws -> GrokCredentials {
        guard let data = try? Data(contentsOf: authFilePath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw GrokAuthError.notLoggedIn }

        var candidates: [Candidate] = []
        for (key, value) in root {
            guard let entry = value as? [String: Any],
                  let token = (entry["key"] as? String)?.trimmedCredentialValue, !token.isEmpty
            else { continue }
            candidates.append(Candidate(key: key, entry: entry, accessToken: token))
        }

        guard let chosen = preferred(candidates) else {
            // A readable file with no usable entry means the login is broken,
            // not that the user never signed in.
            throw root.isEmpty ? GrokAuthError.notLoggedIn : GrokAuthError.invalidAuth
        }
        return chosen.credentials()
    }

    func needsRefresh(_ credentials: GrokCredentials) -> Bool {
        credentials.expiresAt.map { $0 <= now() } ?? false
    }

    func acquireCredentialLock() async throws -> GrokCredentialFileLock {
        try await GrokCredentialFileLock.acquire(
            at: authFilePath.appendingPathExtension("lock"))
    }

    func persistRefreshed(
        _ response: GrokTokenRefreshResponse,
        for credentials: GrokCredentials
    ) throws -> GrokCredentials {
        guard let data = try? Data(contentsOf: authFilePath),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var entry = root[credentials.entryKey] as? [String: Any]
        else { throw GrokAuthError.invalidAuth }

        let expiresAt = response.expiresIn.map { now().addingTimeInterval($0) }
            ?? AgentUsageISO8601.jwtExpiry(response.accessToken)
            ?? now().addingTimeInterval(30 * 24 * 60 * 60)
        entry["key"] = response.accessToken
        if let refreshToken = response.refreshToken { entry["refresh_token"] = refreshToken }
        entry["expires_at"] = AgentUsageISO8601.string(from: expiresAt)
        root[credentials.entryKey] = entry

        guard JSONSerialization.isValidJSONObject(root) else { throw GrokAuthError.invalidAuth }
        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let attributes = try? FileManager.default.attributesOfItem(atPath: authFilePath.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let tempURL = authFilePath.deletingLastPathComponent().appendingPathComponent(
            ".\(authFilePath.lastPathComponent).prism-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try encoded.write(to: tempURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: tempURL.path)
        _ = try FileManager.default.replaceItemAt(authFilePath, withItemAt: tempURL)

        return credentials.replacing(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: expiresAt
        )
    }

    /// Prefer non-expired credentials across all scopes, then OIDC, newest expiry,
    /// and stable key order. Keep expired candidates as a last resort so the
    /// server can decide whether a saved token is still accepted.
    private func preferred(_ candidates: [Candidate]) -> Candidate? {
        let currentTime = now()
        return candidates.sorted { lhs, rhs in
            let lhsExpired = lhs.isExpired(at: currentTime) ? 1 : 0
            let rhsExpired = rhs.isExpired(at: currentTime) ? 1 : 0
            if lhsExpired != rhsExpired { return lhsExpired < rhsExpired }
            let lhsOIDC = lhs.key.hasPrefix(Self.oidcScopePrefix)
            let rhsOIDC = rhs.key.hasPrefix(Self.oidcScopePrefix)
            if lhsOIDC != rhsOIDC { return lhsOIDC }
            let lhsExpiry = lhs.expiresAt?.timeIntervalSince1970 ?? -Double.infinity
            let rhsExpiry = rhs.expiresAt?.timeIntervalSince1970 ?? -Double.infinity
            if lhsExpiry != rhsExpiry { return lhsExpiry > rhsExpiry }
            return lhs.key < rhs.key
        }.first
    }

    // MARK: - Candidate parsing

    private static let oidcScopePrefix = "https://auth.x.ai::"

    private struct Candidate {
        let key: String
        let entry: [String: Any]
        let accessToken: String

        var expiresAt: Date? {
            let recorded = AgentUsageISO8601.date(fromAny: entry["expires_at"])
                ?? AgentUsageISO8601.date(fromAny: entry["expires"])
            // Either source can rule out a token; a stale file must not extend
            // the JWT's lifetime. Opaque tokens still use the recorded expiry.
            return [recorded, AgentUsageISO8601.jwtExpiry(accessToken)].compactMap { $0 }.min()
        }

        var refreshToken: String? {
            ((entry["refresh_token"] as? String) ?? (entry["refresh"] as? String))?
                .trimmedCredentialValue
        }

        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return date >= expiresAt
        }

        func credentials() -> GrokCredentials {
            // The scope key is "<issuer>::<client id>"; only a key that really
            // carries that separator may donate a client id.
            let keySuffix = key.contains("::")
                ? key.components(separatedBy: "::").last?.trimmedCredentialValue
                : nil
            let clientID = (entry["oidc_client_id"] as? String)?.trimmedCredentialValue
                ?? keySuffix
                ?? GrokAuthStore.defaultClientID
            let first = (entry["first_name"] as? String)?.trimmedCredentialValue
            let last = (entry["last_name"] as? String)?.trimmedCredentialValue
            let name = [first, last].compactMap { $0 }.joined(separator: " ")
            let issuerText = (entry["oidc_issuer"] as? String)?.trimmedCredentialValue
                ?? (key.contains("::") ? key.components(separatedBy: "::").first : nil)
            let issuer = issuerText.flatMap(URL.init(string:))
            return GrokCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                clientID: clientID,
                entryKey: key,
                issuerURL: issuer,
                principalType: (entry["principal_type"] as? String)?.trimmedCredentialValue,
                principalID: (entry["principal_id"] as? String)?.trimmedCredentialValue,
                email: (entry["email"] as? String)?.trimmedCredentialValue,
                displayName: name.isEmpty ? nil : name,
                teamID: (entry["team_id"] as? String)?.trimmedCredentialValue,
                loginMethod: (entry["auth_mode"] as? String)?.trimmedCredentialValue
            )
        }
    }
}

final class GrokCredentialFileLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL) async throws -> GrokCredentialFileLock {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw GrokAuthError.invalidAuth }

        do {
            while systemFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw GrokAuthError.invalidAuth
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try recordHolder(on: descriptor)
            try Task.checkCancellation()
            return GrokCredentialFileLock(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Older Grok builds use this diagnostic heartbeat to avoid treating a
    /// live lock as stale. A refresh is bounded below their 60-second threshold,
    /// so one record on acquisition is sufficient.
    private static func recordHolder(on descriptor: Int32) throws {
        let text = "\(Darwin.getpid()):\(Int(Date().timeIntervalSince1970))"
        let bytes = Array(text.utf8)
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) == 0
        else { throw GrokAuthError.invalidAuth }

        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
            }
            guard count > 0 else { throw GrokAuthError.invalidAuth }
            offset += count
        }
        guard Darwin.fsync(descriptor) == 0 else { throw GrokAuthError.invalidAuth }
    }

    deinit {
        _ = systemFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
