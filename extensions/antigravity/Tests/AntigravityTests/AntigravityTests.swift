import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import SQLite3
import Testing
@testable import Antigravity

// MARK: - Test Support

private actor FakeAntigravityLauncher: AntigravityLaunching {
    struct RemoteOpen: Equatable, Sendable {
        let host: String
        let antigravityAppPath: String?
    }

    private(set) var openedLocalApps: [String?] = []
    private(set) var openedRemote: [RemoteOpen] = []
    private(set) var revealed: [String] = []
    var nextError: Error?

    func setNextError(_ error: Error?) {
        nextError = error
    }

    func openLocalApp(antigravityAppPath: String?) async throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
        openedLocalApps.append(antigravityAppPath)
    }

    func openRemoteSSHHost(_ host: String, antigravityAppPath: String?) async throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
        openedRemote.append(RemoteOpen(host: host, antigravityAppPath: antigravityAppPath))
    }

    func revealInFinder(path: String) async throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
        revealed.append(path)
    }
}

private struct TempFixture {
    let root: URL
    let projectsDir: URL
    let conversationsDB: URL
    let appStorage: URL
    let sshWindows: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-tests-\(UUID().uuidString)", isDirectory: true)
        projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        conversationsDB = root.appendingPathComponent("conversation_summaries.db")
        appStorage = root.appendingPathComponent("app_storage.json")
        sshWindows = root.appendingPathComponent("ssh_windows.json")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    }

    func writeProject(filename: String, json: String, modifiedAt: Date? = nil) throws {
        let url = projectsDir.appendingPathComponent(filename)
        try json.write(to: url, atomically: true, encoding: .utf8)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    func writeConversationsDB(sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(conversationsDB.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "AntigravityTests", code: 1)
        }
        defer { sqlite3_close(handle) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(errorMessage)
            throw NSError(domain: "AntigravityTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func writeAppStorage(_ json: String) throws {
        try json.write(to: appStorage, atomically: true, encoding: .utf8)
    }

    func writeSSHWindows(_ json: String) throws {
        try json.write(to: sshWindows, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
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

@Suite("Antigravity")
struct AntigravityTests {
    @Test("Empty state when Antigravity data does not exist")
    func missingDataShowsEmptyState() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-missing-\(UUID().uuidString)")
        let store = AntigravityWorkspaceStore(
            homeDirectory: "/Users/alice",
            projectsDirectoryOverride: missing.appendingPathComponent("projects"),
            conversationsDBURLOverride: missing.appendingPathComponent("conversation_summaries.db"),
            appStorageURLOverride: missing.appendingPathComponent("app_storage.json"),
            sshWindowsURLOverride: missing.appendingPathComponent("ssh_windows.json"),
            fileExists: { _ in false }
        )
        let host = try await PrismTestHost(
            Antigravity(store: store, launcher: FakeAntigravityLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.antigravity"
        )

        let list = try await host.list("recent-projects")
        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "No Recent Projects")
        #expect(list.filters.map(\.id) == ["all", "local", "remote"])

        let localEmpty = try await host.list("recent-projects", filter: "local")
        #expect(localEmpty.emptyMessage?.title == "No Local Projects")

        let remoteEmpty = try await host.list("recent-projects", filter: "remote")
        #expect(remoteEmpty.emptyMessage?.title == "No Remote SSH Hosts")
    }

    @Test("Loads projects, conversation timestamps, Git branch, Pinyin keywords, and SSH hosts while skipping sidecars and deleted paths")
    func loadsProjectsAndRemoteHosts() async throws {
        let fixture = try TempFixture()
        defer { fixture.cleanup() }

        // Multi-folder git project
        try fixture.writeProject(
            filename: "proj-prism.json",
            json: """
                {
                  "id": "proj-prism",
                  "name": "prism",
                  "projectResources": {
                    "resources": [
                      { "gitFolder": { "folderUri": "file:///Users/alice/projects/prism", "defaultBranch": "main" } },
                      { "gitFolder": { "folderUri": "file:///Users/alice/projects/prism-extensions" } }
                    ]
                  }
                }
                """,
            modifiedAt: fixedDate(2026, 11, 20, 8, 0)
        )

        // Single-folder project with Chinese name matching folder name
        try fixture.writeProject(
            filename: "proj-nanyin.json",
            json: """
                {
                  "id": "proj-nanyin",
                  "name": "南音",
                  "projectResources": {
                    "resources": [
                      { "folderUri": "file:///Users/alice/projects/%E5%8D%97%E9%9F%B3" }
                    ]
                  }
                }
                """,
            modifiedAt: fixedDate(2026, 11, 21, 9, 0)
        )

        // Single-folder project whose name differs from its folder name and contains spaces
        try fixture.writeProject(
            filename: "proj-notes.json",
            json: """
                {
                  "id": "proj-notes",
                  "name": "Client Briefs",
                  "projectResources": {
                    "resources": [
                      { "folderUri": "file:///Users/alice/Downloads/briefs-2026" }
                    ]
                  }
                }
                """,
            modifiedAt: fixedDate(2026, 11, 19, 9, 0)
        )

        // Internal sidecar project (must be skipped)
        try fixture.writeProject(
            filename: "proj-sidecar.json",
            json: """
                {
                  "id": "proj-sidecar",
                  "name": "swarm/swarm_board",
                  "projectResources": {
                    "resources": [
                      { "folderUri": "file:///Users/alice/projects/prism" }
                    ]
                  },
                  "sidecar": { "sidecarId": "swarm/swarm_board" }
                }
                """
        )

        // Default CLI project (must be skipped)
        try fixture.writeProject(
            filename: "default-cli-project.json",
            json: """
                {
                  "id": "default-cli-project",
                  "name": "CLI Project",
                  "projectResources": {}
                }
                """
        )

        // Deleted project (must be skipped)
        try fixture.writeProject(
            filename: "proj-deleted.json",
            json: """
                {
                  "id": "proj-deleted",
                  "name": "deleted",
                  "projectResources": {
                    "resources": [
                      { "folderUri": "file:///Users/alice/projects/deleted" }
                    ]
                  }
                }
                """
        )

        // Conversation timestamps: Client Briefs newest (5-digit fraction), prism second (6-digit fraction)
        try fixture.writeConversationsDB(sql: """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL DEFAULT '',
                last_modified_time DATETIME NOT NULL
            );
            INSERT INTO conversation_summaries (conversation_id, project_id, last_modified_time) VALUES
                ('c1', 'proj-notes', '2026-11-24 11:29:40.88352+00:00'),
                ('c2', 'proj-prism', '2026-11-23 13:50:15.606339+00:00'),
                ('c3', 'proj-prism', '2026-11-21 09:00:00+00:00');
            """)

        // Recent SSH hosts in app_storage.json + ssh_windows.json (with a duplicate host)
        try fixture.writeAppStorage("""
            {
              "ssh.recentConnections": "[{\\"host\\":\\"dev.example.com\\",\\"configFile\\":\\"/Users/alice/.ssh/config\\"},{\\"host\\":\\"gpu-box\\"}]"
            }
            """)
        try fixture.writeSSHWindows("""
            {
              "version": 1,
              "windows": [
                { "host": "gpu-box" },
                { "host": "staging.internal" }
              ]
            }
            """)

        let existingPaths: Set<String> = [
            "/Users/alice/projects/prism",
            "/Users/alice/projects/prism-extensions",
            "/Users/alice/projects/南音",
            "/Users/alice/Downloads/briefs-2026",
            fixture.conversationsDB.path,
            fixture.appStorage.path,
            fixture.sshWindows.path,
        ]
        let store = AntigravityWorkspaceStore(
            homeDirectory: "/Users/alice",
            projectsDirectoryOverride: fixture.projectsDir,
            conversationsDBURLOverride: fixture.conversationsDB,
            appStorageURLOverride: fixture.appStorage,
            sshWindowsURLOverride: fixture.sshWindows,
            fileExists: { existingPaths.contains($0) },
            branchLookup: { $0 == "/Users/alice/projects/prism" ? "feat/antigravity" : nil }
        )
        let host = try await PrismTestHost(
            Antigravity(store: store, launcher: FakeAntigravityLauncher(), now: { fixedDate(2026, 11, 24, 12, 0) }),
            extensionID: "prism.antigravity"
        )

        let list = try await host.list("recent-projects")
        #expect(list.items.map(\.title) == [
            "Client Briefs",
            "prism",
            "南音",
            "dev.example.com",
            "gpu-box",
            "staging.internal",
        ])

        // Single folder whose name differs from folder name shows full abbreviated path
        let briefs = list.items[0]
        #expect(briefs.subtitle == "~/Downloads/briefs-2026")
        #expect(briefs.icon == ExtensionIcon(symbol: "folder.fill", tint: "gray", style: .glyph))
        #expect(briefs.actions.map(\.id) == ["open", "copy-agy-command", "show-in-finder", "copy-path"])
        let agyAction = try #require(briefs.actions.first { $0.id == "copy-agy-command" })
        #expect(agyAction.kind == .copy(text: "agy --project='Client Briefs'"))

        // Multi-folder project shows folder count badge + Git branch pill
        let prism = list.items[1]
        #expect(prism.subtitle == "~/projects/prism · ~/projects/prism-extensions")
        #expect(prism.icon == ExtensionIcon(symbol: "folder.fill.badge.plus", tint: "indigo", style: .glyph))
        #expect(prism.accessories.count == 2)
        #expect(prism.accessories[0].text == "2 Folders")
        #expect(prism.accessories[1].text == "feat/antigravity")
        #expect(prism.accessories[1].symbol == "arrow.triangle.branch")
        #expect(prism.keywords.contains("feat/antigravity"))
        let prismAGY = try #require(prism.actions.first { $0.id == "copy-agy-command" })
        #expect(prismAGY.kind == .copy(text: "agy --project=prism"))

        // Chinese project name matching folder name shows parent dir + Pinyin keywords
        let nanyin = list.items[2]
        #expect(nanyin.subtitle == "~/projects")
        #expect(nanyin.keywords.contains("nanyin"))
        #expect(nanyin.keywords.contains("ny"))

        // Remote SSH hosts
        let devSSH = list.items[3]
        #expect(devSSH.subtitle == "~/.ssh/config")
        #expect(devSSH.icon == ExtensionIcon(symbol: "network", tint: "violet", style: .glyph))
        #expect(devSSH.accessories.first?.text == "SSH")
        #expect(devSSH.actions.map(\.id) == ["open", "copy-path"])

        let gpuSSH = list.items[4]
        #expect(gpuSSH.subtitle == "Remote SSH Host")

        // Filter: local only
        let localList = try await host.list("recent-projects", filter: "local")
        #expect(localList.items.map(\.title) == ["Client Briefs", "prism", "南音"])

        // Filter: remote only
        let remoteList = try await host.list("recent-projects", filter: "remote")
        #expect(remoteList.items.map(\.title) == ["dev.example.com", "gpu-box", "staging.internal"])
    }

    @Test("Falls back to project UUID for agy CLI when two projects share the same name")
    func usesProjectIDForDuplicateNames() async throws {
        let fixture = try TempFixture()
        defer { fixture.cleanup() }

        try fixture.writeProject(
            filename: "uuid-1.json",
            json: """
                {
                  "id": "uuid-1",
                  "name": "web",
                  "projectResources": { "resources": [{ "folderUri": "file:///Users/alice/a/web" }] }
                }
                """
        )
        try fixture.writeProject(
            filename: "uuid-2.json",
            json: """
                {
                  "id": "uuid-2",
                  "name": "web",
                  "projectResources": { "resources": [{ "folderUri": "file:///Users/alice/b/web" }] }
                }
                """
        )

        let existing: Set<String> = ["/Users/alice/a/web", "/Users/alice/b/web"]
        let store = AntigravityWorkspaceStore(
            homeDirectory: "/Users/alice",
            projectsDirectoryOverride: fixture.projectsDir,
            conversationsDBURLOverride: fixture.conversationsDB,
            appStorageURLOverride: fixture.appStorage,
            sshWindowsURLOverride: fixture.sshWindows,
            fileExists: { existing.contains($0) }
        )
        let host = try await PrismTestHost(
            Antigravity(store: store, launcher: FakeAntigravityLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.antigravity"
        )

        let list = try await host.list("recent-projects")
        let commands = list.items.compactMap { item in
            item.actions.first(where: { $0.id == "copy-agy-command" })?.kind
        }
        #expect(Set(commands) == [
            .copy(text: "agy --project=uuid-1"),
            .copy(text: "agy --project=uuid-2"),
        ])
    }

    @Test("Reads legacy ssh.recentHosts and ssh.recentConfigFiles keys from app_storage.json")
    func readsLegacySSHStorageKeys() async throws {
        let fixture = try TempFixture()
        defer { fixture.cleanup() }

        try fixture.writeAppStorage("""
            {
              "ssh.recentHosts": "[\\"legacy.box\\",\\"other.box\\"]",
              "ssh.recentConfigFiles": "{\\"legacy.box\\":\\"/Users/alice/.ssh/work_config\\"}"
            }
            """)

        let store = AntigravityWorkspaceStore(
            homeDirectory: "/Users/alice",
            projectsDirectoryOverride: fixture.projectsDir,
            conversationsDBURLOverride: fixture.conversationsDB,
            appStorageURLOverride: fixture.appStorage,
            sshWindowsURLOverride: fixture.sshWindows,
            fileExists: { $0 == fixture.appStorage.path }
        )
        let host = try await PrismTestHost(
            Antigravity(store: store, launcher: FakeAntigravityLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.antigravity"
        )

        let list = try await host.list("recent-projects")
        #expect(list.items.map(\.title) == ["legacy.box", "other.box"])
        #expect(list.items[0].subtitle == "~/.ssh/work_config")
        #expect(list.items[1].subtitle == "Remote SSH Host")
    }

    @Test("Opening local projects and SSH hosts launches Antigravity and bubbles opened items across restart")
    func opensWorkspacesAndPersistsRecentOrder() async throws {
        let fixture = try TempFixture()
        defer { fixture.cleanup() }

        try fixture.writeProject(
            filename: "newer.json",
            json: """
                {
                  "id": "newer",
                  "name": "newer",
                  "projectResources": { "resources": [{ "folderUri": "file:///Users/alice/projects/newer" }] }
                }
                """,
            modifiedAt: fixedDate(2026, 11, 24, 10, 0)
        )
        try fixture.writeProject(
            filename: "older.json",
            json: """
                {
                  "id": "older",
                  "name": "older",
                  "projectResources": { "resources": [{ "folderUri": "file:///Users/alice/projects/older" }] }
                }
                """,
            modifiedAt: fixedDate(2026, 11, 20, 10, 0)
        )
        try fixture.writeAppStorage("""
            {
              "ssh.recentConnections": "[{\\"host\\":\\"prod.example.com\\"}]"
            }
            """)

        let existing: Set<String> = [
            "/Users/alice/projects/newer",
            "/Users/alice/projects/older",
            fixture.appStorage.path,
        ]
        let store = AntigravityWorkspaceStore(
            homeDirectory: "/Users/alice",
            projectsDirectoryOverride: fixture.projectsDir,
            conversationsDBURLOverride: fixture.conversationsDB,
            appStorageURLOverride: fixture.appStorage,
            sshWindowsURLOverride: fixture.sshWindows,
            fileExists: { existing.contains($0) }
        )
        let launcher = FakeAntigravityLauncher()
        let host = try await PrismTestHost(
            Antigravity(store: store, launcher: launcher, now: { fixedDate(2026, 11, 24, 15, 0) }),
            extensionID: "prism.antigravity",
            preferences: ["antigravityApp": .string("/Applications/Antigravity Insiders.app")]
        )

        let before = try await host.list("recent-projects")
        #expect(before.items.map(\.title) == ["newer", "older", "prod.example.com"])

        // Open older local project
        let openLocal = try await host.perform("open", on: before.items[1].id, in: "recent-projects")
        #expect(openLocal == .done)
        #expect(await launcher.openedLocalApps == ["/Applications/Antigravity Insiders.app"])

        // Open remote SSH host
        let openRemote = try await host.perform("open", on: before.items[2].id, in: "recent-projects")
        #expect(openRemote == .done)
        #expect(await launcher.openedRemote == [
            FakeAntigravityLauncher.RemoteOpen(
                host: "prod.example.com",
                antigravityAppPath: "/Applications/Antigravity Insiders.app"
            ),
        ])

        // Reveal in Finder
        let reveal = try await host.perform("show-in-finder", on: before.items[0].id, in: "recent-projects")
        #expect(reveal == .done)
        #expect(await launcher.revealed == ["/Users/alice/projects/newer"])

        // Restart host to prove recentOpens state survives process exit
        try await host.restart()
        let after = try await host.list("recent-projects")
        #expect(after.items.last?.title == "newer")
        #expect(Set(after.items.prefix(2).map(\.title)) == ["older", "prod.example.com"])
    }

    @Test("Handles missing Antigravity app and removed workspace errors gracefully")
    func handlesLaunchErrors() async throws {
        let fixture = try TempFixture()
        defer { fixture.cleanup() }

        try fixture.writeProject(
            filename: "app.json",
            json: """
                {
                  "id": "app",
                  "name": "app",
                  "projectResources": { "resources": [{ "folderUri": "file:///Users/alice/projects/app" }] }
                }
                """
        )

        let store = AntigravityWorkspaceStore(
            homeDirectory: "/Users/alice",
            projectsDirectoryOverride: fixture.projectsDir,
            conversationsDBURLOverride: fixture.conversationsDB,
            appStorageURLOverride: fixture.appStorage,
            sshWindowsURLOverride: fixture.sshWindows,
            fileExists: { $0 == "/Users/alice/projects/app" }
        )
        let launcher = FakeAntigravityLauncher()
        let host = try await PrismTestHost(
            Antigravity(store: store, launcher: launcher, now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.antigravity"
        )

        await launcher.setNextError(AntigravityLaunchError.appNotFound(nil))
        let notInstalled = try await host.perform("open", on: "project:app", in: "recent-projects")
        #expect(notInstalled == ExtensionActionResult(.failed(message: "Antigravity isn’t installed on this Mac.")))

        await launcher.setNextError(AntigravityLaunchError.appNotFound("/Applications/CustomAGY.app"))
        let customMissing = try await host.perform("open", on: "project:app", in: "recent-projects")
        #expect(customMissing == ExtensionActionResult(.failed(message: "Antigravity couldn’t be found at “/Applications/CustomAGY.app”.")))

        let removedProject = try await host.perform("open", on: "project:gone", in: "recent-projects")
        #expect(removedProject == .reload(message: "This project is no longer in Antigravity."))

        let removedRemote = try await host.perform("open", on: "remote:ssh:gone.host", in: "recent-projects")
        #expect(removedRemote == .reload(message: "This remote host is no longer in Antigravity’s recent list."))
    }

    @Test("Reads Git branch from standard repo, nested directory, worktree, and detached HEAD")
    func readsGitBranches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-git-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("prism", isDirectory: true)
        let nested = repo.appendingPathComponent("Sources/App", isDirectory: true)
        let dotGit = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        try "ref: refs/heads/feat/antigravity\n".write(
            to: dotGit.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )

        #expect(GitBranchReader.branch(forDirectory: repo.path, stopAt: root.path) == "feat/antigravity")
        #expect(GitBranchReader.branch(forDirectory: nested.path, stopAt: root.path) == "feat/antigravity")

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

        #expect(GitBranchReader.parseHead("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n") == "a1b2c3d")
        #expect(GitBranchReader.parseHead("ref: refs/tags/v1.0.0\n") == "v1.0.0")
        #expect(GitBranchReader.parseHead("   ") == nil)
    }

    @Test("Parses Antigravity timestamps, file URIs, shell quotes, and channels")
    func parsesFormatsAndChannels() {
        #expect(AntigravityWorkspaceStore.parseTimestamp("2026-11-24 11:29:40.88352+00:00") != nil)
        #expect(AntigravityWorkspaceStore.parseTimestamp("2026-11-21 13:50:15.606339+00:00") != nil)
        #expect(AntigravityWorkspaceStore.parseTimestamp("2026-11-24 10:30:00.12345") != nil)
        #expect(AntigravityWorkspaceStore.parseTimestamp("2026-11-24 10:30:00") != nil)
        #expect(AntigravityWorkspaceStore.parseTimestamp("2026-11-24T10:30:00Z") != nil)
        #expect(AntigravityWorkspaceStore.parseTimestamp("2026-11-24 18:30:00+08:00") == AntigravityWorkspaceStore.parseTimestamp("2026-11-24T10:30:00Z"))
        #expect(AntigravityWorkspaceStore.parseTimestamp("") == nil)

        #expect(AntigravityWorkspace.localPath(fromURI: "file:///Users/alice/my%20app") == "/Users/alice/my app")
        #expect(AntigravityWorkspace.localPath(fromURI: "file:///Users/alice/my app") == "/Users/alice/my app")
        #expect(AntigravityWorkspace.localPath(fromURI: "file:///Users/alice/%E5%8D%97%E9%9F%B3") == "/Users/alice/南音")
        #expect(AntigravityWorkspace.localPath(fromURI: "file://localhost/Users/alice/app") == "/Users/alice/app")
        #expect(AntigravityWorkspace.localPath(fromURI: "file://remote-host/share") == nil)
        #expect(AntigravityWorkspace.localPath(fromURI: "https://example.com/repo") == nil)

        #expect(AntigravityWorkspace.shellQuote("prism") == "prism")
        #expect(AntigravityWorkspace.shellQuote("Client Briefs") == "'Client Briefs'")
        #expect(AntigravityWorkspace.shellQuote("alice's app") == "'alice'\\''s app'")

        #expect(AntigravityChannel.infer(fromAppPath: nil) == .stable)
        #expect(AntigravityChannel.infer(fromAppPath: "") == .stable)
        #expect(AntigravityChannel.infer(fromAppPath: "/Applications/Antigravity.app") == .stable)
        #expect(AntigravityChannel.infer(fromAppPath: "/Applications/Antigravity Insiders.app") == .insiders)
        #expect(AntigravityChannel.infer(fromAppPath: "/Applications/Antigravity Dev.app") == .dev)
    }

    @Test("Localizes list UI in Simplified and Traditional Chinese")
    func localizesChineseStrings() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-l10n-\(UUID().uuidString)")
        let store = AntigravityWorkspaceStore(
            homeDirectory: "/Users/alice",
            projectsDirectoryOverride: missing.appendingPathComponent("projects"),
            conversationsDBURLOverride: missing.appendingPathComponent("conversation_summaries.db"),
            appStorageURLOverride: missing.appendingPathComponent("app_storage.json"),
            sshWindowsURLOverride: missing.appendingPathComponent("ssh_windows.json"),
            fileExists: { _ in false }
        )

        let zhHans = try await PrismTestHost(
            Antigravity(store: store, launcher: FakeAntigravityLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.antigravity",
            language: "zh-Hans"
        )
        let hansList = try await zhHans.list("recent-projects")
        #expect(hansList.searchPlaceholder == "搜索 Antigravity 项目…")
        #expect(hansList.emptyMessage?.title == "没有最近的项目")
        #expect(hansList.filters.map(\.title) == ["全部项目", "本地", "远程"])

        let zhHant = try await PrismTestHost(
            Antigravity(store: store, launcher: FakeAntigravityLauncher(), now: { fixedDate(2026, 11, 24) }),
            extensionID: "prism.antigravity",
            language: "zh-Hant"
        )
        let hantList = try await zhHant.list("recent-projects")
        #expect(hantList.searchPlaceholder == "搜尋 Antigravity 專案…")
        #expect(hantList.emptyMessage?.title == "沒有最近的專案")
        #expect(hantList.filters.map(\.title) == ["全部專案", "本機", "遠端"])
    }
}
