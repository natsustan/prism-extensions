import Foundation
import PrismExtensionKit

/// The items of every account, as the last load found them.
struct VaultSnapshot: Sendable {
    struct Account: Sendable {
        var account: OnePasswordAccount
        /// Newest first, the list's order.
        var items: [OnePasswordItem]
    }

    var accounts: [Account]
    var fetchedAt: Date
    /// Why an account's items are missing or older than the rest.
    var error: String?
}

/// Item lists kept in memory only, never on disk: titles, usernames, and
/// links stay inside 1Password. Prism stops the process after a minute idle,
/// so a list opened again soon after appears at once, and later ones ask
/// `op` again.
actor VaultLibrary {
    /// How long a load answers from memory. Reopening the list, or ⌘R,
    /// within this time shows what is already here.
    static let maxAge: TimeInterval = 30

    private let now: @Sendable () -> Date
    private var snapshot: VaultSnapshot?

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// The last load, while it is fresh. One that failed in part is asked
    /// again.
    func fresh() -> VaultSnapshot? {
        guard let snapshot, snapshot.error == nil, now().timeIntervalSince(snapshot.fetchedAt) < Self.maxAge else { return nil }
        return snapshot
    }

    func load(_ client: OnePasswordClient, accounts: [OnePasswordAccount]) async throws -> VaultSnapshot {
        // Accounts load side by side and are kept in `op`'s order.
        let results = await withTaskGroup(of: (Int, Result<[OnePasswordItem], any Error>).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    do { return (index, .success(try await client.items(in: account))) } catch { return (index, .failure(error)) }
                }
            }
            var results = [Result<[OnePasswordItem], any Error>?](repeating: nil, count: accounts.count)
            for await (index, result) in group { results[index] = result }
            return results.compactMap { $0 }
        }
        try Task.checkCancellation()

        var loaded = [VaultSnapshot.Account]()
        var firstError: (any Error)?
        var failedAccounts = [String]()
        var keptSince: Date?
        for (account, result) in zip(accounts, results) {
            switch result {
            case let .success(items):
                // Sorted once here, not on every load served from memory.
                loaded.append(VaultSnapshot.Account(account: account, items: items.newestFirst()))
            case let .failure(error):
                firstError = firstError ?? error
                failedAccounts.append(account.name)
                // An account that failed keeps the items it had.
                if let snapshot, let kept = snapshot.accounts.first(where: { $0.account.accountUUID == account.accountUUID }) {
                    loaded.append(kept)
                    keptSince = snapshot.fetchedAt
                }
            }
        }
        if let firstError, loaded.isEmpty { throw firstError }
        let failed = failedAccounts.formatted(.list(type: .and).locale(PrismLocalization.locale))
        let next = VaultSnapshot(
            accounts: loaded,
            // Kept items are as old as the load that found them.
            fetchedAt: keptSince ?? now(),
            error: failedAccounts.isEmpty ? nil : localized("Couldn’t load \(failed).")
        )
        snapshot = next
        return next
    }

    /// The item an action names, when this process has loaded it.
    func item(id: String, account: String) -> OnePasswordItem? {
        snapshot?.accounts.first { $0.account.accountUUID == account }?.items.first { $0.id == id }
    }

    /// The next load asks `op` again, after an edit in 1Password.
    func forget() {
        snapshot = nil
    }
}
