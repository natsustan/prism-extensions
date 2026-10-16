import Foundation
import Synchronization

/// Pinyin keywords per note, kept in the extension's data directory.
/// Transliterating takes about half a millisecond per line of Chinese, so a
/// thousand notes would hold up every load; a note's entry is reused until
/// its text changes, and the rest are computed in parallel.
final class PinyinCache {
    private struct Entry: Codable {
        let source: String
        let keywords: [String]
    }

    private let file: URL?
    private var entries: [String: Entry]

    init(directory: URL?) {
        file = directory?.appendingPathComponent("pinyin.json")
        entries = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// Keywords for each note's texts, by note ID. Entries for notes not in
    /// `texts` are dropped, and the file is rewritten when anything changed.
    func keywords(for texts: [String: [String]]) -> [String: [String]] {
        let sources = texts.mapValues { $0.joined(separator: "\u{1F}") }
        let stale = sources.filter { entries[$0.key]?.source != $0.value }.map(\.key)
        let computed = Mutex([String: Entry]())
        DispatchQueue.concurrentPerform(iterations: stale.count) { index in
            let id = stale[index]
            let keywords = texts[id, default: []].flatMap(PinyinKeywords.keywords(for:))
            let entry = Entry(source: sources[id, default: ""], keywords: keywords)
            computed.withLock { $0[id] = entry }
        }
        let fresh = computed.withLock { $0 }
        let removed = entries.keys.contains { sources[$0] == nil }
        if !fresh.isEmpty || removed {
            entries = entries.filter { sources[$0.key] != nil }.merging(fresh) { $1 }
            save()
        }
        return entries.mapValues(\.keywords)
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
