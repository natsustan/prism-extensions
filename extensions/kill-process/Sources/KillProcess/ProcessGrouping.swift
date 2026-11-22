import Darwin
import Foundation

enum ProcessSort: Sendable {
    case cpu
    case memory

    init(filter: String?) {
        switch filter {
        case KillProcess.FilterID.memory:
            self = .memory
        default:
            self = .cpu
        }
    }

    func precedes(lhsCPU: Double, lhsMemory: UInt64, rhsCPU: Double, rhsMemory: UInt64) -> Bool? {
        switch self {
        case .cpu:
            if lhsCPU != rhsCPU { return lhsCPU > rhsCPU }
            if lhsMemory != rhsMemory { return lhsMemory > rhsMemory }
        case .memory:
            if lhsMemory != rhsMemory { return lhsMemory > rhsMemory }
            if lhsCPU != rhsCPU { return lhsCPU > rhsCPU }
        }
        return nil
    }
}

/// One visible row in the list: either a single process or an app bundle
/// aggregating its main executable and helper processes.
struct ProcessEntry: Hashable, Sendable {
    let id: String
    let main: ProcessRecord
    let members: [ProcessRecord]
    let cpu: Double
    let memoryBytes: UInt64

    var isAggregated: Bool { members.count > 1 }
    var isApp: Bool { isAggregated || main.kind == .app }

    var appName: String? { main.appName }

    var displayTitle: String {
        if isAggregated { return appName ?? main.name }
        return main.name
    }

    var restartLaunchPath: String? { main.restartLaunchPath }

    var revealPath: String? {
        isAggregated ? (main.outerAppBundlePath ?? main.revealPath) : main.revealPath
    }

    var iconAppBundlePath: String? { main.outerAppBundlePath }
}

/// Pure grouping, sorting, and target resolution for process snapshots.
enum ProcessGrouping {
    struct ParsedItemID: Equatable, Sendable {
        let isAggregated: Bool
        let identity: ProcessIdentity

        init?(rawValue: String) {
            if rawValue.hasPrefix("app:") {
                guard let identity = ProcessIdentity(key: String(rawValue.dropFirst(4))) else { return nil }
                self.isAggregated = true
                self.identity = identity
            } else if rawValue.hasPrefix("pid:") {
                guard let identity = ProcessIdentity(key: String(rawValue.dropFirst(4))) else { return nil }
                self.isAggregated = false
                self.identity = identity
            } else {
                return nil
            }
        }
    }

    static func entries(
        from records: [ProcessRecord],
        sort: ProcessSort,
        groupApps: Bool,
        currentUserID: uid_t
    ) -> [ProcessEntry] {
        var built: [ProcessEntry] = []
        if groupApps {
            var groups: [String: [ProcessRecord]] = [:]
            var order: [String] = []
            for record in records {
                if let bundlePath = record.outerAppBundlePath {
                    if groups[bundlePath] == nil { order.append(bundlePath) }
                    groups[bundlePath, default: []].append(record)
                } else {
                    built.append(singleEntry(for: record))
                }
            }
            for bundlePath in order {
                guard let group = groups[bundlePath], !group.isEmpty else { continue }
                if group.count == 1 {
                    built.append(singleEntry(for: group[0]))
                } else {
                    built.append(aggregatedEntry(for: group, bundlePath: bundlePath, sort: sort))
                }
            }
        } else {
            built = records.map(singleEntry(for:))
        }

        return built.sorted { compare($0, $1, by: sort, currentUserID: currentUserID) }
    }

    static func targetIdentities(
        for parsed: ParsedItemID,
        in snapshot: [ProcessRecord],
        currentUserID: uid_t,
        excludingPID: pid_t
    ) -> (main: ProcessRecord, targets: [ProcessRecord])? {
        guard let main = snapshot.first(where: { $0.identity == parsed.identity }),
              main.pid > 1, main.pid != excludingPID else {
            return nil
        }
        guard parsed.isAggregated else {
            return (main, [main])
        }

        let bundlePath = main.outerAppBundlePath
        let extras = snapshot
            .filter { record in
                record.isKillable(by: currentUserID, excludingPID: excludingPID)
                    && record.identity != main.identity
                    && bundlePath != nil
                    && record.outerAppBundlePath == bundlePath
            }
            .sorted { $0.pid < $1.pid }

        return (main, [main] + extras)
    }

    static func sameNameOwnProcesses(
        named name: String,
        in snapshot: [ProcessRecord],
        currentUserID: uid_t,
        excludingPID: pid_t
    ) -> [ProcessRecord] {
        snapshot
            .filter { $0.name == name && $0.isKillable(by: currentUserID, excludingPID: excludingPID) }
            .sorted { $0.pid < $1.pid }
    }

    // MARK: - Grouping helpers

    private static func singleEntry(for record: ProcessRecord) -> ProcessEntry {
        ProcessEntry(
            id: "pid:\(record.identity.key)",
            main: record,
            members: [record],
            cpu: record.cpu,
            memoryBytes: record.memoryBytes
        )
    }

    private static func aggregatedEntry(
        for group: [ProcessRecord],
        bundlePath: String,
        sort: ProcessSort
    ) -> ProcessEntry {
        let appName = ProcessRecord.appDisplayName(from: bundlePath)
            ?? URL(fileURLWithPath: bundlePath).lastPathComponent
        let groupPIDs = Set(group.map(\.pid))
        let main = group.min { lhs, rhs in
            isBetterMain(lhs, than: rhs, bundlePath: bundlePath, appName: appName, groupPIDs: groupPIDs)
        } ?? group[0]

        let sortedMembers = group.sorted { compareRecords($0, $1, by: sort) }
        var totalCPU = 0.0
        var totalMemory: UInt64 = 0
        for member in group {
            totalCPU += member.cpu
            let (sum, overflow) = totalMemory.addingReportingOverflow(member.memoryBytes)
            totalMemory = overflow ? UInt64.max : sum
        }

        return ProcessEntry(
            id: "app:\(main.identity.key)",
            main: main,
            members: sortedMembers,
            cpu: totalCPU,
            memoryBytes: totalMemory
        )
    }

    private static func isBetterMain(
        _ lhs: ProcessRecord,
        than rhs: ProcessRecord,
        bundlePath: String,
        appName: String,
        groupPIDs: Set<pid_t>
    ) -> Bool {
        func rank(_ record: ProcessRecord) -> (tier: Int, parentOutsideRank: Int, negativeCPU: Double, pid: pid_t) {
            let isDirectBundle = record.bundlePath == bundlePath
            let matchesName = record.name == appName
            let parentOutside = !groupPIDs.contains(record.parentPID)
            let tier: Int
            if isDirectBundle && matchesName {
                tier = 0
            } else if isDirectBundle && parentOutside {
                tier = 1
            } else if isDirectBundle {
                tier = 2
            } else if matchesName {
                tier = 3
            } else if parentOutside {
                tier = 4
            } else {
                tier = 5
            }
            let outsideRank = parentOutside ? 0 : 1
            let cpuRank = tier == 4 ? -record.cpu : 0
            return (tier, outsideRank, cpuRank, record.pid)
        }
        return rank(lhs) < rank(rhs)
    }

    private static func compare(_ lhs: ProcessEntry, _ rhs: ProcessEntry, by sort: ProcessSort, currentUserID: uid_t) -> Bool {
        if let ordered = sort.precedes(lhsCPU: lhs.cpu, lhsMemory: lhs.memoryBytes, rhsCPU: rhs.cpu, rhsMemory: rhs.memoryBytes) {
            return ordered
        }
        let lhsOwn = lhs.main.userID == currentUserID ? 0 : 1
        let rhsOwn = rhs.main.userID == currentUserID ? 0 : 1
        if lhsOwn != rhsOwn { return lhsOwn < rhsOwn }
        let lhsApp = lhs.isApp ? 0 : 1
        let rhsApp = rhs.isApp ? 0 : 1
        if lhsApp != rhsApp { return lhsApp < rhsApp }
        return lhs.main.pid < rhs.main.pid
    }

    private static func compareRecords(_ lhs: ProcessRecord, _ rhs: ProcessRecord, by sort: ProcessSort) -> Bool {
        if let ordered = sort.precedes(lhsCPU: lhs.cpu, lhsMemory: lhs.memoryBytes, rhsCPU: rhs.cpu, rhsMemory: rhs.memoryBytes) {
            return ordered
        }
        return lhs.pid < rhs.pid
    }
}
