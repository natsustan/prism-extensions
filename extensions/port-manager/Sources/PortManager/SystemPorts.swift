import Darwin
import Foundation

/// The Mac itself: `netstat` for every user's sockets, libproc for the
/// current user's own, and Finder through `open -R`.
struct SystemPorts: PortSystem {
    /// `netstat` answers in milliseconds; a hung one shouldn't hold the list.
    static let netstatTimeout: Duration = .seconds(3)

    var currentUserID: uid_t { getuid() }

    /// macOS hides the socket table from a `netstat` started by a program
    /// that isn't signed with a Developer ID, such as a local build: it
    /// prints its header and no sockets. The current user's own sockets,
    /// which are the ones that can be killed, are always read through libproc
    /// as well.
    func listeningSockets() async -> SocketScan {
        let data = try? await CommandRunner.output(
            of: Netstat.executable, arguments: Netstat.arguments, timeout: Self.netstatTimeout
        )
        let everyone = data.flatMap { Netstat.listeners(in: String(decoding: $0, as: UTF8.self)) } ?? []
        let own = ProcessTable.currentUserListeners()
        return SocketScan(sockets: Self.merge(everyone, own), isCurrentUserOnly: everyone.isEmpty && !own.isEmpty)
    }

    /// The `netstat` sockets, then any it missed; `netstat`'s copy wins, as
    /// it carries the process name.
    static func merge(_ everyone: [SocketListener], _ own: [SocketListener]) -> [SocketListener] {
        func key(_ socket: SocketListener) -> String { "\(socket.pid) \(socket.host) \(socket.port)" }
        let listed = Set(everyone.map(key))
        return everyone + own.filter { !listed.contains(key($0)) }
    }

    func process(_ pid: pid_t) -> RunningProcess? {
        ProcessTable.process(pid)
    }

    func send(_ signal: Int32, to process: ProcessIdentity) throws(SignalError) {
        try ProcessTable.send(signal, to: process)
    }

    func isRunning(_ process: ProcessIdentity) -> Bool {
        ProcessTable.identity(process.pid) == process
    }

    func reveal(_ path: String) async throws {
        _ = try await CommandRunner.output(
            of: URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-R", path], timeout: .seconds(5)
        )
    }

    func bundleIdentifier(ofAppAt path: String) -> String? {
        Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    }
}
