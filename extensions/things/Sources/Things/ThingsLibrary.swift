import Foundation
import Synchronization

/// Caches Things to-dos and containers in memory during a session so typing in
/// the search field does not re-query Things on every keystroke.
final class ThingsLibrary: Sendable {
    struct CachedData: Sendable {
        let todos: [ThingsTodo]
        let containers: [ThingsContainer]
        let loadedAt: Date
        var staleError: String? = nil
    }

    private struct State {
        var active: CachedData?
        var logbook: CachedData?
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
            $0.logbook = nil
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
        let previous = state.withLock { state -> CachedData? in
            logbook ? state.logbook : state.active
        }
        if !forceRefresh, let previous, now.timeIntervalSince(previous.loadedAt) < cacheTTL {
            return previous
        }

        try Task.checkCancellation()
        let snapshot: ThingsSnapshot
        do {
            snapshot = logbook
                ? try await repository.fetchLogbook(limit: logbookLimit)
                : try await repository.fetchActive()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ThingsRepositoryError {
            switch error {
            case .appNotInstalled, .appNotRunning, .automationDenied:
                throw error
            case .notFound, .scriptFailed:
                if var stale = previous {
                    stale.staleError = error.userMessage
                    return stale
                }
                throw error
            }
        } catch {
            if var stale = previous {
                stale.staleError = error.localizedDescription
                return stale
            }
            throw error
        }
        try Task.checkCancellation()

        let texts = Self.pinyinSourceTexts(for: snapshot.todos)
        let pinyinMap = try pinyin.keywords(for: texts, directory: directory)
        let enriched = snapshot.todos.map { todo -> ThingsTodo in
            var copy = todo
            copy.pinyinKeywords = Self.keywords(for: todo, from: pinyinMap)
            return copy
        }

        let data = CachedData(todos: enriched, containers: snapshot.containers, loadedAt: now)
        try Task.checkCancellation()
        state.withLock { state in
            if logbook {
                state.logbook = data
            } else {
                state.active = data
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
