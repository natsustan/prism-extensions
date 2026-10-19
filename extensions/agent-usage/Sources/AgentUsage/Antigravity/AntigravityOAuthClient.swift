import Foundation
import Synchronization

/// The OAuth client `agy` signs in with, which a refresh has to present.
/// Agent Usage ships no copy: the client ID comes from the saved sign-in's
/// ID token, and the secret from the user's own `agy` executable, where it is
/// compiled in (an installed app's secret identifies the app, not the user).
struct AntigravityOAuthClient: Equatable, Sendable {
    let id: String
    let secret: String
}

enum AntigravityOAuthClientLocator {
    /// Where `agy` installs itself, in the order they are tried.
    static func defaultExecutables(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
        ]
    }

    static func locate(
        idToken: String?,
        executables: [URL] = defaultExecutables()
    ) -> AntigravityOAuthClient? {
        guard let idToken, let id = clientID(fromIDToken: idToken) else { return nil }
        for executable in executables {
            if let secret = secrets(in: executable).first {
                return AntigravityOAuthClient(id: id, secret: secret)
            }
        }
        return nil
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return [] }
        let key = "\(executable.path)|\(attributes[.size] ?? 0)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let known = scanned.withLock({ $0[key] }) { return known }
        let found = scan(executable)
        scanned.withLock { $0[key] = found }
        return found
    }

    private static let scanned = Mutex<[String: [String]]>([:])
    private static let prefix = Data("GOCSPX-".utf8)

    private static func scan(_ executable: URL) -> [String] {
        guard let data = try? Data(contentsOf: executable, options: .alwaysMapped) else { return [] }
        var found: [String] = []
        var searchStart = data.startIndex
        while let range = data.range(of: prefix, in: searchStart..<data.endIndex) {
            var end = range.upperBound
            while end < data.endIndex, end - range.upperBound < 64, isSecretByte(data[end]) {
                end += 1
            }
            let length = end - range.upperBound
            if (20...40).contains(length) {
                let secret = String(decoding: data[range.lowerBound..<end], as: UTF8.self)
                if !found.contains(secret) { found.append(secret) }
            }
            searchStart = range.upperBound
        }
        return found
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
}
