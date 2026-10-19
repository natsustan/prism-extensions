import Foundation

/// What a typed query finds: notes where every word appears, ignoring case,
/// accents, and width, in the title, snippet, folder, account, or tags, or in
/// the pinyin of their Chinese. Pinned notes stay first; within each group,
/// notes whose title matches come before notes that match elsewhere, newest
/// first.
struct NoteSearch {
    /// Folded like `SearchableNote`'s text.
    let words: [String]

    init(query: String) {
        words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    /// The texts whose Chinese also matches as pinyin.
    static func pinyinSources(of note: Note) -> [String] {
        [note.title, note.snippet ?? "", note.folder] + note.tags
    }

    /// Text compared without case, accents, or width, so matching is a plain
    /// substring search.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Up to `limit` matching notes, best first. `notes` must be newest first.
    func results(in notes: [SearchableNote], limit: Int) -> [Note] {
        notes.enumerated()
            .compactMap { offset, entry in rank(of: entry).map { (entry.note, $0, offset) } }
            .sorted { ($0.0.isPinned ? 0 : 1, $0.1, $0.2) < ($1.0.isPinned ? 0 : 1, $1.1, $1.2) }
            .prefix(limit)
            .map(\.0)
    }

    /// 0 when the title matches, 1 when only other fields do, `nil` when the
    /// note does not match.
    func rank(of entry: SearchableNote) -> Int? {
        guard !words.isEmpty else { return 0 }
        if words.allSatisfy(entry.title.contains) { return 0 }
        return words.allSatisfy(entry.text.contains) ? 1 : nil
    }
}

/// A note with its searchable text folded once, so a keystroke only compares
/// substrings. Fields are joined by newlines, which a typed word never holds,
/// so a word cannot match across two fields.
struct SearchableNote: Sendable {
    let note: Note
    /// The title and its pinyin.
    let title: String
    /// Every searchable field, the title first.
    let text: String

    init(_ note: Note, pinyin: [String: [String]]) {
        self.note = note
        let titleFields = [note.title] + (pinyin[note.title] ?? [])
        var fields = titleFields + [note.snippet ?? "", note.folder, note.account ?? ""] + note.tags.map { "#\($0)" }
        for source in NoteSearch.pinyinSources(of: note).dropFirst() {
            fields += pinyin[source] ?? []
        }
        title = NoteSearch.fold(titleFields.joined(separator: "\n"))
        text = NoteSearch.fold(fields.joined(separator: "\n"))
    }
}
