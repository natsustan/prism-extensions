import AppKit
import PrismExtensionKit

/// Searches Apple Notes from the launcher. The list is read from Notes' own
/// database on every load, so it follows edits made in Notes; Prism filters it
/// as the user types, matching titles, snippets, folders, tags, and pinyin.
@main
struct AppleNotes: PrismExtension {
    enum CommandID {
        static let search = "search-notes"
    }

    enum ActionID {
        static let open = "open"
        static let copyLink = "copy-link"
        static let copyTitle = "copy-title"
        static let openPrivacySettings = "open-privacy-settings"
    }

    static let fullDiskAccessItemID = "full-disk-access"
    static let fullDiskAccessSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    let store: NoteStore
    /// The app that launched this extension, named in the permission prompt:
    /// macOS grants Full Disk Access to Prism, not to the extension.
    let hostName: @Sendable () -> String
    let openURL: @Sendable (URL) async throws -> Void

    init() {
        self.init(store: NoteStore(), hostName: Self.parentAppName, openURL: Self.openWithWorkspace)
    }

    init(
        store: NoteStore,
        hostName: @escaping @Sendable () -> String = { "Prism" },
        openURL: @escaping @Sendable (URL) async throws -> Void
    ) {
        self.store = store
        self.hostName = hostName
        self.openURL = openURL
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.search else {
            throw PrismExtensionError("Apple Notes has no list “\(command)”.")
        }
        let notes: [Note]
        do {
            notes = try store.notes(limit: ExtensionList.maximumItems)
        } catch NoteStoreError.accessDenied {
            return ExtensionList(items: [fullDiskAccessItem()], searchPlaceholder: Self.searchPlaceholder)
        } catch NoteStoreError.missing {
            notes = []
        } catch let NoteStoreError.unreadable(reason) {
            throw PrismExtensionError("Couldn’t read Apple Notes: \(reason)")
        }
        let ordered = notes.filter(\.isPinned) + notes.filter { !$0.isPinned }
        let pinyin = PinyinCache(directory: context.dataDirectory).keywords(
            for: Dictionary(notes.map { ($0.id, Self.pinyinSources(of: $0)) }) { first, _ in first }
        )
        return ExtensionList(
            items: ordered.map { Self.item(for: $0, pinyin: pinyin[$0.id] ?? []) },
            searchPlaceholder: Self.searchPlaceholder,
            emptyMessage: ExtensionListMessage(
                title: "No Notes",
                message: "Notes you write in Apple Notes appear here.",
                symbol: "note.text"
            ),
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
        case ActionID.openPrivacySettings:
            try await openURL(Self.fullDiskAccessSettings)
            return .done
        default:
            throw PrismExtensionError("Apple Notes has no action “\(action)”.")
        }
    }

    // MARK: - Items

    static let searchPlaceholder = "Search notes by title, folder, content, or tags…"
    static let noteIcon = ExtensionIcon(symbol: "note.text", tint: "gold")

    static func item(for note: Note, pinyin: [String]) -> ExtensionListItem {
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
            keywords: keywords(for: note, pinyin: pinyin),
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

    /// Prism already matches the title, subtitle, and section; these add the
    /// folder, account, tags, and the pinyin of `pinyinSources`.
    static func keywords(for note: Note, pinyin: [String]) -> [String] {
        var words = [note.folder] + note.tags + pinyin
        if let account = note.account { words.append(account) }
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The texts whose Chinese also matches as pinyin.
    static func pinyinSources(of note: Note) -> [String] {
        [note.title, note.snippet ?? "", note.folder] + note.tags
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

    // MARK: - Full Disk Access

    func fullDiskAccessItem() -> ExtensionListItem {
        let host = hostName()
        return ExtensionListItem(
            id: Self.fullDiskAccessItemID,
            title: "Allow \(host) to Read Your Notes",
            subtitle: "Turn on Full Disk Access for \(host) in System Settings",
            icon: ExtensionIcon(symbol: "lock.shield", tint: "gray"),
            actions: [ExtensionAction(
                id: ActionID.openPrivacySettings, title: "Open Privacy Settings", symbol: "gear"
            )]
        )
    }

    private static func parentAppName() -> String {
        NSRunningApplication(processIdentifier: getppid())?.localizedName ?? "Prism"
    }

    private static func openWithWorkspace(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }
}
