import Foundation

/// What a typed query finds: notes where every word appears, ignoring case,
/// accents, and width, in the title, snippet, folder, account, or tags, or in
/// the pinyin of their Chinese. Pinned notes stay first; within each group,
/// notes whose title matches come before notes that match elsewhere, newest
/// first.
struct NoteSearch {
    let words: [String]

    init(query: String) {
        words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The texts whose Chinese also matches as pinyin.
    static func pinyinSources(of note: Note) -> [String] {
        [note.title, note.snippet ?? "", note.folder] + note.tags
    }

    /// Up to `limit` matching notes, best first. `notes` must be newest first.
    func results(in notes: [Note], pinyin: [String: [String]], limit: Int) -> [Note] {
        notes.enumerated()
            .compactMap { offset, note in rank(of: note, pinyin: pinyin).map { (note, $0, offset) } }
            .sorted { ($0.0.isPinned ? 0 : 1, $0.1, $0.2) < ($1.0.isPinned ? 0 : 1, $1.1, $1.2) }
            .prefix(limit)
            .map(\.0)
    }

    /// 0 when the title matches, 1 when only other fields do, `nil` when the
    /// note does not match.
    func rank(of note: Note, pinyin: [String: [String]]) -> Int? {
        guard !words.isEmpty else { return 0 }
        let title = [note.title] + (pinyin[note.title] ?? [])
        if matches(title) { return 0 }
        var fields = title + [note.snippet ?? "", note.folder, note.account ?? ""] + note.tags.map { "#\($0)" }
        for source in Self.pinyinSources(of: note).dropFirst() {
            fields += pinyin[source] ?? []
        }
        return matches(fields) ? 1 : nil
    }

    private func matches(_ fields: [String]) -> Bool {
        let haystack = fields.joined(separator: "\n")
        return words.allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }
}
