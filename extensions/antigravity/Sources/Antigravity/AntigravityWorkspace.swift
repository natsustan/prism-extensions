import Foundation

/// Antigravity desktop release channels, each with its own bundle identifier,
/// Electron `userData` folder under `~/Library/Application Support/`, and
/// runtime data folder under `~/.gemini/`.
enum AntigravityChannel: String, CaseIterable, Hashable, Sendable {
    case stable
    case insiders
    case dev

    var bundleIdentifier: String {
        switch self {
        case .stable: "com.google.antigravity"
        case .insiders: "com.google.antigravity.insiders"
        case .dev: "com.google.antigravity.dev"
        }
    }

    var defaultAppPath: String {
        switch self {
        case .stable: "/Applications/Antigravity.app"
        case .insiders: "/Applications/Antigravity Insiders.app"
        case .dev: "/Applications/Antigravity Dev.app"
        }
    }

    var userDataDirectoryName: String {
        switch self {
        case .stable: "Antigravity"
        case .insiders: "Antigravity Insiders"
        case .dev: "Antigravity Dev"
        }
    }

    var appDataDirectoryName: String {
        switch self {
        case .stable: "antigravity"
        case .insiders: "antigravityinsiders"
        case .dev: "antigravity-dev"
        }
    }

    /// Infers the release channel from a custom app path by checking its
    /// `Info.plist` bundle identifier first, then falling back to the app name.
    static func infer(fromAppPath rawPath: String?) -> AntigravityChannel {
        guard let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return .stable
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if let bundle = Bundle(path: expanded),
           let bundleID = bundle.bundleIdentifier {
            if let matched = allCases.first(where: { $0.bundleIdentifier == bundleID }) {
                return matched
            }
            if let matched = infer(fromIdentifierOrName: bundleID) {
                return matched
            }
        }
        return infer(fromIdentifierOrName: URL(fileURLWithPath: expanded).lastPathComponent) ?? .stable
    }

    private static func infer(fromIdentifierOrName text: String) -> AntigravityChannel? {
        let lower = text.lowercased()
        if lower.contains("insiders") { return .insiders }
        if lower.contains("dev") { return .dev }
        return nil
    }
}

/// Filterable categories for Antigravity workspaces.
enum AntigravityWorkspaceKind: String, Hashable, Sendable {
    case local
    case remote

    var symbol: String {
        switch self {
        case .local: "folder"
        case .remote: "network"
        }
    }
}

/// A recently connected remote SSH host recorded in Antigravity's app storage.
struct AntigravityRemoteHost: Hashable, Sendable {
    let host: String
    let configFile: String?

    init(host: String, configFile: String? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configFile = Self.nonEmpty(configFile)
    }

    var badge: String {
        "SSH"
    }

    var searchKeywords: [String] {
        var terms = ["remote", "ssh", host]
        if let configFile {
            terms.append(configFile)
            terms.append(URL(fileURLWithPath: configFile).lastPathComponent)
        }
        return terms
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// One Antigravity project or remote SSH host shown in the Recent Projects list.
struct AntigravityWorkspace: Hashable, Sendable {
    /// Stable identifier used as the Prism list item ID and recent-open key.
    let id: String
    /// Display name (project name for local projects, SSH host label for remote hosts).
    let name: String
    /// Ordered local folder paths belonging to this project (empty for remote hosts).
    let paths: [String]
    /// Non-nil when this entry represents a remote SSH host.
    let remote: AntigravityRemoteHost?
    /// Current Git branch for the primary local folder when inside a Git repository.
    let gitBranch: String?
    /// Last time the project or host was active in Antigravity or opened from Prism.
    let lastOpened: Date?
    /// Fallback order from Antigravity's stored recency lists when no timestamp exists.
    let recencyRank: Int?
    /// Unambiguous `--project` argument for the `agy` CLI (name when unique, otherwise project ID).
    let agyCLITarget: String?

    var kind: AntigravityWorkspaceKind {
        remote == nil ? .local : .remote
    }

    var primaryPath: String? {
        paths.first
    }

    var isMultiFolder: Bool {
        paths.count > 1
    }

    var title: String {
        name
    }

    var iconSymbol: String {
        if remote != nil {
            return "network"
        }
        if isMultiFolder {
            return "folder.fill.badge.plus"
        }
        return "folder.fill"
    }

    var iconTint: String {
        if remote != nil {
            return "violet"
        }
        if isMultiFolder {
            return "indigo"
        }
        return "gray"
    }

    var badge: String? {
        if let remote {
            return remote.badge
        }
        if isMultiFolder {
            return localized("\(paths.count) Folders")
        }
        return nil
    }

    /// Shell command that opens this local project in the `agy` CLI.
    /// Uses `--project=` so names starting with `-` aren't parsed as flags.
    var agyCommand: String? {
        guard remote == nil, let target = agyCLITarget, !target.isEmpty else {
            return nil
        }
        return "agy --project=\(Self.shellQuote(target))"
    }

    func subtitle(homeDirectory: String) -> String {
        if let remote {
            if let configFile = remote.configFile {
                return Self.abbreviatingHome(configFile, homeDirectory: homeDirectory)
            }
            return localized("Remote SSH Host")
        }
        if isMultiFolder {
            return paths
                .map { Self.abbreviatingHome($0, homeDirectory: homeDirectory) }
                .joined(separator: " · ")
        }
        guard let firstPath = primaryPath else {
            return localized("Antigravity Project")
        }
        let folderName = URL(fileURLWithPath: firstPath).lastPathComponent
        if folderName.caseInsensitiveCompare(name) == .orderedSame {
            let parent = URL(fileURLWithPath: firstPath).deletingLastPathComponent().path
            return Self.abbreviatingHome(parent, homeDirectory: homeDirectory)
        }
        return Self.abbreviatingHome(firstPath, homeDirectory: homeDirectory)
    }

    static func makeProjectID(_ projectID: String) -> String {
        "project:\(projectID)"
    }

    static func makeRemoteID(host: String, configFile: String?) -> String {
        if let configFile, !configFile.isEmpty {
            return "remote:ssh:\(host):\(configFile)"
        }
        return "remote:ssh:\(host)"
    }

    /// Parses a `file://` URI or raw filesystem path into a canonical local path.
    static func localPath(fromURI raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            if let url = URL(string: trimmed), url.isFileURL {
                let host = url.host?.lowercased()
                guard host == nil || host == "" || host == "localhost" else {
                    return nil
                }
                let path = url.standardizedFileURL.path
                return path.isEmpty ? nil : path
            }
            if trimmed.hasPrefix("file:///") {
                let rawPath = String(trimmed.dropFirst("file://".count))
                let decoded = rawPath.removingPercentEncoding ?? rawPath
                return canonicalizeLocalPath(decoded)
            }
            return nil
        }
        if trimmed.contains("://") {
            return nil
        }
        return canonicalizeLocalPath(trimmed)
    }

    static func canonicalizeLocalPath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        return url.path
    }

    static func abbreviatingHome(_ path: String, homeDirectory: String) -> String {
        let normalizedHome = homeDirectory.hasSuffix("/")
            ? String(homeDirectory.dropLast())
            : homeDirectory
        guard !normalizedHome.isEmpty else { return path }
        if path == normalizedHome {
            return "~"
        }
        if path.hasPrefix(normalizedHome + "/") {
            return "~" + path.dropFirst(normalizedHome.count)
        }
        return path
    }

    /// Quotes an argument for POSIX shells only when it contains characters
    /// outside the safe unquoted set.
    static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2B, 0x2D, 0x2E, 0x2F, 0x3A, 0x40, 0x5F:
                true
            default:
                false
            }
        }
        if safe {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
