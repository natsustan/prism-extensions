import Foundation
import Synchronization

/// Caches searchable reminders and lists in memory while typing so keystrokes
/// never re-query EventKit. Opening a list, changing filters, or reloading
/// (`forceRefresh: true`) fetches fresh data so edits made in Reminders.app
/// appear immediately. Incomplete and completed reminders are cached separately.
final class ReminderLibrary: Sendable {
    struct CachedData: Sendable {
        let reminders: [SearchableReminder]
        let lists: [ReminderList]
    }

    private struct Snapshot {
        let directory: URL?
        let data: CachedData
    }

    private struct State {
        var version: UInt64 = 0
        var incomplete: Snapshot?
        var completed: Snapshot?
        var lists: [ReminderList]?
    }

    private let state = Mutex(State())

    func load(
        completed: Bool,
        forceRefresh: Bool,
        from repository: any ReminderRepository,
        pinyin: PinyinCache,
        directory: URL?
    ) async throws -> CachedData {
        let startedVersion: UInt64 = state.withLock { state in
            state.version
        }
        if !forceRefresh,
           let cached = state.withLock({ completed ? $0.completed : $0.incomplete }),
           cached.directory == directory {
            return cached.data
        }

        try Task.checkCancellation()
        let raw = try await repository.fetchSnapshot(completed: completed)
        try Task.checkCancellation()

        let sources = Set(
            raw.reminders.flatMap(ReminderSearch.pinyinSources(of:))
                + raw.lists.map(\.title)
        )
        let keywords = try pinyin.keywords(for: sources, directory: directory)
        let searchable = raw.reminders.map { SearchableReminder($0, pinyin: keywords) }
        let data = CachedData(reminders: searchable, lists: raw.lists)

        try Task.checkCancellation()
        state.withLock { state in
            guard state.version == startedVersion else { return }
            let snapshot = Snapshot(directory: directory, data: data)
            if completed {
                state.completed = snapshot
            } else {
                state.incomplete = snapshot
            }
            state.lists = raw.lists
        }
        return data
    }

    func lists(forceRefresh: Bool, from repository: any ReminderRepository) async throws -> [ReminderList] {
        let (startedVersion, cached) = state.withLock { ($0.version, $0.lists) }
        if !forceRefresh, let cached {
            return cached
        }
        try Task.checkCancellation()
        let fresh = try await repository.fetchLists()
        try Task.checkCancellation()
        state.withLock { state in
            guard state.version == startedVersion else { return }
            state.lists = fresh
        }
        return fresh
    }

    func invalidate() {
        state.withLock { state in
            state.version &+= 1
            state.incomplete = nil
            state.completed = nil
            state.lists = nil
        }
    }
}
