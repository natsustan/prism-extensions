import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import SQLite3
import Synchronization
import Testing
@testable import AppleNotes

/// A temporary NoteStore.sqlite with the columns the extension reads, laid
/// out the way Notes stores notes, folders, accounts, and hashtags in one
/// table.
private final class NotesFixture {
    let folder: URL
    var url: URL { folder.appendingPathComponent("NoteStore.sqlite") }
    private var handle: OpaquePointer?
    private var nextPK: Int64 = 1

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleNotesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        try execute("""
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZTITLE1 TEXT, ZTITLE2 TEXT, ZSNIPPET TEXT,
                ZNAME TEXT, ZFOLDER INTEGER, ZACCOUNT4 INTEGER, ZMODIFICATIONDATE1 REAL,
                ZISPINNED INTEGER, ZISPASSWORDPROTECTED INTEGER, ZHASCHECKLIST INTEGER,
                ZHASCHECKLISTINPROGRESS INTEGER, ZMARKEDFORDELETION INTEGER, ZFOLDERTYPE INTEGER,
                ZNOTE1 INTEGER, ZALTTEXT TEXT, ZTYPEUTI1 TEXT
            )
            """)
    }

    deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: folder)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw NoteStoreError.unreadable(error.map { String(cString: $0) } ?? "")
        }
    }

    private func insert(_ columns: [String: String]) throws -> Int64 {
        let pk = nextPK
        nextPK += 1
        let names = ["Z_PK"] + columns.keys.sorted()
        let values = ["\(pk)"] + columns.keys.sorted().map { columns[$0]! }
        try execute("INSERT INTO ZICCLOUDSYNCINGOBJECT (\(names.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))")
        return pk
    }

    private static func quoted(_ text: String?) -> String {
        text.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
    }

    func account(_ name: String) throws -> Int64 {
        try insert(["ZNAME": Self.quoted(name)])
    }

    func folder(_ title: String, type: Int = 0, deleted: Bool = false) throws -> Int64 {
        try insert(["ZTITLE2": Self.quoted(title), "ZFOLDERTYPE": "\(type)", "ZMARKEDFORDELETION": deleted ? "1" : "0"])
    }

    @discardableResult
    func note(
        _ title: String?,
        id: String = UUID().uuidString,
        snippet: String? = nil,
        folder: Int64,
        account: Int64? = nil,
        modified: TimeInterval,
        pinned: Bool = false,
        locked: Bool = false,
        checklist: Bool? = nil,
        deleted: Bool = false
    ) throws -> Int64 {
        try insert([
            "ZIDENTIFIER": Self.quoted(id),
            "ZTITLE1": Self.quoted(title),
            "ZSNIPPET": Self.quoted(snippet),
            "ZFOLDER": "\(folder)",
            "ZACCOUNT4": account.map(String.init) ?? "NULL",
            "ZMODIFICATIONDATE1": "\(modified)",
            "ZISPINNED": pinned ? "1" : "0",
            "ZISPASSWORDPROTECTED": locked ? "1" : "0",
            "ZHASCHECKLIST": checklist == nil ? "0" : "1",
            "ZHASCHECKLISTINPROGRESS": checklist == true ? "1" : "0",
            "ZMARKEDFORDELETION": deleted ? "1" : "0",
        ])
    }

    func tag(_ text: String, on note: Int64) throws {
        _ = try insert([
            "ZNOTE1": "\(note)", "ZALTTEXT": Self.quoted(text),
            "ZTYPEUTI1": "'com.apple.notes.inlinetextattachment.hashtag'",
        ])
    }
}

private final class OpenedURLs: Sendable {
    private let urls = Mutex<[URL]>([])
    var all: [URL] { urls.withLock { $0 } }
    func open(_ url: URL) { urls.withLock { $0.append(url) } }
}

@Suite("Apple Notes")
struct AppleNotesTests {
    private func host(
        _ url: URL, opened: OpenedURLs = OpenedURLs(), dataDirectory: URL? = nil
    ) async throws -> PrismTestHost {
        try await PrismTestHost(
            AppleNotes(store: NoteStore(url: url), hostName: { "Prism Dev" }, openURL: { opened.open($0) }),
            extensionID: "prism.apple-notes",
            dataDirectory: dataDirectory
        )
    }

    @Test("Lists pinned notes first, then the rest newest first, leaving out deleted notes")
    func listsNotes() async throws {
        let fixture = try NotesFixture()
        let notes = try fixture.folder("Notes")
        let trash = try fixture.folder("最近删除", type: 1)
        let removedFolder = try fixture.folder("Old", deleted: true)
        try fixture.note("Older", folder: notes, modified: 100)
        try fixture.note("Newest", folder: notes, modified: 300)
        try fixture.note("Pinned", folder: notes, modified: 50, pinned: true)
        try fixture.note("In Trash", folder: trash, modified: 400)
        try fixture.note("Marked", folder: notes, modified: 500, deleted: true)
        try fixture.note("In Removed Folder", folder: removedFolder, modified: 600)
        try fixture.note(nil, folder: notes, modified: 700)

        let list = try await host(fixture.url).list("search-notes")

        #expect(list.items.map(\.title) == ["Pinned", "Newest", "Older"])
        #expect(list.items.map(\.section) == ["Pinned", "Notes", "Notes"])
        #expect(list.filtering == .prism)
        #expect(list.showsDetail == false)
    }

    @Test("A row shows the snippet on one line, the folder, and lock and checklist states")
    func rowContent() async throws {
        let fixture = try NotesFixture()
        let work = try fixture.folder("Work")
        let id = UUID().uuidString
        try fixture.note("Plan", id: id, snippet: "first line\n\n  second line ", folder: work, modified: 3, locked: true, checklist: true)
        try fixture.note("Done", snippet: "\n", folder: work, modified: 2, checklist: false)

        let items = try await host(fixture.url).list("search-notes").items

        #expect(items[0].id == id)
        #expect(items[0].subtitle == "first line second line")
        #expect(items[0].accessories.map(\.symbol) == ["lock.fill", "circle", nil])
        #expect(items[0].accessories.last?.text == "Work")
        #expect(items[1].subtitle == nil)
        #expect(items[1].accessories.first?.symbol == "checkmark.circle.fill")
        #expect(items[0].actions.map(\.id) == ["open", "copy-link", "copy-title"])
        #expect(items[0].actions[1].kind == .copy(text: "applenotes://showNote?identifier=\(id)"))
        #expect(items[0].actions[2].kind == .copy(text: "Plan"))
    }

    @Test("Keywords cover the folder, account, tags, and pinyin of Chinese text")
    func keywords() async throws {
        let fixture = try NotesFixture()
        let account = try fixture.account("iCloud")
        let home = try fixture.folder("家")
        let note = try fixture.note("玄关", snippet: "玄关柜的电源改造", folder: home, account: account, modified: 1)
        try fixture.tag("#装修", on: note)
        try fixture.tag("#装修", on: note)

        let keywords = try await host(fixture.url).list("search-notes").items[0].keywords

        #expect(keywords.contains("iCloud"))
        #expect(keywords.contains("装修"))
        #expect(keywords.filter { $0 == "装修" }.count == 1)
        for word in ["xuanguan", "xg", "xuanguanguidedianyuangaizao", "xggddygz", "jia", "zhuangxiu", "zx"] {
            #expect(keywords.contains(word), "missing \(word)")
        }
    }

    @Test("Pinyin is cached per note until its text changes, and dropped with the note")
    func pinyinCache() async throws {
        let fixture = try NotesFixture()
        let notes = try fixture.folder("Notes")
        let first = try fixture.note("玄关", folder: notes, modified: 2)
        try fixture.note("书房", folder: notes, modified: 1)
        let data = fixture.folder.appendingPathComponent("data")
        let prism = try await host(fixture.url, dataDirectory: data)
        let cacheFile = data.appendingPathComponent("pinyin.json")

        _ = try await prism.list("search-notes")
        let cached = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any]
        #expect(cached?.count == 2)

        try fixture.execute("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE1 = '客厅' WHERE Z_PK = \(first)")
        try fixture.execute("DELETE FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE1 = '书房'")
        let items = try await prism.list("search-notes").items

        #expect(items[0].keywords.contains("keting"))
        #expect(!items[0].keywords.contains("xuanguan"))
        let pruned = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any]
        #expect(pruned?.count == 1)
    }

    @Test("Pinyin keeps Latin words and skips text without Chinese")
    func pinyin() {
        #expect(PinyinKeywords.keywords(for: "deepseek 改名为 flash") == ["deepseekgaimingweiflash", "dgmwf"])
        #expect(PinyinKeywords.keywords(for: "Lakr233/libghostty-spm").isEmpty)
        #expect(PinyinKeywords.keywords(for: "かな").isEmpty)
    }

    @Test("Open asks Notes to show the note and closes the launcher")
    func opensNote() async throws {
        let fixture = try NotesFixture()
        let id = UUID().uuidString
        try fixture.note("Plan", id: id, folder: fixture.folder("Notes"), modified: 1)
        let opened = OpenedURLs()
        let prism = try await host(fixture.url, opened: opened)

        let result = try await prism.perform("open", on: id, in: "search-notes")

        #expect(result == .done)
        #expect(opened.all == [URL(string: "applenotes://showNote?identifier=\(id)")!])
        #expect(try await prism.perform("open", on: "not a uuid", in: "search-notes")
            == ExtensionActionResult(.failed(message: "This note can’t be opened.")))
        #expect(opened.all.count == 1)
    }

    @Test("Without Full Disk Access the list offers to open Privacy settings")
    func accessDenied() async throws {
        let fixture = try NotesFixture()
        try fixture.note("Plan", folder: fixture.folder("Notes"), modified: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.url.path) }
        let opened = OpenedURLs()
        let prism = try await host(fixture.url, opened: opened)

        let list = try await prism.list("search-notes")

        #expect(list.items.map(\.id) == ["full-disk-access"])
        #expect(list.items[0].title == "Allow Prism Dev to Read Your Notes")
        #expect(try await prism.perform("open-privacy-settings", on: "full-disk-access", in: "search-notes") == .done)
        #expect(opened.all == [AppleNotes.fullDiskAccessSettings])
    }

    @Test("A Mac without a Notes library shows the empty state")
    func missingLibrary() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleNotesTests-missing-\(UUID().uuidString)/NoteStore.sqlite")

        let list = try await host(missing).list("search-notes")

        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "No Notes")
    }
}
