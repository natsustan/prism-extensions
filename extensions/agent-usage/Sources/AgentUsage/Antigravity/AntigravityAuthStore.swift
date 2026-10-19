import Foundation

/// The `agy` CLI's own credential record, written to
/// `~/.gemini/antigravity-cli/antigravity-oauth-token` when the user signs in.
/// Plain JSON — reading this file is how the CLI authenticates, so Prism never
/// needs the Keychain for Antigravity.
struct AntigravityCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    /// When the file's access token stops being usable (RFC 3339 string).
    var expiry: Date?
    /// The sign-in's ID token, which names the OAuth client a refresh needs.
    var idToken: String? = nil
}

/// File-only credential load: `{ "token": { "access_token", "refresh_token",
/// "expiry" } }`. Malformed JSON or a missing token object both mean "not
/// signed in" rather than an error worth surfacing.
enum AntigravityCredentialFile {
    static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    static func load(url: URL = defaultURL()) -> AntigravityCredentials? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let root = AgentUsageParse.jsonObject(data),
              let token = root["token"] as? [String: Any],
              let accessToken = AgentUsageParse.string(token["access_token"])
        else { return nil }
        return AntigravityCredentials(
            accessToken: accessToken,
            refreshToken: AgentUsageParse.string(token["refresh_token"]),
            expiry: AgentUsageISO8601.date(fromAny: token["expiry"]),
            idToken: AgentUsageParse.string(root["id_token"]))
    }
}

/// Turns the on-disk credential into a live access token. While the file's
/// `expiry` is still fresh the stored access token is used as-is; otherwise the
/// refresh token is exchanged once and the result is cached in memory keyed by
/// the credential — the file itself belongs to `agy` and is never written back.
final class AntigravityAuthStore: @unchecked Sendable {
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// A token within this much of expiry is treated as already expired.
    static let expirySkew: TimeInterval = 60

    var credentialURL: URL
    var httpClient: any AgentUsageHTTPClient
    /// The OAuth client to refresh with, read from the user's `agy`.
    var oauthClient: @Sendable (AntigravityCredentials) -> AntigravityOAuthClient? = {
        AntigravityOAuthClientLocator.locate(idToken: $0.idToken)
    }
    var now: @Sendable () -> Date

    private let lock = NSLock()
    private var cached: (key: String, token: String, expiresAt: Date)?

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
        /// A live bearer token — from the file or a fresh exchange.
        case token(String)
        /// Credentials exist but could not be turned into a usable token.
        case failed(AgentUsageFailure)
        /// No usable credential file — the cloud path doesn't apply.
        case absent
    }

    func hasCredentials() -> Bool {
        AntigravityCredentialFile.load(url: credentialURL) != nil
    }

    func accessToken() async -> AccessTokenResult {
        guard let credentials = AntigravityCredentialFile.load(url: credentialURL)
        else { return .absent }
        let key = credentials.refreshToken ?? credentials.accessToken
        if let token = lock.withLock({ () -> String? in
            guard let cached, cached.key == key,
                  cached.expiresAt > now().addingTimeInterval(Self.expirySkew)
            else { return nil }
            return cached.token
        }) {
            return .token(token)
        }
        if let expiry = credentials.expiry,
           expiry.timeIntervalSince(now()) > Self.expirySkew
        {
            return .token(credentials.accessToken)
        }
        guard let refreshToken = credentials.refreshToken else {
            return .failed(.authExpired(
                "Antigravity's saved sign-in has no refresh token. Run `agy` to sign in again."))
        }
        guard let client = oauthClient(credentials) else {
            return .failed(.authExpired(
                "Antigravity's sign-in needs refreshing. Run `agy` or open Antigravity, then refresh."))
        }
        return await refresh(refreshToken, client: client, key: key)
    }

    /// Exchange the refresh token for a short-lived access token and remember
    /// it for the rest of this process — refresh cycles are frequent enough
    /// that exchanging every time would needlessly age the credential.
    private func refresh(
        _ refreshToken: String, client: AntigravityOAuthClient, key: String
    ) async -> AccessTokenResult {
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
            return .failed(.network("Couldn't reach the sign-in endpoint. Check your connection."))
        }
        if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
            return .failed(.authExpired(
                "Antigravity's saved sign-in expired. Run `agy` to sign in again."))
        }
        guard response.isSuccess,
              let root = AgentUsageParse.jsonObject(response.body),
              let token = AgentUsageParse.string(root["access_token"])
        else {
            return .failed(.invalidResponse(
                "The sign-in endpoint answered with data Prism couldn't read."))
        }
        let expiresIn = AgentUsageParse.number(root["expires_in"]) ?? 3600
        lock.withLock {
            cached = (key: key, token: token, expiresAt: now().addingTimeInterval(expiresIn))
        }
        return .token(token)
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
