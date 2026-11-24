import Foundation

/// Reads Xcode's recent projects from all local sources and merges them into
/// one deduplicated list sorted by recency.
///
/// Xcode spreads recent project history across several files depending on the
/// macOS version and the user's "Recent items" system setting:
/// 1. macOS Shared File List (`com.apple.dt.xcode.sfl4`/`.sfl3`/`.sfl2`)
/// 2. DerivedData `info.plist` files (including custom DerivedData locations)
/// 3. `UserData/IDEEditorInteractivityHistory`
/// 4. `ProductMappingKey` inside `com.apple.dt.Xcode.plist`
struct XcodeProjectStore: Sendable {
    let homeDirectory: String
    let resolveBookmark: @Sendable (Data) -> URL?
    let readFile: @Sendable (String) -> Data?
    let listDirectory: @Sendable (String) -> [String]
    let fileExists: @Sendable (String) -> Bool
    let isDirectory: @Sendable (String) -> Bool
    let modificationDate: @Sendable (String) -> Date?

    init(
        homeDirectory: String = NSHomeDirectory(),
        resolveBookmark: @escaping @Sendable (Data) -> URL? = Self.defaultResolveBookmark,
        readFile: @escaping @Sendable (String) -> Data? = Self.defaultReadFile,
        listDirectory: @escaping @Sendable (String) -> [String] = Self.defaultListDirectory,
        fileExists: @escaping @Sendable (String) -> Bool = Self.defaultFileExists,
        isDirectory: @escaping @Sendable (String) -> Bool = Self.defaultIsDirectory,
        modificationDate: @escaping @Sendable (String) -> Date? = Self.defaultModificationDate
    ) {
        self.homeDirectory = homeDirectory.hasSuffix("/") && homeDirectory.count > 1
            ? String(homeDirectory.dropLast())
            : homeDirectory
        self.resolveBookmark = resolveBookmark
        self.readFile = readFile
        self.listDirectory = listDirectory
        self.fileExists = fileExists
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
    }

    /// Loads recent projects from every available source and merges timestamps
    /// recorded by Prism itself (`recordedOpens`).
    func loadProjects(recordedOpens: [String: Date] = [:]) -> [XcodeProject] {
        var entries: [String: Entry] = [:]

        func merge(path rawPath: String, date: Date?, sflRank: Int?) {
            guard let classified = XcodeProjectClassifier.classify(
                rawPath: rawPath,
                fileExists: fileExists,
                isDirectory: isDirectory
            ) else {
                return
            }
            if var existing = entries[classified.canonicalPath] {
                if let date, existing.lastOpened.map({ date > $0 }) ?? true {
                    existing.lastOpened = date
                }
                if let sflRank, existing.sflRank.map({ sflRank < $0 }) ?? true {
                    existing.sflRank = sflRank
                }
                entries[classified.canonicalPath] = existing
            } else {
                entries[classified.canonicalPath] = Entry(
                    classified: classified,
                    lastOpened: date,
                    sflRank: sflRank
                )
            }
        }

        // 1. Shared File List (Open Recent menu / Welcome window).
        for (index, path) in readSharedFileListPaths().enumerated() {
            merge(path: path, date: nil, sflRank: index)
        }

        // 2. Xcode preferences (`ProductMappingKey` and custom DerivedData path).
        let xcodePlist = readXcodePreferences()
        for item in readProductMappingEntries(from: xcodePlist) {
            merge(path: item.path, date: item.date, sflRank: nil)
        }

        // 3. DerivedData `info.plist` files across default and custom locations.
        for dir in derivedDataDirectories(xcodePreferences: xcodePlist) {
            for item in readDerivedDataEntries(in: dir) {
                merge(path: item.path, date: item.date, sflRank: nil)
            }
        }

        // 4. Editor interactivity history.
        for item in readInteractivityHistoryEntries() {
            merge(path: item.path, date: item.date, sflRank: nil)
        }

        // 5. Projects opened through Prism itself.
        for (path, date) in recordedOpens {
            merge(path: path, date: date, sflRank: nil)
        }

        return entries.values
            .map { entry in
                XcodeProject(
                    path: entry.classified.canonicalPath,
                    openPath: entry.classified.openPath,
                    name: entry.classified.name,
                    kind: entry.classified.kind,
                    lastOpened: entry.lastOpened,
                    sflRank: entry.sflRank
                )
            }
            .sorted(by: Self.byRecency)
    }

    // MARK: - Sources

    private struct Entry {
        let classified: XcodeProjectClassifier.Classified
        var lastOpened: Date?
        var sflRank: Int?
    }

    private struct TimedPath {
        let path: String
        let date: Date?
    }

    private func readSharedFileListPaths() -> [String] {
        let dir = "\(homeDirectory)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
        let candidates = [
            "\(dir)/com.apple.dt.xcode.sfl4",
            "\(dir)/com.apple.dt.xcode.sfl3",
            "\(dir)/com.apple.dt.xcode.sfl2",
        ]
        var paths: [String] = []
        for file in candidates {
            guard let data = readFile(file) else { continue }
            let decoded = parseSharedFileList(data)
            if !decoded.isEmpty {
                paths.append(contentsOf: decoded)
                break
            }
        }
        return paths
    }

    /// Extracts resolved file paths from an `.sfl2`/`.sfl3`/`.sfl4` archive.
    func parseSharedFileList(_ data: Data) -> [String] {
        guard let archive = KeyedArchive(data: data),
              let root = archive.dictionary(archive.topObject(forKey: "root")),
              let items = archive.array(root["items"]) else {
            return []
        }
        var paths: [String] = []
        for item in items {
            let bookmark: Data?
            if let dict = archive.dictionary(item) {
                bookmark = archive.data(dict["Bookmark"])
            } else if let dict = item as? [String: Any] {
                bookmark = archive.data(dict["Bookmark"])
            } else {
                bookmark = nil
            }
            guard let bookmark, let url = resolveBookmark(bookmark), url.isFileURL else {
                continue
            }
            paths.append(url.path)
        }
        return paths
    }

    private func readXcodePreferences() -> [String: Any]? {
        let path = "\(homeDirectory)/Library/Preferences/com.apple.dt.Xcode.plist"
        guard let data = readFile(path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func readProductMappingEntries(from preferences: [String: Any]?) -> [TimedPath] {
        guard let data = preferences?["ProductMappingKey"] as? Data,
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let entries = plist["entries"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let path = entry["workspacePath"] as? String else { return nil }
            return TimedPath(path: path, date: entry["lastOpened"] as? Date)
        }
    }

    private func derivedDataDirectories(xcodePreferences: [String: Any]?) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []

        func add(_ raw: String) {
            let expanded = expandTilde(raw)
            guard expanded.hasPrefix("/") else { return }
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            if seen.insert(standardized).inserted {
                result.append(standardized)
            }
        }

        add("\(homeDirectory)/Library/Developer/Xcode/DerivedData")

        if let custom = xcodePreferences?["IDECustomDerivedDataLocation"] as? String, !custom.isEmpty {
            add(custom)
        }

        let knownLog = "\(homeDirectory)/Library/Developer/Xcode/.knownDerivedDataLocations.log"
        if let data = readFile(knownLog),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dirs = json["derivedDataDirectories"] as? [Any] {
            for item in dirs {
                if let path = item as? String {
                    add(path)
                }
            }
        }

        return result
    }

    private func readDerivedDataEntries(in directory: String) -> [TimedPath] {
        var results: [TimedPath] = []
        for child in listDirectory(directory) {
            let infoPath = "\(directory)/\(child)/info.plist"
            guard let data = readFile(infoPath),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let workspacePath = plist["WorkspacePath"] as? String else {
                continue
            }
            let date = (plist["LastAccessedDate"] as? Date) ?? modificationDate(infoPath)
            results.append(TimedPath(path: workspacePath, date: date))
        }
        return results
    }

    private func readInteractivityHistoryEntries() -> [TimedPath] {
        let path = "\(homeDirectory)/Library/Developer/Xcode/UserData/IDEEditorInteractivityHistory"
        guard let data = readFile(path) else { return [] }
        return parseInteractivityHistory(data)
    }

    private func parseInteractivityHistory(_ data: Data) -> [TimedPath] {
        guard let archive = KeyedArchive(data: data),
              let items = archive.array(archive.topObject(forKey: "historyItems")) else {
            return []
        }
        var results: [TimedPath] = []
        for rawItem in items {
            guard let item = rawItem as? [String: Any],
                  let url = archive.url(item["documentURL"]),
                  url.isFileURL else {
                continue
            }
            let date = archive.date(item["mostRecentActivity"]) ?? archive.date(item["startOfActivity"])
            results.append(TimedPath(path: url.path, date: date))
        }
        return results
    }

    private func expandTilde(_ path: String) -> String {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory + String(path.dropFirst())
        }
        return path
    }

    // MARK: - Ordering

    /// Newest timestamp first; entries known only from Xcode's Shared File List
    /// follow in their SFL order; ties break by name then path for stability.
    static func byRecency(_ lhs: XcodeProject, _ rhs: XcodeProject) -> Bool {
        switch (lhs.lastOpened, rhs.lastOpened) {
        case let (lDate?, rDate?) where lDate != rDate:
            return lDate > rDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            switch (lhs.sflRank, rhs.sflRank) {
            case let (lRank?, rRank?) where lRank != rRank:
                return lRank < rRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.path < rhs.path
            }
        }
    }

    // MARK: - Production filesystem helpers

    private static func defaultResolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private static func defaultReadFile(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func defaultListDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    private static func defaultFileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func defaultIsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func defaultModificationDate(_ path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}
