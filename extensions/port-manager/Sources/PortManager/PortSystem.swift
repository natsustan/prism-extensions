import Darwin
import Foundation

/// What Port Manager reads from and does to the Mac: listening sockets,
/// processes, signals, and Finder. Tests pass a fake.
protocol PortSystem: Sendable {
    var currentUserID: uid_t { get }
    /// Every listening TCP socket that can be seen.
    func listeningSockets() async -> SocketScan
    /// The process with this PID, or nil when there is none.
    func process(_ pid: pid_t) -> RunningProcess?
    /// Sends `signal` to the process only while its PID still belongs to it.
    func send(_ signal: Int32, to process: ProcessIdentity) throws(SignalError)
    /// Whether the process is still running: false once it has exited, even
    /// while it waits as a zombie for its parent, since its sockets are closed.
    func isRunning(_ process: ProcessIdentity) -> Bool
    /// Selects the file in a Finder window.
    func reveal(_ path: String) async throws
    /// The bundle identifier of the app at `path`, for its icon.
    func bundleIdentifier(ofAppAt path: String) -> String?
}

/// One listening socket: a process, the address it is bound to, and the port.
struct SocketListener: Hashable, Sendable {
    let pid: pid_t
    /// The bound address as written in a URL host, without brackets:
    /// `127.0.0.1`, `0.0.0.0`, `::1`, `::`.
    let host: String
    let port: Int
    /// The short name the socket table gives, used when the process can't be
    /// read.
    var processName: String?
}

struct SocketScan: Sendable {
    var sockets: [SocketListener]
    /// Whether only the current user's processes could be seen, because the
    /// system-wide socket table couldn't be read.
    var isCurrentUserOnly = false
}

/// A PID and its start time: together they name one process even after the
/// kernel hands the PID to another.
struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: Int
    let startMicroseconds: Int
}

struct RunningProcess: Hashable, Sendable {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let userID: uid_t
    let userName: String?
    /// The kernel's short name, cut to 16 characters.
    let shortName: String
    /// The executable, when it can be read.
    let path: String?
    /// The arguments it was started with; readable only for the current
    /// user's processes.
    let arguments: [String]?

    var pid: pid_t { identity.pid }

    var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(identity.startSeconds) + TimeInterval(identity.startMicroseconds) / 1_000_000)
    }

    /// The executable's full name, which the kernel's short name may cut.
    var name: String {
        path.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? shortName
    }

    var commandLine: String? {
        guard let arguments, !arguments.isEmpty else { return nil }
        return arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    /// The app whose icon the process shows: its own bundle, or else the
    /// outermost app it ships in, such as Docker for its backend.
    var appPath: String? {
        if let bundlePath { return bundlePath }
        guard let path else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[...index].joined(separator: "/")
    }

    /// The bundle the executable is the program of (`Python.app` for
    /// `Python.app/Contents/MacOS/Python`), even when that bundle sits inside
    /// another, as Python does inside Xcode.
    var bundlePath: String? {
        guard let path else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 3, components[components.count - 4].hasSuffix(".app"),
              components[components.count - 3] == "Contents", components[components.count - 2] == "MacOS" else { return nil }
        return components.dropLast(3).joined(separator: "/")
    }
}

enum SignalError: Error, Equatable {
    /// The process has exited, or its PID now belongs to another process.
    case gone
    case notPermitted
    case failed(Int32)
}
