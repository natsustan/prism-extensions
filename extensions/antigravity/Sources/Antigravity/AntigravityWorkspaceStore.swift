import Foundation
import SQLite3

/// Reads Antigravity 2.0 projects from `~/.gemini/config/projects/*.json`,
/// recent activity timestamps from `conversation_summaries.db`, and recent SSH
/// hosts from `app_storage.json` / `ssh_windows.json`, merging recent opens
/// recorded by Prism so newly opened items immediately rise to the top.
struct AntigravityWorkspaceStore: Sendable {
    typealias FileExists = @Sendable (String) -> Bool
    typealias BranchLookup = @Sendable (String) -> String?

    /// Internal default project created by `agy` CLI without dedicated folders.
    private static let defaultCLIProjectID = "default-cli-project"

    let homeDirectory: String
    let projectsDirectoryOverride: URL?
    let conversationsDBURLOverride: URL?
    let appStorageURLOverride: URL?
    let sshWindowsURLOverride: URL?
    let fileExists: FileExists
    let branchLookup: BranchLookup

    init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        projectsDirectoryOverride: URL? = nil,
        conversationsDBURLOverride: URL? = nil,
        appStorageURLOverride: URL? = nil,
        sshWindowsURLOverride: URL? = nil,
        fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) },
        branchLookup: BranchLookup? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.projectsDirectoryOverride = projectsDirectoryOverride
        self.conversationsDBURLOverride = conversationsDBURLOverride
        self.appStorageURLOverride = appStorageURLOverride
        self.sshWindowsURLOverride = sshWindowsURLOverride
        self.fileExists = fileExists
        self.branchLookup = branchLookup ?? { directory in
            GitBranchReader.branch(forDirectory: directory, stopAt: homeDirectory)
        }
    }

    func projectsDirectoryURL() -> URL {
        if let projectsDirectoryOverride {
            return projectsDirectoryOverride
        }
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".gemini/config/projects", isDirectory: true)
    }

    func conversationsDBURL(for channel: AntigravityChannel) -> URL {
        if let conversationsDBURLOverride {
            return conversationsDBURLOverride
        }
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".gemini")
            .appendingPathComponent(channel.appDataDirectoryName)
            .appendingPathComponent("conversation_summaries.db")
    }

    func appStorageURL(for channel: AntigravityChannel) -> URL {
        if let appStorageURLOverride {
            return appStorageURLOverride
        }
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(channel.userDataDirectoryName)
            .appendingPathComponent("app_storage.json")
    }

    func sshWindowsURL(for channel: AntigravityChannel) -> URL {
        if let sshWindowsURLOverride {
            return sshWindowsURLOverride
        }
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(channel.userDataDirectoryName)
            .appendingPathComponent("ssh_windows.json")
    }

    func loadWorkspaces(
        channel: AntigravityChannel = .stable,
        recordedOpens: [String: Date] = [:],
        includeGitBranch: Bool = true
    ) -> [AntigravityWorkspace] {
        let storageSnapshot = readAppStorage(channel: channel)
        let projectTimestamps = readProjectConversationTimestamps(channel: channel)
        let rawProjects = readProjectFiles()

        // Track project names so the `agy --project` command uses the friendly
        // name when unique and falls back to the UUID when names collide.
        var nameCounts: [String: Int] = [:]
        for project in rawProjects {
            nameCounts[project.name.lowercased(), default: 0] += 1
        }

        let orderIndex = Dictionary(
            storageSnapshot.projectsOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        var workspaces: [AntigravityWorkspace] = []

        for project in rawProjects {
            let id = AntigravityWorkspace.makeProjectID(project.id)
            let sourceDate = projectTimestamps[project.id] ?? project.modifiedDate
            let lastOpened = maxDate(sourceDate, recordedOpens[id])
            let branch = includeGitBranch ? project.paths.first.flatMap { branchLookup($0) } : nil
            let isUniqueName = (nameCounts[project.name.lowercased()] ?? 0) == 1
            let cliTarget = isUniqueName ? project.name : project.id

            workspaces.append(AntigravityWorkspace(
                id: id,
                name: project.name,
                paths: project.paths,
                remote: nil,
                gitBranch: branch,
                lastOpened: lastOpened,
                recencyRank: orderIndex[project.id],
                agyCLITarget: cliTarget
            ))
        }

        let remoteHosts = readRemoteHosts(storageSnapshot: storageSnapshot, channel: channel)
        let remoteRankOffset = storageSnapshot.projectsOrder.count
        for (index, remote) in remoteHosts.enumerated() {
            let id = AntigravityWorkspace.makeRemoteID(host: remote.host, configFile: remote.configFile)
            workspaces.append(AntigravityWorkspace(
                id: id,
                name: remote.host,
                paths: [],
                remote: remote,
                gitBranch: nil,
                lastOpened: recordedOpens[id],
                recencyRank: remoteRankOffset + index,
                agyCLITarget: nil
            ))
        }

        return workspaces.sorted(by: Self.sortOrder)
    }

    // MARK: - Projects (~/.gemini/config/projects/*.json)

    private struct RawProject {
        let id: String
        let name: String
        let paths: [String]
        let modifiedDate: Date?
    }

    private struct ProjectFileRecord: Decodable {
        let id: String?
        let name: String?
        let projectResources: ProjectResources?
        let sidecar: SidecarMarker?

        struct ProjectResources: Decodable {
            let resources: [Resource]?
        }

        struct Resource: Decodable {
            let folderUri: String?
            let gitFolder: FolderRef?
            let folder: FolderRef?

            var uri: String? {
                gitFolder?.folderUri ?? folderUri ?? folder?.folderUri
            }
        }

        struct FolderRef: Decodable {
            let folderUri: String?
        }

        /// Any non-null `"sidecar"` object marks an internal sidecar project
        /// (such as `swarm/swarm_board`) rather than a user project.
        struct SidecarMarker: Decodable {}
    }

    private func readProjectFiles() -> [RawProject] {
        let directory = projectsDirectoryURL()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let jsonFiles = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        var byID: [String: RawProject] = [:]

        for fileURL in jsonFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? decoder.decode(ProjectFileRecord.self, from: data) else {
                continue
            }
            // Skip internal sidecar projects and the implicit CLI bucket.
            if record.sidecar != nil { continue }

            let fallbackID = fileURL.deletingPathExtension().lastPathComponent
            let id = record.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedID = id.isEmpty ? fallbackID : id
            if resolvedID == Self.defaultCLIProjectID { continue }

            let rawResources = record.projectResources?.resources ?? []
            var seenPaths: Set<String> = []
            var existingPaths: [String] = []
            for resource in rawResources {
                guard let uri = resource.uri,
                      let path = AntigravityWorkspace.localPath(fromURI: uri),
                      fileExists(path),
                      seenPaths.insert(path).inserted else {
                    continue
                }
                existingPaths.append(path)
            }
            guard !existingPaths.isEmpty else { continue }

            let trimmedName = record.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = trimmedName.isEmpty
                ? URL(fileURLWithPath: existingPaths[0]).lastPathComponent
                : trimmedName
            let modifiedDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate

            byID[resolvedID] = RawProject(
                id: resolvedID,
                name: displayName,
                paths: existingPaths,
                modifiedDate: modifiedDate
            )
        }

        return Array(byID.values)
    }

    // MARK: - Conversation Timestamps (conversation_summaries.db)

    private func readProjectConversationTimestamps(channel: AntigravityChannel) -> [String: Date] {
        guard let dbURL = resolveChannelURL(
            for: channel,
            override: conversationsDBURLOverride,
            urlForChannel: conversationsDBURL(for:)
        ),
              let database = try? Database(url: dbURL) else {
            return [:]
        }

        let columns = tableColumns("conversation_summaries", in: database)
        guard columns.contains("project_id"), columns.contains("last_modified_time") else {
            return [:]
        }

        // Compute the maximum date in Swift rather than SQLite `MAX(...)` so
        // mixed timezone offsets or fractional-second formats compare accurately.
        let sql = """
            SELECT project_id, last_modified_time
            FROM conversation_summaries
            WHERE project_id IS NOT NULL AND project_id != ''
            """
        var timestamps: [String: Date] = [:]
        try? database.rows(sql) { row in
            guard let projectID = row.string(0),
                  !projectID.isEmpty,
                  let date = Self.parseTimestamp(row.string(1)) else {
                return
            }
            if let existing = timestamps[projectID], existing >= date {
                return
            }
            timestamps[projectID] = date
        }
        return timestamps
    }

    private func tableColumns(_ table: String, in database: Database) -> Set<String> {
        var columns: Set<String> = []
        try? database.rows("PRAGMA table_info(\(table))") { row in
            if let name = row.string(1) {
                columns.insert(name)
            }
        }
        return columns
    }

    // MARK: - App Storage & SSH Hosts (app_storage.json / ssh_windows.json)

    private struct AppStorageSnapshot {
        let projectsOrder: [String]
        let recentConnections: [AntigravityRemoteHost]
    }

    private struct SSHHostRecord: Decodable {
        let host: String?
        let configFile: String?
    }

    private struct SavedSSHWindowsFile: Decodable {
        let windows: [SSHHostRecord]?
    }

    private func readAppStorage(channel: AntigravityChannel) -> AppStorageSnapshot {
        guard let url = resolveChannelURL(
            for: channel,
            override: appStorageURLOverride,
            urlForChannel: appStorageURL(for:)
        ),
              let data = try? Data(contentsOf: url),
              let rawItems = try? JSONDecoder().decode([String: String].self, from: data) else {
            return AppStorageSnapshot(projectsOrder: [], recentConnections: [])
        }

        let projectsOrder = decodeJSON([String].self, from: rawItems["projectsOrder"]) ?? []
        let recentConnections = parseRecentSSHHosts(from: rawItems)
        return AppStorageSnapshot(projectsOrder: projectsOrder, recentConnections: recentConnections)
    }

    private func parseRecentSSHHosts(from items: [String: String]) -> [AntigravityRemoteHost] {
        var hosts: [AntigravityRemoteHost] = []

        if let records = decodeJSON([SSHHostRecord].self, from: items["ssh.recentConnections"]) {
            hosts = remoteHosts(from: records)
        } else if let legacyHosts = decodeJSON([String].self, from: items["ssh.recentHosts"]) {
            let configFiles = decodeJSON([String: String].self, from: items["ssh.recentConfigFiles"]) ?? [:]
            for rawHost in legacyHosts {
                let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { continue }
                hosts.append(AntigravityRemoteHost(host: host, configFile: configFiles[host]))
            }
        }

        return dedupeRemoteHosts(hosts)
    }

    private func readRemoteHosts(
        storageSnapshot: AppStorageSnapshot,
        channel: AntigravityChannel
    ) -> [AntigravityRemoteHost] {
        var combined = storageSnapshot.recentConnections

        if let url = resolveChannelURL(
            for: channel,
            override: sshWindowsURLOverride,
            urlForChannel: sshWindowsURL(for:)
        ),
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SavedSSHWindowsFile.self, from: data) {
            combined.append(contentsOf: remoteHosts(from: saved.windows ?? []))
        }

        return dedupeRemoteHosts(combined)
    }

    private func remoteHosts(from records: [SSHHostRecord]) -> [AntigravityRemoteHost] {
        records.compactMap { record in
            guard let host = record.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !host.isEmpty else {
                return nil
            }
            return AntigravityRemoteHost(host: host, configFile: record.configFile)
        }
    }

    private func resolveChannelURL(
        for channel: AntigravityChannel,
        override: URL?,
        urlForChannel: (AntigravityChannel) -> URL
    ) -> URL? {
        let candidates = override != nil
            ? [channel]
            : [channel] + AntigravityChannel.allCases.filter { $0 != channel }
        return candidates.map(urlForChannel).first(where: { fileExists($0.path) })
    }

    private func dedupeRemoteHosts(_ hosts: [AntigravityRemoteHost]) -> [AntigravityRemoteHost] {
        var seen: Set<String> = []
        return hosts.filter { remote in
            let id = AntigravityWorkspace.makeRemoteID(host: remote.host, configFile: remote.configFile)
            return seen.insert(id).inserted
        }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Timestamp Parsing & Sorting

    /// Parses Go/SQLite timestamps such as `2026-11-24 11:29:40.88352+00:00`,
    /// `2026-11-21 13:50:15.606339+00:00`, `2026-11-24 10:30:00`, and RFC 3339 / ISO 8601.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.count >= 19 else {
            return nil
        }
        // Normalize a space separator between date and time to ISO 8601's `T`
        // and default bare UTC SQLite timestamps without a timezone suffix to `Z`.
        var normalized = trimmed
        let separatorIndex = normalized.index(normalized.startIndex, offsetBy: 10)
        if normalized[separatorIndex] == " " {
            normalized.replaceSubrange(separatorIndex...separatorIndex, with: "T")
        }
        let timePart = normalized[normalized.index(after: separatorIndex)...]
        if !timePart.contains(where: { $0 == "Z" || $0 == "z" || $0 == "+" || $0 == "-" }) {
            normalized.append("Z")
        }

        if let date = try? Date(normalized, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(normalized, strategy: .iso8601)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    private static func sortOrder(_ lhs: AntigravityWorkspace, _ rhs: AntigravityWorkspace) -> Bool {
        switch (lhs.lastOpened, rhs.lastOpened) {
        case let (a?, b?) where a != b:
            return a > b
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            switch (lhs.recencyRank, rhs.recencyRank) {
            case let (a?, b?) where a != b:
                return a < b
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
        }
    }
}

/// A read-only SQLite connection, closed when it goes away.
private final class Database {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            sqlite3_close(handle)
            throw NSError(domain: "AntigravityDatabase", code: Int(status))
        }
        // Antigravity may be writing to its WAL; wait briefly instead of failing on a lock.
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func string(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
    }

    func rows(_ sql: String, _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "AntigravityDatabase", code: Int(sqlite3_errcode(handle)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw NSError(domain: "AntigravityDatabase", code: Int(sqlite3_errcode(handle)))
            }
        }
    }
}
