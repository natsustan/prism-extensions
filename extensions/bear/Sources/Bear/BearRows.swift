import Foundation
import PrismExtensionKit

/// Maps Bear notes, tags, filters, detail panes, and access prompts into Prism
/// list items and actions.
enum BearRows {
    typealias ActionID = Bear.ActionID

    /// Bear's own icon; a red note tile where Bear is not installed.
    static let noteIcon = ExtensionIcon(symbol: "note.text", tint: "red", app: "net.shinyfrog.bear")

    static var notesSearchPlaceholder: String {
        localized("Search notes by title, content, or tags…")
    }

    static var tagsSearchPlaceholder: String {
        localized("Search tags…")
    }

    static var noteFilters: [ExtensionListFilter] {
        [
            ExtensionListFilter(id: BearNoteFilter.all.rawValue, title: localized("All Notes"), symbol: "note.text"),
            ExtensionListFilter(id: BearNoteFilter.pinned.rawValue, title: localized("Pinned"), symbol: "pin"),
            ExtensionListFilter(id: BearNoteFilter.todo.rawValue, title: localized("Todo"), symbol: "checklist"),
            ExtensionListFilter(id: BearNoteFilter.untagged.rawValue, title: localized("Untagged"), symbol: "tag.slash"),
            ExtensionListFilter(id: BearNoteFilter.locked.rawValue, title: localized("Locked"), symbol: "lock"),
            ExtensionListFilter(id: BearNoteFilter.archived.rawValue, title: localized("Archived"), symbol: "archivebox"),
        ]
    }

    static func emptyNotesMessage(for filter: BearNoteFilter, hasQuery: Bool) -> ExtensionListMessage {
        if hasQuery {
            return ExtensionListMessage(title: localized("No Matching Notes"), symbol: "magnifyingglass")
        }
        return switch filter {
        case .all:
            ExtensionListMessage(
                title: localized("No Notes"),
                message: localized("Notes you write in Bear appear here."),
                symbol: "note.text"
            )
        case .pinned:
            ExtensionListMessage(
                title: localized("No Pinned Notes"),
                message: localized("Pin a note in Bear to see it here."),
                symbol: "pin"
            )
        case .todo:
            ExtensionListMessage(
                title: localized("No Todo Notes"),
                message: localized("Notes with incomplete tasks appear here."),
                symbol: "checklist"
            )
        case .untagged:
            ExtensionListMessage(
                title: localized("No Untagged Notes"),
                message: localized("Notes without tags appear here."),
                symbol: "tag.slash"
            )
        case .locked:
            ExtensionListMessage(
                title: localized("No Locked Notes"),
                message: localized("Encrypted notes in Bear appear here."),
                symbol: "lock"
            )
        case .archived:
            ExtensionListMessage(
                title: localized("No Archived Notes"),
                message: localized("Notes you archive in Bear appear here."),
                symbol: "archivebox"
            )
        }
    }

    static func emptyTagsMessage(hasQuery: Bool) -> ExtensionListMessage {
        if hasQuery {
            return ExtensionListMessage(title: localized("No Matching Tags"), symbol: "magnifyingglass")
        }
        return ExtensionListMessage(
            title: localized("No Tags"),
            message: localized("Tags from your Bear notes appear here."),
            symbol: "number"
        )
    }

    // MARK: - Notes

    static func displayTitle(for rawTitle: String) -> String {
        oneLine(rawTitle) ?? localized("Untitled Note")
    }

    static func noteItem(for note: BearNote, headed: Bool, dates: NoteDates) -> ExtensionListItem {
        let title = displayTitle(for: note.title)
        let link = BearURLs.openNote(id: note.id)?.absoluteString
        var actions = [
            ExtensionAction(id: ActionID.openNote, title: localized("Open in Bear"), symbol: "note.text"),
            ExtensionAction(
                id: ActionID.openNoteNewWindow,
                title: localized("Open in New Window"),
                symbol: "macwindow.badge.plus",
                shortcut: ExtensionShortcut("cmd+shift+o")
            ),
        ]
        if let link {
            actions.append(ExtensionAction(
                id: ActionID.copyNoteLink,
                title: localized("Copy Note Link"),
                symbol: "link",
                kind: .copy(text: link),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ))
        }
        if !note.isLocked {
            actions.append(ExtensionAction(
                id: ActionID.copyMarkdown,
                title: localized("Copy Markdown"),
                symbol: "doc.plaintext",
                shortcut: ExtensionShortcut("cmd+shift+m")
            ))
        }
        if !note.title.isEmpty {
            actions.append(ExtensionAction(
                id: ActionID.copyNoteTitle,
                title: localized("Copy Note Title"),
                symbol: "doc.on.doc",
                kind: .copy(text: note.title),
                shortcut: ExtensionShortcut("cmd+shift+t")
            ))
        }
        if !note.isLocked, !note.isArchived {
            actions.append(ExtensionAction(
                id: ActionID.archiveNote,
                title: localized("Archive Note"),
                symbol: "archivebox",
                shortcut: ExtensionShortcut("cmd+shift+a")
            ))
        }
        if !note.isLocked {
            actions.append(ExtensionAction(
                id: ActionID.trashNote,
                title: localized("Move to Trash"),
                symbol: "trash",
                style: .destructive,
                confirmationMessage: localized("Move “\(title)” to Bear’s Trash?")
            ))
        }

        return ExtensionListItem(
            id: note.id,
            title: title,
            subtitle: noteSubtitle(for: note, dates: dates),
            icon: noteIcon,
            accessories: noteAccessories(for: note),
            section: headed ? (note.isPinned ? localized("Pinned") : localized("Notes")) : nil,
            actions: actions
        )
    }

    static func noteSubtitle(for note: BearNote, dates: NoteDates) -> String {
        [dates.label(for: note.modifiedAt), note.snippet.flatMap(oneLine)]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    static func noteAccessories(for note: BearNote) -> [ExtensionListAccessory] {
        var accessories = [ExtensionListAccessory]()
        if let firstTag = note.tags.first {
            let allTags = note.tags.map { "#\($0)" }.joined(separator: " ")
            accessories.append(ExtensionListAccessory(
                text: "#\(firstTag)",
                tint: "gray",
                help: allTags,
                style: .tag
            ))
        }
        if note.isLocked {
            accessories.append(ExtensionListAccessory(symbol: "lock.fill", help: localized("Locked note")))
        }
        if note.hasTodos {
            accessories.append(note.todoIncompleted > 0
                ? ExtensionListAccessory(symbol: "circle", help: localized("Tasks in progress"))
                : ExtensionListAccessory(symbol: "checkmark.circle.fill", tint: "green", help: localized("Tasks completed")))
        }
        return accessories
    }

    static func createNoteItem(title: String) -> ExtensionListItem {
        ExtensionListItem(
            id: Bear.createItemPrefix + title,
            title: localized("Create “\(title)”"),
            subtitle: localized("No matching notes — press Return to create in Bear"),
            icon: ExtensionIcon(symbol: "square.and.pencil", tint: "red"),
            actions: [
                ExtensionAction(id: ActionID.createNote, title: localized("Create Note in Bear"), symbol: "square.and.pencil")
            ]
        )
    }

    // MARK: - Detail

    static func detail(for note: BearNoteDetail, dates: NoteDates) -> ExtensionDetail {
        let title = displayTitle(for: note.title)
        var metadata = [
            ExtensionMetadataRow(label: localized("Modified"), value: dates.detailLabel(for: note.modifiedAt)),
        ]
        if let createdAt = note.createdAt {
            metadata.append(ExtensionMetadataRow(label: localized("Created"), value: dates.detailLabel(for: createdAt)))
        }
        if !note.tags.isEmpty {
            metadata.append(ExtensionMetadataRow(
                label: localized("Tags"),
                value: note.tags.map { "#\($0)" }.joined(separator: ", ")
            ))
        }
        if note.hasTodos {
            metadata.append(ExtensionMetadataRow(
                label: localized("Tasks"),
                value: "\(note.todoCompleted) / \(note.todoTotal)"
            ))
        }
        var statuses = [String]()
        if note.isPinned { statuses.append(localized("Pinned")) }
        if note.isArchived { statuses.append(localized("Archived")) }
        if note.isLocked { statuses.append(localized("Locked")) }
        if !statuses.isEmpty {
            metadata.append(ExtensionMetadataRow(
                label: localized("Status"),
                value: statuses.joined(separator: ", "),
                style: .badge
            ))
        }

        if note.isLocked {
            return ExtensionDetail(
                title: title,
                icon: noteIcon,
                notice: ExtensionNotice(
                    text: localized("Unlock this note in Bear to view or copy its contents."),
                    symbol: "lock.fill",
                    tone: .warning
                ),
                metadata: metadata
            )
        }

        let trimmedMarkdown = note.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMarkdown.isEmpty {
            return ExtensionDetail(
                title: title,
                icon: noteIcon,
                notice: ExtensionNotice(
                    text: localized("This note has no body text yet."),
                    symbol: "note.text",
                    tone: .normal
                ),
                metadata: metadata
            )
        }

        return ExtensionDetail(
            markdown: note.markdown,
            metadata: metadata
        )
    }

    static func createNoteDetail(title: String) -> ExtensionDetail {
        ExtensionDetail(
            title: localized("Create “\(title)”"),
            icon: ExtensionIcon(symbol: "square.and.pencil", tint: "red"),
            notice: ExtensionNotice(
                text: localized("Press Return to create a new note with this title in Bear."),
                symbol: "square.and.pencil",
                tone: .normal
            )
        )
    }

    // MARK: - Tags

    static func tagItem(for tag: BearTag, headed: Bool) -> ExtensionListItem {
        let display = "#\(tag.name)"
        let countText = tag.noteCount == 1
            ? localized("1 note")
            : localized("\(tag.noteCount) notes")
        var actions = [
            ExtensionAction(id: ActionID.openTag, title: localized("Open in Bear"), symbol: "number"),
            ExtensionAction(
                id: ActionID.openTagNewWindow,
                title: localized("Open in New Window"),
                symbol: "macwindow.badge.plus",
                shortcut: ExtensionShortcut("cmd+shift+o")
            ),
            ExtensionAction(
                id: ActionID.copyTag,
                title: localized("Copy Tag"),
                symbol: "doc.on.doc",
                kind: .copy(text: display),
                shortcut: ExtensionShortcut("cmd+shift+c")
            ),
        ]
        if let link = BearURLs.openTag(name: tag.name)?.absoluteString {
            actions.append(ExtensionAction(
                id: ActionID.copyTagLink,
                title: localized("Copy Tag Link"),
                symbol: "link",
                kind: .copy(text: link),
                shortcut: ExtensionShortcut("cmd+shift+l")
            ))
        }

        return ExtensionListItem(
            id: Bear.tagItemPrefix + tag.name,
            title: display,
            subtitle: countText,
            icon: ExtensionIcon(symbol: tag.isPinned ? "pin" : "number", tint: "red", style: .glyph),
            section: headed ? (tag.isPinned ? localized("Pinned") : localized("Tags")) : nil,
            actions: actions
        )
    }

    // MARK: - Access

    /// macOS protects Bear's Group Container. Prism asks the user to choose the
    /// folder declared in the manifest, which lets Prism and this extension
    /// read it from then on; the list reloads afterwards.
    static var allowAccessItem: ExtensionListItem {
        ExtensionListItem(
            id: Bear.allowAccessItemID,
            title: localized("Allow Access to Your Bear Notes"),
            subtitle: localized("Choose the Bear folder once, and Prism can search your notes and tags"),
            icon: ExtensionIcon(symbol: "lock.open", tint: "gray"),
            actions: [ExtensionAction(
                id: ActionID.allowAccess,
                title: localized("Allow Access…"),
                symbol: "folder.badge.plus",
                kind: .grantFolder(id: Bear.bearFolderID)
            )]
        )
    }

    /// Titles and snippets may hold line breaks, tabs, or U+2028 line
    /// separators; a list row displays one line, so each run becomes one space.
    static func oneLine(_ text: String) -> String? {
        let line = BearStore.collapseWhitespace(text)
        return line.isEmpty ? nil : line
    }
}
