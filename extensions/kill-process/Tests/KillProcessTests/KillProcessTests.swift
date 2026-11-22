import Darwin
import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import KillProcess

@Suite("Kill Process")
struct KillProcessTests {
    let command = KillProcess.CommandID.killProcess
    typealias ActionID = KillProcess.ActionID
    typealias FilterID = KillProcess.FilterID

    private func chromeMain(pid: pid_t = 100, cpu: Double = 12.0, memoryMB: UInt64 = 400) -> ProcessRecord {
        .fake(
            pid, "Google Chrome", parent: 1,
            path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            cpu: cpu, memoryMB: memoryMB
        )
    }

    private func chromeHelper(pid: pid_t, cpu: Double, memoryMB: UInt64, parent: pid_t = 100) -> ProcessRecord {
        .fake(
            pid, "Google Chrome Helper (Renderer)", parent: parent,
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            cpu: cpu, memoryMB: memoryMB
        )
    }

    private func typicalMac() -> FakeProcesses {
        let fake = FakeProcesses(bundleIdentifiers: [
            "/Applications/Google Chrome.app": "com.google.Chrome",
            "/Applications/Visual Studio Code.app": "com.microsoft.VSCode",
            "/Applications/Xcode.app": "com.apple.dt.Xcode",
        ])
        fake.add(chromeMain(pid: 100, cpu: 12.0, memoryMB: 400))
        fake.add(chromeHelper(pid: 101, cpu: 28.0, memoryMB: 800, parent: 100))
        fake.add(.fake(200, "node", parent: 50, path: "/opt/homebrew/bin/node", cpu: 65.0, memoryMB: 512))
        fake.add(.fake(300, "Electron", parent: 1, path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", cpu: 5.0, memoryMB: 1500))
        fake.add(.fake(301, "Code Helper", parent: 300, path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", cpu: 15.0, memoryMB: 600))
        fake.add(.fake(456, "WindowServer", user: 88, parent: 1, path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cpu: 8.0, memoryMB: 256))
        fake.add(.fake(1, "launchd", user: root, parent: 0, path: "/sbin/launchd", cpu: 0.1, memoryMB: 24))
        return fake
    }

    // MARK: - Sorting, Layout, and Grouping

    @Test("full-width list sorts by CPU or memory and shows both metrics on each row")
    func sortingAndRows() async throws {
        let prism = try await PrismTestHost(KillProcess(fake: typicalMac()))

        let cpuList = try await prism.list(command)
        #expect(cpuList.filtering == .prism)
        #expect(cpuList.showsDetail == false)
        #expect(cpuList.filters.map(\.id) == [FilterID.cpu, FilterID.memory])
        // node (65%) > Google Chrome (12+28=40%) > Visual Studio Code (5+15=20%) > WindowServer (8%) > launchd (0.1%)
        #expect(cpuList.items.map(\.title) == ["node", "Google Chrome", "Visual Studio Code", "WindowServer", "launchd"])

        #expect(cpuList.items[0].subtitle == nil)
        #expect(cpuList.items[0].accessories.map(\.symbol) == ["cpu", "memorychip"])
        #expect(cpuList.items[0].accessories.map(\.text) == ["65.0%", "512 MB"])
        #expect(cpuList.items[0].accessories.allSatisfy { $0.tint == nil })

        #expect(cpuList.items[1].subtitle == "2 processes")
        #expect(cpuList.items[1].accessories.map(\.symbol) == ["cpu", "memorychip"])

        #expect(cpuList.items[3].subtitle == nil)

        let memList = try await prism.list(command, filter: FilterID.memory)
        // Visual Studio Code (2100 MB) > Google Chrome (1200 MB) > node (512 MB) > WindowServer (256 MB) > launchd (24 MB)
        #expect(memList.items.map(\.title) == ["Visual Studio Code", "Google Chrome", "node", "WindowServer", "launchd"])
        #expect(memList.items[2].accessories.map(\.symbol) == ["cpu", "memorychip"])
    }

    @Test("empty state shows No Running Processes")
    func emptyStates() async throws {
        let emptyPrism = try await PrismTestHost(KillProcess(fake: FakeProcesses()))
        let list = try await emptyPrism.list(command)
        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "No Running Processes")
    }

    @Test("groups app helpers under the app, handles non-matching main names, and hides Restart on toolchain helpers")
    func appGroupingRules() async throws {
        let fake = typicalMac()
        // Only Xcode toolchain helpers running (main Xcode app is not running).
        fake.add(.fake(500, "SWBBuildService", parent: 1, path: "/Applications/Xcode.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/MacOS/SWBBuildService", cpu: 2.0, memoryMB: 900))
        fake.add(.fake(501, "swift-frontend", parent: 500, path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", cpu: 90.0, memoryMB: 500))

        let prism = try await PrismTestHost(KillProcess(fake: fake))
        let list = try await prism.list(command)

        let chrome = try #require(list.items.first { $0.title == "Google Chrome" })
        #expect(chrome.id == "app:100@1700000000.250000")
        #expect(chrome.icon?.app == "com.google.Chrome")
        #expect(chrome.keywords.contains("Google Chrome Helper (Renderer)"))
        #expect(chrome.keywords.contains("101"))
        #expect(chrome.action(id: ActionID.restart) != nil)

        // Visual Studio Code's executable is named Electron, yet it aggregates as Visual Studio Code.
        let vscode = try #require(list.items.first { $0.title == "Visual Studio Code" })
        #expect(vscode.id == "app:300@1700000000.250000")
        #expect(vscode.icon?.app == "com.microsoft.VSCode")
        #expect(vscode.action(id: ActionID.restart) != nil)

        // Xcode toolchain helpers have no main Xcode.app/Contents/MacOS/Xcode process -> no Restart.
        let xcode = try #require(list.items.first { $0.title == "Xcode" })
        #expect(xcode.id == "app:500@1700000000.250000")
        #expect(xcode.action(id: ActionID.restart) == nil)
    }

    @Test("grouped app keeps a stable app: ID as helpers start and stop")
    func groupedAppIDStability() async throws {
        let fake = typicalMac()
        fake.add(.fake(150, "Safari", parent: 1, path: "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 3.0, memoryMB: 200))
        let prism = try await PrismTestHost(KillProcess(fake: fake))

        let alone = try await prism.list(command)
        let safariAlone = try #require(alone.items.first { $0.title == "Safari" })
        #expect(safariAlone.id == "app:150@1700000000.250000")
        #expect(safariAlone.subtitle == nil)

        fake.add(.fake(151, "com.apple.WebKit.WebContent", parent: 150, path: "/Applications/Safari.app/Contents/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", cpu: 4.0, memoryMB: 150))
        let withHelper = try await prism.list(command)
        let safariWithHelper = try #require(withHelper.items.first { $0.title == "Safari" })
        #expect(safariWithHelper.id == "app:150@1700000000.250000")
        #expect(safariWithHelper.subtitle == "2 processes")

        fake.quit(151)
        let backAlone = try await prism.list(command)
        let safariBackAlone = try #require(backAlone.items.first { $0.title == "Safari" })
        #expect(safariBackAlone.id == "app:150@1700000000.250000")
        #expect(safariBackAlone.subtitle == nil)
    }

    @Test("groups same app bundle separately per user so another user does not block actions")
    func multiUserAppGrouping() async throws {
        let fake = typicalMac()
        fake.add(.fake(
            90, "Google Chrome", user: 502, parent: 1,
            path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            cpu: 10.0, memoryMB: 300
        ))
        fake.add(.fake(
            91, "Google Chrome Helper (Renderer)", user: 502, parent: 90,
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            cpu: 5.0, memoryMB: 100
        ))

        let prism = try await PrismTestHost(KillProcess(fake: fake))
        let list = try await prism.list(command)
        let chromes = list.items.filter { $0.title == "Google Chrome" }
        #expect(chromes.count == 2)

        let mine = try #require(chromes.first { $0.id == "app:100@1700000000.250000" })
        #expect(mine.subtitle == "2 processes")
        #expect(mine.action(id: ActionID.kill) != nil)
        #expect(mine.action(id: ActionID.forceKill) != nil)
        #expect(mine.action(id: ActionID.restart) != nil)

        let theirs = try #require(chromes.first { $0.id == "app:90@1700000000.250000" })
        #expect(theirs.subtitle == "2 processes")
        #expect(theirs.action(id: ActionID.kill) == nil)
        #expect(theirs.action(id: ActionID.restart) == nil)
        #expect(theirs.action(id: ActionID.copyKillCommand)?.kind == .copy(text: "sudo kill 90"))

        #expect(try await prism.perform(ActionID.kill, on: mine.id, in: command) == .reload(message: "Killed “Google Chrome”."))
        #expect(fake.signals == [.init(pid: 100, signal: SIGTERM), .init(pid: 101, signal: SIGTERM)])
    }

    @Test("toggling App Grouping persists across extension restarts")
    func toggleAppGroupingPersists() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(KillProcess(fake: fake))

        let grouped = try await prism.list(command)
        let chrome = try #require(grouped.items.first { $0.title == "Google Chrome" })
        #expect(chrome.action(id: ActionID.toggleAppGrouping)?.title == "Ungroup App Processes")

        let toggleResult = try await prism.perform(ActionID.toggleAppGrouping, on: chrome.id, in: command)
        #expect(toggleResult == .reload(message: "Showing individual processes."))
        #expect(await prism.state[KillProcess.StateKey.appGrouping] == .bool(false))

        try await prism.restart()
        let ungrouped = try await prism.list(command)
        #expect(ungrouped.items.contains { $0.title == "Google Chrome Helper (Renderer)" })
        let electron = try #require(ungrouped.items.first { $0.title == "Electron" })
        #expect(electron.subtitle == "Visual Studio Code")
        let helper = try #require(ungrouped.items.first { $0.title == "Google Chrome Helper (Renderer)" })
        #expect(helper.action(id: ActionID.toggleAppGrouping)?.title == "Group App Processes")
        #expect(helper.action(id: ActionID.restart) == nil)
        #expect(electron.action(id: ActionID.restart) != nil)
    }

    @Test("other users' processes cannot be killed directly and offer sudo kill commands except launchd")
    func otherUsers() async throws {
        let prism = try await PrismTestHost(KillProcess(fake: typicalMac()))
        let list = try await prism.list(command)

        let windowServer = try #require(list.items.first { $0.title == "WindowServer" })
        #expect(windowServer.subtitle == nil)
        #expect(windowServer.action(id: ActionID.kill) == nil)
        #expect(windowServer.action(id: ActionID.forceKill) == nil)
        #expect(windowServer.action(id: ActionID.copyKillCommand)?.kind == .copy(text: "sudo kill 456"))
        #expect(windowServer.action(id: ActionID.copyKillCommand)?.shortcut == ExtensionShortcut("cmd+shift+d"))
        #expect(windowServer.action(id: ActionID.copyForceKillCommand)?.kind == .copy(text: "sudo kill -9 456"))

        let launchd = try #require(list.items.first { $0.title == "launchd" })
        #expect(launchd.action(id: ActionID.kill) == nil)
        #expect(launchd.action(id: ActionID.copyKillCommand) == nil)
    }

    // MARK: - Kill, Force Kill, Kill All, Restart

    @Test("kills single process, kills aggregated app with helpers without touching external children, and supports Force Kill & closeAfterKill")
    func killAndForceKill() async throws {
        let fake = typicalMac()
        fake.add(.fake(302, "dev-server", parent: 300, path: "/opt/homebrew/bin/dev-server", cpu: 1.0, memoryMB: 40))
        let prism = try await PrismTestHost(KillProcess(fake: fake))
        let list = try await prism.list(command)

        // Kill aggregated Chrome -> signals both main (100) and helper (101).
        let chrome = try #require(list.items.first { $0.title == "Google Chrome" })
        #expect(try await prism.perform(ActionID.kill, on: chrome.id, in: command) == .reload(message: "Killed “Google Chrome”."))
        #expect(fake.signals == [.init(pid: 100, signal: SIGTERM), .init(pid: 101, signal: SIGTERM)])

        // Kill aggregated VS Code -> signals bundle members (300, 301), leaving external child PID 302 untouched.
        let vscode = try #require(list.items.first { $0.title == "Visual Studio Code" })
        #expect(try await prism.perform(ActionID.kill, on: vscode.id, in: command) == .reload(message: "Killed “Visual Studio Code”."))
        #expect(fake.signals.suffix(2) == [.init(pid: 300, signal: SIGTERM), .init(pid: 301, signal: SIGTERM)])
        #expect(!fake.signals.contains(.init(pid: 302, signal: SIGTERM)))

        // node ignores SIGTERM -> warns, then Force Kill succeeds.
        fake.ignoreTerminate(200)
        let node = try #require(list.items.first { $0.title == "node" })
        #expect(try await prism.perform(ActionID.kill, on: node.id, in: command)
            == .reload(message: "“node” is still running. Force Kill (⇧⌘⌫) stops it at once."))
        try await prism.setPreferences([KillProcess.PreferenceID.closeAfterKill: .bool(true)])
        #expect(try await prism.perform(ActionID.forceKill, on: node.id, in: command)
            == ExtensionActionResult(.hud(message: "Killed “node”."), reload: true))
        #expect(fake.signals.suffix(2) == [.init(pid: 200, signal: SIGTERM), .init(pid: 200, signal: SIGKILL)])
    }

    @Test("verifies PID and start time before signalling and handles EPERM")
    func safetyAndErrors() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(KillProcess(fake: fake))
        let list = try await prism.list(command)
        let node = try #require(list.items.first { $0.title == "node" })

        // PID 200 exited and was reused by a newer process.
        fake.quit(200)
        fake.add(.fake(200, "swift", startedAt: startSeconds + 60))
        #expect(try await prism.perform(ActionID.kill, on: node.id, in: command) == .reload(message: "That process already quit."))
        #expect(fake.signals.isEmpty)

        // Refused signal on Google Chrome.
        fake.refuseSignals(100)
        let chrome = try #require(list.items.first { $0.title == "Google Chrome" })
        #expect(try await prism.perform(ActionID.kill, on: chrome.id, in: command)
            == ExtensionActionResult(.failed(message: "You don’t have permission to kill “Google Chrome”."), reload: true))
        #expect(fake.signals.isEmpty)
    }

    @Test("reports partial signal failures for app groups, Restart, and Kill All")
    func partialSignalFailures() async throws {
        // Kill: main (100) quits, helper (101) refuses -> reports failure instead of success.
        let killFake = typicalMac()
        killFake.refuseSignals(101)
        let killHost = try await PrismTestHost(KillProcess(fake: killFake))
        let chromeKill = try #require(try await killHost.list(command).items.first { $0.title == "Google Chrome" })
        #expect(try await killHost.perform(ActionID.kill, on: chromeKill.id, in: command)
            == ExtensionActionResult(.failed(message: "You don’t have permission to kill “Google Chrome”."), reload: true))

        // Restart: main (100) quits, helper (101) refuses -> reports failure and does not reopen app.
        let restartFake = typicalMac()
        restartFake.refuseSignals(101)
        let restartHost = try await PrismTestHost(KillProcess(fake: restartFake))
        let chromeRestart = try #require(try await restartHost.list(command).items.first { $0.title == "Google Chrome" })
        #expect(try await restartHost.perform(ActionID.restart, on: chromeRestart.id, in: command)
            == ExtensionActionResult(.failed(message: "You don’t have permission to kill “Google Chrome”."), reload: true))
        #expect(restartFake.opened.isEmpty)

        // Kill All: one node (200) quits, another (201) refuses -> reports failure.
        let killAllFake = typicalMac()
        killAllFake.add(.fake(201, "node", parent: 50, path: "/opt/homebrew/bin/node", cpu: 2.0, memoryMB: 100))
        killAllFake.refuseSignals(201)
        let killAllHost = try await PrismTestHost(KillProcess(fake: killAllFake))
        let node = try #require(try await killAllHost.list(command).items.first { $0.title == "node" })
        #expect(try await killAllHost.perform(ActionID.killAll, on: node.id, in: command)
            == ExtensionActionResult(.failed(message: "You don’t have permission to kill “node”."), reload: true))
    }

    @Test("Kill All appears only when multiple same-name processes exist outside a single app group")
    func killAllProcesses() async throws {
        let fake = typicalMac()
        fake.add(.fake(201, "node", parent: 50, path: "/opt/homebrew/bin/node", cpu: 2.0, memoryMB: 100))
        fake.add(chromeHelper(pid: 102, cpu: 1.0, memoryMB: 50, parent: 100))
        let prism = try await PrismTestHost(KillProcess(fake: fake))
        let list = try await prism.list(command)

        // Single standalone node has 2 same-name processes -> Kill All offered.
        let node = try #require(list.items.first { $0.id == "pid:200@1700000000.250000" })
        #expect(node.action(id: ActionID.killAll)?.title == "Kill All “node” (2)")
        #expect(node.action(id: ActionID.forceKillAll)?.title == "Force Kill All “node” (2)")

        // Aggregated Chrome has only 1 Google Chrome main inside its own group -> no Kill All.
        let chrome = try #require(list.items.first { $0.title == "Google Chrome" })
        #expect(chrome.action(id: ActionID.killAll) == nil)

        #expect(try await prism.perform(ActionID.killAll, on: node.id, in: command)
            == .reload(message: "Killed 2 “node” processes."))
        #expect(fake.signals == [.init(pid: 200, signal: SIGTERM), .init(pid: 201, signal: SIGTERM)])
    }

    @Test("Restart kills app group, waits for exit, and reopens bundle; checks bundle existence first")
    func restartApp() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(KillProcess(fake: fake))
        let list = try await prism.list(command)

        let node = try #require(list.items.first { $0.title == "node" })
        #expect(node.action(id: ActionID.restart) == nil)

        let chrome = try #require(list.items.first { $0.title == "Google Chrome" })
        #expect(try await prism.perform(ActionID.restart, on: chrome.id, in: command)
            == .reload(message: "Restarted “Google Chrome”."))
        #expect(fake.signals == [.init(pid: 100, signal: SIGTERM), .init(pid: 101, signal: SIGTERM)])
        #expect(fake.opened == ["/Applications/Google Chrome.app"])

        // Missing bundle fails without signalling VS Code.
        fake.markMissingFile("/Applications/Visual Studio Code.app")
        let refreshed = try await prism.list(command)
        let vscode = try #require(refreshed.items.first { $0.title == "Visual Studio Code" })
        #expect(vscode.action(id: ActionID.restart) == nil)
        #expect(try await prism.perform(ActionID.restart, on: vscode.id, in: command)
            == ExtensionActionResult(.failed(message: "The app’s bundle no longer exists."), reload: true))
        #expect(fake.signals.count == 2)
    }

    @Test("Restart reports timeout if process ignores SIGTERM and Force Restart recovers")
    func restartTimeoutAndForce() async throws {
        let fake = typicalMac()
        fake.ignoreTerminate(300)
        let prism = try await PrismTestHost(KillProcess(fake: fake))
        let vscode = try #require(try await prism.list(command).items.first { $0.title == "Visual Studio Code" })

        #expect(try await prism.perform(ActionID.restart, on: vscode.id, in: command)
            == .reload(message: "“Visual Studio Code” didn’t quit in time. Try Force Restart (⌥⇧⌘R)."))
        #expect(fake.opened.isEmpty)

        #expect(try await prism.perform(ActionID.forceRestart, on: vscode.id, in: command)
            == .reload(message: "Restarted “Visual Studio Code”."))
        #expect(fake.opened == ["/Applications/Visual Studio Code.app"])
    }

    @Test("Copy Path, Copy PID, Show in Finder, and copy submenu fallback work as expected")
    func copyAndReveal() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(KillProcess(fake: fake))
        let list = try await prism.list(command)

        let node = try #require(list.items.first { $0.title == "node" })
        #expect(node.action(id: ActionID.copyPath)?.kind == .copy(text: "/opt/homebrew/bin/node"))
        #expect(node.action(id: ActionID.copyPath)?.shortcut == ExtensionShortcut("cmd+shift+c"))
        #expect(node.action(id: ActionID.copyPID)?.kind == .copy(text: "200"))

        #expect(try await prism.perform(ActionID.showInFinder, on: node.id, in: command) == .done)

        let chrome = try #require(list.items.first { $0.title == "Google Chrome" })
        #expect(try await prism.perform(ActionID.showInFinder, on: chrome.id, in: command) == .done)
        #expect(fake.revealed == ["/opt/homebrew/bin/node", "/Applications/Google Chrome.app"])

        #expect(try await prism.perform(ActionID.copyMenu, on: node.id, in: command)
            == ExtensionActionResult(.failed(message: "Update Prism to open this menu.")))
    }

    // MARK: - Localization

    @Test("Simplified Chinese translates filters, actions, and messages")
    func simplifiedChinese() async throws {
        let prism = try await PrismTestHost(KillProcess(fake: typicalMac()), language: "zh-Hans")
        let list = try await prism.list(command)
        #expect(list.searchPlaceholder == "按名称筛选…")
        #expect(list.filters.map(\.title) == ["CPU 占用", "内存占用"])

        let chrome = try #require(list.items.first { $0.title == "Google Chrome" })
        #expect(chrome.subtitle == "2 个进程")
        #expect(chrome.primaryAction?.title == "结束")
        #expect(chrome.primaryAction?.confirmationMessage == "“Google Chrome”（2 个进程）将退出。")
        #expect(try await prism.perform(ActionID.kill, on: chrome.id, in: command) == .reload(message: "已结束“Google Chrome”。"))
    }

    @Test("Traditional Chinese uses Taiwan terms and corner quotes")
    func traditionalChinese() async throws {
        let prism = try await PrismTestHost(KillProcess(fake: typicalMac()), language: "zh-Hant")
        let list = try await prism.list(command)
        #expect(list.searchPlaceholder == "依名稱篩選…")
        #expect(list.filters.map(\.title) == ["CPU 用量", "記憶體用量"])

        let chrome = try #require(list.items.first { $0.title == "Google Chrome" })
        #expect(chrome.subtitle == "2 個程序")
        #expect(chrome.primaryAction?.title == "結束")
        #expect(chrome.primaryAction?.confirmationMessage == "「Google Chrome」（2 個程序）將會結束。")
        #expect(try await prism.perform(ActionID.kill, on: chrome.id, in: command) == .reload(message: "已結束「Google Chrome」。"))

        let empty = try await PrismTestHost(KillProcess(fake: FakeProcesses()), language: "zh-Hant")
        #expect(try await empty.list(command).emptyMessage?.title == "沒有執行中的程序")
    }
}
