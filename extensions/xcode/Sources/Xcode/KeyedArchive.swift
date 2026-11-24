import Foundation

/// Reads `NSKeyedArchiver` binary plists directly through `PropertyListSerialization`.
///
/// Using the plist object table instead of `NSKeyedUnarchiver` avoids failing
/// on private Apple classes such as `IDEEditorInteractivityHistoryItem` and
/// handles macOS `.sfl2`/`.sfl3`/`.sfl4` shared file lists uniformly.
struct KeyedArchive {
    private let objects: [Any]
    private let top: [String: Any]

    private static let uidKey = "__PrismUID__"

    init?(data: Data) {
        // Binary plists decode `CFKeyedArchiverUID` as an opaque CF type.
        // Round-tripping through XML exposes every UID as `<key>CF$UID</key>`,
        // and renaming the tag keeps `PropertyListSerialization` from turning
        // it back into an opaque `CFKeyedArchiverUID` on reload.
        guard let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let xmlData = try? PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0),
              let xml = String(data: xmlData, encoding: .utf8) else {
            return nil
        }
        let rewritten = xml.replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>\(Self.uidKey)</key>")
        guard let rewrittenData = rewritten.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: rewrittenData, format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any],
              let top = root["$top"] as? [String: Any] else {
            return nil
        }
        self.objects = objects
        self.top = top
    }

    /// Resolves a top-level key from `$top`.
    func topObject(forKey key: String) -> Any? {
        guard let ref = top[key] else { return nil }
        return dereference(ref)
    }

    /// Follows a `CF$UID` reference (or returns the value as is when inline).
    func dereference(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let uid = uidIndex(value) {
            guard uid >= 0, uid < objects.count else { return nil }
            let target = objects[uid]
            if let marker = target as? String, marker == "$null" {
                return nil
            }
            return target
        }
        return value
    }

    /// Decodes an archived `NSArray` (`NS.objects`) into its resolved elements.
    func array(_ value: Any?) -> [Any]? {
        guard let dict = dereference(value) as? [String: Any],
              let raw = dict["NS.objects"] as? [Any] else {
            return nil
        }
        return raw.compactMap { dereference($0) }
    }

    /// Decodes an archived `NSDictionary` (`NS.keys` / `NS.objects`) into a
    /// string-keyed map with resolved values.
    func dictionary(_ value: Any?) -> [String: Any]? {
        guard let dict = dereference(value) as? [String: Any] else { return nil }
        if let keys = dict["NS.keys"] as? [Any],
           let values = dict["NS.objects"] as? [Any],
           keys.count == values.count {
            var result: [String: Any] = [:]
            result.reserveCapacity(keys.count)
            for (rawKey, rawValue) in zip(keys, values) {
                guard let key = dereference(rawKey) as? String,
                      let resolved = dereference(rawValue) else {
                    continue
                }
                result[key] = resolved
            }
            return result
        }
        return nil
    }

    /// Reads a property from an archived keyed object dictionary (such as
    /// `IDEEditorInteractivityHistoryItem`).
    func property(_ key: String, in object: [String: Any]) -> Any? {
        dereference(object[key])
    }

    /// Decodes raw `Data` or an archived `NSMutableData` (`NS.data`).
    func data(_ value: Any?) -> Data? {
        if let raw = dereference(value) as? Data {
            return raw
        }
        if let dict = dereference(value) as? [String: Any],
           let raw = dict["NS.data"] as? Data {
            return raw
        }
        return nil
    }

    /// Decodes an archived `NSDate` (`NS.time` seconds since 2001-01-01).
    func date(_ value: Any?) -> Date? {
        if let date = dereference(value) as? Date {
            return date
        }
        guard let dict = dereference(value) as? [String: Any] else { return nil }
        if let seconds = dict["NS.time"] as? Double {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        if let seconds = dict["NS.time"] as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
        }
        return nil
    }

    /// Decodes an archived `NSURL` (`NS.relative` with optional `NS.base`).
    func url(_ value: Any?) -> URL? {
        if let url = dereference(value) as? URL {
            return url
        }
        guard let dict = dereference(value) as? [String: Any],
              let relative = property("NS.relative", in: dict) as? String else {
            return nil
        }
        if let base = url(dict["NS.base"]) {
            return URL(string: relative, relativeTo: base)?.absoluteURL
        }
        return URL(string: relative)
    }

    private func uidIndex(_ value: Any) -> Int? {
        guard let dict = value as? [String: Any], dict.count == 1,
              let number = (dict[Self.uidKey] ?? dict["CF$UID"]) as? NSNumber else {
            return nil
        }
        return number.intValue
    }
}
