import Foundation

/// A normalized VNC / Screen Sharing destination (`vnc://[user@]host[:port]`).
struct HostAddress: Codable, Hashable, Sendable {
    static let defaultPort = 5900

    let host: String
    let port: Int
    let username: String?

    init(host: String, port: Int = defaultPort, username: String? = nil) {
        self.host = Self.normalizeHost(host)
        self.port = (1...65535).contains(port) ? port : Self.defaultPort
        let trimmedUser = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = trimmedUser?.isEmpty == false ? trimmedUser : nil
    }

    /// Stable item identifier across reloads and versions.
    var stableID: String {
        let userPrefix = username.map { "\($0.lowercased())@" } ?? ""
        let formattedHost = isIPv6 ? "[\(host.lowercased())]" : host.lowercased()
        return "host:\(userPrefix)\(formattedHost):\(port)"
    }

    /// Display form shown in subtitles and copied by "Copy Address":
    /// omits the default 5900 port so common local Macs stay concise.
    var displayAddress: String {
        let formattedHost = isIPv6 ? "[\(host)]" : host
        let userPrefix = username.map { "\($0)@" } ?? ""
        if port == Self.defaultPort {
            return "\(userPrefix)\(formattedHost)"
        }
        return "\(userPrefix)\(formattedHost):\(port)"
    }

    /// The `vnc://` URL passed to macOS Screen Sharing.
    var vncURL: URL? {
        var components = URLComponents()
        components.scheme = "vnc"
        components.user = username
        if isIPv6 {
            guard HostAddressParser.isValidIPv6(host) else { return nil }
            let escaped = host.replacingOccurrences(of: "%", with: "%25")
            components.percentEncodedHost = "[\(escaped)]"
        } else {
            components.host = host
        }
        if port != Self.defaultPort {
            components.port = port
        }
        return components.url
    }

    var isIPv6: Bool {
        host.contains(":")
    }

    static func normalizeHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }
}

/// Parses free-form host input (search box or Saved Hosts preference) into a
/// `HostAddress` and optional display name.
enum HostAddressParser {
    /// Parses a single address such as `mac-mini.local`, `192.168.1.20:5901`,
    /// `alice@100.64.0.12`, `[fe80::1]:5900`, or `vnc://mac-studio.local`.
    /// Returns `nil` for ordinary search phrases that aren't host addresses.
    static func parseAddress(_ raw: String, allowBareLabel: Bool = false) -> HostAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace) else {
            return nil
        }

        // Explicit `vnc://` URL: trust URLComponents parsing.
        if trimmed.lowercased().hasPrefix("vnc://") {
            guard let components = URLComponents(string: trimmed),
                  let host = components.host, !host.isEmpty else {
                return nil
            }
            let port = components.port ?? HostAddress.defaultPort
            guard (1...65535).contains(port) else { return nil }
            let normalized = HostAddress.normalizeHost(host)
            guard isValidHost(normalized, allowBareLabel: true) else { return nil }
            return HostAddress(host: normalized, port: port, username: components.user)
        }

        // Reject other URL schemes like `http://` or `ssh://`.
        if trimmed.contains("://") {
            return nil
        }

        var remainder = trimmed
        var username: String?
        if let atIndex = remainder.lastIndex(of: "@") {
            let userPart = String(remainder[..<atIndex])
            let hostPart = String(remainder[remainder.index(after: atIndex)...])
            guard !userPart.isEmpty, !hostPart.isEmpty, !userPart.contains("/") else {
                return nil
            }
            username = userPart
            remainder = hostPart
        }

        // Reject paths or query fragments in plain host input.
        guard !remainder.contains("/"), !remainder.contains("?"), !remainder.contains("#") else {
            return nil
        }

        let host: String
        var port = HostAddress.defaultPort

        if remainder.hasPrefix("[") {
            // Bracketed IPv6, with optional `:port`.
            guard let closeIndex = remainder.firstIndex(of: "]") else { return nil }
            let inner = String(remainder[remainder.index(after: remainder.startIndex)..<closeIndex])
            let after = remainder[remainder.index(after: closeIndex)...]
            if after.isEmpty {
                host = inner
            } else if after.hasPrefix(":") {
                guard let parsedPort = Int(after.dropFirst()), (1...65535).contains(parsedPort) else {
                    return nil
                }
                host = inner
                port = parsedPort
            } else {
                return nil
            }
            guard isValidIPv6(host) else { return nil }
            return HostAddress(host: host, port: port, username: username)
        }

        let colonCount = remainder.filter { $0 == ":" }.count
        if colonCount == 1, let colonIndex = remainder.firstIndex(of: ":") {
            let hostPart = String(remainder[..<colonIndex])
            let portPart = String(remainder[remainder.index(after: colonIndex)...])
            guard !hostPart.isEmpty, let parsedPort = Int(portPart), (1...65535).contains(parsedPort) else {
                return nil
            }
            host = HostAddress.normalizeHost(hostPart)
            port = parsedPort
            guard isValidHost(host, allowBareLabel: true) else { return nil }
            return HostAddress(host: host, port: port, username: username)
        } else if colonCount > 1 {
            // Bare IPv6 address without brackets.
            guard isValidIPv6(remainder) else { return nil }
            return HostAddress(host: remainder, port: HostAddress.defaultPort, username: username)
        }

        host = HostAddress.normalizeHost(remainder)
        // A bare label with a username (e.g. `alice@studio`) is clearly a host.
        let bareAllowed = allowBareLabel || username != nil
        guard isValidHost(host, allowBareLabel: bareAllowed) else { return nil }
        return HostAddress(host: host, port: port, username: username)
    }

    /// Parses the `savedHosts` preference text into entries.
    /// Entries are separated by newlines or commas; each may be `Name = address`
    /// or just `address`.
    static func parseSavedHosts(_ raw: String) -> [SavedHostEntry] {
        let chunks = raw.split { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == ";" }
        var seen = Set<String>()
        var results = [SavedHostEntry]()

        for chunk in chunks {
            let entry = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let name: String?
            let addressText: String
            if let equals = entry.firstIndex(of: "=") {
                let left = entry[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                let right = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty, !right.isEmpty {
                    name = left
                    addressText = right
                } else {
                    name = nil
                    addressText = entry
                }
            } else {
                name = nil
                addressText = entry
            }

            guard let address = parseAddress(addressText, allowBareLabel: true) else {
                continue
            }
            guard seen.insert(address.stableID).inserted else { continue }
            results.append(SavedHostEntry(name: name, address: address))
        }

        return results
    }

    private static func isValidHost(_ host: String, allowBareLabel: Bool) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if isValidIPv4(host) || isValidIPv6(host) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        if labels.count == 1 && !allowBareLabel {
            return false
        }
        // Reject all-numeric dotted strings that weren't valid IPv4 (e.g. `999.999`).
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return false
        }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard let first = label.first, let last = label.last,
                  first.isASCII && (first.isLetter || first.isNumber),
                  last.isASCII && (last.isLetter || last.isNumber) else {
                return false
            }
            for ch in label {
                guard ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-") else {
                    return false
                }
            }
        }
        return true
    }

    private static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else {
                return false
            }
            return (0...255).contains(value)
        }
    }

    static func isValidIPv6(_ text: String) -> Bool {
        guard text.contains(":"), !text.isEmpty else { return false }
        let core: String
        if let percentIndex = text.firstIndex(of: "%") {
            core = String(text[..<percentIndex])
            let zone = text[text.index(after: percentIndex)...]
            // RFC 6874: ZoneID consists of non-empty unreserved ASCII characters.
            guard !zone.isEmpty, zone.allSatisfy({ ch in
                ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "." || ch == "_" || ch == "~")
            }) else {
                return false
            }
        } else {
            core = text
        }
        var addr = in6_addr()
        return core.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }
}

/// A host discovered on the local network via Bonjour (`_rfb._tcp.`).
struct DiscoveredHost: Codable, Equatable, Sendable {
    let serviceName: String
    let address: HostAddress
    /// Hardware model from `_device-info._tcp.` TXT record, e.g. `Mac16,10` or `MacBookPro18,1`.
    let model: String?
    let lastSeenAt: Date

    var id: String { address.stableID }
}

/// A host explicitly listed in the `savedHosts` preference.
struct SavedHostEntry: Equatable, Sendable {
    let name: String?
    let address: HostAddress

    var id: String { address.stableID }
    var displayName: String { name ?? address.displayAddress }
}

/// Persisted user state for a host that was pinned or recently connected.
struct StoredHostRecord: Codable, Equatable, Sendable {
    var name: String
    var address: HostAddress
    var model: String?
    var lastConnectedAt: Date?
    var isPinned: Bool

    var id: String { address.stableID }
}

/// Merged representation of one row in the Screen Sharing list.
struct ResolvedHost: Equatable, Sendable {
    let id: String
    let name: String
    let address: HostAddress
    let model: String?
    let isLocalOnline: Bool
    let isLocalCached: Bool
    let isSaved: Bool
    let isPinned: Bool
    let lastConnectedAt: Date?
    let isQuickConnect: Bool

    var isLocal: Bool { isLocalOnline || isLocalCached }
    var isRecent: Bool { lastConnectedAt != nil }
}

/// Maps Apple hardware model identifiers (from `_device-info._tcp.`) and host
/// names to fitting SF Symbols.
enum DeviceModelIcon {
    static func symbol(for model: String?, name: String) -> String {
        let lowerModel = (model ?? "").lowercased()
        let lowerName = name.lowercased()

        if lowerModel.hasPrefix("macbook") || lowerName.contains("macbook") {
            return "laptopcomputer"
        }
        if lowerModel.contains("macmini") || lowerName.contains("mac mini") {
            return "macmini"
        }
        if lowerModel.contains("macstudio") || lowerName.contains("mac studio") {
            return "macstudio"
        }
        if lowerModel.contains("macpro") || lowerName.contains("mac pro") {
            return "macpro.gen3"
        }
        if lowerModel.contains("imac") || lowerName.contains("imac") {
            return "desktopcomputer"
        }
        return "display"
    }
}
