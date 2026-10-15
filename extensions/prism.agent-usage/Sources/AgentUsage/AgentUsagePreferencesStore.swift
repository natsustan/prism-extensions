import Foundation

/// Agent Usage preferences as the controller reads them. The extension fills
/// this from its generic preferences (`agents`, `showsRemaining`) and its
/// enabled state; nothing here is persisted on its own.
@MainActor
@Observable
final class AgentUsagePreferencesStore {
    struct Snapshot: Equatable {
        /// Explicit user choices only; absent ids fall back to credential
        /// detection.
        var enabledProviders: [String: Bool] = [:]
        /// Provider ids in the user's list and widget priority order.
        var providerOrder: [String] = []
        var showsRemaining = true
        var refreshesOnOpen = true
        /// Off while the extension is disabled: nothing is fetched or listed.
        var isEnabled = true
    }

    private(set) var snapshot: Snapshot

    init(snapshot: Snapshot = Snapshot()) {
        self.snapshot = snapshot
    }

    /// Takes new user choices, keeping the enabled state the extension owns.
    func replace(_ snapshot: Snapshot) {
        var next = snapshot
        next.isEnabled = self.snapshot.isEnabled
        self.snapshot = next
    }

    /// `nil` when the user has never touched this provider's switch.
    func explicitEnabled(_ id: AgentUsageProviderID) -> Bool? {
        snapshot.enabledProviders[id.rawValue]
    }

    func setEnabled(_ isEnabled: Bool, for id: AgentUsageProviderID) {
        snapshot.enabledProviders[id.rawValue] = isEnabled
    }

    func orderedProviderIDs(_ available: [AgentUsageProviderID]) -> [AgentUsageProviderID] {
        available.enumerated().sorted { lhs, rhs in
            let lhsOrder = snapshot.providerOrder.firstIndex(of: lhs.element.rawValue) ?? Int.max
            let rhsOrder = snapshot.providerOrder.firstIndex(of: rhs.element.rawValue) ?? Int.max
            return lhsOrder == rhsOrder ? lhs.offset < rhs.offset : lhsOrder < rhsOrder
        }.map(\.element)
    }

    func setProviderOrder(_ ids: [AgentUsageProviderID]) {
        snapshot.providerOrder = ids.map(\.rawValue)
    }

    var isEnabled: Bool {
        get { snapshot.isEnabled }
        set { snapshot.isEnabled = newValue }
    }

    var showsRemaining: Bool {
        get { snapshot.showsRemaining }
        set { snapshot.showsRemaining = newValue }
    }

    var refreshesOnOpen: Bool {
        get { snapshot.refreshesOnOpen }
        set { snapshot.refreshesOnOpen = newValue }
    }
}
