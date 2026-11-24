import Foundation

/// Sidebar scopes for Search Bear Notes (⌘P).
enum BearNoteFilter: String, CaseIterable, Sendable {
    case all
    case pinned
    case todo
    case untagged
    case locked
    case archived

    init(filterID: String?) {
        self = filterID.flatMap(Self.init(rawValue:)) ?? .all
    }

    func includes(_ note: BearNote) -> Bool {
        switch self {
        case .all: !note.isArchived
        case .pinned: !note.isArchived && note.isPinned
        case .todo: !note.isArchived && note.todoIncompleted > 0
        case .untagged: !note.isArchived && note.tags.isEmpty
        case .locked: !note.isArchived && note.isLocked
        case .archived: note.isArchived
        }
    }
}

/// Searches Bear notes by title, tags, snippet, body text, and Chinese pinyin.
/// Every typed word must match. Pinned notes come first in the default scope;
/// within each group, title matches rank ahead of tag matches, then body
/// matches, newest first.
struct BearNoteSearch {
    let words: [String]

    init(query: String) {
        words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    /// Texts whose Chinese also matches as pinyin. Keeping full bodies out of
    /// pinyin transliteration keeps `pinyin.json` small and loads fast.
    static func pinyinSources(of note: BearNote) -> [String] {
        [note.title, note.snippet ?? ""] + note.tags
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Up to `limit` matching notes, best first. `notes` must be newest first.
    func results(in notes: [SearchableNote], filter: BearNoteFilter, limit: Int) -> [BearNote] {
        let pinFirst = filter == .all
        return notes.enumerated()
            .compactMap { offset, entry -> (BearNote, Int, Int)? in
                guard filter.includes(entry.note), let rank = rank(of: entry) else { return nil }
                return (entry.note, rank, offset)
            }
            .sorted { lhs, rhs in
                let lhsPin = pinFirst && lhs.0.isPinned ? 0 : 1
                let rhsPin = pinFirst && rhs.0.isPinned ? 0 : 1
                return (lhsPin, lhs.1, lhs.2) < (rhsPin, rhs.1, rhs.2)
            }
            .prefix(limit)
            .map(\.0)
    }

    /// 0 when the title matches, 1 when tags match, 2 when only other fields
    /// match, `nil` when the note does not match.
    func rank(of entry: SearchableNote) -> Int? {
        guard !words.isEmpty else { return 0 }
        if words.allSatisfy(entry.title.contains) { return 0 }
        if !entry.tags.isEmpty, words.allSatisfy(entry.tags.contains) { return 1 }
        return words.allSatisfy(entry.text.contains) ? 2 : nil
    }
}

/// A note with its searchable text folded once so keystrokes only compare
/// substrings. Fields are joined by newlines so words never match across them.
struct SearchableNote: Sendable {
    let note: BearNote
    let title: String
    let tags: String
    let text: String

    init(_ note: BearNote, pinyin: [String: [String]]) {
        self.note = note
        let titleFields = [note.title] + (pinyin[note.title] ?? [])
        let tagFields = note.tags.flatMap { tag -> [String] in
            ["#\(tag)"] + (pinyin[tag] ?? [])
        }
        let snippetPinyin = note.snippet.flatMap { pinyin[$0] } ?? []
        let allFields = titleFields + tagFields + [note.snippet ?? "", note.searchableBody] + snippetPinyin

        title = BearNoteSearch.fold(titleFields.joined(separator: "\n"))
        tags = BearNoteSearch.fold(tagFields.joined(separator: "\n"))
        text = BearNoteSearch.fold(allFields.joined(separator: "\n"))
    }
}

/// Searches Bear tags by name (with or without `#`) and Chinese pinyin.
struct BearTagSearch {
    let words: [String]

    init(query: String) {
        words = query.split(whereSeparator: \.isWhitespace).map { BearNoteSearch.fold(String($0)) }
    }

    func results(in tags: [SearchableTag], limit: Int) -> [BearTag] {
        tags.enumerated()
            .compactMap { offset, entry -> (BearTag, Int, Int)? in
                guard let rank = rank(of: entry) else { return nil }
                return (entry.tag, rank, offset)
            }
            .sorted { lhs, rhs in
                let lhsPin = lhs.0.isPinned ? 0 : 1
                let rhsPin = rhs.0.isPinned ? 0 : 1
                return (lhsPin, lhs.1, lhs.2) < (rhsPin, rhs.1, rhs.2)
            }
            .prefix(limit)
            .map(\.0)
    }

    private func rank(of entry: SearchableTag) -> Int? {
        guard !words.isEmpty else { return 0 }
        guard words.allSatisfy(entry.text.contains) else { return nil }
        let first = words[0].hasPrefix("#") ? String(words[0].dropFirst()) : words[0]
        return !first.isEmpty && entry.name.hasPrefix(first) ? 0 : 1
    }
}

struct SearchableTag: Sendable {
    let tag: BearTag
    let name: String
    let text: String

    init(_ tag: BearTag, pinyin: [String: [String]]) {
        self.tag = tag
        name = BearNoteSearch.fold(tag.name)
        let fields = ["#\(tag.name)"] + (pinyin[tag.name] ?? [])
        text = BearNoteSearch.fold(fields.joined(separator: "\n"))
    }
}
