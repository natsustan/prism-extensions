import Foundation
import PrismExtensionKit

/// Persists pinned hosts and recent connections inside Prism's extension state
/// so they survive process restarts without keeping anything important in memory.
enum HostStateStore {
    enum StateKey {
        static let records = "hostRecords"
    }

    /// Cap stored unpinned recents so state stays well under Prism's 1 MB quota.
    static let maxUnpinnedRecents = 30

    static func load(from context: PrismContext) async -> [String: StoredHostRecord] {
        guard let raw = await context.state(StateKey.records)?.stringValue,
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([StoredHostRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func save(_ records: [String: StoredHostRecord], to context: PrismContext) async {
        let pinned = records.values
            .filter(\.isPinned)
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        let unpinned = records.values
            .filter { !$0.isPinned && $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(maxUnpinnedRecents)

        let combined = pinned + unpinned
        if combined.isEmpty {
            await context.setState(nil, for: StateKey.records)
            return
        }
        guard let data = try? JSONEncoder().encode(combined),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        await context.setState(.string(encoded), for: StateKey.records)
    }

    static func recordConnection(
        name: String,
        address: HostAddress,
        model: String?,
        at date: Date,
        context: PrismContext
    ) async {
        var records = await load(from: context)
        let id = address.stableID
        if var existing = records[id] {
            if !name.isEmpty {
                existing.name = name
            }
            if let model, !model.isEmpty {
                existing.model = model
            }
            existing.lastConnectedAt = date
            records[id] = existing
        } else {
            records[id] = StoredHostRecord(
                name: name.isEmpty ? address.displayAddress : name,
                address: address,
                model: model,
                lastConnectedAt: date,
                isPinned: false
            )
        }
        await save(records, to: context)
    }

    @discardableResult
    static func togglePin(
        name: String,
        address: HostAddress,
        model: String?,
        context: PrismContext
    ) async -> Bool {
        var records = await load(from: context)
        let id = address.stableID
        let nowPinned: Bool
        if var existing = records[id] {
            existing.isPinned.toggle()
            if !name.isEmpty {
                existing.name = name
            }
            if let model, !model.isEmpty {
                existing.model = model
            }
            nowPinned = existing.isPinned
            if !existing.isPinned && existing.lastConnectedAt == nil {
                records.removeValue(forKey: id)
            } else {
                records[id] = existing
            }
        } else {
            nowPinned = true
            records[id] = StoredHostRecord(
                name: name.isEmpty ? address.displayAddress : name,
                address: address,
                model: model,
                lastConnectedAt: nil,
                isPinned: true
            )
        }
        await save(records, to: context)
        return nowPinned
    }

    static func removeRecent(id: String, context: PrismContext) async {
        var records = await load(from: context)
        guard var existing = records[id] else { return }
        if existing.isPinned {
            existing.lastConnectedAt = nil
            records[id] = existing
        } else {
            records.removeValue(forKey: id)
        }
        await save(records, to: context)
    }
}
