import Foundation
import Security

/// The OAuth credential record saved by `agy` / Antigravity — stored in the
/// macOS login Keychain (`service = "gemini"`, `account = "antigravity"`,
/// wrapped with `go-keyring-base64:`) on current builds, or as plain JSON at
/// `~/.gemini/antigravity-cli/antigravity-oauth-token` on older builds.
struct AntigravityCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    /// When the record's access token stops being usable (RFC 3339 string).
    var expiry: Date?
    /// The sign-in's ID token, which names the OAuth client a refresh needs
    /// on legacy file credentials.
    var idToken: String? = nil
    /// Account email stored directly on Keychain credentials (`id_token_email`).
    var email: String? = nil
}

/// Parses both plain JSON files and `go-keyring-base64:` Keychain payloads:
/// `{ "token": { "access_token", "refresh_token", "expiry" }, "id_token",
/// "id_token_email" }`. Malformed payloads or a missing token object mean "not
/// signed in" rather than an error worth surfacing.
enum AntigravityCredentialFile {
    private static let goKeyringBase64Prefix = "go-keyring-base64:"

    static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    static func load(url: URL = defaultURL()) -> AntigravityCredentials? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> AntigravityCredentials? {
        let jsonData = unwrapPayload(data)
        guard let root = AgentUsageParse.jsonObject(jsonData),
              let token = root["token"] as? [String: Any],
              let accessToken = AgentUsageParse.string(token["access_token"])
        else { return nil }
        return AntigravityCredentials(
            accessToken: accessToken,
            refreshToken: AgentUsageParse.string(token["refresh_token"]),
            expiry: AgentUsageISO8601.date(fromAny: token["expiry"]),
            idToken: AgentUsageParse.string(root["id_token"]),
            email: AgentUsageParse.string(root["id_token_email"]))
    }

    /// Unwraps `/usr/bin/security -w` hex output (if present) and
    /// `go-keyring-base64:<b64>` into raw JSON bytes.
    private static func unwrapPayload(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return data }
        if !text.hasPrefix("{"), !text.hasPrefix(goKeyringBase64Prefix),
           let hexDecoded = decodeHex(text),
           let decodedText = String(data: hexDecoded, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !decodedText.isEmpty
        {
            text = decodedText
        }
        if text.hasPrefix(goKeyringBase64Prefix) {
            let encoded = String(text.dropFirst(goKeyringBase64Prefix.count))
            return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) ?? data
        }
        return Data(text.utf8)
    }

    private static func decodeHex(_ text: String) -> Data? {
        guard text.count >= 2, text.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Keychain access for Antigravity's `go-keyring` credential item.
enum AntigravityKeychain {
    static let service = "gemini"
    static let account = "antigravity"
    private static let securityToolURL = URL(fileURLWithPath: "/usr/bin/security")

    /// Reads through `/usr/bin/security` so reading `go-keyring`'s Keychain
    /// item never prompts the user for Prism access on every refresh.
    @Sendable
    static func readSecret(service: String, account: String) async -> Data? {
        let lookup = SecurityToolLookup(
            executableURL: securityToolURL,
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"])
        guard let data = await withTaskCancellationHandler(
            operation: { await lookup.run() },
            onCancel: { lookup.cancel() }
        ) else { return nil }
        return data.isEmpty ? nil : data
    }

    /// Attribute-only probe: never decrypts the secret, so it never prompts.
    @Sendable
    static func itemExists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// Turns Antigravity's saved credential (Keychain first, then the legacy file)
/// into a live access token. While the record's `expiry` is still fresh the
/// stored access token is used as-is; otherwise the refresh token is exchanged
/// once and the result is cached in memory keyed by the credential — the
/// stored record belongs to Antigravity and is never written back.
final class AntigravityAuthStore: @unchecked Sendable {
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// A token within this much of expiry is treated as already expired.
    static let expirySkew: TimeInterval = 60

    var credentialURL: URL
    var httpClient: any AgentUsageHTTPClient
    /// Returns the Keychain item's secret, or `nil` when absent.
    var readKeychainSecret: @Sendable (_ service: String, _ account: String) async -> Data? = AntigravityKeychain.readSecret
    /// Attribute-only probe: never decrypts the secret, so it never prompts.
    var keychainItemExists: @Sendable (_ service: String, _ account: String) -> Bool = AntigravityKeychain.itemExists
    /// Candidate OAuth clients to refresh with, read from the user's `agy` or
    /// Antigravity executable.
    var oauthClients: @Sendable (AntigravityCredentials) -> [AntigravityOAuthClient] = {
        AntigravityOAuthClientLocator.locateAll(idToken: $0.idToken)
    }
    var now: @Sendable () -> Date

    private let lock = NSLock()
    private var cached: (key: String, token: String, expiresAt: Date)?
    private var preferredClient: AntigravityOAuthClient?

    init(
        credentialURL: URL = AntigravityCredentialFile.defaultURL(),
        httpClient: any AgentUsageHTTPClient = URLSessionAgentUsageHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialURL = credentialURL
        self.httpClient = httpClient
        self.now = now
    }

    /// What `accessToken()` can produce.
    enum AccessTokenResult: Sendable {
        /// A live bearer token — from the saved record or a fresh exchange —
        /// plus the account email if the record carried one (`id_token_email`).
        case token(String, email: String? = nil)
        /// Credentials exist but could not be turned into a usable token.
        case failed(AgentUsageFailure)
        /// No usable credential in Keychain or on disk — the cloud path
        /// doesn't apply.
        case absent
    }

    func hasCredentials() -> Bool {
        keychainItemExists(AntigravityKeychain.service, AntigravityKeychain.account)
            || AntigravityCredentialFile.load(url: credentialURL) != nil
    }

    func accessToken() async -> AccessTokenResult {
        guard let credentials = await loadCredentials() else {
            if Task.isCancelled {
                return .failed(.network(localized("Cancelled.")))
            }
            return .absent
        }
        let key = credentials.refreshToken ?? credentials.accessToken
        if let token = lock.withLock({ () -> String? in
            guard let cached, cached.key == key,
                  cached.expiresAt > now().addingTimeInterval(Self.expirySkew)
            else { return nil }
            return cached.token
        }) {
            return .token(token, email: credentials.email)
        }
        if let expiry = credentials.expiry,
           expiry.timeIntervalSince(now()) > Self.expirySkew
        {
            return .token(credentials.accessToken, email: credentials.email)
        }
        guard let refreshToken = credentials.refreshToken else {
            return .failed(.authExpired(
                localized("Antigravity's saved sign-in has no refresh token. Run `agy` to sign in again.")))
        }
        let candidates = orderedClients(for: credentials)
        guard !candidates.isEmpty else {
            return .failed(.authExpired(
                localized("Antigravity's sign-in needs refreshing. Run `agy` or open Antigravity, then refresh.")))
        }
        return await refresh(refreshToken, clients: candidates, key: key, email: credentials.email)
    }

    private func loadCredentials() async -> AntigravityCredentials? {
        if let data = await readKeychainSecret(AntigravityKeychain.service, AntigravityKeychain.account),
           let credentials = AntigravityCredentialFile.parse(data)
        {
            return credentials
        }
        guard !Task.isCancelled else { return nil }
        return AntigravityCredentialFile.load(url: credentialURL)
    }

    private func orderedClients(for credentials: AntigravityCredentials) -> [AntigravityOAuthClient] {
        var clients = oauthClients(credentials)
        if let preferred = lock.withLock({ preferredClient }),
           let index = clients.firstIndex(of: preferred),
           index != 0
        {
            clients.remove(at: index)
            clients.insert(preferred, at: 0)
        }
        return clients
    }

    /// Exchange the refresh token for a short-lived access token and remember
    /// it for the rest of this process — refresh cycles are frequent enough
    /// that exchanging every time would needlessly age the credential.
    ///
    /// Current `agy` / Antigravity binaries compile in multiple OAuth clients
    /// and omit `id_token` from the Keychain record, so candidate pairs are
    /// tried until one succeeds or Google rejects the refresh token itself
    /// (`invalid_grant`).
    private func refresh(
        _ refreshToken: String,
        clients: [AntigravityOAuthClient],
        key: String,
        email: String?
    ) async -> AccessTokenResult {
        var rejectedClientIDs = Set<String>()

        for client in clients {
            guard !Task.isCancelled else {
                return .failed(.network(localized("Cancelled.")))
            }
            if rejectedClientIDs.contains(client.id) { continue }

            // Deterministic ordering keeps test assertions stable.
            let body = [
                "client_id": client.id,
                "client_secret": client.secret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ].sorted { $0.key < $1.key }
                .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
                .joined(separator: "&")
            let request = AgentUsageHTTPRequest(
                url: Self.tokenEndpoint,
                method: "POST",
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json",
                ],
                body: Data(body.utf8),
                timeout: 15)
            let response: AgentUsageHTTPResponse
            do {
                response = try await httpClient.send(request)
            } catch {
                if Task.isCancelled {
                    return .failed(.network(localized("Cancelled.")))
                }
                return .failed(.network(localized("Couldn't reach the sign-in endpoint. Check your connection.")))
            }
            if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
                let errorCode = AgentUsageParse.jsonObject(response.body)
                    .flatMap { AgentUsageParse.string($0["error"]) }
                if errorCode == "invalid_client" { continue }
                if errorCode == "unauthorized_client" {
                    rejectedClientIDs.insert(client.id)
                    continue
                }
                return .failed(.authExpired(
                    localized("Antigravity's saved sign-in expired. Run `agy` to sign in again.")))
            }
            guard response.isSuccess,
                  let root = AgentUsageParse.jsonObject(response.body),
                  let token = AgentUsageParse.string(root["access_token"])
            else {
                return .failed(.invalidResponse(
                    localized("The sign-in endpoint answered with data Prism couldn't read.")))
            }
            let expiresIn = AgentUsageParse.number(root["expires_in"]) ?? 3600
            lock.withLock {
                cached = (key: key, token: token, expiresAt: now().addingTimeInterval(expiresIn))
                preferredClient = client
            }
            return .token(token, email: email)
        }

        return .failed(.authExpired(
            localized("Antigravity's sign-in needs refreshing. Run `agy` or open Antigravity, then refresh.")))
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
