import AppKit
import PrismExtensionKit

/// Searches Bear notes and tags from Prism's launcher. Every load checks Bear's
/// SQLite database and rereads it only when modified (`BearLibrary`), indexes
/// titles, tags, snippets, body text, and Chinese pinyin (`BearNoteSearch`),
/// previews Markdown in the detail pane, and opens or updates notes through
/// Bear's `x-callback-url` scheme.
@main
struct Bear: PrismExtension {
    enum CommandID {
        static let searchNotes = "search-notes"
        static let searchTags = "search-tags"
        static let newNoteFromClipboard = "new-note-from-clipboard"
    }

    enum ActionID {
        static let openNote = "open-note"
        static let openNoteNewWindow = "open-note-new-window"
        static let copyNoteLink = "copy-note-link"
        static let copyMarkdown = "copy-markdown"
        static let copyNoteTitle = "copy-note-title"
        static let archiveNote = "archive-note"
        static let trashNote = "trash-note"
        static let createNote = "create-note"
        static let openTag = "open-tag"
        static let copyTag = "copy-tag"
        static let copyTagLink = "copy-tag-link"
        static let allowAccess = "allow-access"
    }

    /// The manifest's folder ID for Bear's Group Container.
    static let bearFolderID = "bear"
    static let allowAccessItemID = "allow-access"
    static let createItemPrefix = "create:"
    static let tagItemPrefix = "tag:"

    /// Results per load so typing stays responsive on large libraries.
    static let resultLimit = 100

    let store: BearStore
    let pinyinCache = PinyinCache()
    let library = BearLibrary()
    let openURL: @Sendable (URL) async throws -> Void
    let readClipboard: @Sendable () -> String?
    let now: @Sendable () -> Date
    let calendar: Calendar

    init() {
        self.init(
            store: BearStore(),
            openURL: Self.openWithWorkspace,
            readClipboard: Self.readPasteboardString
        )
    }

    init(
        store: BearStore,
        openURL: @escaping @Sendable (URL) async throws -> Void,
        readClipboard: @escaping @Sendable () -> String? = Self.readPasteboardString,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
        self.openURL = openURL
        self.readClipboard = readClipboard
        self.now = now
        self.calendar = calendar
    }

    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        switch command {
        case CommandID.newNoteFromClipboard:
            guard let text = readClipboard(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .failed(message: localized("Clipboard has no text to create a note."))
            }
            try await openURL(BearURLs.createNoteFromClipboard)
            return .done
        default:
            throw PrismExtensionError(localized("Bear has no command “\(command)”."))
        }
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        switch command {
        case CommandID.searchNotes:
            return try await listNotes(query: query, filter: filter, context: context)
        case CommandID.searchTags:
            return try await listTags(query: query, context: context)
        default:
            throw PrismExtensionError(localized("Bear has no list “\(command)”."))
        }
    }

    func detail(command: String, item: String, context: PrismContext) async throws -> ExtensionDetail {
        guard command == CommandID.searchNotes, item != Self.allowAccessItemID else {
            return ExtensionDetail()
        }
        if item.hasPrefix(Self.createItemPrefix) {
            let title = String(item.dropFirst(Self.createItemPrefix.count))
            return BearRows.createNoteDetail(title: title)
        }
        try Task.checkCancellation()
        do {
            guard let note = try store.noteDetail(id: item) else {
                return ExtensionDetail()
            }
            try Task.checkCancellation()
            return BearRows.detail(for: note, dates: makeDates(now: now()))
        } catch BearStoreError.accessDenied, BearStoreError.missing {
            return ExtensionDetail()
        } catch let BearStoreError.unreadable(reason) {
            throw PrismExtensionError(localized("Couldn’t read Bear: \(reason)"))
        }
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        switch action {
        case ActionID.openNote:
            return try await open(
                BearURLs.openNote(id: item, edit: true),
                failure: localized("This note can’t be opened.")
            )

        case ActionID.openNoteNewWindow:
            return try await open(
                BearURLs.openNote(id: item, newWindow: true, edit: true),
                failure: localized("This note can’t be opened.")
            )

        case ActionID.copyMarkdown:
            return try copyMarkdown(id: item)

        case ActionID.archiveNote:
            return try await open(
                BearURLs.archiveNote(id: item),
                failure: localized("This note can’t be archived."),
                result: ExtensionActionResult(.hud(message: localized("Archived in Bear")))
            )

        case ActionID.trashNote:
            return try await open(
                BearURLs.trashNote(id: item),
                failure: localized("This note can’t be moved to Trash."),
                result: ExtensionActionResult(.hud(message: localized("Moved to Trash")))
            )

        case ActionID.createNote:
            let title = Self.stripPrefix(Self.createItemPrefix, from: item)
            return try await open(
                BearURLs.createNote(title: title),
                failure: localized("Couldn’t create this note.")
            )

        case ActionID.openTag:
            return try await open(
                BearURLs.openTag(name: Self.stripPrefix(Self.tagItemPrefix, from: item)),
                failure: localized("This tag can’t be opened.")
            )

        default:
            throw PrismExtensionError(localized("Bear has no action “\(action)”."))
        }
    }

    // MARK: - List & Action Helpers

    private enum LibraryState {
        case loaded(BearLibrary.CachedData)
        case missing
        case accessDenied
    }

    private func loadLibrary(context: PrismContext) async throws -> LibraryState {
        do {
            return .loaded(try await library.load(from: store, pinyin: pinyinCache, directory: context.dataDirectory))
        } catch BearStoreError.accessDenied {
            return .accessDenied
        } catch BearStoreError.missing {
            return .missing
        } catch let BearStoreError.unreadable(reason) {
            throw PrismExtensionError(localized("Couldn’t read Bear: \(reason)"))
        }
    }

    private func listNotes(query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        let noteFilter = BearNoteFilter(filterID: filter)
        let notes: [SearchableNote]
        let isMissing: Bool
        switch try await loadLibrary(context: context) {
        case let .loaded(cached):
            notes = cached.notes
            isMissing = false
        case .missing:
            notes = []
            isMissing = true
        case .accessDenied:
            return ExtensionList(
                items: [BearRows.allowAccessItem],
                filtering: .extension,
                searchPlaceholder: BearRows.notesSearchPlaceholder,
                filters: BearRows.noteFilters,
                showsDetail: false
            )
        }

        let search = BearNoteSearch(query: query)
        let bodyMatches: Set<String>
        if !isMissing {
            let candidates = search.bodySearchCandidates(in: notes, filter: noteFilter)
            do {
                bodyMatches = try store.bodyMatchIDs(
                    words: search.words,
                    filter: noteFilter,
                    candidates: candidates,
                    limit: Self.resultLimit
                )
            } catch BearStoreError.accessDenied, BearStoreError.missing {
                bodyMatches = []
            } catch let BearStoreError.unreadable(reason) {
                throw PrismExtensionError(localized("Couldn’t read Bear: \(reason)"))
            }
        } else {
            bodyMatches = []
        }
        let results = search.results(in: notes, filter: noteFilter, bodyMatches: bodyMatches, limit: Self.resultLimit)
        let loadedAt = now()
        let createTitle = BearStore.collapseWhitespace(query)
        if results.isEmpty, noteFilter == .all, !createTitle.isEmpty, !isMissing {
            return ExtensionList(
                items: [BearRows.createNoteItem(title: createTitle)],
                filtering: .extension,
                searchPlaceholder: BearRows.notesSearchPlaceholder,
                filters: BearRows.noteFilters,
                showsDetail: true,
                fetchedAt: loadedAt
            )
        }

        let dates = makeDates(now: loadedAt)
        let headed = noteFilter == .all && results.contains(where: \.isPinned)
        return ExtensionList(
            items: results.map { BearRows.noteItem(for: $0, headed: headed, dates: dates) },
            filtering: .extension,
            searchPlaceholder: BearRows.notesSearchPlaceholder,
            filters: BearRows.noteFilters,
            emptyMessage: BearRows.emptyNotesMessage(for: noteFilter, hasQuery: !search.words.isEmpty),
            showsDetail: !results.isEmpty,
            fetchedAt: loadedAt
        )
    }

    private func listTags(query: String, context: PrismContext) async throws -> ExtensionList {
        let tags: [SearchableTag]
        switch try await loadLibrary(context: context) {
        case let .loaded(cached):
            tags = cached.tags
        case .missing:
            tags = []
        case .accessDenied:
            return ExtensionList(
                items: [BearRows.allowAccessItem],
                filtering: .extension,
                searchPlaceholder: BearRows.tagsSearchPlaceholder
            )
        }

        let search = BearTagSearch(query: query)
        let results = search.results(in: tags, limit: Self.resultLimit)
        let loadedAt = now()
        let headed = results.contains(where: \.isPinned)
        return ExtensionList(
            items: results.map { BearRows.tagItem(for: $0, headed: headed) },
            filtering: .extension,
            searchPlaceholder: BearRows.tagsSearchPlaceholder,
            emptyMessage: BearRows.emptyTagsMessage(hasQuery: !search.words.isEmpty),
            showsDetail: false,
            fetchedAt: loadedAt
        )
    }

    private func copyMarkdown(id: String) throws -> ExtensionActionResult {
        do {
            guard let note = try store.noteDetail(id: id) else {
                return ExtensionActionResult(.failed(message: localized("This note can’t be opened.")))
            }
            if note.isLocked {
                return ExtensionActionResult(.failed(message: localized("This note is locked in Bear.")))
            }
            guard !note.markdown.isEmpty else {
                return ExtensionActionResult(.failed(message: localized("This note has no text to copy.")))
            }
            return ExtensionActionResult(.copy(text: note.markdown, message: localized("Copied Markdown")))
        } catch BearStoreError.accessDenied, BearStoreError.missing {
            return ExtensionActionResult(.failed(message: localized("This note can’t be opened.")))
        } catch let BearStoreError.unreadable(reason) {
            throw PrismExtensionError(localized("Couldn’t read Bear: \(reason)"))
        }
    }

    private func open(
        _ url: URL?,
        failure: String,
        result: ExtensionActionResult = .done
    ) async throws -> ExtensionActionResult {
        guard let url else { return ExtensionActionResult(.failed(message: failure)) }
        try await openURL(url)
        return result
    }

    private func makeDates(now: Date) -> NoteDates {
        NoteDates(now: now, calendar: calendar, locale: NoteDates.locale(prismLanguage: PrismLocalization.language))
    }

    private static func stripPrefix(_ prefix: String, from value: String) -> String {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    private static func openWithWorkspace(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func readPasteboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
