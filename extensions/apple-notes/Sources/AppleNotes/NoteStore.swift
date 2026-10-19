import Foundation
import SQLite3

/// One note as the list shows it.
struct Note: Hashable, Sendable {
    /// The note's `ZIDENTIFIER`, a UUID that `applenotes://showNote` opens.
    let id: String
    let title: String
    let snippet: String?
    let folder: String
    let account: String?
    let modifiedAt: Date
    let isPinned: Bool
    let isLocked: Bool
    let hasChecklist: Bool
    let isChecklistInProgress: Bool
    /// Inline hashtags, without the leading `#`.
    var tags: [String] = []
}

enum NoteStoreError: Error, Equatable {
    /// macOS protects the Notes library until the user allows it.
    case accessDenied
    /// Notes has never run on this Mac, or its library moved.
    case missing
    case unreadable(String)
}

/// Reads Apple Notes' own Core Data store read-only, the way the Raycast
/// extension does: Notes has no API for searching, and AppleScript is too slow
/// to list every note.
struct NoteStore: Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")

    let url: URL

    init(url: URL = NoteStore.defaultURL) {
        self.url = url
    }

    /// Notes that are not deleted, newest first. Notes in Recently Deleted are
    /// left out.
    func notes() throws -> [Note] {
        try checkAccess()
        let database = try Database(url: url)
        var notes = [Note]()
        var indexes = [Int64: Int]()
        try database.rows(Self.notesQuery) { row in
            let pk = row.int(0)
            guard indexes[pk] == nil, let id = row.string(1), let title = row.string(2) else { return }
            indexes[pk] = notes.count
            notes.append(Note(
                id: id,
                title: title,
                snippet: row.string(3),
                folder: row.string(4) ?? "",
                account: row.string(5),
                modifiedAt: Date(timeIntervalSinceReferenceDate: row.double(6)),
                isPinned: row.int(7) == 1,
                isLocked: row.int(8) == 1,
                hasChecklist: row.int(9) == 1,
                isChecklistInProgress: row.int(10) == 1
            ))
        }
        try database.rows(Self.tagsQuery) { row in
            guard let index = indexes[row.int(0)], let text = row.string(1) else { return }
            let tag = text.hasPrefix("#") ? String(text.dropFirst()) : text
            if !tag.isEmpty, !notes[index].tags.contains(tag) { notes[index].tags.append(tag) }
        }
        return notes
    }

    /// Changes whenever Notes writes: the sizes and modification times of the
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
        case EPERM, EACCES: throw NoteStoreError.accessDenied
        case ENOENT, ENOTDIR: throw NoteStoreError.missing
        case let code: throw NoteStoreError.unreadable(String(cString: strerror(code)))
        }
    }

    /// Folder type 1 is Recently Deleted, whatever its localized title.
    private static let notesQuery = """
        SELECT
            note.Z_PK,
            note.ZIDENTIFIER,
            note.ZTITLE1,
            note.ZSNIPPET,
            folder.ZTITLE2,
            account.ZNAME,
            note.ZMODIFICATIONDATE1,
            note.ZISPINNED,
            note.ZISPASSWORDPROTECTED,
            note.ZHASCHECKLIST,
            note.ZHASCHECKLISTINPROGRESS
        FROM ZICCLOUDSYNCINGOBJECT AS note
        INNER JOIN ZICCLOUDSYNCINGOBJECT AS folder ON note.ZFOLDER = folder.Z_PK
        LEFT JOIN ZICCLOUDSYNCINGOBJECT AS account ON note.ZACCOUNT4 = account.Z_PK
        WHERE note.ZTITLE1 IS NOT NULL
            AND note.ZIDENTIFIER IS NOT NULL
            AND note.ZMODIFICATIONDATE1 IS NOT NULL
            AND COALESCE(note.ZMARKEDFORDELETION, 0) != 1
            AND COALESCE(folder.ZMARKEDFORDELETION, 0) != 1
            AND COALESCE(folder.ZFOLDERTYPE, 0) != 1
        ORDER BY note.ZMODIFICATIONDATE1 DESC
        """

    private static let tagsQuery = """
        SELECT tag.ZNOTE1, tag.ZALTTEXT
        FROM ZICCLOUDSYNCINGOBJECT AS tag
        WHERE tag.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.hashtag'
            AND tag.ZNOTE1 IS NOT NULL
        """
}

/// A read-only SQLite connection, closed when it goes away.
private final class Database {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(status))
            sqlite3_close(handle)
            throw NoteStoreError.unreadable(message)
        }
        // Notes may be writing; wait briefly instead of failing on a lock.
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func string(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
    }

    func rows(_ sql: String, _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NoteStoreError.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw NoteStoreError.unreadable(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
