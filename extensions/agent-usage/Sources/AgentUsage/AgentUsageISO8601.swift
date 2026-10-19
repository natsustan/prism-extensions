import Foundation

/// Date parsing shared by the agent-usage parsers: provider payloads mix
/// ISO-8601 with and without fractional seconds, epoch numbers, and JWTs.
enum AgentUsageISO8601 {
    /// Formatters are built per call: `ISO8601DateFormatter` is not `Sendable`,
    /// and parsing happens only a handful of times per refresh.
    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    static func date(from raw: String?) -> Date? {
        guard let raw = raw?.trimmedCredentialValue, !raw.isEmpty else { return nil }
        return formatter(fractionalSeconds: true).date(from: raw)
            ?? formatter(fractionalSeconds: false).date(from: raw)
    }

    /// Accepts a string timestamp or a numeric epoch (seconds, or milliseconds
    /// when the value is too large to be seconds).
    static func date(fromAny value: Any?) -> Date? {
        if let string = value as? String { return date(from: string) }
        guard let number = (value as? NSNumber)?.doubleValue, number > 0 else { return nil }
        let seconds = number > 100_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    /// Seconds-precision UTC string, the form the Grok CLI writes.
    static func string(from date: Date) -> String {
        let formatter = formatter(fractionalSeconds: false)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// `exp` claim of a JWT, when the token is one and carries a numeric expiry.
    static func jwtExpiry(_ token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = (json["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
