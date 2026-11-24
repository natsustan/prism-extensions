import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import SQLite3
import Testing
@testable import Zed

// MARK: - Test Support

private actor FakeZedLauncher: ZedLaunching {
    struct LocalOpen: Equatable, Sendable {
        let paths: [String]
        let zedAppPath: String?
    }

    struct RemoteOpen: Equatable, Sendable {
        let urls: [URL]
        let zedAppPath: String?
    }

    private(set) var openedLocal: [LocalOpen] = []
    private(set) var openedRemote: [RemoteOpen] = []
    private(set) var revealed: [String] = []
    var nextError: Error?

    func setNextError(_ error: Error?) {
        nextError = error
    }

    func openLocalWorkspace(paths: [String], zedAppPath: String?) async throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
        openedLocal.append(LocalOpen(paths: paths, zedAppPath: zedAppPath))
    }

    func openRemoteWorkspace(urls: [URL], zedAppPath: String?) async throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
        openedRemote.append(RemoteOpen(urls: urls, zedAppPath: zedAppPath))
    }

    func revealInFinder(path: String) async throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
        revealed.append(path)
    }
}

private func makeTempDatabase(sql: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zed-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("db.sqlite")

    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
        throw NSError(domain: "ZedTests", code: 1)
    }
    defer { sqlite3_close(handle) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    if result != SQLITE_OK {
        let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
        sqlite3_free(errorMessage)
        throw NSError(domain: "ZedTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
    }
    return url
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func fixedDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.timeZone = TimeZone(secondsFromGMT: 0)
    return utcCalendar().date(from: components)!
}

// MARK: - Tests

@Suite("Zed")
struct ZedTests {
    @Test("Empty state when Zed database does not exist")
    func missingDatabaseShowsEmptyState() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("zed-missing-\(UUID().uuidString)/db.sqlite")
        let store = ZedWorkspaceStore(
            homeDirectory: "/Users/alice",
            databaseURLOverride: missing,
            fileExists: { _ in false },
            isDirectory: { _ in false }
        )
        let host = try await PrismTestHost(
            Zed(store: store, launcher: FakeZedLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.zed"
        )

        let list = try await host.list("recent-projects")
        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "No Recent Projects")
        #expect(list.filters.map(\.id) == ["all", "local", "remote"])
    }

    @Test("Loads modern workspaces, respects paths_order, skips deleted and empty rows")
    func loadsModernWorkspaces() async throws {
        let dbURL = try makeTempDatabase(sql: """
            CREATE TABLE remote_connections (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                host TEXT,
                port INTEGER,
                user TEXT,
                distro TEXT,
                name TEXT,
                container_id TEXT
            );
            CREATE TABLE workspaces (
                workspace_id INTEGER PRIMARY KEY,
                paths TEXT,
                paths_order TEXT,
                remote_connection_id INTEGER REFERENCES remote_connections(id),
                timestamp TEXT NOT NULL
            );

            INSERT INTO remote_connections (id, kind, host, port, user)
            VALUES (1, 'ssh', 'dev.example.com', 2222, 'alice');
            INSERT INTO remote_connections (id, kind, name, container_id)
            VALUES (2, 'docker', 'api-dev', 'abc123');

            INSERT INTO workspaces (workspace_id, paths, paths_order, remote_connection_id, timestamp) VALUES
                (1, '/Users/alice/projects/prism', '0', NULL, '2026-11-24 10:30:00'),
                (2, '', '', NULL, '2026-11-24 11:00:00'),
                (3, '/Users/alice/projects/deleted', '0', NULL, '2026-11-24 11:15:00'),
                (4, '/Users/alice/docs\n/Users/alice/projects/南音', '1,0', NULL, '2026-11-23 09:00:00'),
                (5, '/Users/alice/notes/todo.md', '0', NULL, '2026-11-20 08:00:00'),
                (6, '/home/alice/service', '0', 1, '2026-11-24 09:00:00'),
                (7, '/workspace/api', '0', 2, '2026-11-22 15:00:00');
            """)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let existingDirs: Set<String> = [
            "/Users/alice/projects/prism",
            "/Users/alice/docs",
            "/Users/alice/projects/南音",
        ]
        let existingFiles: Set<String> = [
            dbURL.path,
            "/Users/alice/notes/todo.md",
        ]
        let store = ZedWorkspaceStore(
            homeDirectory: "/Users/alice",
            databaseURLOverride: dbURL,
            fileExists: { existingDirs.contains($0) || existingFiles.contains($0) },
            isDirectory: { existingDirs.contains($0) },
            branchLookup: { $0 == "/Users/alice/projects/prism" ? "feat/ios-diction" : nil }
        )
        let host = try await PrismTestHost(
            Zed(store: store, launcher: FakeZedLauncher(), now: { fixedDate(2026, 11, 24, 12, 0) }),
            extensionID: "prism.zed"
        )

        let list = try await host.list("recent-projects")
        #expect(list.items.map(\.title) == [
            "prism",
            "service",
            "南音, docs",
            "api",
            "todo.md",
        ])

        // Local single folder: clean glyph folder icon + Git branch pill (no timestamp)
        let prism = try #require(list.items.first)
        #expect(prism.subtitle == "~/projects")
        #expect(prism.icon == ExtensionIcon(symbol: "folder.fill", tint: "gray", style: .glyph))
        #expect(prism.accessories.count == 1)
        #expect(prism.accessories.first?.text == "feat/ios-diction")
        #expect(prism.accessories.first?.symbol == "arrow.triangle.branch")
        #expect(prism.accessories.first?.style == .tag)
        #expect(prism.keywords.contains("feat/ios-diction"))
        #expect(prism.actions.map(\.id) == ["open", "show-in-finder", "copy-path"])

        // Remote SSH workspace
        let ssh = list.items[1]
        #expect(ssh.subtitle == "alice@dev.example.com:2222 — /home/alice/service")
        #expect(ssh.accessories.first?.text == "SSH")
        #expect(ssh.actions.map(\.id) == ["open", "copy-path"])

        // Multi-folder workspace reordered by paths_order ("1,0") + Pinyin keywords
        let multi = list.items[2]
        #expect(multi.subtitle == "~/projects/南音 · ~/docs")
        #expect(multi.accessories.first?.text == "2 Folders")
        #expect(multi.keywords.contains("nanyin") == true)
        #expect(multi.keywords.contains("ny") == true)

        // Docker remote workspace has Copy Path as primary action
        let docker = list.items[3]
        #expect(docker.accessories.first?.text == "Docker")
        #expect(docker.actions.map(\.id) == ["copy-path"])

        // Single local file shows File badge and Copy Containing Folder action
        let file = list.items[4]
        #expect(file.accessories.first?.text == "File")
        #expect(file.actions.map(\.id) == ["open", "show-in-finder", "copy-path", "copy-directory"])

        // Filter: local only
        let localList = try await host.list("recent-projects", filter: "local")
        #expect(localList.items.map(\.title) == ["prism", "南音, docs", "todo.md"])

        // Filter: remote only
        let remoteList = try await host.list("recent-projects", filter: "remote")
        #expect(remoteList.items.map(\.title) == ["service", "api"])
    }

    @Test("Loads legacy ssh_connections schema")
    func loadsLegacySSHSchema() async throws {
        let dbURL = try makeTempDatabase(sql: """
            CREATE TABLE ssh_connections (
                id INTEGER PRIMARY KEY,
                host TEXT NOT NULL,
                port INTEGER,
                username TEXT
            );
            CREATE TABLE workspaces (
                workspace_id INTEGER PRIMARY KEY,
                local_paths TEXT,
                ssh_connection_id INTEGER REFERENCES ssh_connections(id),
                timestamp TEXT NOT NULL
            );
            INSERT INTO ssh_connections (id, host, port, username) VALUES (1, 'box.internal', NULL, 'dev');
            INSERT INTO workspaces (workspace_id, local_paths, ssh_connection_id, timestamp)
            VALUES (1, '/srv/app', 1, '2026-11-24 08:00:00');
            """)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let store = ZedWorkspaceStore(
            homeDirectory: "/Users/alice",
            databaseURLOverride: dbURL,
            fileExists: { $0 == dbURL.path },
            isDirectory: { _ in false }
        )
        let host = try await PrismTestHost(
            Zed(store: store, launcher: FakeZedLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.zed"
        )

        let list = try await host.list("recent-projects")
        #expect(list.items.count == 1)
        #expect(list.items[0].title == "app")
        #expect(list.items[0].subtitle == "dev@box.internal — /srv/app")
    }

    @Test("Opening local and SSH workspaces launches Zed and bubbles item to top across restart")
    func opensWorkspacesAndPersistsRecentOrder() async throws {
        let dbURL = try makeTempDatabase(sql: """
            CREATE TABLE remote_connections (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                host TEXT,
                port INTEGER,
                user TEXT
            );
            CREATE TABLE workspaces (
                workspace_id INTEGER PRIMARY KEY,
                paths TEXT,
                paths_order TEXT,
                remote_connection_id INTEGER REFERENCES remote_connections(id),
                timestamp TEXT NOT NULL
            );
            INSERT INTO remote_connections (id, kind, host, port, user)
            VALUES (1, 'ssh', 'prod.example.com', 2200, 'deploy');
            INSERT INTO workspaces (workspace_id, paths, paths_order, remote_connection_id, timestamp) VALUES
                (1, '/Users/alice/projects/newer', '0', NULL, '2026-11-24 10:00:00'),
                (2, '/Users/alice/projects/older', '0', NULL, '2026-11-20 10:00:00'),
                (3, '/var/www/api\n/var/www/site', '1,0', 1, '2026-11-21 10:00:00');
            """)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let dirs: Set<String> = ["/Users/alice/projects/newer", "/Users/alice/projects/older"]
        let store = ZedWorkspaceStore(
            homeDirectory: "/Users/alice",
            databaseURLOverride: dbURL,
            fileExists: { $0 == dbURL.path || dirs.contains($0) },
            isDirectory: { dirs.contains($0) }
        )
        let launcher = FakeZedLauncher()
        let host = try await PrismTestHost(
            Zed(store: store, launcher: launcher, now: { fixedDate(2026, 11, 24, 15, 0) }),
            extensionID: "prism.zed",
            preferences: ["zedApp": .string("/Applications/Zed Preview.app")]
        )

        let before = try await host.list("recent-projects")
        #expect(before.items.map(\.title) == ["newer", "site, api", "older"])

        // Open older local project
        let openLocal = try await host.perform("open", on: before.items[2].id, in: "recent-projects")
        #expect(openLocal == .done)
        let localOpens = await launcher.openedLocal
        #expect(localOpens == [
            FakeZedLauncher.LocalOpen(paths: ["/Users/alice/projects/older"], zedAppPath: "/Applications/Zed Preview.app"),
        ])

        // Open multi-folder SSH workspace: uses ssh:// for all channels and preserves every folder
        let openRemote = try await host.perform("open", on: before.items[1].id, in: "recent-projects")
        #expect(openRemote == .done)
        let remoteOpens = await launcher.openedRemote
        #expect(remoteOpens.count == 1)
        #expect(remoteOpens[0].urls.map(\.absoluteString) == [
            "ssh://deploy@prod.example.com:2200/var/www/site",
            "ssh://deploy@prod.example.com:2200/var/www/api",
        ])
        #expect(remoteOpens[0].zedAppPath == "/Applications/Zed Preview.app")

        // Reveal in Finder
        let reveal = try await host.perform("show-in-finder", on: before.items[0].id, in: "recent-projects")
        #expect(reveal == .done)
        #expect(await launcher.revealed == ["/Users/alice/projects/newer"])

        // Restart host to prove recentOpens state survives process exit
        try await host.restart()
        let after = try await host.list("recent-projects")
        #expect(after.items.first?.title == "older" || after.items.first?.title == "site, api")
        #expect(after.items.last?.title == "newer")
    }

    @Test("Handles missing Zed app and missing project errors gracefully")
    func handlesLaunchErrors() async throws {
        let dbURL = try makeTempDatabase(sql: """
            CREATE TABLE workspaces (
                workspace_id INTEGER PRIMARY KEY,
                paths TEXT,
                paths_order TEXT,
                timestamp TEXT NOT NULL
            );
            INSERT INTO workspaces (workspace_id, paths, paths_order, timestamp)
            VALUES (1, '/Users/alice/projects/app', '0', '2026-11-24 10:00:00');
            """)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let store = ZedWorkspaceStore(
            homeDirectory: "/Users/alice",
            databaseURLOverride: dbURL,
            fileExists: { $0 == dbURL.path || $0 == "/Users/alice/projects/app" },
            isDirectory: { $0 == "/Users/alice/projects/app" }
        )
        let launcher = FakeZedLauncher()
        let host = try await PrismTestHost(
            Zed(store: store, launcher: launcher, now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.zed"
        )

        await launcher.setNextError(ZedLaunchError.zedNotFound(nil))
        let notInstalled = try await host.perform("open", on: "/Users/alice/projects/app", in: "recent-projects")
        #expect(notInstalled == ExtensionActionResult(.failed(message: "Zed isn’t installed on this Mac.")))

        await launcher.setNextError(ZedLaunchError.zedNotFound("/Applications/CustomZed.app"))
        let customMissing = try await host.perform("open", on: "/Users/alice/projects/app", in: "recent-projects")
        #expect(customMissing == ExtensionActionResult(.failed(message: "Zed couldn’t be found at “/Applications/CustomZed.app”.")))

        let deleted = try await host.perform("open", on: "/Users/alice/projects/gone", in: "recent-projects")
        #expect(deleted == .reload(message: "“gone” no longer exists on disk."))
    }

    @Test("Reads Git branch from standard repo, nested directory, worktree, and detached HEAD")
    func readsGitBranches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zed-git-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Standard repo + nested subdirectory
        let repo = root.appendingPathComponent("prism", isDirectory: true)
        let nested = repo.appendingPathComponent("Sources/App", isDirectory: true)
        let dotGit = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        try "ref: refs/heads/feat/ios-diction\n".write(
            to: dotGit.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )

        #expect(GitBranchReader.branch(forDirectory: repo.path, stopAt: root.path) == "feat/ios-diction")
        #expect(GitBranchReader.branch(forDirectory: nested.path, stopAt: root.path) == "feat/ios-diction")

        // Worktree with `.git` file pointing via relative gitdir
        let worktree = root.appendingPathComponent("prism-wt", isDirectory: true)
        let wtGitDir = root.appendingPathComponent("git-wt-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wtGitDir, withIntermediateDirectories: true)
        try "gitdir: ../git-wt-meta\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/main\n".write(
            to: wtGitDir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        #expect(GitBranchReader.branch(forDirectory: worktree.path, stopAt: root.path) == "main")

        // Detached HEAD parsing
        #expect(GitBranchReader.parseHead("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n") == "a1b2c3d")
        #expect(GitBranchReader.parseHead("ref: refs/tags/v1.0.0\n") == "v1.0.0")
        #expect(GitBranchReader.parseHead("   ") == nil)
    }

    @Test("Keeps workspace ID stable when multi-folder display order changes")
    func workspaceIDIsIndependentOfDisplayOrder() {
        let localA = ZedWorkspace.makeID(paths: ["/Users/alice/b", "/Users/alice/a"], remote: nil)
        let localB = ZedWorkspace.makeID(paths: ["/Users/alice/a", "/Users/alice/b"], remote: nil)
        #expect(localA == localB)

        let ssh = ZedRemoteConnection(kind: "ssh", host: "dev.example.com", user: "alice")
        let remoteA = ZedWorkspace.makeID(paths: ["/srv/two", "/srv/one"], remote: ssh)
        let remoteB = ZedWorkspace.makeID(paths: ["/srv/one", "/srv/two"], remote: ssh)
        #expect(remoteA == remoteB)
    }

    @Test("Brackets IPv6 SSH hosts and preserves path whitespace")
    func bracketsIPv6AndPreservesPathWhitespace() {
        let ipv6 = ZedRemoteConnection(kind: "ssh", host: "2001:db8::1", port: 2222, user: "alice")
        let workspace = ZedWorkspace(
            id: "remote",
            paths: ["/srv/my project "],
            isDirectory: true,
            remote: ipv6,
            gitBranch: nil,
            lastOpened: nil
        )
        #expect(ipv6.sshAuthority == "alice@[2001:db8::1]:2222")
        #expect(workspace.sshURLs().map(\.absoluteString) == ["ssh://alice@[2001:db8::1]:2222/srv/my%20project%20"])

        let parsed = ZedWorkspace.orderedPaths(rawPaths: "/Users/alice/project \n/Users/alice/ leading", pathsOrder: "1,0")
        #expect(parsed == ["/Users/alice/ leading", "/Users/alice/project "])
    }

    @Test("Infers Zed channel from custom app path")
    func infersChannelFromAppPath() {
        #expect(ZedChannel.infer(fromAppPath: nil) == .stable)
        #expect(ZedChannel.infer(fromAppPath: "") == .stable)
        #expect(ZedChannel.infer(fromAppPath: "/Applications/Zed.app") == .stable)
        #expect(ZedChannel.infer(fromAppPath: "/Applications/Zed Preview.app") == .preview)
        #expect(ZedChannel.infer(fromAppPath: "/Applications/Zed Nightly.app") == .nightly)
        #expect(ZedChannel.infer(fromAppPath: "/Applications/Zed Dev.app") == .dev)
    }

    @Test("Localizes list UI in Simplified and Traditional Chinese")
    func localizesChineseStrings() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("zed-l10n-\(UUID().uuidString)/db.sqlite")
        let store = ZedWorkspaceStore(
            homeDirectory: "/Users/alice",
            databaseURLOverride: missing,
            fileExists: { _ in false },
            isDirectory: { _ in false }
        )

        let zhHans = try await PrismTestHost(
            Zed(store: store, launcher: FakeZedLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.zed",
            language: "zh-Hans"
        )
        let hansList = try await zhHans.list("recent-projects")
        #expect(hansList.searchPlaceholder == "搜索最近的 Zed 项目…")
        #expect(hansList.emptyMessage?.title == "没有最近的项目")
        #expect(hansList.filters.map(\.title) == ["全部项目", "本地", "远程"])

        let zhHant = try await PrismTestHost(
            Zed(store: store, launcher: FakeZedLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.zed",
            language: "zh-Hant"
        )
        let hantList = try await zhHant.list("recent-projects")
        #expect(hantList.searchPlaceholder == "搜尋最近的 Zed 專案…")
        #expect(hantList.emptyMessage?.title == "沒有最近的專案")
        #expect(hantList.filters.map(\.title) == ["全部專案", "本機", "遠端"])
    }
}
