import Foundation
import Synchronization

/// Searchable notes and tags kept between loads while Bear's database is
/// unchanged. Typing skips reading SQLite and folding every note, and only
/// compares the query.
final class BearLibrary: Sendable {
    struct CachedData: Sendable {
        let notes: [SearchableNote]
        let tags: [SearchableTag]
    }

    private struct Snapshot {
        let signature: String
        let directory: URL?
        let data: CachedData
    }

    private let snapshot = Mutex<Snapshot?>(nil)

    /// Searchable notes and tags, rebuilt when Bear's database or `directory`
    /// (where `pinyin` keeps its cache) changes.
    func load(from store: BearStore, pinyin: PinyinCache, directory: URL?) throws -> CachedData {
        try Task.checkCancellation()
        let signature = store.signature()
        if let signature, let cached = snapshot.withLock({ $0 }),
           cached.signature == signature, cached.directory == directory {
            return cached.data
        }
        let fresh = try store.snapshot()
        try Task.checkCancellation()
        var sources = Set<String>()
        for note in fresh.notes {
            sources.formUnion(BearNoteSearch.pinyinSources(of: note))
        }
        for tag in fresh.tags {
            sources.insert(tag.name)
        }
        let keywords = pinyin.keywords(for: sources, directory: directory)
        try Task.checkCancellation()
        let data = CachedData(
            notes: fresh.notes.map { SearchableNote($0, pinyin: keywords) },
            tags: fresh.tags.map { SearchableTag($0, pinyin: keywords) }
        )
        snapshot.withLock {
            $0 = signature.map { Snapshot(signature: $0, directory: directory, data: data) }
        }
        return data
    }
}
