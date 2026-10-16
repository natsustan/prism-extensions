import AppKit
import PrismExtensionKit

/// Searches Apple Notes from the launcher. Every load reads Notes' own
/// database, so the list follows edits made in Notes, and searches all notes
/// (`NoteSearch`) before cutting the results to `resultLimit`, as the Raycast
/// extension does.
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
    let openURL: @Sendable (URL) async throws -> Void

    init() {
        self.init(store: NoteStore(), openURL: Self.openWithWorkspace)
    }

    init(store: NoteStore, openURL: @escaping @Sendable (URL) async throws -> Void) {
        self.store = store
        self.openURL = openURL
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.search else {
            throw PrismExtensionError("Apple Notes has no list “\(command)”.")
        }
        let notes: [Note]
        do {
            notes = try store.notes()
        } catch NoteStoreError.accessDenied {
            return ExtensionList(items: [Self.allowAccessItem], filtering: .extension, searchPlaceholder: Self.searchPlaceholder)
        } catch NoteStoreError.missing {
            notes = []
        } catch let NoteStoreError.unreadable(reason) {
            throw PrismExtensionError("Couldn’t read Apple Notes: \(reason)")
        }
        let search = NoteSearch(query: query)
        let pinyin = pinyinCache.keywords(
            for: Set(notes.flatMap(NoteSearch.pinyinSources)), directory: context.dataDirectory
        )
        let results = search.results(in: notes, pinyin: pinyin, limit: Self.resultLimit)
        return ExtensionList(
            items: results.map(Self.item(for:)),
            filtering: .extension,
            searchPlaceholder: Self.searchPlaceholder,
            emptyMessage: search.words.isEmpty
                ? ExtensionListMessage(
                    title: "No Notes", message: "Notes you write in Apple Notes appear here.", symbol: "note.text"
                )
                : ExtensionListMessage(title: "No Matching Notes", symbol: "magnifyingglass"),
            fetchedAt: Date()
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        switch action {
        case ActionID.open:
            guard let url = Self.noteURL(item) else {
                throw PrismExtensionError("This note can’t be opened.")
            }
            try await openURL(url)
            return .done
        default:
            throw PrismExtensionError("Apple Notes has no action “\(action)”.")
        }
    }

    // MARK: - Items

    static let searchPlaceholder = "Search notes by title, folder, content, or tags…"
    /// Notes' own icon; the gold tile where Notes is missing.
    static let noteIcon = ExtensionIcon(symbol: "note.text", tint: "gold", app: "com.apple.Notes")

    static func item(for note: Note) -> ExtensionListItem {
        let link = noteURL(note.id)?.absoluteString
        var actions = [ExtensionAction(id: ActionID.open, title: "Open in Notes", symbol: "note.text")]
        if let link {
            actions.append(ExtensionAction(
                id: ActionID.copyLink, title: "Copy Note Link", symbol: "link",
                kind: .copy(text: link), shortcut: ExtensionShortcut("cmd+shift+c")
            ))
        }
        actions.append(ExtensionAction(
            id: ActionID.copyTitle, title: "Copy Note Title", symbol: "doc.on.doc",
            kind: .copy(text: note.title), shortcut: ExtensionShortcut("cmd+shift+t")
        ))
        return ExtensionListItem(
            id: note.id,
            title: note.title,
            subtitle: subtitle(note.snippet),
            icon: noteIcon,
            accessories: accessories(for: note),
            section: note.isPinned ? "Pinned" : "Notes",
            actions: actions
        )
    }

    /// Snippets keep the note's line breaks; a row shows one line.
    static func subtitle(_ snippet: String?) -> String? {
        guard let snippet else { return nil }
        let line = snippet.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    static func accessories(for note: Note) -> [ExtensionListAccessory] {
        var accessories = [ExtensionListAccessory]()
        if note.isLocked {
            accessories.append(ExtensionListAccessory(symbol: "lock.fill", help: "Locked note"))
        }
        if note.hasChecklist {
            accessories.append(note.isChecklistInProgress
                ? ExtensionListAccessory(symbol: "circle", help: "Checklist in progress")
                : ExtensionListAccessory(symbol: "checkmark.circle.fill", tint: "green", help: "Checklist done"))
        }
        if !note.folder.isEmpty {
            accessories.append(ExtensionListAccessory(text: note.folder, help: "Folder"))
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
    static let allowAccessItem = ExtensionListItem(
        id: allowAccessItemID,
        title: "Allow Access to Your Notes",
        subtitle: "Choose the Notes folder once, and Prism can search your notes",
        icon: ExtensionIcon(symbol: "lock.open", tint: "gray"),
        actions: [ExtensionAction(
            id: ActionID.allowAccess, title: "Allow Access…", symbol: "folder.badge.plus",
            kind: .grantFolder(id: notesFolderID)
        )]
    )

    private static func openWithWorkspace(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }
}
