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
            AppleNotes(store: NoteStore(url: url), openURL: { opened.open($0) }),
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
        #expect(list.filtering == .extension)
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
        #expect(items[0].icon?.app == "com.apple.Notes")
        #expect(items[0].subtitle == "first line second line")
        #expect(items[0].accessories.map(\.symbol) == ["lock.fill", "circle", nil])
        #expect(items[0].accessories.last?.text == "Work")
        #expect(items[1].subtitle == nil)
        #expect(items[1].accessories.first?.symbol == "checkmark.circle.fill")
        #expect(items[0].actions.map(\.id) == ["open", "copy-link", "copy-title"])
        #expect(items[0].actions[1].kind == .copy(text: "applenotes://showNote?identifier=\(id)"))
        #expect(items[0].actions[2].kind == .copy(text: "Plan"))
    }

    private func titles(_ prism: PrismTestHost, _ query: String) async throws -> [String] {
        try await prism.list("search-notes", query: query).items.map(\.title)
    }

    @Test("Search covers title, snippet, folder, account, tags, and pinyin, every word required")
    func searchFields() async throws {
        let fixture = try NotesFixture()
        let account = try fixture.account("iCloud")
        let home = try fixture.folder("家")
        let work = try fixture.folder("Work")
        let hallway = try fixture.note("玄关", snippet: "玄关柜的电源改造", folder: home, account: account, modified: 3)
        try fixture.tag("#装修", on: hallway)
        try fixture.note("Résumé draft", snippet: "Ｆｕｌｌ width text", folder: work, modified: 2)
        try fixture.note("deepseek 改名为 deepseek flash", folder: work, modified: 1)
        let prism = try await host(fixture.url)

        #expect(try await titles(prism, "xuanguan") == ["玄关"])
        #expect(try await titles(prism, "xg") == ["玄关"])
        #expect(try await titles(prism, "dianyuan") == ["玄关"])
        #expect(try await titles(prism, "zhuangxiu") == ["玄关"])
        #expect(try await titles(prism, "#装修") == ["玄关"])
        #expect(try await titles(prism, "jia icloud") == ["玄关"])
        #expect(try await titles(prism, "resume full") == ["Résumé draft"])
        #expect(try await titles(prism, "work") == ["Résumé draft", "deepseek 改名为 deepseek flash"])
        #expect(try await titles(prism, "deepseek gaiming") == ["deepseek 改名为 deepseek flash"])
        #expect(try await titles(prism, "work 玄关").isEmpty)
        #expect(try await prism.list("search-notes", query: "nothing").emptyMessage?.title == "No Matching Notes")
    }

    @Test("Search reaches every note and returns the best matches up to the limit")
    func searchBeyondLimit() async throws {
        let fixture = try NotesFixture()
        let notes = try fixture.folder("Notes")
        try fixture.note("Ancient recipe", folder: notes, modified: 0)
        for index in 1...AppleNotes.resultLimit + 20 {
            try fixture.note("Note \(index)", snippet: "recipe ideas", folder: notes, modified: Double(index))
        }
        let prism = try await host(fixture.url)

        let browsing = try await titles(prism, "")
        #expect(browsing.count == AppleNotes.resultLimit)
        #expect(browsing.first == "Note \(AppleNotes.resultLimit + 20)")
        #expect(!browsing.contains("Ancient recipe"))

        let found = try await titles(prism, "recipe")
        #expect(found.count == AppleNotes.resultLimit)
        #expect(found.first == "Ancient recipe")
        #expect(try await titles(prism, "ancient") == ["Ancient recipe"])
    }

    @Test("Pinned notes stay first, and title matches rank above other matches")
    func searchRanking() async throws {
        let fixture = try NotesFixture()
        let notes = try fixture.folder("Notes")
        try fixture.note("Groceries", snippet: "budget for the week", folder: notes, modified: 4)
        try fixture.note("Budget 2026", folder: notes, modified: 1)
        try fixture.note("Ideas", snippet: "budget app", folder: notes, modified: 3, pinned: true)
        try fixture.note("Budget pinned", folder: notes, modified: 2, pinned: true)

        let items = try await host(fixture.url).list("search-notes", query: "budget").items

        #expect(items.map(\.title) == ["Budget pinned", "Ideas", "Budget 2026", "Groceries"])
        #expect(items.map(\.section) == ["Pinned", "Pinned", "Notes", "Notes"])
    }

    @Test("Pinyin is cached by text across loads and runs, and drops texts no note uses")
    func pinyinCache() async throws {
        let fixture = try NotesFixture()
        let notes = try fixture.folder("Notes")
        let first = try fixture.note("玄关", folder: notes, modified: 2)
        try fixture.note("书房", folder: notes, modified: 1)
        let data = fixture.folder.appendingPathComponent("data")
        let cacheFile = data.appendingPathComponent("pinyin.json")
        let prism = try await host(fixture.url, dataDirectory: data)

        _ = try await prism.list("search-notes")
        let cached = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: cacheFile))
        #expect(cached == ["玄关": ["xuanguan", "xg"], "书房": ["shufang", "sf"]])

        try fixture.execute("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE1 = '客厅' WHERE Z_PK = \(first)")
        try fixture.execute("DELETE FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE1 = '书房'")
        #expect(try await titles(prism, "keting") == ["客厅"])
        let pruned = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: cacheFile))
        #expect(pruned == ["客厅": ["keting", "kt"]])

        // A new process starts from the saved file.
        try fixture.execute("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE1 = '玄关' WHERE Z_PK = \(first)")
        try JSONEncoder().encode(["玄关": ["cached"]]).write(to: cacheFile)
        let restarted = try await host(fixture.url, dataDirectory: data)
        #expect(try await titles(restarted, "cached") == ["玄关"])
    }

    @Test("The library reuses its notes while the database is unchanged and rereads it after a change")
    func libraryReuse() throws {
        let fixture = try NotesFixture()
        let notes = try fixture.folder("Notes")
        try fixture.note("First", folder: notes, modified: 1)
        let library = NoteLibrary()
        let store = NoteStore(url: fixture.url)
        let pinyin = PinyinCache()
        func titles() throws -> [String] {
            try library.notes(from: store, pinyin: pinyin, directory: nil).map(\.note.title)
        }
        #expect(try titles() == ["First"])

        // Unchanged, the database is not opened again, even when it can't be.
        let path = fixture.url.path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        #expect(try titles() == ["First"])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        try fixture.note("Second", folder: notes, modified: 2)
        #expect(try titles() == ["Second", "First"])
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

    @Test("Without access the list asks Prism for the declared Notes folder")
    func accessDenied() async throws {
        let fixture = try NotesFixture()
        try fixture.note("Plan", folder: fixture.folder("Notes"), modified: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.url.path) }

        let list = try await host(fixture.url).list("search-notes", query: "plan")

        #expect(list.items.map(\.id) == ["allow-access"])
        #expect(list.items[0].primaryAction?.kind == .grantFolder(id: "notes"))
        let manifest = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("manifest.json"))
        )
        #expect(manifest.folder(id: "notes")?.url().path == NoteStore.defaultURL.deletingLastPathComponent().path)
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
