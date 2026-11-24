import Foundation
import SQLite3

/// One Bear note as the list indexes it. Body text is never kept in memory;
/// full-text searches stream `ZTEXT` row by row from SQLite, and the detail
/// pane / Copy Markdown load one note on demand.
struct BearNote: Hashable, Sendable {
    /// `ZUNIQUEIDENTIFIER`, used by `bear://x-callback-url/open-note`.
    let id: String
    let title: String
    /// One-line preview text, nil for locked or empty notes.
    let snippet: String?
    let createdAt: Date?
    let modifiedAt: Date
    let isPinned: Bool
    let isArchived: Bool
    let isLocked: Bool
    let todoCompleted: Int
    let todoIncompleted: Int
    /// Tag names without the leading `#` (e.g. `work/projects`).
    var tags: [String] = []

    var todoTotal: Int { todoCompleted + todoIncompleted }
    var hasTodos: Bool { todoTotal > 0 }
}

/// Full note data loaded on demand for the detail pane or Copy Markdown.
struct BearNoteDetail: Hashable, Sendable {
    let id: String
    let title: String
    let markdown: String
    let createdAt: Date?
    let modifiedAt: Date
    let isPinned: Bool
    let isArchived: Bool
    let isLocked: Bool
    let todoCompleted: Int
    let todoIncompleted: Int
    var tags: [String] = []

    var todoTotal: Int { todoCompleted + todoIncompleted }
    var hasTodos: Bool { todoTotal > 0 }
}

/// One Bear tag with its active (non-archived, non-trashed) note count.
struct BearTag: Hashable, Sendable {
    let name: String
    let noteCount: Int
    let isPinned: Bool
}

struct BearSnapshot: Sendable {
    let notes: [BearNote]
    let tags: [BearTag]
}

enum BearStoreError: Error, Equatable {
    /// macOS protects Bear's Group Container until the user allows access.
    case accessDenied
    /// Bear has never run on this Mac, or its library moved.
    case missing
    case unreadable(String)
}

/// Reads Bear's Core Data SQLite database read-only. Bear's x-callback-url
/// scheme has no synchronous search API, and reading the database directly
/// mirrors how Prism's Apple Notes extension works.
struct BearStore: Sendable {
    static let defaultContainerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear")

    static let defaultURL = defaultContainerURL
        .appendingPathComponent("Application Data/database.sqlite")

    private static let maxSnippetLength = 240

    let url: URL

    init(url: URL = BearStore.defaultURL) {
        self.url = url
    }

    /// Reads all active and archived note metadata (excluding trashed and
    /// permanently deleted ones) along with active tag counts, newest modified
    /// first. Full `ZTEXT` bodies are not loaded into memory.
    func snapshot() throws -> BearSnapshot {
        try checkAccess()
        let database = try Database(url: url)
        let schema = try Schema(database: database)

        var notes = [BearNote]()
        var indexes = [Int64: Int]()
        try database.rows(schema.notesQuery) { row in
            let pk = row.int(0)
            guard indexes[pk] == nil, let id = row.string(1), !id.isEmpty else { return }
            let rawTitle = row.string(2) ?? ""
            let rawSubtitle = row.string(3)
            let rawTextPreview = row.string(4)
            let createdAt = row.optionalDouble(5).map { Date(timeIntervalSinceReferenceDate: $0) }
            guard let modifiedSeconds = row.optionalDouble(6) ?? row.optionalDouble(5) else { return }
            let isPinned = row.int(7) == 1
            let isArchived = row.int(8) == 1
            let isLocked = row.int(9) == 1
            let todoCompleted = max(0, Int(row.int(10)))
            let todoIncompleted = max(0, Int(row.int(11)))
            let snippet = isLocked
                ? nil
                : Self.makeSnippet(subtitle: rawSubtitle, text: rawTextPreview, title: rawTitle)

            indexes[pk] = notes.count
            notes.append(BearNote(
                id: id,
                title: rawTitle,
                snippet: snippet,
                createdAt: createdAt,
                modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedSeconds),
                isPinned: isPinned,
                isArchived: isArchived,
                isLocked: isLocked,
                todoCompleted: todoCompleted,
                todoIncompleted: todoIncompleted
            ))
        }

        var tagMetadata = [String: Bool]()
        var activeTagCounts = [String: Int]()
        if let tagQuery = schema.tagsQuery {
            try database.rows(tagQuery) { row in
                guard let name = row.string(0), !name.isEmpty else { return }
                let isPinned = row.int(1) == 1
                tagMetadata[name] = (tagMetadata[name] ?? false) || isPinned
            }
        }
        if let noteTagsQuery = schema.noteTagsQuery {
            try database.rows(noteTagsQuery) { row in
                guard let index = indexes[row.int(0)], let tag = row.string(1), !tag.isEmpty else { return }
                if !notes[index].tags.contains(tag) {
                    notes[index].tags.append(tag)
                    if !notes[index].isArchived {
                        activeTagCounts[tag, default: 0] += 1
                    }
                }
            }
        }
        for index in notes.indices {
            notes[index].tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        let tags = activeTagCounts.map { name, count in
            BearTag(name: name, noteCount: count, isPinned: tagMetadata[name] ?? false)
        }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return BearSnapshot(notes: notes, tags: tags)
    }

    /// Streams `ZTEXT` one row at a time from SQLite for `candidates` that did
    /// not match in memory, returning up to `limit` matching note IDs without
    /// retaining note bodies in memory.
    func bodyMatchIDs(
        words: [String],
        filter: BearNoteFilter,
        candidates: [String: SearchableNote],
        limit: Int
    ) throws -> Set<String> {
        guard !words.isEmpty, !candidates.isEmpty, limit > 0, filter != .locked else {
            return []
        }
        try checkAccess()
        let database = try Database(url: url)
        let schema = try Schema(database: database)
        guard let bodyQuery = schema.bodySearchQuery(for: filter) else { return [] }

        var matched = Set<String>()
        try database.rows(bodyQuery) { row, stop in
            try Task.checkCancellation()
            guard let id = row.string(0), let entry = candidates[id], let body = row.string(1), !body.isEmpty else {
                return
            }
            let foldedBody = BearNoteSearch.fold(body)
            if words.allSatisfy({ entry.text.contains($0) || foldedBody.contains($0) }) {
                matched.insert(id)
                if matched.count >= limit {
                    stop = true
                }
            }
        }
        return matched
    }

    /// Reads one note's full Markdown body and metadata on demand.
    func noteDetail(id: String) throws -> BearNoteDetail? {
        try checkAccess()
        let database = try Database(url: url)
        let schema = try Schema(database: database)

        var pk: Int64?
        var detail: BearNoteDetail?
        try database.rows(schema.noteDetailQuery, bindings: [id]) { row in
            guard detail == nil else { return }
            let notePK = row.int(0)
            guard let identifier = row.string(1), !identifier.isEmpty else { return }
            let title = row.string(2) ?? ""
            let isLocked = row.int(7) == 1
            let markdown = isLocked ? "" : (row.string(3) ?? "")
            let createdAt = row.optionalDouble(4).map { Date(timeIntervalSinceReferenceDate: $0) }
            guard let modifiedSeconds = row.optionalDouble(5) ?? row.optionalDouble(4) else { return }
            pk = notePK
            detail = BearNoteDetail(
                id: identifier,
                title: title,
                markdown: markdown,
                createdAt: createdAt,
                modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedSeconds),
                isPinned: row.int(6) == 1,
                isArchived: row.int(8) == 1,
                isLocked: isLocked,
                todoCompleted: max(0, Int(row.int(9))),
                todoIncompleted: max(0, Int(row.int(10)))
            )
        }
        guard var found = detail, let notePK = pk else { return nil }

        if let singleNoteTagsQuery = schema.singleNoteTagsQuery {
            try database.rows(singleNoteTagsQuery, intBindings: [notePK]) { row in
                if let tag = row.string(0), !tag.isEmpty, !found.tags.contains(tag) {
                    found.tags.append(tag)
                }
            }
        }
        found.tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return found
    }

    /// Changes whenever Bear writes: the sizes and modification times of the
    /// database and its write-ahead log. `nil` when the database can't be
    /// examined, so nothing is reused.
    func signature() -> String? {
        var parts = [String]()
        for path in [url.path, url.path + "-wal"] {
            var info = stat()
            guard stat(path, &info) == 0 else {
                if path == url.path { return nil }
                parts.append("none")
                continue
            }
            parts.append("\(info.st_size)@\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
        }
        return parts.joined(separator: " ")
    }

    /// SQLite reports a missing permission as a generic open failure, so the
    /// file is opened directly first to tell the cases apart.
    private func checkAccess() throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor < 0 else {
            close(descriptor)
            return
        }
        switch errno {
        case EPERM, EACCES: throw BearStoreError.accessDenied
        case ENOENT, ENOTDIR: throw BearStoreError.missing
        case let code: throw BearStoreError.unreadable(String(cString: strerror(code)))
        }
    }

    /// Prefers Bear's `ZSUBTITLE`; falls back to the first non-title line of
    /// `ZTEXT` so notes without a stored subtitle still show a preview.
    static func makeSnippet(subtitle: String?, text: String?, title: String) -> String? {
        if let subtitle {
            let collapsed = collapseWhitespace(subtitle)
            if !collapsed.isEmpty { return String(collapsed.prefix(maxSnippetLength)) }
        }
        guard let text, !text.isEmpty else { return nil }
        let normalizedTitle = collapseWhitespace(title)
        var skippedTitleLine = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = collapseWhitespace(String(rawLine))
            if line.isEmpty { continue }
            if !skippedTitleLine {
                skippedTitleLine = true
                let strippedHeading = line.drop(while: { $0 == "#" || $0 == " " })
                if !normalizedTitle.isEmpty, strippedHeading == normalizedTitle || line == normalizedTitle {
                    continue
                }
            }
            return String(line.prefix(maxSnippetLength))
        }
        return nil
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Inspects Bear's Core Data schema at read time so queries stay compatible
/// across Bear 1 and Bear 2 migrations (for example, `Z_5TAGS` vs `Z_7TAGS`
/// and optional columns such as `ZPERMANENTLYDELETED` or `ZSFNOTETAG.ZPINNED`).
private struct Schema {
    let notesQuery: String
    let noteDetailQuery: String
    let tagsQuery: String?
    let noteTagsQuery: String?
    let singleNoteTagsQuery: String?
    private let noteColumns: Set<String>
    private let activeWhereSQL: String

    init(database: Database) throws {
        let noteColumns = try database.columns(of: "ZSFNOTE")
        guard noteColumns.contains("Z_PK"), noteColumns.contains("ZUNIQUEIDENTIFIER") else {
            throw BearStoreError.unreadable("Missing ZSFNOTE table.")
        }
        self.noteColumns = noteColumns

        func col(_ name: String, fallback: String) -> String {
            noteColumns.contains(name) ? "note.\(name)" : fallback
        }

        var whereClauses = ["note.ZUNIQUEIDENTIFIER IS NOT NULL"]
        if noteColumns.contains("ZTRASHED") {
            whereClauses.append("COALESCE(note.ZTRASHED, 0) != 1")
        }
        if noteColumns.contains("ZPERMANENTLYDELETED") {
            whereClauses.append("COALESCE(note.ZPERMANENTLYDELETED, 0) != 1")
        }
        let whereSQL = whereClauses.joined(separator: " AND ")
        activeWhereSQL = whereSQL

        // Read at most 512 chars of ZTEXT only when ZSUBTITLE is absent/empty,
        // so large note bodies never enter the in-memory index.
        let textPreviewSQL: String
        if !noteColumns.contains("ZTEXT") {
            textPreviewSQL = "NULL"
        } else if noteColumns.contains("ZSUBTITLE") {
            textPreviewSQL = "CASE WHEN note.ZSUBTITLE IS NOT NULL AND note.ZSUBTITLE != '' THEN NULL ELSE SUBSTR(note.ZTEXT, 1, 512) END"
        } else {
            textPreviewSQL = "SUBSTR(note.ZTEXT, 1, 512)"
        }

        notesQuery = """
            SELECT
                note.Z_PK,
                note.ZUNIQUEIDENTIFIER,
                \(col("ZTITLE", fallback: "''")),
                \(col("ZSUBTITLE", fallback: "NULL")),
                \(textPreviewSQL),
                \(col("ZCREATIONDATE", fallback: "NULL")),
                \(col("ZMODIFICATIONDATE", fallback: "NULL")),
                \(col("ZPINNED", fallback: "0")),
                \(col("ZARCHIVED", fallback: "0")),
                \(col("ZENCRYPTED", fallback: "0")),
                \(col("ZTODOCOMPLETED", fallback: "0")),
                \(col("ZTODOINCOMPLETED", fallback: "0"))
            FROM ZSFNOTE AS note
            WHERE \(whereSQL)
            ORDER BY COALESCE(\(col("ZMODIFICATIONDATE", fallback: "NULL")), \(col("ZCREATIONDATE", fallback: "0"))) DESC
            """

        noteDetailQuery = """
            SELECT
                note.Z_PK,
                note.ZUNIQUEIDENTIFIER,
                \(col("ZTITLE", fallback: "''")),
                \(col("ZTEXT", fallback: "NULL")),
                \(col("ZCREATIONDATE", fallback: "NULL")),
                \(col("ZMODIFICATIONDATE", fallback: "NULL")),
                \(col("ZPINNED", fallback: "0")),
                \(col("ZENCRYPTED", fallback: "0")),
                \(col("ZARCHIVED", fallback: "0")),
                \(col("ZTODOCOMPLETED", fallback: "0")),
                \(col("ZTODOINCOMPLETED", fallback: "0"))
            FROM ZSFNOTE AS note
            WHERE note.ZUNIQUEIDENTIFIER = ?
                AND \(whereSQL)
            LIMIT 1
            """

        let tagColumns = try database.columns(of: "ZSFNOTETAG")
        if tagColumns.contains("Z_PK"), tagColumns.contains("ZTITLE") {
            let tagPinned = tagColumns.contains("ZPINNED") ? "COALESCE(ZPINNED, 0)" : "0"
            tagsQuery = "SELECT ZTITLE, \(tagPinned) FROM ZSFNOTETAG WHERE ZTITLE IS NOT NULL"

            if let join = try Self.discoverTagJoinTable(in: database) {
                noteTagsQuery = """
                    SELECT link.\(join.noteColumn), tag.ZTITLE
                    FROM \(join.table) AS link
                    INNER JOIN ZSFNOTETAG AS tag ON link.\(join.tagColumn) = tag.Z_PK
                    WHERE tag.ZTITLE IS NOT NULL
                    """
                singleNoteTagsQuery = """
                    SELECT tag.ZTITLE
                    FROM \(join.table) AS link
                    INNER JOIN ZSFNOTETAG AS tag ON link.\(join.tagColumn) = tag.Z_PK
                    WHERE link.\(join.noteColumn) = ? AND tag.ZTITLE IS NOT NULL
                    """
            } else {
                noteTagsQuery = nil
                singleNoteTagsQuery = nil
            }
        } else {
            tagsQuery = nil
            noteTagsQuery = nil
            singleNoteTagsQuery = nil
        }
    }

    func bodySearchQuery(for filter: BearNoteFilter) -> String? {
        guard noteColumns.contains("ZTEXT") else { return nil }
        var clauses = [activeWhereSQL, "note.ZTEXT IS NOT NULL", "note.ZTEXT != ''"]
        if noteColumns.contains("ZENCRYPTED") {
            clauses.append("COALESCE(note.ZENCRYPTED, 0) != 1")
        }
        if noteColumns.contains("ZARCHIVED") {
            clauses.append(filter == .archived ? "COALESCE(note.ZARCHIVED, 0) = 1" : "COALESCE(note.ZARCHIVED, 0) != 1")
        } else if filter == .archived {
            return nil
        }
        if filter == .pinned {
            guard noteColumns.contains("ZPINNED") else { return nil }
            clauses.append("COALESCE(note.ZPINNED, 0) = 1")
        }
        if filter == .todo {
            guard noteColumns.contains("ZTODOINCOMPLETED") else { return nil }
            clauses.append("COALESCE(note.ZTODOINCOMPLETED, 0) > 0")
        }
        let modifiedCol = noteColumns.contains("ZMODIFICATIONDATE") ? "note.ZMODIFICATIONDATE" : "NULL"
        let createdCol = noteColumns.contains("ZCREATIONDATE") ? "note.ZCREATIONDATE" : "0"
        let orderPrefix = (filter == .all && noteColumns.contains("ZPINNED")) ? "COALESCE(note.ZPINNED, 0) DESC, " : ""
        return """
            SELECT note.ZUNIQUEIDENTIFIER, note.ZTEXT
            FROM ZSFNOTE AS note
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(orderPrefix)COALESCE(\(modifiedCol), \(createdCol)) DESC
            """
    }

    private struct TagJoin {
        let table: String
        let noteColumn: String
        let tagColumn: String
    }

    private static func discoverTagJoinTable(in database: Database) throws -> TagJoin? {
        var candidates = [String]()
        try database.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z\\_%TAGS' ESCAPE '\\' ORDER BY name") { row in
            if let name = row.string(0), isNumberedCoreDataName(name, suffix: "TAGS") {
                candidates.append(name)
            }
        }
        for table in candidates {
            let columns = try database.columns(of: table)
            guard let noteColumn = columns.first(where: { isNumberedCoreDataName($0, suffix: "NOTES") }),
                  let tagColumn = columns.first(where: { isNumberedCoreDataName($0, suffix: "TAGS") })
            else { continue }
            return TagJoin(table: table, noteColumn: noteColumn, tagColumn: tagColumn)
        }
        return nil
    }

    /// Matches Core Data's `Z_<digits><suffix>` join table and column names
    /// (such as `Z_5TAGS`, `Z_5NOTES`, `Z_13TAGS`) while skipping related
    /// tables such as Bear 2's `Z_5PINNEDINTAGS`.
    private static func isNumberedCoreDataName(_ name: String, suffix: String) -> Bool {
        guard name.hasPrefix("Z_"), name.hasSuffix(suffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: 2)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return false }
        return name[start..<end].unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }
}

/// A read-only SQLite connection, closed when it goes away.
private final class Database {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(status))
            sqlite3_close(handle)
            throw BearStoreError.unreadable(message)
        }
        // Bear may be writing; wait briefly instead of failing on a lock.
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

        func optionalDouble(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }

        func string(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
    }

    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try rows("PRAGMA table_info(\(table))") { row in
            if let name = row.string(1) { names.insert(name) }
        }
        return names
    }

    func rows(_ sql: String, bindings: [String] = [], intBindings: [Int64] = [], _ body: (Row) throws -> Void) throws {
        try rows(sql, bindings: bindings, intBindings: intBindings) { row, _ in
            try body(row)
        }
    }

    func rows(
        _ sql: String,
        bindings: [String] = [],
        intBindings: [Int64] = [],
        _ body: (Row, inout Bool) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BearStoreError.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.sqliteTransient)
        }
        for (index, value) in intBindings.enumerated() {
            sqlite3_bind_int64(statement, Int32(bindings.count + index + 1), value)
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var stop = false
                try body(Row(statement: statement), &stop)
                if stop { return }
            case SQLITE_DONE:
                return
            default:
                throw BearStoreError.unreadable(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
