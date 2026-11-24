import Foundation
import SQLite3

/// Reads recent workspaces from Zed's local SQLite database read-only, skips
/// empty windows and deleted local paths, and merges recent opens recorded by
/// Prism so newly opened items immediately rise to the top.
struct ZedWorkspaceStore: Sendable {
    typealias FileExists = @Sendable (String) -> Bool
    typealias IsDirectory = @Sendable (String) -> Bool
    typealias BranchLookup = @Sendable (String) -> String?

    let homeDirectory: String
    let databaseURLOverride: URL?
    let fileExists: FileExists
    let isDirectory: IsDirectory
    let branchLookup: BranchLookup

    init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        databaseURLOverride: URL? = nil,
        fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: @escaping IsDirectory = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        },
        branchLookup: BranchLookup? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.databaseURLOverride = databaseURLOverride
        self.fileExists = fileExists
        self.isDirectory = isDirectory
        self.branchLookup = branchLookup ?? { directory in
            GitBranchReader.branch(forDirectory: directory, stopAt: homeDirectory)
        }
    }

    func databaseURL(for channel: ZedChannel) -> URL {
        if let databaseURLOverride {
            return databaseURLOverride
        }
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/Zed/db")
            .appendingPathComponent(channel.databaseDirectoryName)
            .appendingPathComponent("db.sqlite")
    }

    func loadWorkspaces(
        channel: ZedChannel = .stable,
        recordedOpens: [String: Date] = [:],
        includeGitBranch: Bool = true
    ) -> [ZedWorkspace] {
        let candidateChannels = databaseURLOverride != nil
            ? [channel]
            : [channel] + ZedChannel.allCases.filter { $0 != channel }
        guard let dbURL = candidateChannels.map(databaseURL(for:)).first(where: { fileExists($0.path) }),
              let database = try? Database(url: dbURL) else {
            return []
        }

        let rawRows = readWorkspaceRows(from: database)
        var byID: [String: ZedWorkspace] = [:]

        for row in rawRows {
            let ordered = ZedWorkspace.orderedPaths(rawPaths: row.paths, pathsOrder: row.pathsOrder)
            guard !ordered.isEmpty else { continue }

            let finalPaths: [String]
            let isDir: Bool
            if row.remote == nil {
                let existing = ordered
                    .map(ZedWorkspace.canonicalizeLocalPath)
                    .filter { fileExists($0) }
                guard !existing.isEmpty else { continue }
                finalPaths = existing
                isDir = existing.count > 1 ? true : isDirectory(existing[0])
            } else {
                finalPaths = ordered
                isDir = true
            }

            let id = ZedWorkspace.makeID(paths: finalPaths, remote: row.remote)
            let lastOpened = maxDate(row.timestamp, recordedOpens[id])
            let branchDirectory: String?
            if includeGitBranch, row.remote == nil {
                branchDirectory = isDir
                    ? finalPaths[0]
                    : URL(fileURLWithPath: finalPaths[0]).deletingLastPathComponent().path
            } else {
                branchDirectory = nil
            }
            let candidate = ZedWorkspace(
                id: id,
                paths: finalPaths,
                isDirectory: isDir,
                remote: row.remote,
                gitBranch: branchDirectory.flatMap { branchLookup($0) },
                lastOpened: lastOpened
            )

            if let existing = byID[id] {
                if Self.shouldReplace(existing: existing, with: candidate) {
                    byID[id] = candidate
                }
            } else {
                byID[id] = candidate
            }
        }

        return byID.values.sorted(by: Self.sortOrder)
    }

    // MARK: - SQLite reading

    private struct RawWorkspaceRow {
        let paths: String?
        let pathsOrder: String?
        let timestamp: Date?
        let remote: ZedRemoteConnection?
    }

    private func readWorkspaceRows(from database: Database) -> [RawWorkspaceRow] {
        let columns = workspaceColumns(in: database)
        guard !columns.isEmpty else { return [] }

        let pathsColumn: String
        if columns.contains("paths") {
            pathsColumn = "w.paths"
        } else if columns.contains("local_paths") {
            pathsColumn = "w.local_paths"
        } else {
            return []
        }

        let orderColumn = columns.contains("paths_order") ? "w.paths_order" : "NULL"
        let timestampColumn = columns.contains("timestamp") ? "w.timestamp" : "NULL"

        if columns.contains("remote_connection_id"), tableExists("remote_connections", in: database) {
            return readModernWorkspaces(
                database: database,
                pathsColumn: pathsColumn,
                orderColumn: orderColumn,
                timestampColumn: timestampColumn
            )
        }

        if columns.contains("ssh_connection_id"), tableExists("ssh_connections", in: database) {
            return readLegacySSHWorkspaces(
                database: database,
                pathsColumn: pathsColumn,
                orderColumn: orderColumn,
                timestampColumn: timestampColumn
            )
        }

        return readLocalOnlyWorkspaces(
            database: database,
            pathsColumn: pathsColumn,
            orderColumn: orderColumn,
            timestampColumn: timestampColumn
        )
    }

    private func readModernWorkspaces(
        database: Database,
        pathsColumn: String,
        orderColumn: String,
        timestampColumn: String
    ) -> [RawWorkspaceRow] {
        let remoteColumns = tableColumns("remote_connections", in: database)
        let kindExpr = remoteColumns.contains("kind") ? "r.kind" : "NULL"
        let hostExpr = remoteColumns.contains("host") ? "r.host" : "NULL"
        let portExpr = remoteColumns.contains("port") ? "r.port" : "NULL"
        let userExpr = remoteColumns.contains("user") ? "r.user" : "NULL"
        let distroExpr = remoteColumns.contains("distro") ? "r.distro" : "NULL"
        let nameExpr = remoteColumns.contains("name") ? "r.name" : "NULL"
        let containerExpr = remoteColumns.contains("container_id") ? "r.container_id" : "NULL"

        let sql = """
            SELECT
                \(pathsColumn),
                \(orderColumn),
                \(timestampColumn),
                w.remote_connection_id,
                \(kindExpr),
                \(hostExpr),
                \(portExpr),
                \(userExpr),
                \(distroExpr),
                \(nameExpr),
                \(containerExpr)
            FROM workspaces AS w
            LEFT JOIN remote_connections AS r ON w.remote_connection_id = r.id
            WHERE \(pathsColumn) IS NOT NULL AND \(pathsColumn) != ''
            ORDER BY \(timestampColumn) DESC
            """

        var rows: [RawWorkspaceRow] = []
        try? database.rows(sql) { row in
            let remote: ZedRemoteConnection?
            if row.intOrNil(3) != nil, let kind = row.string(4) {
                remote = ZedRemoteConnection(
                    kind: kind,
                    host: row.string(5),
                    port: row.intOrNil(6).map(Int.init),
                    user: row.string(7),
                    distro: row.string(8),
                    name: row.string(9),
                    containerID: row.string(10)
                )
            } else {
                remote = nil
            }
            rows.append(RawWorkspaceRow(
                paths: row.string(0),
                pathsOrder: row.string(1),
                timestamp: Self.parseTimestamp(row.string(2)),
                remote: remote
            ))
        }
        return rows
    }

    private func readLegacySSHWorkspaces(
        database: Database,
        pathsColumn: String,
        orderColumn: String,
        timestampColumn: String
    ) -> [RawWorkspaceRow] {
        let sshColumns = tableColumns("ssh_connections", in: database)
        let hostExpr = sshColumns.contains("host") ? "s.host" : "NULL"
        let portExpr = sshColumns.contains("port") ? "s.port" : "NULL"
        let userExpr = sshColumns.contains("username")
            ? "s.username"
            : (sshColumns.contains("user") ? "s.user" : "NULL")

        let sql = """
            SELECT
                \(pathsColumn),
                \(orderColumn),
                \(timestampColumn),
                w.ssh_connection_id,
                \(hostExpr),
                \(portExpr),
                \(userExpr)
            FROM workspaces AS w
            LEFT JOIN ssh_connections AS s ON w.ssh_connection_id = s.id
            WHERE \(pathsColumn) IS NOT NULL AND \(pathsColumn) != ''
            ORDER BY \(timestampColumn) DESC
            """

        var rows: [RawWorkspaceRow] = []
        try? database.rows(sql) { row in
            let remote: ZedRemoteConnection?
            if row.intOrNil(3) != nil, let host = row.string(4) {
                remote = ZedRemoteConnection(
                    kind: "ssh",
                    host: host,
                    port: row.intOrNil(5).map(Int.init),
                    user: row.string(6)
                )
            } else {
                remote = nil
            }
            rows.append(RawWorkspaceRow(
                paths: row.string(0),
                pathsOrder: row.string(1),
                timestamp: Self.parseTimestamp(row.string(2)),
                remote: remote
            ))
        }
        return rows
    }

    private func readLocalOnlyWorkspaces(
        database: Database,
        pathsColumn: String,
        orderColumn: String,
        timestampColumn: String
    ) -> [RawWorkspaceRow] {
        let sql = """
            SELECT
                \(pathsColumn),
                \(orderColumn),
                \(timestampColumn)
            FROM workspaces AS w
            WHERE \(pathsColumn) IS NOT NULL AND \(pathsColumn) != ''
            ORDER BY \(timestampColumn) DESC
            """

        var rows: [RawWorkspaceRow] = []
        try? database.rows(sql) { row in
            rows.append(RawWorkspaceRow(
                paths: row.string(0),
                pathsOrder: row.string(1),
                timestamp: Self.parseTimestamp(row.string(2)),
                remote: nil
            ))
        }
        return rows
    }

    private func workspaceColumns(in database: Database) -> Set<String> {
        tableColumns("workspaces", in: database)
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

    private func tableExists(_ table: String, in database: Database) -> Bool {
        var exists = false
        try? database.rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(table)' LIMIT 1") { _ in
            exists = true
        }
        return exists
    }

    // MARK: - Helpers

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if let date = sqliteTimestampFormatter.date(from: trimmed) {
            return date
        }
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(trimmed, strategy: .iso8601) {
            return date
        }
        return nil
    }

    private static let sqliteTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    private static func shouldReplace(existing: ZedWorkspace, with candidate: ZedWorkspace) -> Bool {
        switch (existing.lastOpened, candidate.lastOpened) {
        case let (old?, new?): new > old
        case (nil, _?): true
        default: false
        }
    }

    private static func sortOrder(_ lhs: ZedWorkspace, _ rhs: ZedWorkspace) -> Bool {
        switch (lhs.lastOpened, rhs.lastOpened) {
        case let (a?, b?) where a != b:
            return a > b
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

/// A read-only SQLite connection, closed when it goes away.
private final class Database {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            sqlite3_close(handle)
            throw NSError(domain: "ZedDatabase", code: Int(status))
        }
        // Zed may be writing to its WAL; wait briefly instead of failing on a lock.
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func intOrNil(_ column: Int32) -> Int64? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
                return nil
            }
            return sqlite3_column_int64(statement, column)
        }

        func string(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
    }

    func rows(_ sql: String, _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "ZedDatabase", code: Int(sqlite3_errcode(handle)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw NSError(domain: "ZedDatabase", code: Int(sqlite3_errcode(handle)))
            }
        }
    }
}
