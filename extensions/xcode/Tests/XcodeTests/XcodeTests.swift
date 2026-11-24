import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import Xcode

@Suite("Xcode Extension")
struct XcodeTests {
    static let home = "/Users/dev"

    /// Fixed UTC reference clock so date labels hold in every time zone.
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Empty states

    @Test("Shows helpful empty states when no projects exist")
    func emptyStates() async throws {
        let env = FakeEnvironment(home: Self.home)
        let host = try await makeHost(env: env)

        let all = try await host.list(Xcode.CommandID.recentProjects)
        #expect(all.items.isEmpty)
        #expect(all.filtering == .prism)
        #expect(all.filters.map(\.id) == ["all", "project", "workspace", "package", "playground"])
        #expect(all.emptyMessage?.title == "No Recent Projects")

        let workspaces = try await host.list(Xcode.CommandID.recentProjects, filter: Xcode.FilterID.workspace)
        #expect(workspaces.emptyMessage?.title == "No Recent Workspaces")

        let packages = try await host.list(Xcode.CommandID.recentProjects, filter: Xcode.FilterID.package)
        #expect(packages.emptyMessage?.title == "No Recent Swift Packages")

        let playgrounds = try await host.list(Xcode.CommandID.recentProjects, filter: Xcode.FilterID.playground)
        #expect(playgrounds.emptyMessage?.title == "No Recent Playgrounds")

        let projects = try await host.list(Xcode.CommandID.recentProjects, filter: Xcode.FilterID.project)
        #expect(projects.emptyMessage?.title == "No Recent Xcode Projects")
    }

    // MARK: - Multi-source discovery, merging, filtering, and deduplication

    @Test("Merges SFL, DerivedData, interactivity history, and ProductMapping newest first")
    func mergesAllSourcesAndDeduplicates() async throws {
        let now = Self.utcDate(2026, 11, 24, 15, 0)
        var env = FakeEnvironment(home: Self.home)

        // Existing paths on disk.
        let prismProj = "\(Self.home)/projects/prism/Prism.xcodeproj"
        let prismWorktree = "\(Self.home)/projects/prism-feat/Prism.xcodeproj"
        let appWorkspace = "\(Self.home)/work/App/App.xcworkspace"
        let kitPackage = "\(Self.home)/packages/PrismKit"
        let demoPlayground = "\(Self.home)/playgrounds/Shaders.playground"
        let sflOnlyProj = "\(Self.home)/old/Legacy.xcodeproj"
        let deletedProj = "\(Self.home)/projects/deleted/Gone.xcodeproj"
        let tempContainer = "/var/folders/0w/abc/Xcode/FilesWorkspaces/123/Files.xcfilescontainer"
        let checkoutProj = "\(Self.home)/projects/prism/SourcePackages/checkouts/Sparkle/Sparkle.xcodeproj"

        env.addExistingFile(prismProj)
        env.addExistingFile(prismWorktree)
        env.addExistingFile(appWorkspace)
        env.addExistingPackage(kitPackage)
        env.addExistingFile(demoPlayground)
        env.addExistingFile(sflOnlyProj)
        env.addExistingFile(tempContainer)
        env.addExistingFile(checkoutProj)

        // 1. SFL4: contains sflOnlyProj, kitPackage/Package.swift, deletedProj, and prismProj.
        try env.writeSFL4(paths: [
            sflOnlyProj,
            "\(kitPackage)/Package.swift",
            deletedProj,
            prismProj,
        ])

        // 2. Default DerivedData: prismProj (older), prismWorktree (yesterday), deletedProj, checkoutProj.
        try env.writeDerivedData(
            folder: "Prism-aaa",
            workspacePath: prismProj,
            lastAccessed: Self.utcDate(2026, 11, 20, 10, 0)
        )
        try env.writeDerivedData(
            folder: "Prism-bbb",
            workspacePath: prismWorktree,
            lastAccessed: Self.utcDate(2026, 11, 23, 9, 0)
        )
        try env.writeDerivedData(
            folder: "Gone-ccc",
            workspacePath: deletedProj,
            lastAccessed: Self.utcDate(2026, 11, 24, 14, 0)
        )
        try env.writeDerivedData(
            folder: "Sparkle-ddd",
            workspacePath: checkoutProj,
            lastAccessed: Self.utcDate(2026, 11, 24, 14, 30)
        )

        // Custom DerivedData directory with Swift package (recorded by directory).
        let customDD = "\(Self.home)/CustomDerivedData"
        try env.writeDerivedData(
            in: customDD,
            folder: "PrismKit-eee",
            workspacePath: kitPackage,
            lastAccessed: Self.utcDate(2026, 11, 24, 11, 0)
        )

        // 3. Xcode plist: custom DerivedData location + ProductMappingKey (newer prismProj + temp container).
        try env.writeXcodePreferences(
            customDerivedData: "~/CustomDerivedData",
            productMappings: [
                (prismProj, Self.utcDate(2026, 11, 24, 14, 0)),
                (tempContainer, Self.utcDate(2026, 11, 24, 14, 59)),
            ]
        )

        // 4. Interactivity history: appWorkspace (newest), internal project.xcworkspace (merges into prismProj), demoPlayground.
        try env.writeInteractivityHistory(items: [
            ("file://\(appWorkspace)", Self.utcDate(2026, 11, 24, 14, 45)),
            ("file://\(prismProj)/project.xcworkspace", Self.utcDate(2026, 11, 22, 8, 0)),
            ("file://\(demoPlayground)", Self.utcDate(2026, 11, 18, 12, 0)),
            ("x-initial-editor-document://start-page/123", Self.utcDate(2026, 11, 24, 15, 0)),
        ])

        let host = try await makeHost(env: env, now: now)
        let list = try await host.list(Xcode.CommandID.recentProjects)

        // Expected order:
        // 1. App.xcworkspace (Nov 24 14:45)
        // 2. Prism (Nov 24 14:00, merged from SFL + DerivedData + ProductMapping + project.xcworkspace)
        // 3. PrismKit (Nov 24 11:00, merged from SFL Package.swift + Custom DerivedData dir)
        // 4. Prism worktree (Nov 23 09:00)
        // 5. Shaders playground (Nov 18 12:00)
        // 6. Legacy (SFL-only, undated -> after dated items)
        #expect(list.items.map(\.id) == [
            appWorkspace,
            prismProj,
            kitPackage,
            prismWorktree,
            demoPlayground,
            sflOnlyProj,
        ])

        // Check titles, subtitles, and badges.
        #expect(list.items[0].title == "App")
        #expect(list.items[0].subtitle == "~/work/App")
        #expect(list.items[0].accessories.first?.text == "Workspace")

        #expect(list.items[1].title == "Prism")
        #expect(list.items[1].subtitle == "~/projects/prism")
        #expect(list.items[1].accessories.first?.text == "Project")

        #expect(list.items[2].title == "PrismKit")
        #expect(list.items[2].subtitle == "~/packages")
        #expect(list.items[2].accessories.first?.text == "Package")
        // Packages already copy the directory via Copy Path, so Copy Project Directory is omitted.
        #expect(list.items[2].actions.map(\.id) == ["open", "show-in-finder", "copy-path"])

        // Worktree disambiguation + Yesterday label.
        #expect(list.items[3].title == "Prism")
        #expect(list.items[3].subtitle == "~/projects/prism-feat")
        #expect(list.items[3].accessories.last?.text == "Yesterday")
        #expect(list.items[3].actions.map(\.id) == ["open", "show-in-finder", "copy-path", "copy-directory"])

        // SFL-only entry has kind tag and no date accessory.
        #expect(list.items[5].accessories.count == 1)
        #expect(list.items[5].accessories[0].text == "Project")

        // Filter by each project kind.
        #expect(try await host.list(Xcode.CommandID.recentProjects, filter: Xcode.FilterID.workspace).items.map(\.id) == [appWorkspace])
        #expect(try await host.list(Xcode.CommandID.recentProjects, filter: Xcode.FilterID.package).items.map(\.id) == [kitPackage])
        #expect(try await host.list(Xcode.CommandID.recentProjects, filter: Xcode.FilterID.playground).items.map(\.id) == [demoPlayground])
        #expect(try await host.list(Xcode.CommandID.recentProjects, filter: Xcode.FilterID.project).items.map(\.id) == [prismProj, prismWorktree, sflOnlyProj])
    }

    // MARK: - Actions, state persistence, and preferences

    @Test("Opens projects with configured Xcode, records recency across restarts, and reveals in Finder")
    func openAndRevealActions() async throws {
        let t1 = Self.utcDate(2026, 11, 24, 10, 0)
        let t2 = Self.utcDate(2026, 11, 24, 16, 0)
        let clock = TestClock(t1)

        var env = FakeEnvironment(home: Self.home)
        let alphaProj = "\(Self.home)/projects/alpha/Alpha.xcodeproj"
        let pkgDir = "\(Self.home)/packages/BetaKit"
        env.addExistingFile(alphaProj)
        env.addExistingPackage(pkgDir)
        try env.writeDerivedData(folder: "Alpha-1", workspacePath: alphaProj, lastAccessed: Self.utcDate(2026, 11, 24, 9, 0))
        try env.writeDerivedData(folder: "BetaKit-2", workspacePath: pkgDir, lastAccessed: Self.utcDate(2026, 11, 20, 9, 0))

        let launcher = FakeLauncher()
        let host = try await makeHost(env: env, launcher: launcher, now: { clock.now })

        let before = try await host.list(Xcode.CommandID.recentProjects)
        #expect(before.items.map(\.id) == [alphaProj, pkgDir])

        // Open Swift package with custom Xcode preference.
        try await host.setPreferences([Xcode.PreferenceID.xcodeApp: .string("/Applications/Xcode-beta.app")])
        clock.now = t2
        let openResult = try await host.perform(
            Xcode.ActionID.open,
            on: pkgDir,
            in: Xcode.CommandID.recentProjects
        )
        #expect(openResult == .done)
        #expect(await launcher.opened == [
            FakeLauncher.OpenCall(path: "\(pkgDir)/Package.swift", xcodeAppPath: "/Applications/Xcode-beta.app"),
        ])

        // Restart the extension: recorded open timestamp persists in Prism state and moves BetaKit first.
        try await host.restart()
        let after = try await host.list(Xcode.CommandID.recentProjects)
        #expect(after.items.map(\.id) == [pkgDir, alphaProj])

        // Reveal in Finder.
        let revealResult = try await host.perform(
            Xcode.ActionID.showInFinder,
            on: alphaProj,
            in: Xcode.CommandID.recentProjects
        )
        #expect(revealResult == .done)
        #expect(await launcher.revealed == [alphaProj])
    }

    @Test("Handles deleted projects, missing Xcode, and unknown IDs gracefully")
    func errorPaths() async throws {
        var env = FakeEnvironment(home: Self.home)
        let proj = "\(Self.home)/projects/App/App.xcodeproj"
        env.addExistingFile(proj)

        let launcher = FakeLauncher()
        let host = try await makeHost(env: env, launcher: launcher)

        // Deleted project reloads the list with a clear message.
        let missingResult = try await host.perform(
            Xcode.ActionID.open,
            on: "\(Self.home)/projects/Gone/Gone.xcodeproj",
            in: Xcode.CommandID.recentProjects
        )
        #expect(missingResult == .reload(message: "“Gone.xcodeproj” no longer exists on disk."))

        // Missing custom Xcode app path.
        await launcher.setOpenError(XcodeLaunchError.xcodeNotFound("/Applications/Xcode-beta.app"))
        let customMissing = try await host.perform(
            Xcode.ActionID.open,
            on: proj,
            in: Xcode.CommandID.recentProjects
        )
        #expect(customMissing.result == .failed(message: "Xcode couldn’t be found at “/Applications/Xcode-beta.app”."))

        // Xcode not installed.
        await launcher.setOpenError(XcodeLaunchError.xcodeNotFound(nil))
        let notInstalled = try await host.perform(
            Xcode.ActionID.open,
            on: proj,
            in: Xcode.CommandID.recentProjects
        )
        #expect(notInstalled.result == .failed(message: "Xcode isn’t installed on this Mac."))

        // Finder error.
        await launcher.setRevealError(XcodeLaunchError.openFailed("denied"))
        let finderFailed = try await host.perform(
            Xcode.ActionID.showInFinder,
            on: proj,
            in: Xcode.CommandID.recentProjects
        )
        #expect(finderFailed.result == .failed(message: "Finder couldn’t show “App.xcodeproj”."))

        // Unknown command fails the list request; unknown action returns a failed result.
        await #expect(throws: PrismTestHost.Failure.self) {
            _ = try await host.list("unknown-command")
        }
        let unknownAction = try await host.perform("unknown-action", on: proj, in: Xcode.CommandID.recentProjects)
        #expect(unknownAction == ExtensionActionResult(.failed(message: "Xcode has no action “unknown-action”.")))
    }

    // MARK: - Pinyin & localizations

    @Test("Adds pinyin keywords for Chinese project names and localizes UI")
    func pinyinAndLocalizations() async throws {
        let now = Self.utcDate(2026, 11, 24, 15, 0)
        var env = FakeEnvironment(home: Self.home)
        let chineseProj = "\(Self.home)/项目/南音.xcodeproj"
        env.addExistingFile(chineseProj)
        try env.writeDerivedData(folder: "Nanyin-1", workspacePath: chineseProj, lastAccessed: Self.utcDate(2026, 11, 23, 12, 0))

        let zhHansHost = try await makeHost(env: env, now: now, language: "zh-Hans")
        let hansList = try await zhHansHost.list(Xcode.CommandID.recentProjects)
        let hansItem = try #require(hansList.items.first)
        #expect(hansItem.title == "南音")
        #expect(hansItem.keywords.contains("nanyin"))
        #expect(hansItem.keywords.contains("ny"))
        #expect(hansItem.keywords.contains("xiangmu"))
        #expect(hansItem.accessories.map(\.text) == ["项目", "昨天"])
        #expect(hansItem.actions.first?.title == "在 Xcode 中打开")
        #expect(hansList.searchPlaceholder == "搜索最近使用的 Xcode 项目…")

        let zhHantHost = try await makeHost(env: env, now: now, language: "zh-Hant")
        let hantList = try await zhHantHost.list(Xcode.CommandID.recentProjects)
        let hantItem = try #require(hantList.items.first)
        #expect(hantItem.accessories.map(\.text) == ["專案", "昨天"])
        #expect(hantItem.actions.first?.title == "在 Xcode 中打開")
        #expect(hantList.searchPlaceholder == "搜尋最近使用的 Xcode 專案…")
    }

    // MARK: - Helpers

    private func makeHost(
        env: FakeEnvironment,
        launcher: FakeLauncher = FakeLauncher(),
        now: Date = utcDate(2026, 11, 24, 15, 0),
        language: String? = nil
    ) async throws -> PrismTestHost {
        try await makeHost(env: env, launcher: launcher, now: { now }, language: language)
    }

    private func makeHost(
        env: FakeEnvironment,
        launcher: FakeLauncher = FakeLauncher(),
        now: @escaping @Sendable () -> Date,
        language: String? = nil
    ) async throws -> PrismTestHost {
        let extensionUnderTest = Xcode(
            store: env.makeStore(),
            launcher: launcher,
            now: now,
            calendar: Self.utcCalendar
        )
        return try await PrismTestHost(
            extensionUnderTest,
            extensionID: "prism.xcode",
            language: language
        )
    }
}

// MARK: - Test doubles

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ initial: Date) { self.now = initial }
}

private actor FakeLauncher: XcodeLaunching {
    struct OpenCall: Equatable, Sendable {
        let path: String
        let xcodeAppPath: String?
    }

    private(set) var opened: [OpenCall] = []
    private(set) var revealed: [String] = []
    private var openError: Error?
    private var revealError: Error?

    func setOpenError(_ error: Error?) {
        openError = error
    }

    func setRevealError(_ error: Error?) {
        revealError = error
    }

    func openProject(at path: String, xcodeAppPath: String?) async throws {
        if let openError {
            throw openError
        }
        opened.append(OpenCall(path: path, xcodeAppPath: xcodeAppPath))
    }

    func revealInFinder(path: String) async throws {
        if let revealError {
            throw revealError
        }
        revealed.append(path)
    }
}

/// In-memory filesystem and Xcode artifact builder for deterministic tests.
private struct FakeEnvironment: Sendable {
    let home: String
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private var bookmarks: [Data: URL] = [:]

    init(home: String) {
        self.home = home
    }

    mutating func addExistingFile(_ path: String) {
        files[path] = Data()
    }

    mutating func addExistingPackage(_ directoryPath: String) {
        directories.insert(directoryPath)
        files["\(directoryPath)/Package.swift"] = Data()
    }

    mutating func writeDerivedData(
        in baseDirectory: String? = nil,
        folder: String,
        workspacePath: String,
        lastAccessed: Date
    ) throws {
        let base = baseDirectory ?? "\(home)/Library/Developer/Xcode/DerivedData"
        let infoPath = "\(base)/\(folder)/info.plist"
        let plist: [String: Any] = [
            "WorkspacePath": workspacePath,
            "LastAccessedDate": lastAccessed,
        ]
        files[infoPath] = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    mutating func writeXcodePreferences(
        customDerivedData: String? = nil,
        productMappings: [(String, Date)] = []
    ) throws {
        var root: [String: Any] = [:]
        if let customDerivedData {
            root["IDECustomDerivedDataLocation"] = customDerivedData
        }
        if !productMappings.isEmpty {
            let entries: [[String: Any]] = productMappings.map { path, date in
                ["workspacePath": path, "lastOpened": date]
            }
            let mappingData = try PropertyListSerialization.data(
                fromPropertyList: ["entries": entries],
                format: .binary,
                options: 0
            )
            root["ProductMappingKey"] = mappingData
        }
        let path = "\(home)/Library/Preferences/com.apple.dt.Xcode.plist"
        files[path] = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    mutating func writeSFL4(paths: [String]) throws {
        var archivedItems: [NSDictionary] = []
        for path in paths {
            let bookmark = Data("bookmark:\(path)".utf8)
            bookmarks[bookmark] = URL(fileURLWithPath: path)
            archivedItems.append([
                "Name": URL(fileURLWithPath: path).lastPathComponent,
                "Bookmark": bookmark,
                "visibility": 0,
            ])
        }
        let root: NSDictionary = [
            "items": archivedItems as NSArray,
            "properties": NSDictionary(),
        ]
        let data = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
        let path = "\(home)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.dt.xcode.sfl4"
        files[path] = data
    }

    /// Writes a synthetic `IDEEditorInteractivityHistory` binary plist using the
    /// same `NSKeyedArchiver` `$objects` / `$top` graph that Xcode produces.
    mutating func writeInteractivityHistory(items: [(String, Date)]) throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        let encodedItems = items.map { urlString, date in
            FakeHistoryItem(urlString: urlString, date: date)
        }
        archiver.encode(encodedItems, forKey: "historyItems")
        archiver.encode(1, forKey: "version")
        archiver.finishEncoding()

        let path = "\(home)/Library/Developer/Xcode/UserData/IDEEditorInteractivityHistory"
        files[path] = archiver.encodedData
    }

    func makeStore() -> XcodeProjectStore {
        let snapshotFiles = files
        let snapshotDirs = directories
        let snapshotBookmarks = bookmarks

        return XcodeProjectStore(
            homeDirectory: home,
            resolveBookmark: { snapshotBookmarks[$0] },
            readFile: { snapshotFiles[$0] },
            listDirectory: { dir in
                let prefix = dir.hasSuffix("/") ? dir : dir + "/"
                var children: Set<String> = []
                for path in snapshotFiles.keys {
                    guard path.hasPrefix(prefix) else { continue }
                    let remainder = path.dropFirst(prefix.count)
                    if let first = remainder.split(separator: "/").first {
                        children.insert(String(first))
                    }
                }
                return Array(children).sorted()
            },
            fileExists: { snapshotFiles[$0] != nil || snapshotDirs.contains($0) },
            isDirectory: { snapshotDirs.contains($0) },
            modificationDate: { _ in nil }
        )
    }
}

@objc(IDEEditorInteractivityHistoryItem)
private final class FakeHistoryItem: NSObject, NSCoding {
    let urlString: String
    let date: Date

    init(urlString: String, date: Date) {
        self.urlString = urlString
        self.date = date
    }

    required init?(coder: NSCoder) {
        fatalError("unused")
    }

    func encode(with coder: NSCoder) {
        if let url = URL(string: urlString) {
            coder.encode(url as NSURL, forKey: "documentURL")
        }
        coder.encode(date as NSDate, forKey: "mostRecentActivity")
        coder.encode(date as NSDate, forKey: "startOfActivity")
    }
}
