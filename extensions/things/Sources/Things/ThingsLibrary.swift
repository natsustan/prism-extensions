import Foundation
import Synchronization

/// Caches Things to-dos and containers in memory during a session so typing in
/// the search field does not re-query Things on every keystroke.
final class ThingsLibrary: Sendable {
    struct CachedData: Sendable {
        let todos: [ThingsTodo]
        let containers: [ThingsContainer]
    }

    private struct State {
        var active: CachedData?
        var activeLoadedAt: Date?
        var logbook: CachedData?
        var logbookLoadedAt: Date?
        var containers: [ThingsContainer]?
        var containersLoadedAt: Date?
    }

    private let state = Mutex(State())
    private let cacheTTL: TimeInterval

    init(cacheTTL: TimeInterval = 15) {
        self.cacheTTL = cacheTTL
    }

    func invalidate() {
        state.withLock {
            $0.active = nil
            $0.activeLoadedAt = nil
            $0.logbook = nil
            $0.logbookLoadedAt = nil
            $0.containers = nil
            $0.containersLoadedAt = nil
        }
    }

    func load(
        logbook: Bool,
        forceRefresh: Bool,
        now: Date,
        from repository: any ThingsRepository,
        pinyin: PinyinCache,
        directory: URL?,
        logbookLimit: Int = 150
    ) async throws -> CachedData {
        if !forceRefresh {
            let cached = state.withLock { state -> CachedData? in
                if logbook {
                    guard let data = state.logbook, let loadedAt = state.logbookLoadedAt,
                          now.timeIntervalSince(loadedAt) < cacheTTL else { return nil }
                    return data
                } else {
                    guard let data = state.active, let loadedAt = state.activeLoadedAt,
                          now.timeIntervalSince(loadedAt) < cacheTTL else { return nil }
                    return data
                }
            }
            if let cached { return cached }
        }

        try Task.checkCancellation()
        let snapshot = logbook
            ? try await repository.fetchLogbook(limit: logbookLimit)
            : try await repository.fetchActive()
        try Task.checkCancellation()

        let texts = Self.pinyinSourceTexts(for: snapshot.todos)
        let pinyinMap = try pinyin.keywords(for: texts, directory: directory)
        let enriched = snapshot.todos.map { todo -> ThingsTodo in
            var copy = todo
            copy.pinyinKeywords = Self.keywords(for: todo, from: pinyinMap)
            return copy
        }

        let data = CachedData(todos: enriched, containers: snapshot.containers)
        try Task.checkCancellation()
        state.withLock { state in
            if logbook {
                state.logbook = data
                state.logbookLoadedAt = now
            } else {
                state.active = data
                state.activeLoadedAt = now
            }
            state.containers = snapshot.containers
            state.containersLoadedAt = now
        }
        return data
    }

    func containers(
        forceRefresh: Bool,
        now: Date,
        from repository: any ThingsRepository
    ) async throws -> [ThingsContainer] {
        if !forceRefresh {
            let cached = state.withLock { state -> [ThingsContainer]? in
                guard let list = state.containers, let loadedAt = state.containersLoadedAt,
                      now.timeIntervalSince(loadedAt) < cacheTTL else { return nil }
                return list
            }
            if let cached { return cached }
        }

        try Task.checkCancellation()
        let fetched = try await repository.fetchContainers()
        try Task.checkCancellation()
        state.withLock { state in
            state.containers = fetched
            state.containersLoadedAt = now
        }
        return fetched
    }

    private static func pinyinSourceTexts(for todos: [ThingsTodo]) -> Set<String> {
        var texts = Set<String>()
        for todo in todos {
            texts.insert(todo.title)
            if let project = todo.projectTitle { texts.insert(project) }
            if let area = todo.areaTitle { texts.insert(area) }
            for tag in todo.tags { texts.insert(tag) }
        }
        return texts
    }

    private static func keywords(for todo: ThingsTodo, from map: [String: [String]]) -> [String] {
        var result: [String] = []
        if let list = map[todo.title] { result.append(contentsOf: list) }
        if let project = todo.projectTitle, let list = map[project] { result.append(contentsOf: list) }
        if let area = todo.areaTitle, let list = map[area] { result.append(contentsOf: list) }
        for tag in todo.tags {
            if let list = map[tag] { result.append(contentsOf: list) }
        }
        return result
    }
}
