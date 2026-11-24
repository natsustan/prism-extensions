import Foundation
import Synchronization

/// The OAuth client Antigravity (`agy` / desktop app) signs in with, which a
/// refresh has to present. Agent Usage ships no copy: the client ID comes from
/// the saved sign-in's ID token when present (or the user's installed binary),
/// and the secret from the user's own `agy` or Antigravity executable, where
/// they are compiled in (an installed app's secret identifies the app, not the
/// user).
struct AntigravityOAuthClient: Equatable, Hashable, Sendable {
    let id: String
    let secret: String
}

enum AntigravityOAuthClientLocator {
    private struct ScanResult: Sendable {
        var clientIDs: [String]
        var secrets: [String]
    }

    /// Google OAuth client secrets are always `GOCSPX-` followed by 28
    /// URL-safe base64 characters. Go binaries pack string literals without
    /// null terminators, so a contiguous run longer than 28 characters ran
    /// into the next literal and is trimmed back to 28.
    private static let googleSecretBodyLength = 28

    /// Where `agy` or the desktop app's language server installs itself, in
    /// the order they are tried.
    static func defaultExecutables(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"),
            home.appendingPathComponent("Applications/Antigravity.app/Contents/Resources/bin/language_server"),
            URL(fileURLWithPath: "/Applications/Gemini.app/Contents/Resources/bin/language_server"),
            home.appendingPathComponent("Applications/Gemini.app/Contents/Resources/bin/language_server"),
        ]
    }

    static func locate(
        idToken: String?,
        executables: [URL] = defaultExecutables()
    ) -> AntigravityOAuthClient? {
        locateAll(idToken: idToken, executables: executables).first
    }

    /// Candidate OAuth clients to try on a token refresh. When an ID token
    /// names the exact client ID, only that ID is paired with the secrets in
    /// the executable; when modern Keychain credentials omit the ID token,
    /// every client ID and secret compiled into the executable is paired.
    static func locateAll(
        idToken: String?,
        executables: [URL] = defaultExecutables()
    ) -> [AntigravityOAuthClient] {
        let tokenClientID = idToken.flatMap(clientID(fromIDToken:))
        for executable in executables {
            let result = scanResult(in: executable)
            guard !result.secrets.isEmpty else { continue }
            let ids = tokenClientID.map { [$0] } ?? result.clientIDs
            guard !ids.isEmpty else { continue }
            var clients: [AntigravityOAuthClient] = []
            for id in ids {
                for secret in result.secrets {
                    clients.append(AntigravityOAuthClient(id: id, secret: secret))
                }
            }
            return clients
        }
        return []
    }

    /// The client an ID token was issued to: `azp`, else a single `aud`.
    static func clientID(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = AgentUsageParse.jsonObject(data) else { return nil }
        let id = AgentUsageParse.string(claims["azp"]) ?? AgentUsageParse.string(claims["aud"])
        return id.flatMap { $0.hasSuffix(".apps.googleusercontent.com") ? $0 : nil }
    }

    /// Google client secrets (`GOCSPX-…`) compiled into an executable. The
    /// file is large, so each version is scanned once per process.
    static func secrets(in executable: URL) -> [String] {
        scanResult(in: executable).secrets
    }

    /// Google OAuth client IDs (`*.apps.googleusercontent.com`) compiled into
    /// an executable.
    static func clientIDs(in executable: URL) -> [String] {
        scanResult(in: executable).clientIDs
    }

    private static func scanResult(in executable: URL) -> ScanResult {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return ScanResult(clientIDs: [], secrets: [])
        }
        let key = "\(executable.path)|\(attributes[.size] ?? 0)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let known = scanned.withLock({ $0[key] }) { return known }
        let found = scan(executable)
        scanned.withLock { $0[key] = found }
        return found
    }

    private static let scanned = Mutex<[String: ScanResult]>([:])
    private static let secretPrefix = Data("GOCSPX-".utf8)
    private static let clientIDSuffix = Data(".apps.googleusercontent.com".utf8)

    /// Streamed chunk size when scanning executables so large (~200 MB) Go
    /// binaries never fault their whole image into resident memory.
    private static let scanChunkSize = 1_048_576
    private static let scanChunkOverlap = 128

    private static func scan(_ executable: URL) -> ScanResult {
        guard let handle = try? FileHandle(forReadingFrom: executable) else {
            return ScanResult(clientIDs: [], secrets: [])
        }
        defer { try? handle.close() }

        var clientIDs = Set<String>()
        var secrets: [String] = []
        var tail = Data()

        while let chunk = try? handle.read(upToCount: scanChunkSize), !chunk.isEmpty {
            let buffer = tail.isEmpty ? chunk : (tail + chunk)
            scanClientIDs(in: buffer, into: &clientIDs)
            scanSecrets(in: buffer, into: &secrets)
            if buffer.count > scanChunkOverlap {
                tail = Data(buffer.suffix(scanChunkOverlap))
            } else {
                tail = buffer
            }
        }
        return ScanResult(clientIDs: clientIDs.sorted(), secrets: secrets)
    }

    private static func scanSecrets(in data: Data, into found: inout [String]) {
        var searchStart = data.startIndex
        while let range = data.range(of: secretPrefix, in: searchStart..<data.endIndex) {
            var end = range.upperBound
            while end < data.endIndex, end - range.upperBound < 64, isSecretByte(data[end]) {
                end += 1
            }
            let length = end - range.upperBound
            if length >= googleSecretBodyLength {
                let exactEnd = range.upperBound + googleSecretBodyLength
                let secret = String(decoding: data[range.lowerBound..<exactEnd], as: UTF8.self)
                if !found.contains(secret) { found.append(secret) }
            } else if (20..<googleSecretBodyLength).contains(length) {
                let secret = String(decoding: data[range.lowerBound..<end], as: UTF8.self)
                if !found.contains(secret) { found.append(secret) }
            }
            searchStart = range.upperBound
        }
    }

    private static func scanClientIDs(in data: Data, into found: inout Set<String>) {
        var searchStart = data.startIndex
        while let range = data.range(of: clientIDSuffix, in: searchStart..<data.endIndex) {
            // Walk back across `<digits>-<alnum>` right before the suffix.
            var start = range.lowerBound
            let limit = max(data.startIndex, range.lowerBound - 64)
            while start > limit, isClientIDByte(data[start - 1]) {
                start -= 1
            }
            let prefix = String(decoding: data[start..<range.lowerBound], as: UTF8.self)
            if let cleaned = extractGoogleClientIDPrefix(prefix) {
                found.insert(cleaned + ".apps.googleusercontent.com")
            }
            searchStart = range.upperBound
        }
    }

    /// Extracts `<digits>-<alnum>` at the end of `raw` — Go string tables can
    /// place an ASCII word immediately before the numeric project ID.
    private static func extractGoogleClientIDPrefix(_ raw: String) -> String? {
        guard let dash = raw.lastIndex(of: "-") else { return nil }
        let suffix = raw[raw.index(after: dash)...]
        guard (10...48).contains(suffix.count),
              suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        let beforeDash = raw[..<dash]
        let digits = beforeDash.reversed().prefix(while: { $0.isASCII && $0.isNumber })
        guard (6...20).contains(digits.count) else { return nil }
        return String(digits.reversed()) + "-" + suffix
    }

    private static func isSecretByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }

    private static func isClientIDByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }
}
