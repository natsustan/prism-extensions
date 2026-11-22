import Darwin
import Foundation

/// What Kill Process reads from and does to the Mac: running processes,
/// signals, app launches, and Finder. Tests pass a fake.
protocol ProcessSystem: Sendable {
    var currentUserID: uid_t { get }
    var currentPID: pid_t { get }
    /// A fresh snapshot of running processes with live CPU and memory usage.
    func snapshot() async throws -> [ProcessRecord]
    /// Kernel metadata for one PID, or nil when it is gone.
    func process(_ pid: pid_t) -> KernelProcessInfo?
    /// Sends `signal` only while `process`'s PID still belongs to the same start time.
    func send(_ signal: Int32, to process: ProcessIdentity) throws(SignalError)
    /// Whether the process is still live (not exited or turned zombie).
    func isRunning(_ process: ProcessIdentity) -> Bool
    func fileExists(at path: String) -> Bool
    /// Launches an application or preference pane bundle at `path`.
    func open(_ path: String) async throws
    /// Selects a file or bundle in a Finder window.
    func reveal(_ path: String) async throws
    /// Bundle identifier of the `.app` at `path`, for its icon.
    func bundleIdentifier(ofAppAt path: String) -> String?
}

/// A PID and its start time: together they name one process even after the
/// kernel hands the PID to another.
struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: Int
    let startMicroseconds: Int

    init(pid: pid_t, startSeconds: Int, startMicroseconds: Int) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    init?(key: String) {
        guard let atIndex = key.firstIndex(of: "@"),
              let dotIndex = key[key.index(after: atIndex)...].firstIndex(of: ".") else {
            return nil
        }
        guard let pid = pid_t(key[..<atIndex]),
              let seconds = Int(key[key.index(after: atIndex)..<dotIndex]),
              let microseconds = Int(key[key.index(after: dotIndex)...]) else {
            return nil
        }
        self.init(pid: pid, startSeconds: seconds, startMicroseconds: microseconds)
    }

    var key: String {
        "\(pid)@\(startSeconds).\(startMicroseconds)"
    }
}

/// Process metadata read directly from the kernel (`sysctl` / `libproc`).
struct KernelProcessInfo: Hashable, Sendable {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let userID: uid_t
    /// The kernel's short name, cut to `MAXCOMLEN` (16 characters).
    let shortName: String
    /// Full executable path when readable (`proc_pidpath`).
    let path: String?
}

enum ProcessKind: Hashable, Sendable {
    case app
    case prefPane
    case binary
}

/// A running process combined from `ps` metrics and kernel identity.
struct ProcessRecord: Hashable, Sendable {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let userID: uid_t
    let shortName: String
    let path: String?
    let comm: String
    let cpu: Double
    let memoryBytes: UInt64

    var pid: pid_t { identity.pid }

    func isKillable(by userID: uid_t, excludingPID: pid_t) -> Bool {
        self.userID == userID && pid > 1 && pid != excludingPID
    }

    /// The full executable name when a path is known, else the basename of `comm`.
    var name: String {
        if let path, !path.isEmpty, path != "-" {
            let component = URL(fileURLWithPath: path).lastPathComponent
            if !component.isEmpty { return component }
        }
        if !comm.isEmpty, comm != "-" {
            let component = URL(fileURLWithPath: comm).lastPathComponent
            if !component.isEmpty { return component }
        }
        return shortName
    }

    private var effectivePath: String? {
        if let path, !path.isEmpty { return path }
        return comm.isEmpty ? nil : comm
    }

    private var absolutePath: String? {
        if let path, path.hasPrefix("/") { return path }
        return comm.hasPrefix("/") ? comm : nil
    }

    /// The outermost `.app` bundle containing this process, used both to
    /// group helper processes with their app and to pick the app's icon.
    var outerAppBundlePath: String? {
        Self.bundlePrefix(in: effectivePath, suffix: ".app")
    }

    /// The `.app` bundle when this process is that bundle's own main
    /// executable (`<Something>.app/Contents/MacOS/<Executable>`).
    var bundlePath: String? {
        Self.directAppBundlePath(in: absolutePath)
    }

    var prefPaneBundlePath: String? {
        Self.bundlePrefix(in: effectivePath, suffix: ".prefPane")
    }

    var kind: ProcessKind {
        if prefPaneBundlePath != nil { return .prefPane }
        if outerAppBundlePath != nil { return .app }
        return .binary
    }

    /// Display name of the enclosing `.app` bundle without the `.app` suffix.
    var appName: String? {
        outerAppBundlePath.flatMap(Self.appDisplayName(from:))
    }

    /// Launchable bundle path when restarting a process cleanly via
    /// `/usr/bin/open` is well-defined: a top-level `.app` bundle's main
    /// executable (never an embedded helper `.app`) or a preference pane.
    var restartLaunchPath: String? {
        if let bundlePath, bundlePath == outerAppBundlePath { return bundlePath }
        return prefPaneBundlePath
    }

    var revealPath: String? {
        Self.revealPath(for: absolutePath)
    }

    static func appDisplayName(from bundlePath: String) -> String? {
        let last = URL(fileURLWithPath: bundlePath).lastPathComponent
        guard last.hasSuffix(".app"), last.count > 4 else { return nil }
        return String(last.dropLast(4))
    }

    static func directAppBundlePath(in path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 3,
              components[components.count - 4].hasSuffix(".app"),
              components[components.count - 4].count > 4,
              components[components.count - 3] == "Contents",
              components[components.count - 2] == "MacOS" else { return nil }
        return components.dropLast(3).joined(separator: "/")
    }

    static func revealPath(for path: String?, aggregated: Bool = false) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        if aggregated, let outer = bundlePrefix(in: path, suffix: ".app") {
            return outer
        }
        return directAppBundlePath(in: path) ?? bundlePrefix(in: path, suffix: ".prefPane") ?? path
    }

    static func bundlePrefix(in path: String?, suffix: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(suffix) && $0.count > suffix.count }) else {
            return nil
        }
        let joined = components[...index].joined(separator: "/")
        return joined.isEmpty ? nil : joined
    }
}

enum SignalError: Error, Equatable {
    /// The process has exited, or its PID now belongs to another process.
    case gone
    case notPermitted
    case failed(Int32)
}
