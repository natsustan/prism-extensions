import Foundation

/// Builds `bear://x-callback-url/...` links for Bear on macOS.
enum BearURLs {
    /// Characters safe unencoded inside a query value; excludes `+`, `&`, `=`,
    /// `#`, and `;` so `x-callback-url` parsers never decode `+` as a space.
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "+&=?#;"))

    /// Opens a note by its unique identifier (`ZUNIQUEIDENTIFIER`).
    static func openNote(id: String, newWindow: Bool = false, edit: Bool = false) -> URL? {
        guard isValidIdentifier(id) else { return nil }
        var items = [("id", id)]
        if newWindow { items.append(("new_window", "yes")) }
        if edit { items.append(("edit", "yes")) }
        return makeURL(action: "open-note", queryItems: items)
    }

    /// Opens a tag in Bear's sidebar.
    static func openTag(name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return makeURL(action: "open-tag", queryItems: [("name", trimmed)])
    }

    /// Creates a new note with a title and focuses the editor.
    static func createNote(title: String) -> URL? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return makeURL(action: "create", queryItems: [("title", trimmed), ("edit", "yes")])
    }

    /// Creates a new note from the system clipboard and focuses the editor.
    static let createNoteFromClipboard = URL(string: "bear://x-callback-url/create?clipboard=yes&edit=yes")!

    /// Archives a note in Bear without forcing Bear's window forward.
    static func archiveNote(id: String) -> URL? {
        guard isValidIdentifier(id) else { return nil }
        return makeURL(action: "archive", queryItems: [("id", id), ("show_window", "no")])
    }

    /// Moves a note to Bear's Trash without forcing Bear's window forward.
    static func trashNote(id: String) -> URL? {
        guard isValidIdentifier(id) else { return nil }
        return makeURL(action: "trash", queryItems: [("id", id), ("show_window", "no")])
    }

    /// Bear's identifiers are UUIDs (or UUID-prefixed sync IDs in older
    /// versions) and never contain whitespace or control characters.
    static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && !id.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func makeURL(action: String, queryItems: [(String, String)]) -> URL? {
        var components = URLComponents()
        components.scheme = "bear"
        components.host = "x-callback-url"
        components.path = "/\(action)"
        components.percentEncodedQueryItems = queryItems.map { name, value in
            URLQueryItem(
                name: name,
                value: value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
            )
        }
        return components.url
    }
}
