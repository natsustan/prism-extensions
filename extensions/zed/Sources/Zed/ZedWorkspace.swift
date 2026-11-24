import Foundation

/// Zed release channels, each with its own macOS bundle identifier and SQLite
/// database directory under `~/Library/Application Support/Zed/db/`.
enum ZedChannel: String, CaseIterable, Hashable, Sendable {
    case stable
    case preview
    case nightly
    case dev

    var databaseDirectoryName: String {
        "0-\(rawValue)"
    }

    var bundleIdentifier: String {
        switch self {
        case .stable: "dev.zed.Zed"
        case .preview: "dev.zed.Zed-Preview"
        case .nightly: "dev.zed.Zed-Nightly"
        case .dev: "dev.zed.Zed-Dev"
        }
    }

    var defaultAppPath: String {
        switch self {
        case .stable: "/Applications/Zed.app"
        case .preview: "/Applications/Zed Preview.app"
        case .nightly: "/Applications/Zed Nightly.app"
        case .dev: "/Applications/Zed Dev.app"
        }
    }

    /// Infers the release channel from a custom app path by checking its
    /// `Info.plist` bundle identifier first, then falling back to the app name.
    static func infer(fromAppPath rawPath: String?) -> ZedChannel {
        guard let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return .stable
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if let bundle = Bundle(path: expanded),
           let bundleID = bundle.bundleIdentifier,
           let matched = allCases.first(where: { $0.bundleIdentifier == bundleID }) {
            return matched
        }
        let lowerName = URL(fileURLWithPath: expanded).lastPathComponent.lowercased()
        if lowerName.contains("preview") { return .preview }
        if lowerName.contains("nightly") { return .nightly }
        if lowerName.contains("dev") { return .dev }
        return .stable
    }
}

/// Filterable categories for Zed workspaces.
enum ZedWorkspaceKind: String, Hashable, Sendable {
    case local
    case remote

    var symbol: String {
        switch self {
        case .local: "folder"
        case .remote: "network"
        }
    }
}

/// Remote connection metadata attached to a Zed workspace (`remote_connections`
/// or legacy `ssh_connections`).
struct ZedRemoteConnection: Hashable, Sendable {
    let kind: String
    let host: String?
    let port: Int?
    let user: String?
    let distro: String?
    let name: String?
    let containerID: String?

    init(
        kind: String,
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        distro: String? = nil,
        name: String? = nil,
        containerID: String? = nil
    ) {
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.host = Self.nonEmpty(host)
        self.port = port.flatMap { $0 > 0 ? $0 : nil }
        self.user = Self.nonEmpty(user)
        self.distro = Self.nonEmpty(distro)
        self.name = Self.nonEmpty(name)
        self.containerID = Self.nonEmpty(containerID)
    }

    var isSSH: Bool {
        kind == "ssh" && host != nil
    }

    /// `[user@]host[:port]` for SSH connections, bracketing IPv6 literals.
    var sshAuthority: String? {
        guard let host else { return nil }
        let formattedHost = (host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]")))
            ? "[\(host)]"
            : host
        var result = ""
        if let user {
            result += "\(user)@"
        }
        result += formattedHost
        if let port {
            result += ":\(port)"
        }
        return result
    }

    /// Human-readable remote target shown in subtitles and search keywords.
    var displayTarget: String {
        if let sshAuthority, isSSH {
            return sshAuthority
        }
        switch kind {
        case "wsl":
            return distro ?? name ?? "WSL"
        case "docker", "devcontainer":
            return name ?? containerID ?? "Docker"
        default:
            return host ?? name ?? distro ?? containerID ?? kind
        }
    }

    var badge: String {
        switch kind {
        case "ssh": "SSH"
        case "wsl": "WSL"
        case "docker", "devcontainer": "Docker"
        default: localized("Remote")
        }
    }

    var searchKeywords: [String] {
        var terms = ["remote", kind, badge.lowercased(), displayTarget]
        if let host { terms.append(host) }
        if let user { terms.append(user) }
        if let name { terms.append(name) }
        if let distro { terms.append(distro) }
        return terms
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// One recent Zed workspace (a local folder, local file, multi-folder
/// workspace, or remote workspace).
struct ZedWorkspace: Hashable, Sendable {
    /// Stable identifier used as the Prism list item ID and recent-open key.
    let id: String
    /// Ordered paths in this workspace (always non-empty).
    let paths: [String]
    /// Whether `primaryPath` is a directory (always `true` for multi-folder or remote).
    let isDirectory: Bool
    /// Non-nil when this workspace lives on a remote host or container.
    let remote: ZedRemoteConnection?
    /// Current Git branch for local workspaces inside a Git repository.
    let gitBranch: String?
    /// Last time the workspace was opened in Zed or through Prism.
    let lastOpened: Date?

    var kind: ZedWorkspaceKind {
        remote == nil ? .local : .remote
    }

    var primaryPath: String {
        paths[0]
    }

    var isMultiFolder: Bool {
        paths.count > 1
    }

    var title: String {
        if paths.count == 1 {
            return Self.displayName(for: paths[0])
        }
        let names = paths.map { Self.displayName(for: $0) }
        if names.count == 2 {
            return "\(names[0]), \(names[1])"
        }
        return "\(names[0]), \(names[1]) +\(names.count - 2)"
    }

    var directoryPath: String {
        if remote != nil || isDirectory || isMultiFolder {
            return primaryPath
        }
        return URL(fileURLWithPath: primaryPath).deletingLastPathComponent().path
    }

    var iconSymbol: String {
        if remote != nil {
            return "network"
        }
        if isMultiFolder {
            return "folder.fill.badge.plus"
        }
        return isDirectory ? "folder.fill" : "doc.text.fill"
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
        if !isDirectory {
            return localized("File")
        }
        return nil
    }

    func subtitle(homeDirectory: String) -> String {
        if let remote {
            let pathText = paths.count == 1
                ? primaryPath
                : paths.joined(separator: " · ")
            return "\(remote.displayTarget) — \(pathText)"
        }
        if isMultiFolder {
            return paths
                .map { Self.abbreviatingHome($0, homeDirectory: homeDirectory) }
                .joined(separator: " · ")
        }
        let parent = URL(fileURLWithPath: primaryPath).deletingLastPathComponent().path
        return Self.abbreviatingHome(parent, homeDirectory: homeDirectory)
    }

    /// Builds `ssh://[user@]host[:port]/path` URLs for every folder in an SSH
    /// workspace. `WorkspaceZedLauncher` opens these URLs directly with the
    /// resolved Zed app URL, which works across every Zed release channel and
    /// preserves RFC 3986 IPv6 host bracketing and path encoding.
    func sshURLs() -> [URL] {
        guard let remote, remote.isSSH, let host = remote.host else {
            return []
        }
        let formattedHost = (host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]")))
            ? "[\(host)]"
            : host
        return paths.compactMap { path in
            var components = URLComponents()
            components.scheme = "ssh"
            components.user = remote.user
            components.percentEncodedHost = formattedHost
            components.port = remote.port
            components.path = path.hasPrefix("/") ? path : "/\(path)"
            return components.url
        }
    }

    /// Builds a stable workspace identifier independent of `paths_order` so
    /// favorites, hotkeys, and recorded opens survive display-order changes.
    static func makeID(paths: [String], remote: ZedRemoteConnection?) -> String {
        let canonical = Array(Set(paths)).sorted().joined(separator: "\n")
        if let remote {
            return "remote:\(remote.kind):\(remote.displayTarget):\(canonical)"
        }
        return canonical
    }

    /// Parses Zed's newline-separated `paths` column and optional comma-separated
    /// `paths_order` column into an ordered array of non-empty paths, preserving
    /// any leading or trailing spaces that belong to a filename or directory.
    static func orderedPaths(rawPaths: String?, pathsOrder: String?) -> [String] {
        guard let rawPaths else { return [] }
        let entries = rawPaths
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return [] }
        guard entries.count > 1,
              let pathsOrder = pathsOrder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pathsOrder.isEmpty else {
            return entries
        }
        let indices = pathsOrder
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard indices.count == entries.count,
              Set(indices).count == entries.count,
              indices.allSatisfy({ $0 >= 0 && $0 < entries.count }) else {
            return entries
        }
        // `paths_order[i]` stores the display position of `entries[i]`, or
        // when Zed stores a permutation of entry indices, both are valid
        // bijections; order entries by their assigned position.
        var ordered = Array(repeating: "", count: entries.count)
        for (entryIndex, position) in indices.enumerated() {
            ordered[position] = entries[entryIndex]
        }
        return ordered
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

    private static func displayName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
