import AppKit
import PrismExtensionKit

/// Searches Apple Notes from the launcher. Every load checks Notes' own
/// database and rereads it when it changed (`NoteLibrary`), so the list
/// follows edits made in Notes, and searches all notes (`NoteSearch`) before
/// cutting the results to `resultLimit`, as the Raycast extension does.
@main
struct AppleNotes: PrismExtension {
    enum CommandID {
        static let search = "search-notes"
    }

    enum ActionID {
        static let open = "open"
        static let copyLink = "copy-link"
        static let copyTitle = "copy-title"
        static let allowAccess = "allow-access"
    }

    /// The manifest's folder for the Notes library.
    static let notesFolderID = "notes"
    static let allowAccessItemID = "allow-access"

    /// Results per load. More would slow every keystroke for rows nobody
    /// scrolls to; typing narrows the search instead.
    static let resultLimit = 100

    let store: NoteStore
    let pinyinCache = PinyinCache()
    let library = NoteLibrary()
    let openURL: @Sendable (URL) async throws -> Void
    let now: @Sendable () -> Date
    let calendar: Calendar

    init() {
        self.init(store: NoteStore(), openURL: Self.openWithWorkspace)
    }

    init(
        store: NoteStore,
        openURL: @escaping @Sendable (URL) async throws -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
        self.openURL = openURL
        self.now = now
        self.calendar = calendar
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.search else {
            throw PrismExtensionError(localized("Apple Notes has no list “\(command)”."))
        }
        let notes: [SearchableNote]
        do {
            notes = try library.notes(from: store, pinyin: pinyinCache, directory: context.dataDirectory)
        } catch NoteStoreError.accessDenied {
            return ExtensionList(items: [Self.allowAccessItem], filtering: .extension, searchPlaceholder: Self.searchPlaceholder)
        } catch NoteStoreError.missing {
            notes = []
        } catch let NoteStoreError.unreadable(reason) {
            throw PrismExtensionError(localized("Couldn’t read Apple Notes: \(reason)"))
        }
        let search = NoteSearch(query: query)
        let results = search.results(in: notes, limit: Self.resultLimit)
        let loadedAt = now()
        let dates = NoteDates(
            now: loadedAt, calendar: calendar, locale: NoteDates.locale(prismLanguage: PrismLocalization.language)
        )
        let hasPinned = results.contains(where: \.isPinned)
        return ExtensionList(
            items: results.map { Self.item(for: $0, headed: hasPinned, dates: dates) },
            filtering: .extension,
            searchPlaceholder: Self.searchPlaceholder,
            emptyMessage: search.words.isEmpty
                ? ExtensionListMessage(
                    title: localized("No Notes"), message: localized("Notes you write in Apple Notes appear here."), symbol: "note.text"
                )
                : ExtensionListMessage(title: localized("No Matching Notes"), symbol: "magnifyingglass"),
            fetchedAt: loadedAt
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        switch action {
        case ActionID.open:
            guard let url = Self.noteURL(item) else {
                throw PrismExtensionError(localized("This note can’t be opened."))
            }
            try await openURL(url)
            return .done
        default:
            throw PrismExtensionError(localized("Apple Notes has no action “\(action)”."))
        }
    }

    // MARK: - Items

    static var searchPlaceholder: String { localized("Search notes by title, folder, content, or tags…") }
    /// Notes' own icon; the gold tile where Notes is missing.
    static let noteIcon = ExtensionIcon(symbol: "note.text", tint: "gold", app: "com.apple.Notes")

    /// Headings appear only when pinned notes are listed, to set them apart;
    /// otherwise a lone "Notes" heading would repeat the scope's own title.
    static func item(for note: Note, headed: Bool, dates: NoteDates) -> ExtensionListItem {
        let title = oneLine(note.title) ?? note.title
        let link = noteURL(note.id)?.absoluteString
        var actions = [ExtensionAction(id: ActionID.open, title: localized("Open in Notes"), symbol: "note.text")]
        if let link {
            actions.append(ExtensionAction(
                id: ActionID.copyLink, title: localized("Copy Note Link"), symbol: "link",
                kind: .copy(text: link), shortcut: ExtensionShortcut("cmd+shift+c")
            ))
        }
        actions.append(ExtensionAction(
            id: ActionID.copyTitle, title: localized("Copy Note Title"), symbol: "doc.on.doc",
            kind: .copy(text: note.title), shortcut: ExtensionShortcut("cmd+shift+t")
        ))
        return ExtensionListItem(
            id: note.id,
            title: title,
            subtitle: subtitle(for: note, dates: dates),
            icon: noteIcon,
            accessories: accessories(for: note),
            section: headed ? (note.isPinned ? localized("Pinned") : localized("Notes")) : nil,
            actions: actions
        )
    }

    /// Titles and snippets keep the note's tabs and line breaks, including
    /// the line separators (U+2028) Notes writes for Shift-Return; a row
    /// shows one line, so each run of them becomes a single space.
    static func oneLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// When the note last changed, its folder, then the start of its text,
    /// as Notes' list puts the date before the preview. Every row then has
    /// a second line, even a note with nothing after its title. Notes'
    /// default folder holds most notes, so naming it says nothing.
    static func subtitle(for note: Note, dates: NoteDates) -> String {
        let folder = note.folder.isEmpty || note.isInDefaultFolder ? nil : note.folder
        return [dates.label(for: note.modifiedAt), folder, note.snippet.flatMap(oneLine)]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    static func accessories(for note: Note) -> [ExtensionListAccessory] {
        var accessories = [ExtensionListAccessory]()
        if note.isLocked {
            accessories.append(ExtensionListAccessory(symbol: "lock.fill", help: localized("Locked note")))
        }
        if note.hasChecklist {
            accessories.append(note.isChecklistInProgress
                ? ExtensionListAccessory(symbol: "circle", help: localized("Checklist in progress"))
                : ExtensionListAccessory(symbol: "checkmark.circle.fill", tint: "green", help: localized("Checklist done")))
        }
        return accessories
    }

    /// The link Notes opens a note from (macOS 14 and later).
    static func noteURL(_ identifier: String) -> URL? {
        guard UUID(uuidString: identifier) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "applenotes"
        components.host = "showNote"
        components.queryItems = [URLQueryItem(name: "identifier", value: identifier)]
        return components.url
    }

    // MARK: - Access

    /// macOS protects the Notes library. Prism asks the user to choose the
    /// folder declared in the manifest, which lets Prism, and this extension,
    /// read it from then on; the list reloads afterwards.
    static var allowAccessItem: ExtensionListItem {
        ExtensionListItem(
            id: allowAccessItemID,
            title: localized("Allow Access to Your Notes"),
            subtitle: localized("Choose the Notes folder once, and Prism can search your notes"),
            icon: ExtensionIcon(symbol: "lock.open", tint: "gray"),
            actions: [ExtensionAction(
                id: ActionID.allowAccess, title: localized("Allow Access…"), symbol: "folder.badge.plus",
                kind: .grantFolder(id: notesFolderID)
            )]
        )
    }

    private static func openWithWorkspace(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }
}
