import Foundation

/// Combines Bonjour-discovered hosts, Saved Hosts preferences, and persisted
/// pinned/recent records into a deduplicated, searchable, sorted list.
enum HostCatalog {
    static func merge(
        onlineLocal: [DiscoveredHost],
        cachedLocal: [DiscoveredHost],
        saved: [SavedHostEntry],
        stored: [String: StoredHostRecord]
    ) -> [ResolvedHost] {
        var ids = [String]()
        var seen = Set<String>()

        func register(_ id: String) {
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }

        let onlineByID = Dictionary(onlineLocal.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cachedByID = Dictionary(cachedLocal.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for host in onlineLocal { register(host.id) }
        for host in cachedLocal { register(host.id) }
        for entry in saved { register(entry.id) }
        for id in stored.keys { register(id) }

        var resolved = [ResolvedHost]()
        resolved.reserveCapacity(ids.count)

        for id in ids {
            let online = onlineByID[id]
            let cached = cachedByID[id]
            let savedEntry = savedByID[id]
            let record = stored[id]

            guard let address = online?.address ?? cached?.address ?? savedEntry?.address ?? record?.address else {
                continue
            }

            let name = savedEntry?.name
                ?? online?.serviceName
                ?? cached?.serviceName
                ?? record?.name
                ?? address.displayAddress

            let model = online?.model ?? cached?.model ?? record?.model

            resolved.append(ResolvedHost(
                id: id,
                name: name,
                address: address,
                model: model,
                isLocalOnline: online != nil,
                isLocalCached: online == nil && cached != nil,
                isSaved: savedEntry != nil,
                isPinned: record?.isPinned ?? false,
                lastConnectedAt: record?.lastConnectedAt,
                isQuickConnect: false
            ))
        }

        return resolved
    }

    /// Filters, sorts, and optionally appends a Quick Connect row when `query`
    /// looks like a direct host address not already matched.
    static func query(
        hosts: [ResolvedHost],
        query: String,
        filter: String?
    ) -> [ResolvedHost] {
        let filteredByKind = hosts.filter { host in
            switch filter {
            case ScreenSharing.FilterID.pinned:
                host.isPinned
            case ScreenSharing.FilterID.local:
                host.isLocal
            case ScreenSharing.FilterID.recent:
                host.isRecent
            default:
                true
            }
        }

        let words = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        var matched = words.isEmpty
            ? filteredByKind
            : filteredByKind.filter { matches($0, words: words) }

        matched.sort(by: sortOrder)

        // Offer direct connection when the user types an IP, hostname, or vnc:// URL
        // that isn't already represented by an exact host match in the results.
        if let direct = HostAddressParser.parseAddress(query) {
            let alreadyListed = matched.contains { $0.id == direct.stableID }
            if !alreadyListed {
                matched.append(ResolvedHost(
                    id: quickConnectID(for: direct),
                    name: direct.displayAddress,
                    address: direct,
                    model: nil,
                    isLocalOnline: false,
                    isLocalCached: false,
                    isSaved: false,
                    isPinned: false,
                    lastConnectedAt: nil,
                    isQuickConnect: true
                ))
            }
        }

        return matched
    }

    static func quickConnectID(for address: HostAddress) -> String {
        "quick:\(address.displayAddress)"
    }

    /// Reconstructs a `HostAddress` from either a `quick:` or `host:` item ID
    /// when a user triggers an action on a row that is no longer in the live
    /// discovery snapshot.
    static func fallbackAddress(forItemID itemID: String) -> HostAddress? {
        for prefix in ["quick:", "host:"] where itemID.hasPrefix(prefix) {
            let raw = String(itemID.dropFirst(prefix.count))
            return HostAddressParser.parseAddress(raw, allowBareLabel: true)
        }
        return nil
    }

    static func matches(_ host: ResolvedHost, words: [String]) -> Bool {
        var searchable = [
            host.name.lowercased(),
            host.address.host.lowercased(),
            host.address.displayAddress.lowercased(),
        ]
        if let user = host.address.username {
            searchable.append(user.lowercased())
        }
        if let model = host.model {
            searchable.append(model.lowercased())
        }
        searchable.append(contentsOf: PinyinKeywords.keywords(for: host.name))

        return words.allSatisfy { word in
            searchable.contains { $0.contains(word) }
        }
    }

    /// Section bucket used both for sorting and visual grouping.
    static func bucket(for host: ResolvedHost) -> Int {
        if host.isQuickConnect { return 4 }
        if host.isPinned { return 0 }
        if host.isLocal { return 1 }
        if host.isSaved { return 2 }
        return 3
    }

    private static func sortOrder(_ lhs: ResolvedHost, _ rhs: ResolvedHost) -> Bool {
        let lhsBucket = bucket(for: lhs)
        let rhsBucket = bucket(for: rhs)
        if lhsBucket != rhsBucket {
            return lhsBucket < rhsBucket
        }
        if lhs.isLocalOnline != rhs.isLocalOnline {
            return lhs.isLocalOnline
        }
        let lhsDate = lhs.lastConnectedAt ?? .distantPast
        let rhsDate = rhs.lastConnectedAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
