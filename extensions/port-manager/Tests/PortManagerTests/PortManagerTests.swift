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

    let node = RunningProcess.fake(4242, "node", parent: 4200, arguments: ["node", "server.js", "--port", "3000"])
    let npm = RunningProcess.fake(4200, "npm")
    let postgres = RunningProcess.fake(610, "postgres", path: "/opt/homebrew/opt/postgresql@17/bin/postgres")
    let sshd = RunningProcess.fake(1, "launchd", user: root, parent: 0, path: "/sbin/launchd")

    /// node on localhost over IPv4 and IPv6, Postgres on every interface, and
    /// root's Remote Login.
    func typicalMac() -> FakePorts {
        let fake = FakePorts()
        fake.run(npm)
        fake.listen(node, at: ("127.0.0.1", 3000), ("::1", 3000))
        fake.listen(postgres, at: ("0.0.0.0", 5432), ("::", 5432))
        fake.listen(sshd, at: ("0.0.0.0", 22), ("::", 22), listedName: "launchd")
        return fake
    }

    @Test("lists one row per process and port, by port, with IPv4 and IPv6 sockets together")
    func rows() async throws {
        let prism = try await PrismTestHost(PortManager(fake: typicalMac()))
        let list = try await prism.list(command)
        #expect(list.items.map(\.id) == ["1:22", "4242:3000", "610:5432"])
        #expect(list.items.map(\.title) == ["22", "3000", "5432"])
        #expect(list.items.map(\.subtitle) == ["launchd", "node", "postgres"])
        #expect(list.filtering == .prism)
        #expect(list.error == nil)

        let nodeRow = list.items[1]
        #expect(nodeRow.accessories == [
            ExtensionListAccessory(text: "Localhost", symbol: "lock.fill", tint: "green", help: "Reachable only from this Mac"),
        ])
        #expect(nodeRow.keywords.contains("node server.js --port 3000"))
        #expect(nodeRow.keywords.contains("[::1]:3000"))
        #expect(nodeRow.keywords.contains("4242"))
        #expect(list.items[2].accessories.map(\.text) == ["Network"])
    }

    @Test("a port the user named shows its name before the process")
    func portNames() async throws {
        let prism = try await PrismTestHost(
            PortManager(fake: typicalMac()), preferences: [PortManager.PreferenceID.portNames: .string("3000 Web, 5432=Postgres")]
        )
        let list = try await prism.list(command)
        #expect(list.items.map(\.subtitle) == ["launchd", "Web · node", "Postgres · postgres"])
        #expect(list.items[1].detail?.title == "Port 3000 · Web")
        #expect(list.items[1].keywords.contains("Web"))
    }

    @Test("filters narrow the list by how far a port reaches")
    func filters() async throws {
        let fake = typicalMac()
        fake.listen(.fake(900, "vite"), at: ("192.168.1.20", 5173))
        let prism = try await PrismTestHost(PortManager(fake: fake))
        typealias FilterID = PortManager.FilterID

        #expect(try await prism.list(command).filters.map(\.id) == [FilterID.all, FilterID.localhost, FilterID.network, FilterID.interface])
        #expect(try await prism.list(command, filter: FilterID.all).items.map(\.title) == ["22", "3000", "5173", "5432"])
        #expect(try await prism.list(command, filter: FilterID.localhost).items.map(\.title) == ["3000"])
        #expect(try await prism.list(command, filter: FilterID.network).items.map(\.title) == ["22", "5432"])
        let interface = try await prism.list(command, filter: FilterID.interface)
        #expect(interface.items.map(\.title) == ["5173"])
        #expect(interface.items[0].accessories.map(\.text) == ["192.168.1.20"])
        #expect(interface.filters.count == 4)
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

    @Test("when only the user's own sockets could be read, the list says so")
    func currentUserOnly() async throws {
        let fake = FakePorts()
        fake.listen(node, at: ("127.0.0.1", 3000))
        fake.showOnlyCurrentUser()
        let list = try await PrismTestHost(PortManager(fake: fake)).list(command)
        #expect(list.items.map(\.title) == ["3000"])
        #expect(list.error == "Only your own processes are shown, because the system’s list of sockets couldn’t be read.")
    }

    @Test("the user's own process can be killed, force killed, or have its parent killed")
    func ownActions() async throws {
        let list = try await PrismTestHost(PortManager(fake: typicalMac())).list(command)
        let row = try #require(list.items.first { $0.id == "4242:3000" })
        #expect(row.actions.map(\.id) == [
            ActionID.kill, ActionID.forceKill, ActionID.killParent, ActionID.openInBrowser,
            ActionID.showInFinder, ActionID.copyPID, ActionID.copyCommandLine,
        ])
        #expect(row.actions.filter { $0.style == .destructive }.count == 3)
        #expect(row.primaryAction?.confirmationMessage == "“node” (PID 4242) stops listening on port 3000 and quits.")
        #expect(row.action(id: ActionID.killParent)?.confirmationMessage == "“npm” (PID 4200), which started “node”, quits.")
        #expect(row.action(id: ActionID.openInBrowser)?.kind == .open(url: URL(string: "http://localhost:3000")!))
        #expect(row.action(id: ActionID.copyPID)?.kind == .copy(text: "4242"))
        #expect(row.action(id: ActionID.copyCommandLine)?.kind == .copy(text: "node server.js --port 3000"))
        // Postgres's parent is launchd, which is never offered.
        #expect(list.items.first { $0.id == "610:5432" }?.action(id: ActionID.killParent) == nil)
    }

    @Test("another user's process shows its owner and offers no kill")
    func otherUsersProcess() async throws {
        let list = try await PrismTestHost(PortManager(fake: typicalMac())).list(command)
        let row = try #require(list.items.first)
        #expect(row.accessories.map(\.text) == ["root", "Network"])
        #expect(row.actions.map(\.id) == [ActionID.openInBrowser, ActionID.showInFinder, ActionID.copyPID])
    }

    @Test("Open in Browser uses localhost, or the one address a server is bound to")
    func browserURL() async throws {
        let fake = FakePorts()
        fake.listen(.fake(900, "vite"), at: ("192.168.1.20", 5173))
        fake.listen(.fake(901, "dev"), at: ("fe80::1", 8080))
        let list = try await PrismTestHost(PortManager(fake: fake)).list(command)
        #expect(list.items.map { $0.action(id: ActionID.openInBrowser)?.kind } == [
            .open(url: URL(string: "http://192.168.1.20:5173")!),
            .open(url: URL(string: "http://[fe80::1]:8080")!),
        ])
    }

    @Test("the detail shows where it listens, the process, and its command line")
    func detail() async throws {
        let list = try await PrismTestHost(PortManager(fake: typicalMac())).list(command)
        let detail = try #require(list.items[1].detail)
        #expect(detail.title == "Port 3000")
        #expect(detail.subtitle == "node")
        #expect(detail.markdown == "```\nnode server.js --port 3000\n```")
        #expect(detail.sections.map(\.title) == ["Listening On", "Process"])
        #expect(detail.sections[0].rows.map(\.label) == ["127.0.0.1:3000", "[::1]:3000"])
        #expect(detail.sections[0].rows.map(\.value) == ["This Mac only", "This Mac only"])
        #expect(detail.sections[1].rows.map(\.label) == ["Name", "PID", "User", "Parent", "Path"])
        #expect(detail.sections[1].rows.map(\.value) == ["node", "4242", "jane", "npm (PID 4200)", "/usr/local/bin/node"])
        #expect(detail.metadata == [ExtensionMetadataRow(label: "Started", date: Date(timeIntervalSince1970: TimeInterval(startSeconds)))])
        // Another user's arguments can't be read.
        #expect(list.items[0].detail?.markdown == nil)
    }

    @Test("an app's process shows its app's icon, and Show in Finder reveals its own bundle")
    func apps() async throws {
        let xcodePython = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app"
        let fake = FakePorts(bundleIdentifiers: [
            xcodePython: "org.python.python",
            "/Applications/Docker.app": "com.docker.docker",
        ])
        fake.listen(.fake(77, "Python", path: "\(xcodePython)/Contents/MacOS/Python"), at: ("127.0.0.1", 8000))
        fake.listen(.fake(78, "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"), at: ("127.0.0.1", 2375))
        fake.listen(.fake(79, "com.docker.vpnkit", path: "/Applications/Docker.app/Contents/Resources/bin/com.docker.vpnkit"), at: ("127.0.0.1", 2376))
        fake.listen(.fake(80, "redis-server"), at: ("127.0.0.1", 6379))
        let prism = try await PrismTestHost(PortManager(fake: fake))
        let list = try await prism.list(command)
        #expect(list.items.map(\.icon?.app) == ["com.docker.docker", "com.docker.docker", nil, "org.python.python"])
        #expect(list.items[2].icon == ExtensionIcon(symbol: "terminal", tint: "gray"))

        for item in ["77:8000", "78:2375", "79:2376", "80:6379"] {
            #expect(try await prism.perform(ActionID.showInFinder, on: item, in: command) == .done)
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
        #expect(try await prism.perform(ActionID.kill, on: "4242:3000", in: command) == .reload(message: "Killed “node”."))
        #expect(fake.signals == [.init(pid: 4242, signal: SIGTERM)])
        #expect(try await prism.list(command).items.map(\.title) == ["22", "5432"])
    }

    @Test("a process that ignores SIGTERM is reported still running, and Force Kill stops it")
    func forceKill() async throws {
        let fake = typicalMac()
        fake.ignoreTerminate(4242)
        let prism = try await PrismTestHost(PortManager(fake: fake))
        #expect(try await prism.perform(ActionID.kill, on: "4242:3000", in: command)
            == .reload(message: "“node” is still running. Force Kill (⌘⇧⌫) stops it at once."))
        #expect(try await prism.perform(ActionID.forceKill, on: "4242:3000", in: command) == .reload(message: "Killed “node”."))
        #expect(fake.signals == [.init(pid: 4242, signal: SIGTERM), .init(pid: 4242, signal: SIGKILL)])
    }

    @Test("Kill Parent stops the process that started the server")
    func killParent() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(PortManager(fake: fake))
        #expect(try await prism.perform(ActionID.killParent, on: "4242:3000", in: command) == .reload(message: "Killed “npm”."))
        #expect(fake.signals == [.init(pid: 4200, signal: SIGTERM)])
    }

    @Test("an action on a port that has closed since the list loaded signals nothing")
    func closedPort() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(PortManager(fake: fake))
        fake.quit(4242)
        #expect(try await prism.perform(ActionID.kill, on: "4242:3000", in: command) == .reload(message: "Port 3000 is no longer open."))
        #expect(fake.signals.isEmpty)
    }

    @Test("a server restarted under a new PID is a new row, so the old row signals nothing")
    func restartedServer() async throws {
        let fake = typicalMac()
        let prism = try await PrismTestHost(PortManager(fake: fake))
        fake.quit(4242)
        fake.listen(.fake(4300, "node"), at: ("127.0.0.1", 3000))
        #expect(try await prism.perform(ActionID.kill, on: "4242:3000", in: command) == .reload(message: "Port 3000 is no longer open."))
        #expect(fake.signals.isEmpty)
        #expect(try await prism.list(command).items.map(\.id).contains("4300:3000"))
    }

    @Test("a refused signal is shown as a failure")
    func notPermitted() async throws {
        let fake = typicalMac()
        fake.refuseSignals(4242)
        let prism = try await PrismTestHost(PortManager(fake: fake))
        #expect(try await prism.perform(ActionID.kill, on: "4242:3000", in: command)
            == ExtensionActionResult(.failed(message: "You don’t have permission to kill “node”."), reload: true))
        #expect(fake.signals.isEmpty)
    }
}
