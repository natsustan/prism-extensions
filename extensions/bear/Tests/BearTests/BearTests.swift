import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import SQLite3
import Synchronization
import Testing
@testable import Bear

/// A temporary Bear `database.sqlite` with Core Data tables matching Bear 2
/// (or an older Bear 1-style schema when `legacySchema` is true).
private final class BearFixture {
    let folder: URL
    var url: URL { folder.appendingPathComponent("database.sqlite") }
    private var handle: OpaquePointer?
    private var nextNotePK: Int64 = 1
    private var nextTagPK: Int64 = 1
    private let legacySchema: Bool
    private var joinTable: String { legacySchema ? "Z_7TAGS" : "Z_5TAGS" }
    private var joinNoteCol: String { legacySchema ? "Z_7NOTES" : "Z_5NOTES" }
    private var joinTagCol: String { legacySchema ? "Z_14TAGS" : "Z_13TAGS" }

    init(legacySchema: Bool = false) throws {
        self.legacySchema = legacySchema
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BearTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)

        if legacySchema {
            try execute("""
                CREATE TABLE ZSFNOTE (
                    Z_PK INTEGER PRIMARY KEY, ZUNIQUEIDENTIFIER TEXT, ZTITLE TEXT, ZTEXT TEXT,
                    ZCREATIONDATE REAL, ZMODIFICATIONDATE REAL, ZPINNED INTEGER,
                    ZARCHIVED INTEGER, ZTRASHED INTEGER, ZENCRYPTED INTEGER,
                    ZTODOCOMPLETED INTEGER, ZTODOINCOMPLETED INTEGER
                )
                """)
            try execute("""
                CREATE TABLE ZSFNOTETAG (
                    Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT
                )
                """)
        } else {
            try execute("""
                CREATE TABLE ZSFNOTE (
                    Z_PK INTEGER PRIMARY KEY, ZUNIQUEIDENTIFIER TEXT, ZTITLE TEXT, ZSUBTITLE TEXT,
                    ZTEXT TEXT, ZCREATIONDATE REAL, ZMODIFICATIONDATE REAL, ZPINNED INTEGER,
                    ZARCHIVED INTEGER, ZTRASHED INTEGER, ZPERMANENTLYDELETED INTEGER,
                    ZENCRYPTED INTEGER, ZTODOCOMPLETED INTEGER, ZTODOINCOMPLETED INTEGER
                )
                """)
            try execute("""
                CREATE TABLE ZSFNOTETAG (
                    Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZPINNED INTEGER
                )
                """)
        }
        try execute("""
            CREATE TABLE \(joinTable) (
                \(joinNoteCol) INTEGER, \(joinTagCol) INTEGER
            )
            """)
        if !legacySchema {
            // Bear 2 also has a pinned-in-tag table whose name sorts ahead of
            // Z_5TAGS; discovery must ignore it and use Z_5TAGS.
            try execute("""
                CREATE TABLE Z_5PINNEDINTAGS (
                    Z_5PINNEDNOTES INTEGER, Z_13PINNEDINTAGS INTEGER
                )
                """)
        }
    }

    deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: folder)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw BearStoreError.unreadable(error.map { String(cString: $0) } ?? "")
        }
    }

    private static func quoted(_ text: String?) -> String {
        text.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
    }

    @discardableResult
    func note(
        _ title: String?,
        id: String = UUID().uuidString,
        subtitle: String? = nil,
        text: String? = nil,
        created: TimeInterval? = nil,
        modified: TimeInterval,
        pinned: Bool = false,
        archived: Bool = false,
        trashed: Bool = false,
        permanentlyDeleted: Bool = false,
        locked: Bool = false,
        todoCompleted: Int = 0,
        todoIncompleted: Int = 0
    ) throws -> Int64 {
        let pk = nextNotePK
        nextNotePK += 1
        var columns: [String: String] = [
            "Z_PK": "\(pk)",
            "ZUNIQUEIDENTIFIER": Self.quoted(id),
            "ZTITLE": Self.quoted(title),
            "ZTEXT": Self.quoted(text),
            "ZCREATIONDATE": created.map { "\($0)" } ?? "\(modified)",
            "ZMODIFICATIONDATE": "\(modified)",
            "ZPINNED": pinned ? "1" : "0",
            "ZARCHIVED": archived ? "1" : "0",
            "ZTRASHED": trashed ? "1" : "0",
            "ZENCRYPTED": locked ? "1" : "0",
            "ZTODOCOMPLETED": "\(todoCompleted)",
            "ZTODOINCOMPLETED": "\(todoIncompleted)",
        ]
        if !legacySchema {
            columns["ZSUBTITLE"] = Self.quoted(subtitle)
            columns["ZPERMANENTLYDELETED"] = permanentlyDeleted ? "1" : "0"
        }
        let keys = columns.keys.sorted()
        let values = keys.map { columns[$0]! }
        try execute("INSERT INTO ZSFNOTE (\(keys.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))")
        return pk
    }

    @discardableResult
    func tag(_ title: String, pinned: Bool = false) throws -> Int64 {
        let pk = nextTagPK
        nextTagPK += 1
        if legacySchema {
            try execute("INSERT INTO ZSFNOTETAG (Z_PK, ZTITLE) VALUES (\(pk), \(Self.quoted(title)))")
        } else {
            try execute("INSERT INTO ZSFNOTETAG (Z_PK, ZTITLE, ZPINNED) VALUES (\(pk), \(Self.quoted(title)), \(pinned ? 1 : 0))")
        }
        return pk
    }

    func link(note: Int64, tag: Int64) throws {
        try execute("INSERT INTO \(joinTable) (\(joinNoteCol), \(joinTagCol)) VALUES (\(note), \(tag))")
    }
}

private final class OpenedURLs: Sendable {
    private let urls = Mutex<[URL]>([])
    var all: [URL] { urls.withLock { $0 } }
    func open(_ url: URL) { urls.withLock { $0.append(url) } }
}

@Suite("Bear")
struct BearTests {
    static let today = Date(timeIntervalSinceReferenceDate: 3_600)

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func host(
        _ url: URL,
        opened: OpenedURLs = OpenedURLs(),
        clipboard: String? = nil,
        dataDirectory: URL? = nil,
        language: String = "en",
        now: Date = BearTests.today
    ) async throws -> PrismTestHost {
        try await PrismTestHost(
            Bear(
                store: BearStore(url: url),
                openURL: { opened.open($0) },
                readClipboard: { clipboard },
                now: { now },
                calendar: Self.utc
            ),
            extensionID: "prism.bear",
            dataDirectory: dataDirectory,
            language: language
        )
    }

    private func time(_ seconds: TimeInterval, language: String = "en") -> String {
        NoteDates(now: Self.today, calendar: Self.utc, locale: NoteDates.locale(prismLanguage: language))
            .label(for: Date(timeIntervalSinceReferenceDate: seconds))
    }

    @Test("Lists pinned notes first, then active notes newest first, excluding trashed, permanently deleted, and archived notes")
    func listsNotes() async throws {
        let fixture = try BearFixture()
        try fixture.note("Older", modified: 100)
        try fixture.note("Newest", modified: 300)
        try fixture.note("Pinned", modified: 50, pinned: true)
        try fixture.note("Trashed", modified: 400, trashed: true)
        try fixture.note("Purged", modified: 500, permanentlyDeleted: true)
        try fixture.note("Archived", modified: 600, archived: true)

        let list = try await host(fixture.url).list("search-notes")

        #expect(list.items.map(\.title) == ["Pinned", "Newest", "Older"])
        #expect(list.items.map(\.section) == ["Pinned", "Notes", "Notes"])
        #expect(list.filtering == .extension)
        #expect(list.showsDetail == true)
        #expect(list.filters.map(\.id) == ["all", "pinned", "todo", "untagged", "locked", "archived"])
    }

    @Test("Works with Bear 1 legacy schemas using Z_7TAGS and without ZSUBTITLE or ZPERMANENTLYDELETED")
    func legacySchema() async throws {
        let fixture = try BearFixture(legacySchema: true)
        let work = try fixture.tag("work")
        let note = try fixture.note("Roadmap", text: "# Roadmap\nShip Bear support", modified: 100)
        try fixture.link(note: note, tag: work)

        let prism = try await host(fixture.url)
        let notesList = try await prism.list("search-notes")
        let tagsList = try await prism.list("search-tags")

        #expect(notesList.items.map(\.title) == ["Roadmap"])
        #expect(notesList.items[0].subtitle == "\(time(100)) Ship Bear support")
        #expect(notesList.items[0].accessories.first?.text == "#work")
        #expect(tagsList.items.map(\.title) == ["#work"])
    }

    @Test("Row formatting shows one-line title, date and snippet, tag pill, lock, todos, and right actions")
    func rowFormattingAndActions() async throws {
        let fixture = try BearFixture()
        let work = try fixture.tag("work")
        let ideas = try fixture.tag("ideas")
        let id = "7E4B681B-639F-4444-8888-1234567890AB-1234-000012345678"
        let active = try fixture.note(
            "Plan\nNext Quarter",
            id: id,
            subtitle: "first line\n\n  second line",
            text: "# Plan\nfirst line\nsecond line",
            modified: 30,
            todoCompleted: 1,
            todoIncompleted: 2
        )
        try fixture.link(note: active, tag: work)
        try fixture.link(note: active, tag: ideas)
        try fixture.note("Secret", text: nil, modified: 20, locked: true)
        try fixture.note("", text: "Body without heading", modified: 10, todoCompleted: 3, todoIncompleted: 0)

        let items = try await host(fixture.url).list("search-notes").items

        #expect(items[0].id == id)
        #expect(items[0].title == "Plan Next Quarter")
        #expect(items[0].icon?.app == "net.shinyfrog.bear")
        #expect(items[0].subtitle == "\(time(30)) first line second line")
        #expect(items[0].accessories[0] == ExtensionListAccessory(text: "#ideas", tint: "gray", help: "#ideas #work", style: .tag))
        #expect(items[0].accessories[1].symbol == "circle")
        #expect(items[0].actions.map(\.id) == [
            "open-note", "open-note-new-window", "copy-note-link", "copy-markdown", "copy-note-title", "archive-note", "trash-note",
        ])
        #expect(items[0].actions[2].kind == .copy(text: "bear://x-callback-url/open-note?id=\(id)"))
        #expect(items[0].actions[4].kind == .copy(text: "Plan\nNext Quarter"))
        #expect(items[0].actions[6].style == .destructive)

        // Locked notes omit Copy Markdown, Archive, and Trash (Bear rejects them).
        #expect(items[1].accessories.map(\.symbol) == ["lock.fill"])
        #expect(items[1].actions.map(\.id) == ["open-note", "open-note-new-window", "copy-note-link", "copy-note-title"])

        // Untitled notes fall back to Untitled Note and derive a snippet from body text.
        #expect(items[2].title == "Untitled Note")
        #expect(items[2].subtitle == "\(time(10)) Body without heading")
        #expect(items[2].accessories.map(\.symbol) == ["checkmark.circle.fill"])
        #expect(!items[2].actions.map(\.id).contains("copy-note-title"))
    }

    @Test("Filters switch between pinned, todo, untagged, locked, and archived scopes")
    func filters() async throws {
        let fixture = try BearFixture()
        let work = try fixture.tag("work")
        let pinned = try fixture.note("Pinned", modified: 50, pinned: true)
        try fixture.link(note: pinned, tag: work)
        let todo = try fixture.note("Tasks", modified: 40, todoCompleted: 1, todoIncompleted: 1)
        try fixture.link(note: todo, tag: work)
        try fixture.note("Orphan", modified: 30)
        try fixture.note("Vault", modified: 20, locked: true)
        let archived = try fixture.note("Old Project", modified: 10, archived: true)
        try fixture.link(note: archived, tag: work)

        let prism = try await host(fixture.url)

        #expect(try await prism.list("search-notes", filter: "pinned").items.map(\.title) == ["Pinned"])
        #expect(try await prism.list("search-notes", filter: "todo").items.map(\.title) == ["Tasks"])
        #expect(try await prism.list("search-notes", filter: "untagged").items.map(\.title) == ["Orphan", "Vault"])
        #expect(try await prism.list("search-notes", filter: "locked").items.map(\.title) == ["Vault"])
        let archivedList = try await prism.list("search-notes", filter: "archived")
        #expect(archivedList.items.map(\.title) == ["Old Project"])
        #expect(!archivedList.items[0].actions.map(\.id).contains("archive-note"))
    }

    @Test("Search covers title, tags, snippet, full body text, and pinyin, ranking pinned then title then tags then body")
    func searchAndRanking() async throws {
        let fixture = try BearFixture()
        let home = try fixture.tag("装修/玄关")
        let work = try fixture.tag("work")
        let budget = try fixture.tag("budget")

        let hallway = try fixture.note("玄关改造", subtitle: "电源插座位置", text: "# 玄关改造\n电源插座位置\n米家开关", modified: 50)
        try fixture.link(note: hallway, tag: home)

        let bodyMatch = try fixture.note("Groceries", text: "# Groceries\nbudget for the week", modified: 40)
        try fixture.link(note: bodyMatch, tag: work)

        let tagMatch = try fixture.note("Quarterly Plan", text: "# Quarterly Plan\nQ4 review", modified: 30)
        try fixture.link(note: tagMatch, tag: budget)

        try fixture.note("Budget 2026", text: "# Budget 2026\nNumbers", modified: 10)
        try fixture.note("Pinned Notes", text: "# Pinned Notes\nbudget tracker", modified: 20, pinned: true)

        let prism = try await host(fixture.url)

        #expect(try await prism.list("search-notes", query: "xuanguan").items.map(\.title) == ["玄关改造"])
        #expect(try await prism.list("search-notes", query: "xggz").items.map(\.title) == ["玄关改造"])
        #expect(try await prism.list("search-notes", query: "dianyuan").items.map(\.title) == ["玄关改造"])
        #expect(try await prism.list("search-notes", query: "zhuangxiu").items.map(\.title) == ["玄关改造"])
        #expect(try await prism.list("search-notes", query: "#装修/玄关").items.map(\.title) == ["玄关改造"])
        #expect(try await prism.list("search-notes", query: "米家").items.map(\.title) == ["玄关改造"])
        // Cross-field search combines in-memory tag pinyin with streamed SQLite body text.
        #expect(try await prism.list("search-notes", query: "zhuangxiu 米家").items.map(\.title) == ["玄关改造"])
        // Body match works beyond 16 KiB because full text is streamed from SQLite.
        let longBody = "# Long Note\n" + String(repeating: "filler ", count: 3_000) + "needle-at-end"
        try fixture.note("Long Note", subtitle: "Short preview", text: longBody, modified: 5)
        #expect(try await prism.list("search-notes", query: "needle-at-end").items.map(\.title) == ["Long Note"])

        let ranked = try await prism.list("search-notes", query: "budget").items
        #expect(ranked.map(\.title) == ["Pinned Notes", "Budget 2026", "Quarterly Plan", "Groceries"])
        #expect(ranked.map(\.section) == ["Pinned", "Notes", "Notes", "Notes"])
    }

    @Test("When nothing matches in All Notes, offers a Create Note fallback row; other filters show empty state")
    func createFallbackRow() async throws {
        let fixture = try BearFixture()
        try fixture.note("Existing", modified: 100)
        let opened = OpenedURLs()
        let prism = try await host(fixture.url, opened: opened)

        let list = try await prism.list("search-notes", query: "  C++ & Swift #1  ")
        #expect(list.items.count == 1)
        #expect(list.items[0].id == "create:C++ & Swift #1")
        #expect(list.items[0].title == "Create “C++ & Swift #1”")

        let detail = try await prism.detail("create:C++ & Swift #1", in: "search-notes")
        #expect(detail.title == "Create “C++ & Swift #1”")
        #expect(detail.notice != nil)

        let result = try await prism.perform("create-note", on: "create:C++ & Swift #1", in: "search-notes")
        #expect(result == .done)
        #expect(opened.all == [URL(string: "bear://x-callback-url/create?title=C%2B%2B%20%26%20Swift%20%231&edit=yes")!])

        let pinnedEmpty = try await prism.list("search-notes", query: "C++ & Swift #1", filter: "pinned")
        #expect(pinnedEmpty.items.isEmpty)
        #expect(pinnedEmpty.emptyMessage?.title == "No Matching Notes")

        // An existing empty database still offers Create Note; a missing database does not.
        let emptyFixture = try BearFixture()
        #expect(try await host(emptyFixture.url).list("search-notes", query: "First Note").items.map(\.id) == ["create:First Note"])
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("BearTests-missing-\(UUID().uuidString)/database.sqlite")
        #expect(try await host(missing).list("search-notes", query: "First Note").items.isEmpty)
    }

    @Test("Detail pane returns Markdown and metadata, or a notice for locked and empty notes")
    func detailPane() async throws {
        let fixture = try BearFixture()
        let tag = try fixture.tag("projects/prism")
        let normalID = UUID().uuidString
        let lockedID = UUID().uuidString
        let emptyID = UUID().uuidString

        let normalPK = try fixture.note(
            "Launch Checklist",
            id: normalID,
            text: "# Launch Checklist\n- [x] Build\n- [ ] Ship",
            created: 100,
            modified: 200,
            pinned: true,
            todoCompleted: 1,
            todoIncompleted: 1
        )
        try fixture.link(note: normalPK, tag: tag)
        try fixture.note("Private Key", id: lockedID, text: "hidden", modified: 150, locked: true)
        try fixture.note("Blank", id: emptyID, text: "   ", modified: 120)

        let prism = try await host(fixture.url)

        let normalDetail = try await prism.detail(normalID, in: "search-notes")
        #expect(normalDetail.markdown == "# Launch Checklist\n- [x] Build\n- [ ] Ship")
        #expect(normalDetail.metadata.map(\.label) == ["Modified", "Created", "Tags", "Tasks", "Status"])
        #expect(normalDetail.metadata.first { $0.label == "Tags" }?.value == "#projects/prism")
        #expect(normalDetail.metadata.first { $0.label == "Tasks" }?.value == "1 / 2")
        #expect(normalDetail.metadata.first { $0.label == "Status" }?.value == "Pinned")

        let lockedDetail = try await prism.detail(lockedID, in: "search-notes")
        #expect(lockedDetail.markdown == nil)
        #expect(lockedDetail.notice?.symbol == "lock.fill")

        let emptyDetail = try await prism.detail(emptyID, in: "search-notes")
        #expect(emptyDetail.markdown == nil)
        #expect(emptyDetail.notice?.symbol == "note.text")
    }

    @Test("Note actions open, copy Markdown, archive, and trash through Bear URLs")
    func noteActions() async throws {
        let fixture = try BearFixture()
        let id = UUID().uuidString
        let lockedID = UUID().uuidString
        try fixture.note("Spec", id: id, text: "# Spec\nDetails", modified: 100)
        try fixture.note("Secret", id: lockedID, text: "secret", modified: 90, locked: true)
        let opened = OpenedURLs()
        let prism = try await host(fixture.url, opened: opened)

        #expect(try await prism.perform("open-note", on: id, in: "search-notes") == .done)
        #expect(try await prism.perform("open-note-new-window", on: id, in: "search-notes") == .done)
        #expect(try await prism.perform("copy-markdown", on: id, in: "search-notes")
            == ExtensionActionResult(.copy(text: "# Spec\nDetails", message: "Copied Markdown")))
        #expect(try await prism.perform("copy-markdown", on: lockedID, in: "search-notes")
            == ExtensionActionResult(.failed(message: "This note is locked in Bear.")))
        #expect(try await prism.perform("archive-note", on: id, in: "search-notes")
            == ExtensionActionResult(.hud(message: "Archived in Bear")))
        #expect(try await prism.perform("trash-note", on: id, in: "search-notes")
            == ExtensionActionResult(.hud(message: "Moved to Trash")))

        #expect(opened.all == [
            URL(string: "bear://x-callback-url/open-note?id=\(id)&edit=yes")!,
            URL(string: "bear://x-callback-url/open-note?id=\(id)&new_window=yes&edit=yes")!,
            URL(string: "bear://x-callback-url/archive?id=\(id)&show_window=no")!,
            URL(string: "bear://x-callback-url/trash?id=\(id)&show_window=no")!,
        ])

        #expect(try await prism.perform("open-note", on: "bad id", in: "search-notes")
            == ExtensionActionResult(.failed(message: "This note can’t be opened.")))
    }

    @Test("Search Bear Tags lists active tags with pinned first, supports pinyin, and opens tags in Bear")
    func searchTags() async throws {
        let fixture = try BearFixture()
        let work = try fixture.tag("work", pinned: true)
        let zh = try fixture.tag("工作/设计")
        let archivedOnly = try fixture.tag("old")

        let n1 = try fixture.note("One", modified: 30)
        let n2 = try fixture.note("Two", modified: 20)
        let n3 = try fixture.note("Three", modified: 10, archived: true)
        try fixture.link(note: n1, tag: work)
        try fixture.link(note: n2, tag: work)
        try fixture.link(note: n1, tag: zh)
        try fixture.link(note: n3, tag: archivedOnly)

        let opened = OpenedURLs()
        let prism = try await host(fixture.url, opened: opened)

        let list = try await prism.list("search-tags")
        #expect(list.items.map(\.title) == ["#work", "#工作/设计"])
        #expect(list.items.map(\.subtitle) == ["2 notes", "1 note"])
        #expect(list.items.map(\.section) == ["Pinned", "Tags"])
        #expect(list.showsDetail == false)
        #expect(list.items[0].actions.map(\.id) == ["open-tag", "copy-tag", "copy-tag-link"])
        #expect(list.items[0].actions[1].kind == .copy(text: "#work"))

        #expect(try await prism.list("search-tags", query: "sheji").items.map(\.title) == ["#工作/设计"])
        #expect(try await prism.list("search-tags", query: "#work").items.map(\.title) == ["#work"])
        #expect(try await prism.list("search-tags", query: "missing").emptyMessage?.title == "No Matching Tags")

        #expect(try await prism.perform("open-tag", on: "tag:工作/设计", in: "search-tags") == .done)
        #expect(opened.all == [
            URL(string: "bear://x-callback-url/open-tag?name=%E5%B7%A5%E4%BD%9C/%E8%AE%BE%E8%AE%A1")!,
        ])
    }

    @Test("New Note from Clipboard opens Bear when clipboard has text and fails cleanly when empty")
    func newNoteFromClipboard() async throws {
        let fixture = try BearFixture()
        let opened = OpenedURLs()

        let emptyPrism = try await host(fixture.url, opened: opened, clipboard: "   \n ")
        #expect(try await emptyPrism.run("new-note-from-clipboard")
            == .failed(message: "Clipboard has no text to create a note."))
        #expect(opened.all.isEmpty)

        let prism = try await host(fixture.url, opened: opened, clipboard: "Quick thought")
        #expect(try await prism.run("new-note-from-clipboard") == .done)
        #expect(opened.all == [URL(string: "bear://x-callback-url/create?clipboard=yes&edit=yes")!])
    }

    @Test("Pinyin cache persists across runs and prunes removed texts; library reuses cache while DB is unchanged")
    func cachingAndLibraryReuse() async throws {
        let fixture = try BearFixture()
        let first = try fixture.note("玄关", modified: 2)
        try fixture.note("书房", modified: 1)
        let data = fixture.folder.appendingPathComponent("data")
        let cacheFile = data.appendingPathComponent("pinyin.json")
        let prism = try await host(fixture.url, dataDirectory: data)

        _ = try await prism.list("search-notes")
        let cached = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: cacheFile))
        #expect(cached == ["玄关": ["xuanguan", "xg"], "书房": ["shufang", "sf"]])

        try fixture.execute("UPDATE ZSFNOTE SET ZTITLE = '客厅' WHERE Z_PK = \(first)")
        try fixture.execute("DELETE FROM ZSFNOTE WHERE ZTITLE = '书房'")
        #expect(try await prism.list("search-notes", query: "keting").items.map(\.title) == ["客厅"])
        let pruned = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: cacheFile))
        #expect(pruned == ["客厅": ["keting", "kt"]])

        // Library skips reopening SQLite while file signature is unchanged.
        let library = BearLibrary()
        let store = BearStore(url: fixture.url)
        let pinyin = PinyinCache()
        #expect(try await library.load(from: store, pinyin: pinyin, directory: nil).notes.map(\.note.title) == ["客厅"])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url.path) }
        #expect(try await library.load(from: store, pinyin: pinyin, directory: nil).notes.map(\.note.title) == ["客厅"])

        // A cancelled load does not persist pinyin.json.
        let cancelledDir = fixture.folder.appendingPathComponent("cancelled-data")
        let cancelledTask = Task {
            try await PinyinCache().keywords(for: ["玄关", "客厅"], directory: cancelledDir)
        }
        cancelledTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledTask.value
        }
        #expect(!FileManager.default.fileExists(atPath: cancelledDir.appendingPathComponent("pinyin.json").path))
    }

    @Test("Without access both lists ask Prism for the declared Bear folder; missing DB shows empty states")
    func accessDeniedAndMissing() async throws {
        let fixture = try BearFixture()
        try fixture.note("Plan", modified: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.url.path) }

        let prism = try await host(fixture.url)
        let notesList = try await prism.list("search-notes", query: "plan")
        let tagsList = try await prism.list("search-tags")

        #expect(notesList.items.map(\.id) == ["allow-access"])
        #expect(notesList.items[0].primaryAction?.kind == .grantFolder(id: "bear"))
        #expect(notesList.showsDetail == false)
        #expect(tagsList.items.map(\.id) == ["allow-access"])
        #expect(tagsList.items[0].primaryAction?.kind == .grantFolder(id: "bear"))

        let manifest = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("manifest.json"))
        )
        #expect(manifest.folder(id: "bear")?.url().path == BearStore.defaultContainerURL.path)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("BearTests-missing-\(UUID().uuidString)/database.sqlite")
        let missingHost = try await host(missing)
        #expect(try await missingHost.list("search-notes").emptyMessage?.title == "No Notes")
        #expect(try await missingHost.list("search-tags").emptyMessage?.title == "No Tags")
    }

    @Test("Simplified and Traditional Chinese localizations translate UI chrome and keep note content intact")
    func localizations() async throws {
        let fixture = try BearFixture()
        let tag = try fixture.tag("work")
        let id = UUID().uuidString
        let pk = try fixture.note("Roadmap", id: id, text: "# Roadmap\nHello", modified: 20, pinned: true)
        try fixture.link(note: pk, tag: tag)
        try fixture.note("Locked", modified: 10, locked: true)

        let hansHost = try await host(fixture.url, language: "zh-Hans")
        let hansNotes = try await hansHost.list("search-notes")
        #expect(hansNotes.searchPlaceholder == "按标题、内容或标签搜索笔记…")
        #expect(hansNotes.items.map(\.section) == ["已置顶", "笔记"])
        #expect(hansNotes.items[0].title == "Roadmap")
        #expect(hansNotes.items[0].actions.first?.title == "在 Bear 中打开")
        #expect(hansNotes.items[1].accessories.first?.help == "已锁定的笔记")
        #expect(try await hansHost.list("search-tags").items[0].subtitle == "1 条笔记")
        #expect(try await hansHost.detail(id, in: "search-notes").metadata.first?.label == "修改时间")

        let hantHost = try await host(fixture.url, language: "zh-Hant")
        let hantNotes = try await hantHost.list("search-notes")
        #expect(hantNotes.searchPlaceholder == "依標題、內容或標籤搜尋筆記…")
        #expect(hantNotes.items[0].actions.last?.title == "移至垃圾桶")
        #expect(try await hantHost.list("search-tags").items[0].subtitle == "1 則筆記")

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.url.path) }
        let row = try await host(fixture.url, language: "zh-Hant").list("search-notes").items[0]
        #expect(row.title == "允許取用你的 Bear 筆記")
        #expect(row.primaryAction?.title == "允許取用…")
    }
}
