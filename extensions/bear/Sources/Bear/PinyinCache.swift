import Foundation
import Synchronization

/// Pinyin keywords by source text, held for the life of the process and kept
/// in the extension's data directory between runs. Transliterating takes about
/// half a millisecond per line of Chinese, too slow to repeat for every note
/// on every keystroke; new texts are computed in parallel.
final class PinyinCache: Sendable {
    private struct State {
        var loadedFrom: URL??
        var keywords: [String: [String]] = [:]
    }

    private let state = Mutex(State())

    /// Keywords for each of `texts`. Entries for texts no longer in use are
    /// dropped, and the file is rewritten when anything changed.
    func keywords(for texts: Set<String>, directory: URL?) -> [String: [String]] {
        let file = directory?.appendingPathComponent("pinyin.json")
        let missing = state.withLock { state in
            if state.loadedFrom != .some(file) {
                state.loadedFrom = .some(file)
                state.keywords = file.flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
            }
            return texts.filter { state.keywords[$0] == nil && PinyinKeywords.containsHan($0) }
        }
        let sources = Array(missing)
        let computed = Mutex([String: [String]]())
        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            let keywords = PinyinKeywords.keywords(for: sources[index])
            computed.withLock { $0[sources[index]] = keywords }
        }
        let fresh = computed.withLock { $0 }
        return state.withLock { state in
            let stale = state.keywords.keys.contains { !texts.contains($0) }
            if !fresh.isEmpty || stale {
                state.keywords = state.keywords.filter { texts.contains($0.key) }.merging(fresh) { $1 }
                Self.save(state.keywords, to: file)
            }
            return state.keywords
        }
    }

    private static func save(_ keywords: [String: [String]], to file: URL?) {
        guard let file, let data = try? JSONEncoder().encode(keywords) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
