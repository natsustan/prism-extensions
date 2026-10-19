import Foundation
import Synchronization

/// The notes ready to search, kept between loads while Notes' database is
/// unchanged. Typing then skips reading the database and folding every note,
/// and only compares the query.
final class NoteLibrary: Sendable {
    private struct Snapshot {
        let signature: String
        let directory: URL?
        let notes: [SearchableNote]
    }

    private let snapshot = Mutex<Snapshot?>(nil)

    /// Searchable notes, newest first, rebuilt when the database or `directory`
    /// (where `pinyin` keeps its cache) changes.
    func notes(from store: NoteStore, pinyin: PinyinCache, directory: URL?) throws -> [SearchableNote] {
        let signature = store.signature()
        if let signature, let cached = snapshot.withLock({ $0 }),
           cached.signature == signature, cached.directory == directory {
            return cached.notes
        }
        let notes = try store.notes()
        let keywords = pinyin.keywords(for: Set(notes.flatMap(NoteSearch.pinyinSources)), directory: directory)
        let searchable = notes.map { SearchableNote($0, pinyin: keywords) }
        snapshot.withLock {
            $0 = signature.map { Snapshot(signature: $0, directory: directory, notes: searchable) }
        }
        return searchable
    }
}
