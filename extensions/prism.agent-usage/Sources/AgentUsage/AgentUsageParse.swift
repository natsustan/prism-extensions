import Foundation

/// Behavior-free parsing chores shared by the providers whose payloads are
/// decoded with `JSONSerialization` (numbers that arrive as strings, booleans
/// that arrive as `0`/`1`, proto3-omitted fields). Consolidated so a new
/// provider reuses one implementation instead of copying it.
enum AgentUsageParse {
    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Permissive numeric read: JSON numbers and numeric strings, but never
    /// booleans (`JSONSerialization` bridges them through `NSNumber`, so the
    /// Core Foundation check keeps `true` from becoming `1`).
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String {
            let parsed = Double(string.trimmedCredentialValue)
            return parsed?.isFinite == true ? parsed : nil
        }
        return nil
    }

    /// Permissive boolean read: real `Bool`s, numeric `NSNumber`s, and the
    /// strings "true"/"1"/"false"/"0". `nil` for anything else, so an absent
    /// field stays distinguishable from an explicit false.
    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmedCredentialValue.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let trimmed = (value as? String)?.trimmedCredentialValue, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}
