import Foundation

/// Recent GitHub responses, kept while the extension runs (Prism stops it
/// after a minute idle). Reopening a list or retyping a search answers from
/// here instead of spending GitHub's search quota of 30 requests a minute.
/// When a refresh fails, the last good value comes back with the error so
/// the list keeps its rows and says why they may be stale.
actor ResponseCache {
    struct Entry<Value: Sendable>: Sendable {
        let value: Value
        let fetchedAt: Date
        /// Why the refresh failed, when `value` is the last good one.
        let error: GitHubError?
    }

    private var entries: [String: (value: any Sendable, fetchedAt: Date)] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func value<Value: Sendable>(
        _ key: String,
        maxAge: TimeInterval,
        load: @Sendable () async throws -> Value
    ) async throws -> Entry<Value> {
        let cached = entries[key].flatMap { entry in (entry.value as? Value).map { ($0, entry.fetchedAt) } }
        if let (value, fetchedAt) = cached, now().timeIntervalSince(fetchedAt) < maxAge {
            return Entry(value: value, fetchedAt: fetchedAt, error: nil)
        }
        do {
            let value = try await load()
            let fetchedAt = now()
            entries[key] = (value, fetchedAt)
            return Entry(value: value, fetchedAt: fetchedAt, error: nil)
        } catch let error as GitHubError {
            // A token or server that no longer works should not keep showing
            // another account's rows.
            guard let (value, fetchedAt) = cached, error.keepsStaleData else { throw error }
            return Entry(value: value, fetchedAt: fetchedAt, error: error)
        }
    }
}

extension GitHubError {
    /// Failures that say nothing about whether the data is still right.
    var keepsStaleData: Bool {
        switch self {
        case .rateLimited, .unreachable, .status, .unexpectedResponse: true
        case .missingToken, .invalidServer, .invalidToken, .missingScope, .notificationsNeedClassicToken: false
        }
    }
}
