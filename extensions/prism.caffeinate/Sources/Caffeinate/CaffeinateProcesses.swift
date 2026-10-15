import Darwin
import Foundation

/// The caffeinate processes Caffeinate sees and stops.
protocol CaffeinateProcesses: Sendable {
    func isRunning() -> Bool
    func stopAll() throws
}

/// The current user's `/usr/bin/caffeinate` processes, read with libproc
/// rather than by running `ps`.
struct SystemCaffeinateProcesses: CaffeinateProcesses {
    let inspector = ProcessInspector(executableURL: URL(fileURLWithPath: "/usr/bin/caffeinate"))

    func isRunning() -> Bool {
        !inspector.matchingProcesses().isEmpty
    }

    func stopAll() throws {
        try inspector.terminate(inspector.matchingProcesses())
    }
}

/// A process identity that survives PID reuse: the start time changes when the
/// kernel hands the PID to another process.
struct ProcessRecord: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

/// Finds the current user's processes running one exact executable.
struct ProcessInspector: Sendable {
    let executablePath: String
    private let executableName: String

    init(executableURL: URL) {
        executableName = executableURL.lastPathComponent
        var resolved = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        executablePath = realpath(executableURL.path, &resolved) != nil
            ? Self.string(resolved)
            : executableURL.path
    }

    func matchingProcesses() -> [ProcessRecord] {
        Self.userProcessIDs().compactMap(record)
    }

    /// The live record for `pid` when it still runs this executable for the
    /// current user.
    func record(for pid: pid_t) -> ProcessRecord? {
        guard pid > 0 else { return nil }

        var name = [CChar](repeating: 0, count: 64)
        let nameLength = proc_name(pid, &name, UInt32(name.count))
        guard nameLength == executableName.utf8.count,
              Self.string(Array(name.prefix(Int(nameLength))) + [0]) == executableName else { return nil }

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return nil }

        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              Self.string(path) == executablePath else { return nil }

        return ProcessRecord(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    /// Sends SIGTERM to each record that is still the same process; a PID may
    /// have been reused since it was read.
    func terminate(_ records: [ProcessRecord]) throws {
        for record in records {
            guard self.record(for: record.pid) == record else { continue }
            if kill(record.pid, SIGTERM) != 0, errno != ESRCH {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        }
    }

    private static func userProcessIDs() -> ArraySlice<pid_t> {
        let bytesNeeded = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard bytesNeeded > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<pid_t>.size + 64)
        let bytesRead = proc_listpids(
            UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard bytesRead > 0 else { return [] }
        return pids.prefix(Int(bytesRead) / MemoryLayout<pid_t>.size)
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
