import Darwin
import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import PortManager

@Suite("Open Ports")
struct PortManagerTests {
    let command = PortManager.CommandID.openPorts
    typealias ActionID = PortManager.ActionID

    let node = RunningProcess.fake(4242, "node", parent: 4200, path: "/opt/homebrew/bin/node", arguments: ["node", "server.js", "--port", "3000"])
    let npm = RunningProcess.fake(4200, "npm")
    let postgres = RunningProcess.fake(610, "postgres", path: "/opt/homebrew/opt/postgresql@17/bin/postgres")
    let sshd = RunningProcess.fake(1, "launchd", user: root, parent: 0, path: "/sbin/launchd")

    let nodeRow = "4242@1700000000.250000"

    /// node on localhost over IPv4 and IPv6 on two ports, Postgres on every
    /// interface, and root's Remote Login.
    func typicalMac() -> FakePorts {
        let fake = FakePorts()
        fake.run(npm)
        fake.listen(node, at: ("127.0.0.1", 3000), ("::1", 3000), ("0.0.0.0", 9229))
        fake.listen(postgres, at: ("0.0.0.0", 5432), ("::", 5432))
        fake.listen(sshd, at: ("0.0.0.0", 22), ("::", 22), listedName: "launchd")
        return fake
    }

    @Test("lists one row per process, by its lowest port, with each port colored by its reach")
    func rows() async throws {
        let prism = try await PrismTestHost(PortManager(fake: typicalMac()))
        let list = try await prism.list(command)
        #expect(list.items.map(\.id) == ["1@1700000000.250000", nodeRow, "610@1700000000.250000"])
        #expect(list.items.map(\.title) == ["launchd", "node", "postgres"])
        #expect(list.items.map(\.subtitle) == ["root", nil, nil])
        #expect(list.filtering == .prism)
        #expect(list.error == nil)

        let row = list.items[1]
        #expect(row.accessories == [
            ExtensionListAccessory(text: "3000", tint: "green", help: "127.0.0.1:3000, [::1]:3000: reachable only from this Mac", style: .tag),
            ExtensionListAccessory(text: "9229", tint: "orange", help: "0.0.0.0:9229: reachable from other devices on your network", style: .tag),
        ])
        for keyword in ["3000", "9229", "[::1]:3000", "4242", "node server.js --port 3000", "/opt/homebrew/bin/node"] {
            #expect(row.keywords.contains(keyword))
        }
    }

    @Test("a process with more than two ports shows the first and a count of the rest")
    func manyPorts() async throws {
        let fake = FakePorts()
        fake.listen(.fake(1111, "Surge"), at: ("127.0.0.1", 6171), ("0.0.0.0", 6152), ("0.0.0.0", 6153), ("127.0.0.1", 49160))
        fake.listen(.fake(721, "ControlCenter"), at: ("0.0.0.0", 5000), ("0.0.0.0", 7000), ("::", 7000))
        let list = try await PrismTestHost(PortManager(fake: fake)).list(command)
        #expect(list.items.map { $0.accessories.map(\.text) } == [["5000", "7000"], ["6152", "+3"]])
        #expect(list.items[1].accessories.last == ExtensionListAccessory(text: "+3", help: "6153, 6171, 49160", style: .tag))
    }

    @Test("a port the user named is found by its name and shows it in the detail")
    func portNames() async throws {
        let prism = try await PrismTestHost(
            PortManager(fake: typicalMac()), preferences: [PortManager.PreferenceID.portNames: .string("3000 Web, 5432=Postgres")]
        )
        let row = try #require(try await prism.list(command).items.first { $0.id == nodeRow })
        #expect(row.keywords.contains("Web"))
        #expect(row.accessories.map(\.text) == ["3000", "9229"])
        #expect(row.accessories[0].help == "Web, 127.0.0.1:3000, [::1]:3000: reachable only from this Mac")
        #expect(row.detail?.metadata.prefix(2).map(\.label) == ["Port 3000 (Web)", "Port 9229"])
    }

    @Test("filters keep the processes with a port that reaches that far, and only those ports")
    func filters() async throws {
        let fake = typicalMac()
        fake.listen(.fake(900, "vite"), at: ("192.168.1.20", 5173))
        let prism = try await PrismTestHost(PortManager(fake: fake))
        typealias FilterID = PortManager.FilterID

        #expect(try await prism.list(command).filters.map(\.id) == [FilterID.all, FilterID.localhost, FilterID.network, FilterID.interface])
        #expect(try await prism.list(command, filter: FilterID.all).items.map(\.title) == ["launchd", "node", "vite", "postgres"])

        let localhost = try await prism.list(command, filter: FilterID.localhost)
        #expect(localhost.items.map(\.title) == ["node"])
        #expect(localhost.items[0].accessories.map(\.text) == ["3000"])

        let network = try await prism.list(command, filter: FilterID.network)
        #expect(network.items.map(\.title) == ["launchd", "postgres", "node"])
        #expect(network.items[2].accessories.map(\.text) == ["9229"])
        // A kill closes every port, so the row's actions and detail still name them all.
        #expect(network.items[2].primaryAction?.confirmationMessage
            == "“node” (PID 4242) stops listening on ports 3000 and 9229 and quits.")
        #expect(network.items[2].detail?.subtitle == "Ports 3000, 9229")
        #expect(network.items[2].action(id: "\(ActionID.openInBrowser):3000") != nil)

        let interface = try await prism.list(command, filter: FilterID.interface)
        #expect(interface.items.map(\.title) == ["vite"])
        #expect(interface.items[0].accessories == [
            ExtensionListAccessory(text: "5173", tint: "blue", help: "192.168.1.20:5173: reachable only through this address", style: .tag),
        ])
    }

    @Test("an empty list says nothing is listening, or nothing matches the filter")
    func emptyStates() async throws {
        let prism = try await PrismTestHost(PortManager(fake: FakePorts()))
        #expect(try await prism.list(command).emptyMessage?.title == "No Open Ports")
        let typical = try await PrismTestHost(PortManager(fake: typicalMac()))
        let interface = try await typical.list(command, filter: PortManager.FilterID.interface)
        #expect(interface.items.isEmpty)
        #expect(interface.emptyMessage?.title == "No Ports on a Specific Interface")
    }

    @Test("the user's own process can be killed, force killed, have its parent killed, or opened on each port")
    func ownActions() async throws {
        let list = try await PrismTestHost(PortManager(fake: typicalMac())).list(command)
        let row = try #require(list.items.first { $0.id == nodeRow })
        // Kills stay at the top; opening, showing, and copying are submenus.
        #expect(row.actions.map(\.id) == [
            ActionID.kill, ActionID.forceKill, ActionID.killParent, ActionID.browserMenu, ActionID.finderMenu, ActionID.copyMenu,
        ])
        #expect(row.actions.map(\.actions).map { $0.map(\.id) } == [
            [], [], [],
            ["\(ActionID.openInBrowser):3000", "\(ActionID.openInBrowser):9229"],
            [ActionID.showInFinder, ActionID.showParentInFinder],
            [ActionID.copyPID, ActionID.copyPath, ActionID.copyCommandLine],
        ])
        #expect(row.actions.suffix(3).map(\.title) == ["Open in Browser", "Show in Finder", "Copy"])
        #expect(row.action(id: ActionID.copyPath)?.kind == .copy(text: "/opt/homebrew/bin/node"))
        #expect(row.allActions.filter { $0.style == .destructive }.count == 3)
        #expect(row.primaryAction?.confirmationMessage == "“node” (PID 4242) stops listening on ports 3000 and 9229 and quits.")
        #expect(row.action(id: ActionID.killParent)?.confirmationMessage == "“npm” (PID 4200), which started “node”, quits.")
        #expect(row.action(id: ActionID.browserMenu)?.actions.map(\.title) == ["Open 3000 in Browser", "Open 9229 in Browser"])
        #expect(row.action(id: "\(ActionID.openInBrowser):3000")?.kind == .open(url: URL(string: "http://localhost:3000")!))
        #expect(row.action(id: "\(ActionID.openInBrowser):3000")?.shortcut == ExtensionShortcut("cmd+o"))
        #expect(row.action(id: ActionID.copyPID)?.kind == .copy(text: "4242"))
        #expect(row.action(id: ActionID.copyCommandLine)?.kind == .copy(text: "node server.js --port 3000"))

        let postgresRow = try #require(list.items.last)
        // Postgres's parent is launchd, which is never offered.
        #expect(postgresRow.action(id: ActionID.killParent) == nil)
        // One port opens directly, with no submenu around it.
        #expect(postgresRow.actions.map(\.id).contains("\(ActionID.openInBrowser):5432"))
        #expect(postgresRow.action(id: "\(ActionID.openInBrowser):5432")?.title == "Open in Browser")
        #expect(postgresRow.primaryAction?.confirmationMessage == "“postgres” (PID 610) stops listening on port 5432 and quits.")
    }

    @Test("another user's process names its owner, offers no kill, and copies a sudo kill instead")
    func otherUsersProcess() async throws {
        let fake = typicalMac()
        fake.listen(.fake(88, "httpd", user: root, path: "/usr/sbin/httpd"), at: ("0.0.0.0", 80))
        let list = try await PrismTestHost(PortManager(fake: fake)).list(command)
        let launchd = try #require(list.items.first)
        #expect(launchd.subtitle == "root")
        // launchd is never offered: killing it takes the Mac down.
        #expect(launchd.actions.map(\.id) == ["\(ActionID.openInBrowser):22", ActionID.showInFinder, ActionID.copyMenu])
        #expect(launchd.action(id: ActionID.copyMenu)?.actions.map(\.id) == [ActionID.copyPID, ActionID.copyPath])

        let httpd = try #require(list.items.first { $0.title == "httpd" })
        #expect(httpd.allActions.map(\.id) == [
            "\(ActionID.openInBrowser):80", ActionID.showInFinder, ActionID.copyMenu, ActionID.copyPID, ActionID.copyPath,
            ActionID.copyKillCommand,
        ])
        #expect(httpd.action(id: ActionID.copyKillCommand)?.kind == .copy(text: "sudo kill 88"))
    }

    @Test("Open in Browser uses localhost, or the one address a server is bound to")
    func browserURL() async throws {
        let fake = FakePorts()
        fake.listen(.fake(900, "vite"), at: ("192.168.1.20", 5173))
        fake.listen(.fake(901, "dev"), at: ("fe80::1", 8080))
        let list = try await PrismTestHost(PortManager(fake: fake)).list(command)
        #expect(zip(list.items, [5173, 8080]).map { $0.action(id: "\(ActionID.openInBrowser):\($1)")?.kind } == [
            .open(url: URL(string: "http://192.168.1.20:5173")!),
            .open(url: URL(string: "http://[fe80::1]:8080")!),
        ])
    }

    @Test("the detail shows the command line, and every fact about the process in its Information block")
    func detail() async throws {
        let list = try await PrismTestHost(PortManager(fake: typicalMac())).list(command)
        let detail = try #require(list.items[1].detail)
        #expect(detail.title == "node")
        #expect(detail.subtitle == "Ports 3000, 9229")
        #expect(detail.markdown == """
        ```
        node server.js --port 3000
        ```
        """)
        #expect(detail.sections.isEmpty)
        #expect(detail.metadata == [
            ExtensionMetadataRow(label: "Port 3000", value: "127.0.0.1:3000, [::1]:3000 · This Mac only"),
            ExtensionMetadataRow(label: "Port 9229", value: "0.0.0.0:9229 · Every network interface"),
            ExtensionMetadataRow(label: "PID", value: "4242"),
            ExtensionMetadataRow(label: "User", value: "jane (501)"),
            ExtensionMetadataRow(label: "Parent", value: "npm (4200)"),
            ExtensionMetadataRow(label: "Path", value: "/opt/homebrew/bin/node"),
            ExtensionMetadataRow(label: "Parent Path", value: "/usr/local/bin/npm"),
            ExtensionMetadataRow(label: "Started", date: Date(timeIntervalSince1970: TimeInterval(startSeconds))),
        ])

        // Another user's arguments can't be read.
        let launchd = try #require(list.items[0].detail)
        #expect(launchd.markdown == nil)
        #expect(launchd.subtitle == "Port 22")
        #expect(launchd.metadata.map(\.label) == ["Port 22", "PID", "User", "Path", "Started"])
        #expect(launchd.metadata.map(\.value)[0...2] == ["0.0.0.0:22, [::]:22 · Every network interface", "1", "root (0)"])
        // A program started without arguments still shows its command line.
        #expect(list.items[2].detail?.markdown == "```\n/opt/homebrew/opt/postgresql@17/bin/postgres\n```")
    }

    @Test("a Prism without submenus that runs one is asked to update")
    func submenuOnOlderPrism() async throws {
        let prism = try await PrismTestHost(PortManager(fake: typicalMac()))
        #expect(try await prism.perform(ActionID.copyMenu, on: nodeRow, in: command)
            == ExtensionActionResult(.failed(message: "Update Prism to open this menu.")))
    }

    @Test("Show Parent in Finder reveals the program that started the server")
    func revealParent() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(PortManager(fake: fake))
        #expect(try await prism.perform(ActionID.showParentInFinder, on: nodeRow, in: command) == .done)
        #expect(fake.revealed == ["/usr/local/bin/npm"])
    }

    @Test("an app's process shows its app's icon, and Show in Finder reveals its own bundle")
    func apps() async throws {
        let xcodePython = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app"
        let fake = FakePorts(bundleIdentifiers: [
            xcodePython: "org.python.python",
            "/Applications/Docker.app": "com.docker.docker",
        ])
        let python = RunningProcess.fake(77, "Python", path: "\(xcodePython)/Contents/MacOS/Python")
        let backend = RunningProcess.fake(78, "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        let vpnkit = RunningProcess.fake(79, "com.docker.vpnkit", path: "/Applications/Docker.app/Contents/Resources/bin/com.docker.vpnkit")
        let redis = RunningProcess.fake(80, "redis-server")
        fake.listen(python, at: ("127.0.0.1", 8000))
        fake.listen(backend, at: ("127.0.0.1", 2375))
        fake.listen(vpnkit, at: ("127.0.0.1", 2376))
        fake.listen(redis, at: ("127.0.0.1", 6379))
        let prism = try await PrismTestHost(PortManager(fake: fake))
        let list = try await prism.list(command)
        #expect(list.items.map(\.icon?.app) == ["com.docker.docker", "com.docker.docker", nil, "org.python.python"])
        #expect(list.items[2].icon == ExtensionIcon(symbol: "terminal", tint: "gray"))

        for process in [python, backend, vpnkit, redis] {
            let id = "\(process.pid)@1700000000.250000"
            #expect(try await prism.perform(ActionID.showInFinder, on: id, in: command) == .done)
        }
        #expect(fake.revealed == [
            xcodePython, "/Applications/Docker.app",
            "/Applications/Docker.app/Contents/Resources/bin/com.docker.vpnkit", "/usr/local/bin/redis-server",
        ])
    }

    // MARK: - Killing

    @Test("Kill sends SIGTERM and reloads once the process has quit")
    func kill() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(PortManager(fake: fake))
        #expect(try await prism.perform(ActionID.kill, on: nodeRow, in: command) == .reload(message: "Killed “node”."))
        #expect(fake.signals == [.init(pid: 4242, signal: SIGTERM)])
        #expect(try await prism.list(command).items.map(\.title) == ["launchd", "postgres"])
    }

    @Test("a process that ignores SIGTERM is reported still running, and Force Kill stops it")
    func forceKill() async throws {
        let fake = typicalMac()
        fake.ignoreTerminate(4242)
        let prism = try await PrismTestHost(PortManager(fake: fake))
        #expect(try await prism.perform(ActionID.kill, on: nodeRow, in: command)
            == .reload(message: "“node” is still running. Force Kill (⌘⇧⌫) stops it at once."))
        #expect(try await prism.perform(ActionID.forceKill, on: nodeRow, in: command) == .reload(message: "Killed “node”."))
        #expect(fake.signals == [.init(pid: 4242, signal: SIGTERM), .init(pid: 4242, signal: SIGKILL)])
    }

    @Test("Kill Parent stops the process that started the server")
    func killParent() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(PortManager(fake: fake))
        #expect(try await prism.perform(ActionID.killParent, on: nodeRow, in: command) == .reload(message: "Killed “npm”."))
        #expect(fake.signals == [.init(pid: 4200, signal: SIGTERM)])
    }

    @Test("an action on a process that stopped listening since the list loaded signals nothing")
    func stoppedListening() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(PortManager(fake: fake))
        fake.quit(4242)
        #expect(try await prism.perform(ActionID.kill, on: nodeRow, in: command) == .reload(message: "That process is no longer listening."))
        #expect(fake.signals.isEmpty)
    }

    @Test("a new process that got the old one's PID is a new row, so the old row signals nothing")
    func reusedPID() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(PortManager(fake: fake))
        fake.quit(4242)
        fake.listen(.fake(4242, "node", startedAt: startSeconds + 60), at: ("127.0.0.1", 3000))
        #expect(try await prism.perform(ActionID.kill, on: nodeRow, in: command) == .reload(message: "That process is no longer listening."))
        #expect(fake.signals.isEmpty)
        #expect(try await prism.list(command).items.map(\.id).contains("4242@1700000060.250000"))
    }

    @Test("a refused signal is shown as a failure")
    func notPermitted() async throws {
        let fake = typicalMac()
        fake.refuseSignals(4242)
        let prism = try await PrismTestHost(PortManager(fake: fake))
        #expect(try await prism.perform(ActionID.kill, on: nodeRow, in: command)
            == ExtensionActionResult(.failed(message: "You don’t have permission to kill “node”."), reload: true))
        #expect(fake.signals.isEmpty)
    }
}
