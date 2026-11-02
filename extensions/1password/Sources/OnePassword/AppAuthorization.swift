import Foundation

/// Asking the 1Password app for a CLI session (`op account get`) without
/// holding up the list. 1Password may show its prompt and wait for the user
/// far longer than Prism waits for a list, and stopping `op` would take the
/// prompt away, so the request runs on its own: a load waits for it briefly,
/// shows a waiting row if it is still pending, and the list reloads once the
/// user has answered.
actor AppAuthorization {
    typealias Outcome = Result<[OnePasswordAccount], OnePasswordError>

    private let quickWait: Duration
    /// The request every load waits on, until one of them takes its outcome.
    private var request: Task<Outcome, Never>?
    /// Whether a load gave up waiting and showed the waiting row, so the
    /// list must reload when the request ends.
    private var listIsWaiting = false

    init(quickWait: Duration) {
        self.quickWait = quickWait
    }

    /// The outcome of the request, started now if none is pending, or nil
    /// while 1Password is still waiting for the user. `finished` runs when a
    /// request ends after a load showed the waiting row.
    func accounts(_ client: OnePasswordClient, finished: @escaping @Sendable () async -> Void) async -> Outcome? {
        let request = self.request ?? start(client, finished: finished)
        // A race, not a task group: a group would wait for `request.value`,
        // which ignores cancellation, long after the quick wait ran out.
        let outcome: Outcome? = await withCheckedContinuation { continuation in
            let first = FirstAnswer(continuation)
            Task { first.resume(await request.value) }
            Task { [quickWait] in
                try? await Task.sleep(for: quickWait)
                first.resume(nil)
            }
        }
        guard let outcome else {
            listIsWaiting = true
            return nil
        }
        // Loads waiting at the same time read the same outcome; the next
        // load after them asks again.
        if self.request == request { self.request = nil }
        return outcome
    }

    private func start(_ client: OnePasswordClient, finished: @escaping @Sendable () async -> Void) -> Task<Outcome, Never> {
        listIsWaiting = false
        let request = Task {
            let outcome: Outcome
            do {
                outcome = .success(try await client.appAccounts(timeout: OnePasswordClient.signInTimeout))
            } catch let error as OnePasswordError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.failed(error.localizedDescription))
            }
            if takeListIsWaiting() { await finished() }
            return outcome
        }
        self.request = request
        return request
    }

    private func takeListIsWaiting() -> Bool {
        defer { listIsWaiting = false }
        return listIsWaiting
    }
}

/// Resumes a continuation with whichever answer comes first.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }?.resume(returning: value)
    }
}
